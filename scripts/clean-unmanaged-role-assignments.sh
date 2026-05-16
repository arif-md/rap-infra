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

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"

if [ -z "$AZURE_RESOURCE_GROUP" ]; then
  echo "  ℹ  AZURE_RESOURCE_GROUP not set — skipping."
  exit 0
fi

echo ""
echo "Pre-deployment role assignment cleanup (RG: ${AZURE_RESOURCE_GROUP})"

# ── Role definition GUIDs ─────────────────────────────────────────────────────
APP_CONFIG_DATA_READER_ROLE="516239f1-63e1-4d78-a4de-a74fb236a071"
SQL_SERVER_CONTRIBUTOR_ROLE="6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"

DELETED_COUNT=0

# delete_at_scope <resource-id> <role-guid> <label>
#
# Lists role assignments scoped EXACTLY to <resource-id> (no --include-inherited,
# no --resource-group). Filters by role GUID using python3 .lower() to avoid the
# case-sensitivity issue with OData $filter and JMESPath contains().
# Deletes any found so the deployment stack can recreate and own them.
#
# WHY query per resource scope (not --resource-group):
#   `az role assignment list --resource-group X` only returns assignments whose
#   scope IS the RG (or above). Assignments scoped to child resources within the
#   RG (App Config store, SQL Server) are NOT returned — they live at the resource
#   scope, not the RG scope. This was causing every previous version to scan 0
#   matching assignments while the conflicting assignments still existed.
delete_at_scope() {
  local SCOPE_ID="$1"
  local ROLE_GUID="$2"
  local LABEL="$3"

  if [ -z "$SCOPE_ID" ]; then
    echo "  ℹ  ${LABEL}: resource not found in RG — skipping."
    return
  fi

  local RESOURCE_NAME="${SCOPE_ID##*/}"
  echo "  Querying assignments scoped to ${RESOURCE_NAME}..."

  # --scope without --include-inherited returns ONLY assignments at exactly this scope
  local ALL_AT_SCOPE
  ALL_AT_SCOPE=$(az role assignment list \
    --scope "$SCOPE_ID" \
    --output json 2>/dev/null || echo "[]")

  local IDS
  IDS=$(echo "$ALL_AT_SCOPE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '${ROLE_GUID}'.lower()
for ra in data:
    if target in ra.get('roleDefinitionId', '').lower():
        print(ra['id'])
")

  if [ -z "$IDS" ]; then
    echo "  ✅ ${LABEL}: no existing assignment at ${RESOURCE_NAME} — stack will create it."
    return
  fi

  while IFS= read -r RA_ID; do
    [ -z "$RA_ID" ] && continue
    echo "  🗑  ${LABEL}: deleting ${RA_ID##*/}..."
    az role assignment delete --ids "$RA_ID"
    DELETED_COUNT=$((DELETED_COUNT + 1))
    echo "  ✅ ${LABEL}: deleted — stack will recreate under its ownership."
  done <<< "$IDS"
}

# ── App Configuration Data Reader (scoped to App Config store) ───────────────
APP_CONFIG_ID=$(az appconfig list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].id" --output tsv 2>/dev/null || echo "")

delete_at_scope "$APP_CONFIG_ID" "$APP_CONFIG_DATA_READER_ROLE" "App Config Data Reader"

# ── SQL Server Contributor (scoped to SQL Server) ────────────────────────────
SQL_SERVER_ID=$(az sql server list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].id" --output tsv 2>/dev/null || echo "")

delete_at_scope "$SQL_SERVER_ID" "$SQL_SERVER_CONTRIBUTOR_ROLE" "SQL Server Contributor"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$DELETED_COUNT" -gt 0 ]; then
  echo "Removed ${DELETED_COUNT} role assignment(s) — deployment stack will recreate and own them."
else
  echo "No conflicting role assignments found — deployment stack will create them fresh."
fi
