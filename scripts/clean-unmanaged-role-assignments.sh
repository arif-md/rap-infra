#!/usr/bin/env bash
# scripts/clean-unmanaged-role-assignments.sh
#
# PURPOSE:
#   Detects role assignments that exist in Azure but are NOT managed by the
#   current deployment stack, and removes them so the stack can recreate and
#   own them cleanly. This prevents RoleAssignmentExists (ARM 409) failures
#   that occur when an Azure Deployment Stack tries to manage a role assignment
#   it doesn't own — for example, when an environment was first provisioned
#   without deployment stacks enabled (locally or via pre-stacks CI), or when
#   a conditional exclusion on a prior run caused the stack to lose ownership.
#
# BEHAVIOR BY CASE:
#   - No stack exists (fresh provision)      → exits without changes
#   - Assignment is in the stack             → left untouched (stack manages it)
#   - Assignment exists, NOT in the stack   → deleted so stack can recreate it
#   - Assignment doesn't exist              → nothing to do (stack will create it)
#   - azd down then up                      → stack deletes on down; no assignment
#                                             to clean; stack recreates on up
#
# ROLE ASSIGNMENTS CHECKED:
#   - App Configuration Data Reader (scoped to App Config → backend identity)
#   - SQL Server Contributor        (scoped to SQL Server → sql-admin identity)
#
# REQUIRED ENV VARS:
#   AZURE_ENV_NAME          azd environment name (e.g. dev, test, train, prod)
#   AZURE_RESOURCE_GROUP    Azure resource group name

set -euo pipefail

info()    { echo "  ℹ  $*"; }
success() { echo "  ✅ $*"; }
warning() { echo "  ⚠️  $*"; }
removed() { echo "  🗑️  $*"; }

AZURE_ENV_NAME="${AZURE_ENV_NAME:-}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

if [ -z "$AZURE_ENV_NAME" ] || [ -z "$AZURE_RESOURCE_GROUP" ]; then
  info "AZURE_ENV_NAME or AZURE_RESOURCE_GROUP not set — skipping."
  exit 0
fi

STACK_NAME="azd-${AZURE_ENV_NAME}"

echo ""
echo "Checking for unmanaged role assignments (stack: ${STACK_NAME}, RG: ${AZURE_RESOURCE_GROUP})..."

# ── Get deployment stack's managed resource IDs ──────────────────────────────
# Stack resource IDs are compared case-insensitively (ARM IDs are case-insensitive).
STACK_RESOURCES=$(az stack group show \
  --name        "$STACK_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query       "resources[*].id" \
  --output      tsv 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' || echo "")

if [ -z "$STACK_RESOURCES" ]; then
  info "Stack '${STACK_NAME}' not found or has no managed resources — nothing to clean."
  exit 0
fi

# ── Role definition IDs ───────────────────────────────────────────────────────
APP_CONFIG_DATA_READER_ROLE="516239f1-63e1-4d78-a4de-a74fb236a071"
SQL_SERVER_CONTRIBUTOR_ROLE="6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"

DELETED_COUNT=0

# check_and_clean <scope-resource-id> <role-definition-id> <label>
# Lists role assignments for <role> scoped to <resource>.
# Deletes any that are not in the current deployment stack's managed resources.
check_and_clean() {
  local SCOPE_ID="$1"
  local ROLE_ID="$2"
  local LABEL="$3"

  if [ -z "$SCOPE_ID" ]; then
    info "${LABEL}: resource not found in RG — skipping."
    return
  fi

  # List assignments for this role scoped exactly to this resource
  ASSIGNMENT_IDS=$(az role assignment list \
    --scope  "$SCOPE_ID" \
    --role   "$ROLE_ID" \
    --query  "[].id" \
    --output tsv 2>/dev/null || echo "")

  if [ -z "$ASSIGNMENT_IDS" ]; then
    info "${LABEL}: no assignment found — stack will create it."
    return
  fi

  while IFS= read -r RA_ID; do
    [ -z "$RA_ID" ] && continue
    RA_ID_LOWER=$(echo "$RA_ID" | tr '[:upper:]' '[:lower:]')

    if echo "$STACK_RESOURCES" | grep -qF "$RA_ID_LOWER"; then
      success "${LABEL}: assignment is stack-managed — leaving untouched."
    else
      warning "${LABEL}: assignment exists but is NOT managed by stack '${STACK_NAME}'."
      info    "          Deleting so the deployment stack can recreate and own it..."
      az role assignment delete --ids "$RA_ID" --output none
      DELETED_COUNT=$((DELETED_COUNT + 1))
      removed "${LABEL}: unmanaged assignment deleted."
    fi
  done <<< "$ASSIGNMENT_IDS"
}

# ── App Configuration Data Reader ────────────────────────────────────────────
APP_CONFIG_ID=$(az appconfig list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].id" \
  --output tsv 2>/dev/null || echo "")

check_and_clean "$APP_CONFIG_ID" "$APP_CONFIG_DATA_READER_ROLE" "App Config Data Reader"

# ── SQL Server Contributor ────────────────────────────────────────────────────
SQL_SERVER_ID=$(az sql server list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].id" \
  --output tsv 2>/dev/null || echo "")

check_and_clean "$SQL_SERVER_ID" "$SQL_SERVER_CONTRIBUTOR_ROLE" "SQL Server Contributor"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$DELETED_COUNT" -gt 0 ]; then
  echo "Cleaned ${DELETED_COUNT} unmanaged role assignment(s) — deployment stack will recreate and own them."
else
  echo "All role assignments are either stack-managed or absent — no action needed."
fi
