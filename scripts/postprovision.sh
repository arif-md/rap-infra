#!/bin/bash
set -euo pipefail

# =============================================================================
# Post-Provision Hook: Database Initialization and Permission Grants (LOCAL ONLY)
# =============================================================================
# This script runs AFTER main.bicep deployment completes in LOCAL environments.
# 
# Purpose:
#   1. Grant SQL database permissions to backend managed identity
#   2. Database schema is initialized automatically by Flyway migrations (app startup)
# 
# Environment Behavior:
#   - LOCAL (azd up):     Runs this script using 'az sql db query --auth-type ActiveDirectoryDefault'
#   - GITHUB ACTIONS:     SKIPPED - uses separate grant-sql-permissions.yml workflow job instead
# 
# Why skip in GitHub Actions?
#   - GitHub workflow uses Python + pyodbc with explicit token (more reliable)
#   - Workflow handles firewall cleanup and container restart automatically
#   - Prevents duplicate execution (both hook and workflow would run)
# 
# Prerequisites for local execution:
#   - Azure CLI authenticated as user who is member of RAP-SQL-Admins group
#   - SQL Server has public access enabled (or you're on VNet)
# =============================================================================

echo "==> Running post-provision tasks..."

# Skip in GitHub Actions - the grant-sql-permissions workflow job handles this
if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
  echo "Detected GitHub Actions environment."
  echo "SQL permissions will be granted by the grant-sql-permissions workflow job."
  echo "Skipping postprovision hook to avoid duplicate execution."
  exit 0
fi

# Check if SQL Database is enabled
ENABLE_SQL=$(azd env get-value ENABLE_SQL_DATABASE 2>/dev/null || echo "true")
if [ "$ENABLE_SQL" != "true" ]; then
  echo "SQL Database is disabled. Skipping post-provision SQL tasks."
  exit 0
fi

# Run the SQL permissions script (it handles all the checks)
echo "Ensuring SQL permissions are configured..."
chmod +x "$(dirname "$0")/ensure-sql-permissions.sh"
"$(dirname "$0")/ensure-sql-permissions.sh"

echo "==> Post-provision tasks complete!"
echo ""
echo "ℹ️  Database schema will be initialized automatically by Flyway migrations"
echo "   when the backend container app starts for the first time."
echo ""
echo "   Check backend logs with:"
echo "   az containerapp logs show -n \$(azd env get-value BACKEND_APP_NAME) -g \$(azd env get-value AZURE_RESOURCE_GROUP) --tail 100"
