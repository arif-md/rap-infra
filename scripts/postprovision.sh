#!/bin/bash
set -euo pipefail

# =============================================================================
# Post-Provision Hook: Database Initialization and Permission Grants
# =============================================================================
# This script runs AFTER main.bicep deployment completes.
# It ensures:
# 1. Backend managed identity has SQL database permissions
# 2. Database schema is initialized (via Flyway migrations in the app)
#
# Note: Flyway migrations run automatically when the Spring Boot app starts,
# so we only need to ensure the managed identity has permissions.
# =============================================================================

echo "==> Running post-provision tasks..."

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
