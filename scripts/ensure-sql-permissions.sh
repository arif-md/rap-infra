#!/bin/bash
set -euo pipefail

# =============================================================================
# Ensure SQL Database Exists and Grant Managed Identity Permissions
# =============================================================================
# This script is called by azd hooks:preprovision to ensure SQL resources
# exist and backend managed identity has appropriate database permissions.
#
# This runs BEFORE main.bicep deployment, which is ideal for:
# 1. Creating SQL Server/Database if it doesn't exist
# 2. Granting managed identity permissions after identity is created
#
# Note: This requires SQL admin credentials and Azure CLI with sqlcmd extension
# =============================================================================

echo "==> Ensuring SQL Database setup and permissions..."

# Check if SQL Database is enabled
ENABLE_SQL=$(azd env get-value ENABLE_SQL_DATABASE 2>/dev/null || echo "true")
if [ "$ENABLE_SQL" != "true" ]; then
  echo "SQL Database is disabled. Skipping SQL setup."
  exit 0
fi

# Get required environment variables
AZURE_ENV_NAME=$(azd env get-value AZURE_ENV_NAME)
AZURE_RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP)
SQL_ADMIN_LOGIN=$(azd env get-value SQL_ADMIN_LOGIN 2>/dev/null || echo "sqladmin")
SQL_ADMIN_PASSWORD=$(azd env get-value SQL_ADMIN_PASSWORD 2>/dev/null || echo "")

if [ -z "$SQL_ADMIN_PASSWORD" ]; then
  echo "WARNING: SQL_ADMIN_PASSWORD is not set. Cannot configure SQL permissions."
  echo "Set it with: azd env set SQL_ADMIN_PASSWORD 'YourSecurePassword123!'"
  echo "Skipping SQL permission grants."
  exit 0
fi

echo "Environment: $AZURE_ENV_NAME"
echo "Resource Group: $AZURE_RESOURCE_GROUP"
echo "SQL Admin: $SQL_ADMIN_LOGIN"

# Check if SQL Server exists
SQL_SERVER_NAME=$(az sql server list -g "$AZURE_RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -z "$SQL_SERVER_NAME" ]; then
  echo "SQL Server not found in resource group. Will be created by main.bicep deployment."
  echo "Skipping permission grants (will run in postprovision after deployment)."
  exit 0
fi

echo "Found SQL Server: $SQL_SERVER_NAME"

# Get database name
SQL_DATABASE_NAME=$(az sql db list -g "$AZURE_RESOURCE_GROUP" -s "$SQL_SERVER_NAME" --query "[?name != 'master'].name | [0]" -o tsv 2>/dev/null || echo "")

if [ -z "$SQL_DATABASE_NAME" ]; then
  echo "SQL Database not found. Will be created by main.bicep deployment."
  exit 0
fi

echo "Found SQL Database: $SQL_DATABASE_NAME"

# Get backend managed identity name
BACKEND_IDENTITY_NAME=$(az identity list -g "$AZURE_RESOURCE_GROUP" --query "[?contains(name, 'backend')].name | [0]" -o tsv 2>/dev/null || echo "")

if [ -z "$BACKEND_IDENTITY_NAME" ]; then
  echo "Backend managed identity not found yet. Will be created by main.bicep deployment."
  echo "SQL permissions will be granted in postprovision."
  exit 0
fi

echo "Found backend identity: $BACKEND_IDENTITY_NAME"

# Get processes managed identity name
PROCESSES_IDENTITY_NAME=$(az identity list -g "$AZURE_RESOURCE_GROUP" --query "[?contains(name, 'processes')].name | [0]" -o tsv 2>/dev/null || echo "")

if [ -z "$PROCESSES_IDENTITY_NAME" ]; then
  echo "Processes managed identity not found yet. Will be created by main.bicep deployment."
  echo "Will only grant permissions to backend identity."
else
  echo "Found processes identity: $PROCESSES_IDENTITY_NAME"
fi

# Get SQL Server FQDN
SQL_SERVER_FQDN=$(az sql server show -n "$SQL_SERVER_NAME" -g "$AZURE_RESOURCE_GROUP" --query "fullyQualifiedDomainName" -o tsv)

echo "SQL Server FQDN: $SQL_SERVER_FQDN"

# Check if public access is enabled (required for this script)
PUBLIC_ACCESS=$(az sql server show -n "$SQL_SERVER_NAME" -g "$AZURE_RESOURCE_GROUP" --query "publicNetworkAccess" -o tsv)

if [ "$PUBLIC_ACCESS" = "Disabled" ]; then
  echo "WARNING: SQL Server has public access disabled (using private endpoint)."
  echo "Cannot grant permissions from this script. You have two options:"
  echo ""
  echo "Option 1: Temporarily enable public access, run this script, then disable:"
  echo "  az sql server update -n $SQL_SERVER_NAME -g $AZURE_RESOURCE_GROUP --enable-public-network true"
  echo "  azd hooks run preprovision"
  echo "  az sql server update -n $SQL_SERVER_NAME -g $AZURE_RESOURCE_GROUP --enable-public-network false"
  echo ""
  echo "Option 2: Run SQL commands from a machine with VNet access (see postprovision script)"
  echo ""
  echo "Skipping permission grants."
  exit 0
fi

# Get current IP for firewall rule (if needed)
MY_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "")

if [ -n "$MY_IP" ]; then
  echo "Current IP: $MY_IP"
  
  # Check if firewall rule exists
  RULE_EXISTS=$(az sql server firewall-rule list -g "$AZURE_RESOURCE_GROUP" -s "$SQL_SERVER_NAME" --query "[?name=='AllowDeploymentScript'].name | [0]" -o tsv 2>/dev/null || echo "")
  
  if [ -z "$RULE_EXISTS" ]; then
    echo "Creating temporary firewall rule for deployment script..."
    az sql server firewall-rule create \
      -g "$AZURE_RESOURCE_GROUP" \
      -s "$SQL_SERVER_NAME" \
      -n "AllowDeploymentScript" \
      --start-ip-address "$MY_IP" \
      --end-ip-address "$MY_IP" \
      -o none
    CLEANUP_FIREWALL_RULE=true
  fi
fi

# Grant managed identity permissions using sqlcmd
echo "Granting database permissions to managed identities..."

# Generate SQL script with actual identity values substituted
# Using cat with here-doc to properly expand variables
SQL_SCRIPT=$(cat <<EOSQL
-- ============================================
-- SQL Permissions for Backend and Processes Managed Identities
-- ============================================
-- Database: ${SQL_DATABASE_NAME}
-- Backend Identity: ${BACKEND_IDENTITY_NAME}
-- Processes Identity: ${PROCESSES_IDENTITY_NAME:-<not found>}
-- Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
-- ============================================

-- ============================================
-- Backend Service Permissions
-- ============================================

-- Create user for backend managed identity
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '${BACKEND_IDENTITY_NAME}')
BEGIN
    PRINT 'Creating backend user from external provider...'
    CREATE USER [${BACKEND_IDENTITY_NAME}] FROM EXTERNAL PROVIDER
END
ELSE
BEGIN
    PRINT 'Backend user already exists.'
END
GO

-- Grant db_datareader role to backend
IF IS_ROLEMEMBER('db_datareader', '${BACKEND_IDENTITY_NAME}') = 0
BEGIN
    PRINT 'Granting db_datareader role to backend identity...'
    ALTER ROLE db_datareader ADD MEMBER [${BACKEND_IDENTITY_NAME}]
END
ELSE
BEGIN
    PRINT 'db_datareader role already assigned to backend identity.'
END
GO

-- Grant db_datawriter role to backend
IF IS_ROLEMEMBER('db_datawriter', '${BACKEND_IDENTITY_NAME}') = 0
BEGIN
    PRINT 'Granting db_datawriter role to backend identity...'
    ALTER ROLE db_datawriter ADD MEMBER [${BACKEND_IDENTITY_NAME}]
END
ELSE
BEGIN
    PRINT 'db_datawriter role already assigned to backend identity.'
END
GO

-- Grant db_ddladmin role to backend (for Flyway migrations)
IF IS_ROLEMEMBER('db_ddladmin', '${BACKEND_IDENTITY_NAME}') = 0
BEGIN
    PRINT 'Granting db_ddladmin role to backend identity (for Flyway migrations)...'
    ALTER ROLE db_ddladmin ADD MEMBER [${BACKEND_IDENTITY_NAME}]
END
ELSE
BEGIN
    PRINT 'db_ddladmin role already assigned to backend identity.'
END
GO

PRINT 'Permissions granted successfully to [${BACKEND_IDENTITY_NAME}].'
GO
EOSQL
)

# Add processes identity permissions if it exists
if [ -n "$PROCESSES_IDENTITY_NAME" ]; then
  SQL_SCRIPT="${SQL_SCRIPT}
$(cat <<EOSQL

-- ============================================
-- Processes Service Permissions
-- ============================================

-- Create user for processes managed identity
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '${PROCESSES_IDENTITY_NAME}')
BEGIN
    PRINT 'Creating processes user from external provider...'
    CREATE USER [${PROCESSES_IDENTITY_NAME}] FROM EXTERNAL PROVIDER
END
ELSE
BEGIN
    PRINT 'Processes user already exists.'
END
GO

-- Grant db_datareader role to processes
IF IS_ROLEMEMBER('db_datareader', '${PROCESSES_IDENTITY_NAME}') = 0
BEGIN
    PRINT 'Granting db_datareader role to processes identity...'
    ALTER ROLE db_datareader ADD MEMBER [${PROCESSES_IDENTITY_NAME}]
END
ELSE
BEGIN
    PRINT 'db_datareader role already assigned to processes identity.'
END
GO

-- Grant db_datawriter role to processes
IF IS_ROLEMEMBER('db_datawriter', '${PROCESSES_IDENTITY_NAME}') = 0
BEGIN
    PRINT 'Granting db_datawriter role to processes identity...'
    ALTER ROLE db_datawriter ADD MEMBER [${PROCESSES_IDENTITY_NAME}]
END
ELSE
BEGIN
    PRINT 'db_datawriter role already assigned to processes identity.'
END
GO

-- Grant db_ddladmin role to processes
IF IS_ROLEMEMBER('db_ddladmin', '${PROCESSES_IDENTITY_NAME}') = 0
BEGIN
    PRINT 'Granting db_ddladmin role to processes identity...'
    ALTER ROLE db_ddladmin ADD MEMBER [${PROCESSES_IDENTITY_NAME}]
END
ELSE
BEGIN
    PRINT 'db_ddladmin role already assigned to processes identity.'
END
GO

PRINT 'Permissions granted successfully to [${PROCESSES_IDENTITY_NAME}].'
GO
EOSQL
)"
fi

# Add verification query
SQL_SCRIPT="${SQL_SCRIPT}
$(cat <<EOSQL

-- ============================================
-- Verify users were created
-- ============================================
SELECT
    name as UserName,
    type_desc as UserType,
    authentication_type_desc as AuthType,
    create_date as CreatedDate
FROM sys.database_principals
WHERE name IN ('${BACKEND_IDENTITY_NAME}'$([ -n "$PROCESSES_IDENTITY_NAME" ] && echo ", '${PROCESSES_IDENTITY_NAME}'" || echo ""))
ORDER BY name;
GO
EOSQL
)"

# Check if sqlcmd is available
if command -v sqlcmd &> /dev/null; then
  echo "Using sqlcmd to grant permissions..."
  echo "$SQL_SCRIPT" | sqlcmd -S "$SQL_SERVER_FQDN" -d "$SQL_DATABASE_NAME" -U "$SQL_ADMIN_LOGIN" -P "$SQL_ADMIN_PASSWORD" -b
  echo "✅ SQL permissions granted successfully!"
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  WARNING: sqlcmd not found - Manual execution required"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Install sqlcmd with:"
  echo "  curl https://packages.microsoft.com/config/ubuntu/\$(lsb_release -rs)/prod.list | sudo tee /etc/apt/sources.list.d/msprod.list"
  echo "  sudo apt-get update && sudo apt-get install -y mssql-tools18 unixodbc-dev"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 COPY-PASTE READY SQL SCRIPT (Values already substituted)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Execute this in Azure Portal → SQL Database → Query Editor:"
  echo ""
  echo "$SQL_SCRIPT"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Connection Details:"
  echo "  Server: $SQL_SERVER_FQDN"
  echo "  Database: $SQL_DATABASE_NAME"
  echo "  Authentication: Use Azure AD (Active Directory - Universal with MFA)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# Cleanup temporary firewall rule if created
if [ "${CLEANUP_FIREWALL_RULE:-false}" = "true" ]; then
  echo "Removing temporary firewall rule..."
  az sql server firewall-rule delete \
    -g "$AZURE_RESOURCE_GROUP" \
    -s "$SQL_SERVER_NAME" \
    -n "AllowDeploymentScript" \
    -o none
fi

echo "==> SQL setup complete!"
