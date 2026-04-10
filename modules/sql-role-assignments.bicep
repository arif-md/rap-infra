// =============================================================================
// SQL Role Assignments via Deployment Script
// =============================================================================
// Creates database users for managed identities and grants them appropriate
// roles using a Bicep deployment script (runs in a temporary ACI container).
//
// Uses SID + TYPE = E/X syntax so that the SQL Server does NOT need the
// Directory Readers Azure AD role to resolve identities.
//
// Identity grants and AD group info are passed as JSON environment variables;
// the PowerShell script builds and executes the SQL dynamically (avoids
// Bicep's limitation on nested for-expressions).
// =============================================================================

@description('Azure region for the deployment script resource')
param location string = resourceGroup().location

@description('Tags to apply to resources')
param tags object = {}

@description('SQL Server fully qualified domain name')
param sqlServerFqdn string

@description('SQL Database name')
param sqlDatabaseName string

@description('Resource ID of the user-assigned managed identity that is the SQL AD admin')
param sqlAdminIdentityId string

@description('Array of managed identity principals to grant SQL access. Each entry: { name: string, clientId: string, roles: string[] }')
param identityGrants array

@description('Optional: Azure AD group to add as a db_owner in the database. { name: string, objectId: string }')
param adAdminGroup object = {}

@description('Force script re-execution by changing this value (e.g., utcNow)')
param forceUpdateTag string = utcNow()

// Serialize grant data as JSON for the PowerShell script to consume
var identityGrantsJson = string(identityGrants)
var adAdminGroupJson = string(adAdminGroup)

resource grantPermissions 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'grant-sql-permissions'
  location: location
  tags: tags
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${sqlAdminIdentityId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '12.3'
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    forceUpdateTag: forceUpdateTag
    cleanupPreference: 'OnSuccess'
    arguments: '-SqlServerFqdn \'${sqlServerFqdn}\' -DatabaseName \'${sqlDatabaseName}\''
    environmentVariables: [
      {
        name: 'IDENTITY_GRANTS_JSON'
        value: identityGrantsJson
      }
      {
        name: 'AD_ADMIN_GROUP_JSON'
        value: adAdminGroupJson
      }
    ]
    scriptContent: loadTextContent('../scripts/grant-sql-permissions.ps1')
  }
}

output scriptOutput string = grantPermissions.properties.outputs.result
