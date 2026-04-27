#!/bin/bash
# =============================================================================
# Pre-Provision: Detect "azd down/up on retained-MI environment" and auto-set
# FORCE_SQL_SETUP_TAG so that the sql-setup ACI actually runs.
# See ensure-sql-setup.ps1 for detailed explanation of why this is needed.
# =============================================================================

set -e

RG="${AZURE_RESOURCE_GROUP}"
ENV_NAME="${AZURE_ENV_NAME}"

if [ -z "$RG" ] || [ -z "$ENV_NAME" ]; then
    echo "  ensure-sql-setup: AZURE_RESOURCE_GROUP or AZURE_ENV_NAME not set — skipping."
    exit 0
fi

# BACKEND_IDENTITY_NAME is exported by ensure-identities.sh (runs before this)
BACKEND_MI_NAME=$(azd env get-value BACKEND_IDENTITY_NAME 2>/dev/null || true)
if [ -z "$BACKEND_MI_NAME" ]; then
    echo "  ensure-sql-setup: BACKEND_IDENTITY_NAME not set — ensure-identities.sh must run first."
    exit 0
fi

# Check if the backend MI already exists
MI_EXISTS=$(az identity show --resource-group "$RG" --name "$BACKEND_MI_NAME" --query name -o tsv 2>/dev/null || true)
if [ -z "$MI_EXISTS" ]; then
    echo "  ensure-sql-setup: Fresh deploy detected (MI '$BACKEND_MI_NAME' absent) — no action needed."
    exit 0
fi

# MI exists — check if SQL server is present
SQL_SERVER=$(az sql server list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || true)

if [ -n "$SQL_SERVER" ]; then
    SQL_DB_NAME="sqldb-raptor-${ENV_NAME}"
    DB_EXISTS=$(az sql db show --resource-group "$RG" --server "$SQL_SERVER" --name "$SQL_DB_NAME" --query name -o tsv 2>/dev/null || true)
    if [ -n "$DB_EXISTS" ]; then
        echo "  ensure-sql-setup: SQL database '$SQL_DB_NAME' exists — no action needed."
        exit 0
    fi
    echo "  ensure-sql-setup: SQL server exists but database '$SQL_DB_NAME' is absent."
else
    echo "  ensure-sql-setup: SQL server absent in '$RG'."
fi

# MI present but SQL database absent → force sql-setup re-run
TAG=$(date -u +"%Y%m%d%H%M%S")
echo "  ensure-sql-setup: Managed identities retained but SQL database gone."
echo "  Setting FORCE_SQL_SETUP_TAG=$TAG to force sql-setup re-run on this deployment."
azd env set FORCE_SQL_SETUP_TAG "$TAG"
echo "  After 'azd up' succeeds, clear it with: azd env set FORCE_SQL_SETUP_TAG ''"
exit 0
