#!/bin/bash
set -euo pipefail

# Grant Directory Readers role to SQL Server's managed identity
# This allows SQL Server to expand Azure AD group membership when authenticating users

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔐 Granting Directory Readers role to SQL Server"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get SQL Server details from azd environment
RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP)
SQL_SERVER_NAME=$(azd env get-value sqlServerName 2>/dev/null || echo "")

if [ -z "$SQL_SERVER_NAME" ]; then
  echo "⚠️  SQL Server name not found in azd environment, attempting auto-discovery..."
  SQL_SERVER_NAME=$(az sql server list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
  
  if [ -z "$SQL_SERVER_NAME" ]; then
    echo "❌ No SQL Server found in resource group $RESOURCE_GROUP"
    exit 1
  fi
  echo "✅ Found SQL Server: $SQL_SERVER_NAME"
fi

# Get SQL Server managed identity principal ID
echo ""
echo "📋 Retrieving SQL Server managed identity..."
IDENTITY_PRINCIPAL_ID=$(az sql server show \
  -g "$RESOURCE_GROUP" \
  -n "$SQL_SERVER_NAME" \
  --query "identity.principalId" -o tsv)

if [ -z "$IDENTITY_PRINCIPAL_ID" ] || [ "$IDENTITY_PRINCIPAL_ID" = "null" ]; then
  echo "❌ SQL Server does not have a system-assigned managed identity"
  echo "💡 The Bicep template should enable identity: { type: 'SystemAssigned' }"
  exit 1
fi

echo "✅ SQL Server managed identity: $IDENTITY_PRINCIPAL_ID"

# Get Directory Readers role ID
echo ""
echo "🔍 Looking up Directory Readers role..."
DIRECTORY_READERS_ROLE_ID=$(az rest \
  --method GET \
  --uri 'https://graph.microsoft.com/v1.0/directoryRoles' \
  --query "value[?displayName=='Directory Readers'].id | [0]" -o tsv)

if [ -z "$DIRECTORY_READERS_ROLE_ID" ]; then
  echo "❌ Directory Readers role not found"
  echo "💡 The role may need to be activated first"
  exit 1
fi

echo "✅ Directory Readers role ID: $DIRECTORY_READERS_ROLE_ID"

# Check if already a member
echo ""
echo "🔍 Checking if SQL Server identity is already a Directory Reader..."
IS_MEMBER=$(az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/directoryRoles/$DIRECTORY_READERS_ROLE_ID/members" \
  --query "value[?id=='$IDENTITY_PRINCIPAL_ID'].id | [0]" -o tsv 2>/dev/null || echo "")

if [ -n "$IS_MEMBER" ]; then
  echo "✅ SQL Server identity is already a member of Directory Readers role"
  echo "   No action needed."
  exit 0
fi

# Grant Directory Readers role
echo ""
echo "➕ Adding SQL Server identity to Directory Readers role..."

# Create JSON body
BODY=$(cat <<EOF
{
  "@odata.id": "https://graph.microsoft.com/v1.0/directoryObjects/$IDENTITY_PRINCIPAL_ID"
}
EOF
)

# Add to role
az rest \
  --method POST \
  --uri "https://graph.microsoft.com/v1.0/directoryRoles/$DIRECTORY_READERS_ROLE_ID/members/\$ref" \
  --body "$BODY" \
  --headers "Content-Type=application/json" 2>&1 | tee /tmp/grant-result.txt

# Check for success or already exists
if grep -q "Forbidden\|Authorization_RequestDenied" /tmp/grant-result.txt; then
  echo ""
  echo "❌ Insufficient permissions to grant Directory Readers role"
  echo ""
  echo "📋 Required permission: RoleManagement.ReadWrite.Directory or Privileged Role Administrator"
  echo ""
  echo "🔧 Manual steps to fix:"
  echo "   1. Go to Azure Portal → Azure Active Directory → Roles and administrators"
  echo "   2. Select 'Directory Readers' role"
  echo "   3. Click 'Add assignment'"
  echo "   4. Search for and select: $SQL_SERVER_NAME"
  echo "   5. Click 'Add'"
  echo ""
  echo "⚠️  Continuing without Directory Readers role..."
  echo "   Azure AD group admin will NOT work for service principals."
  echo "   Consider using service principal directly as Azure AD admin instead."
  exit 0  # Don't fail the deployment
elif grep -q "already exists\|already a member" /tmp/grant-result.txt; then
  echo "✅ SQL Server identity is already a member (confirmed)"
else
  echo "✅ Successfully granted Directory Readers role to SQL Server identity"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Directory Readers configuration complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
