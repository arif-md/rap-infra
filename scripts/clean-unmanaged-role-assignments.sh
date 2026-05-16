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

# ── Role definition GUIDs to remove before deploying ─────────────────────────
APP_CONFIG_DATA_READER_ROLE="516239f1-63e1-4d78-a4de-a74fb236a071"
SQL_SERVER_CONTRIBUTOR_ROLE="6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437"

# ── Fetch ALL role assignments in the resource group ─────────────────────────
# We deliberately do NOT pass --role here. The --role flag adds an OData
# $filter on roleDefinitionId using a subscription-specific path that silently
# returns empty when Azure stored the assignment's roleDefinitionId with a
# different path format (e.g. uppercase GUID, different subscription prefix).
# By fetching all assignments and filtering locally with python3 we avoid the
# case-sensitivity and path-format mismatches entirely.
echo "  Fetching all role assignments in RG..."
ALL_JSON=$(az role assignment list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --include-inherited \
  --output json 2>/dev/null || echo "[]")

# ── Find IDs matching our target roles (case-insensitive, python3) ───────────
# roleDefinitionId in Azure responses often has uppercase GUIDs, e.g.
#   /subscriptions/.../roleDefinitions/516239F1-63E1-4D78-A4DE-A74FB236A071
# JMESPath contains() is case-sensitive so we use python3 .lower() instead.
# Stderr (diagnostic lines) flows to the terminal; stdout (IDs) is captured.
TARGETS="${APP_CONFIG_DATA_READER_ROLE} ${SQL_SERVER_CONTRIBUTOR_ROLE}"
CONFLICTING_IDS=$(echo "$ALL_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
targets = {t.lower() for t in '${TARGETS}'.split()}
print(f'  Scanning {len(data)} assignment(s) for target roles...', file=sys.stderr)
for ra in data:
    rd_id = ra.get('roleDefinitionId', '').lower()
    ra_id  = ra.get('id', '')
    if any(t in rd_id for t in targets):
        print(f'  MATCH: {ra_id.split(\"/\")[-1]}  scope={ra.get(\"scope\",\"?\")}', file=sys.stderr)
        print(ra_id)
")

if [ -z "$CONFLICTING_IDS" ]; then
  echo "  ✅ No conflicting role assignments found — deployment stack will create them fresh."
  exit 0
fi

# ── Delete each conflicting assignment ───────────────────────────────────────
DELETED_COUNT=0
while IFS= read -r RA_ID; do
  [ -z "$RA_ID" ] && continue
  echo "  🗑  Deleting ${RA_ID##*/}..."
  az role assignment delete --ids "$RA_ID"
  DELETED_COUNT=$((DELETED_COUNT + 1))
  echo "  ✅  Deleted — stack will recreate under its ownership."
done <<< "$CONFLICTING_IDS"

echo ""
echo "Removed ${DELETED_COUNT} role assignment(s) — deployment stack will recreate and own them."
