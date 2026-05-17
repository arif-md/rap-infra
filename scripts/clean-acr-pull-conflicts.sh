#!/bin/bash
###############################################################################
# clean-acr-pull-conflicts.sh
#
# Deletes AcrPull role assignments for this environment's managed identities
# on the shared ACR that are NOT owned by the current deployment stack.
#
# WHY THIS EXISTS
# ---------------
# Azure deployment stacks use deterministic GUIDs for role assignment names:
#   guid(acr.id, 'AcrPull', principalId)
# If a matching assignment already exists in Azure but was NOT created by the
# current deployment stack (e.g., from a run before stacks were enabled, or
# after an azd down/up that lost stack ownership), the stack cannot adopt it
# and fails with ARM 409 RoleAssignmentExists.
#
# This script detects and removes such orphaned assignments BEFORE azd provision
# runs, allowing the deployment stack to create them fresh and own them.
#
# SAFETY
# ------
# Only removes assignments for identities in the CURRENT environment's resource
# group. If an assignment IS owned by the current stack, it is left untouched
# (dev's owned assignments are never deleted). Other environments' identities
# are not in this resource group so their assignments are never affected.
###############################################################################

set -euo pipefail

info()    { echo -e "\033[1;34mℹ $1\033[0m" >&2; }
success() { echo -e "\033[1;32m✓ $1\033[0m" >&2; }
warning() { echo -e "\033[1;33m⚠ $1\033[0m" >&2; }
error()   { echo -e "\033[1;31m✗ $1\033[0m" >&2; }

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
ENV_NAME="${AZURE_ENV_NAME:-}"
ACR_NAME="${AZURE_ACR_NAME:-}"
ACR_RESOURCE_GROUP="${AZURE_ACR_RESOURCE_GROUP:-}"

if [ -z "$RESOURCE_GROUP" ] || [ -z "$ENV_NAME" ] || [ -z "$ACR_NAME" ]; then
  warning "AZURE_RESOURCE_GROUP, AZURE_ENV_NAME, or AZURE_ACR_NAME not set — skipping AcrPull conflict cleanup"
  exit 0
fi

STACK_NAME="azd-stack-${ENV_NAME}"

# Resolve ACR resource ID
if [ -n "$ACR_RESOURCE_GROUP" ]; then
  ACR_ID=$(az acr show -n "$ACR_NAME" -g "$ACR_RESOURCE_GROUP" --query id -o tsv 2>/dev/null || true)
else
  ACR_ID=$(az acr show -n "$ACR_NAME" --query id -o tsv 2>/dev/null || true)
fi

if [ -z "$ACR_ID" ]; then
  warning "ACR '$ACR_NAME' not found — skipping AcrPull conflict cleanup"
  exit 0
fi

info "Checking for unowned AcrPull assignments on '$ACR_NAME' for '$ENV_NAME' identities..."

# Get the deployment stack's managed resource IDs (lowercase for case-insensitive comparison)
STACK_RESOURCES=$(az stack group show \
  --name "$STACK_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "resources[].id" \
  -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)

# Get all managed identity principal IDs in this environment's resource group.
# These are the only principals whose assignments we may delete.
IDENTITY_PRINCIPAL_IDS=$(az identity list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[].principalId" \
  -o tsv 2>/dev/null || true)

if [ -z "$IDENTITY_PRINCIPAL_IDS" ]; then
  info "No managed identities found in '$RESOURCE_GROUP' — nothing to clean up"
  exit 0
fi

DELETED_COUNT=0

while IFS= read -r PRINCIPAL_ID; do
  [ -z "$PRINCIPAL_ID" ] && continue

  # Find the AcrPull assignment for this principal on the ACR (if any)
  ASSIGNMENT_ID=$(az role assignment list \
    --scope "$ACR_ID" \
    --assignee "$PRINCIPAL_ID" \
    --role AcrPull \
    --query "[0].id" \
    -o tsv 2>/dev/null || true)

  [ -z "$ASSIGNMENT_ID" ] && continue

  # Check if this assignment is in the stack's managed resources
  ASSIGNMENT_ID_LOWER=$(echo "$ASSIGNMENT_ID" | tr '[:upper:]' '[:lower:]')
  if echo "$STACK_RESOURCES" | grep -qiF "$ASSIGNMENT_ID_LOWER" 2>/dev/null; then
    info "  AcrPull for $PRINCIPAL_ID — owned by $STACK_NAME, keeping"
  else
    warning "  AcrPull for $PRINCIPAL_ID — NOT owned by $STACK_NAME, deleting (stack will recreate)"
    az role assignment delete --ids "$ASSIGNMENT_ID" 2>/dev/null || true
    DELETED_COUNT=$((DELETED_COUNT + 1))
  fi
done <<< "$IDENTITY_PRINCIPAL_IDS"

if [ "$DELETED_COUNT" -gt 0 ]; then
  success "Removed $DELETED_COUNT unowned AcrPull assignment(s) — deployment stack will recreate and own them"
else
  success "No unowned AcrPull conflicts detected"
fi
