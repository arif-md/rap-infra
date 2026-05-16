#!/usr/bin/env bash
# scripts/clean-unmanaged-role-assignments.sh
#
# PURPOSE:
#   Removes role assignments that would conflict with Azure Deployment Stack
#   ownership, preventing RoleAssignmentExists (ARM 409) failures. Runs as a
#   preprovision hook immediately before `azd up`.
#
# APPROACH:
#   For each role assignment that Bicep unconditionally creates, delete any
#   existing assignment for that role on that resource before the deployment.
#   The deployment stack then recreates the assignment under its ownership.
#
#   This is safe because:
#   - This script runs in the preprovision hook, before Bicep provisions.
#   - Bicep always recreates the assignment (conditional ones are only cleaned
#     when the relevant resource exists in the RG, implying the condition is met).
#   - If the assignment was already stack-managed, deleting it and recreating
#     it has no net effect on permissions.
#   - If the assignment was unmanaged (pre-stack or orphaned), this fixes the
#     ownership so the stack can manage it going forward.
#
# ROLE ASSIGNMENTS CLEANED:
#   - App Configuration Data Reader (scope: App Config store → backend identity)
#   - SQL Server Contributor        (scope: SQL Server     → sql-admin identity)
#
# REQUIRED ENV VARS:
#   AZURE_RESOURCE_GROUP    Azure resource group name

set -euo pipefail

info()    { echo "  ℹ  $*"; }
success() { echo "  ✅ $*"; }
removed() { echo "  🗑️  $*"; }

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

if [ -z "$AZURE_RESOURCE_GROUP" ]; then
  info "AZURE_RESOURCE_GROUP not set — skipping."
  exit 0
fi

echo ""
echo "Pre-deployment role assignment cleanup (RG: ${AZURE_RESOURCE_GROUP})..."

# ── Role definition IDs ───────────────────────────────────────────────────────
APP_CONFIG_DATA_READER_ROLE="516239f1-63e1-4d78-a4de-a74fb236a071"
SQL_SERVER_CONTRIBUTOR_ROLE="6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"

DELETED_COUNT=0

# delete_if_exists <scope-resource-id> <role-definition-id> <label>
#
# Lists all assignments for <role> scoped exactly to <resource> and deletes them.
# The deployment stack will recreate the correct assignment under its ownership.
#
# This handles two cases:
#   - Assignment is unmanaged (pre-stack or orphaned) → delete → stack creates it
#   - Assignment is stack-managed from a prior run    → delete → stack recreates it
# Either way the stack ends up owning a fresh assignment with no ARM 409 conflict.
delete_if_exists() {
  local SCOPE_ID="$1"
  local ROLE_ID="$2"
  local LABEL="$3"

  if [ -z "$SCOPE_ID" ]; then
    info "${LABEL}: resource not found in RG — skipping."
    return
  fi

  info "${LABEL}: checking for existing assignments on $(basename "$SCOPE_ID")..."

  # List assignments for this exact role on this exact resource scope
  ASSIGNMENT_IDS=$(az role assignment list \
    --scope  "$SCOPE_ID" \
    --role   "$ROLE_ID" \
    --query  "[].id" \
    --output tsv 2>/dev/null || echo "")

  if [ -z "$ASSIGNMENT_IDS" ]; then
    success "${LABEL}: no existing assignment — stack will create it fresh."
    return
  fi

  while IFS= read -r RA_ID; do
    [ -z "$RA_ID" ] && continue
    info "${LABEL}: deleting existing assignment so stack can own it: ${RA_ID##*/}"
    az role assignment delete --ids "$RA_ID" --output none
    DELETED_COUNT=$((DELETED_COUNT + 1))
    removed "${LABEL}: deleted — stack will recreate under its ownership."
  done <<< "$ASSIGNMENT_IDS"
}

# ── App Configuration Data Reader ────────────────────────────────────────────
APP_CONFIG_ID=$(az appconfig list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].id" \
  --output tsv 2>/dev/null || echo "")

delete_if_exists "$APP_CONFIG_ID" "$APP_CONFIG_DATA_READER_ROLE" "App Config Data Reader"

# ── SQL Server Contributor ────────────────────────────────────────────────────
SQL_SERVER_ID=$(az sql server list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].id" \
  --output tsv 2>/dev/null || echo "")

delete_if_exists "$SQL_SERVER_ID" "$SQL_SERVER_CONTRIBUTOR_ROLE" "SQL Server Contributor"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$DELETED_COUNT" -gt 0 ]; then
  echo "Removed ${DELETED_COUNT} role assignment(s) — deployment stack will recreate and own them."
else
  echo "No conflicting role assignments found — deployment stack will create them fresh."
fi
