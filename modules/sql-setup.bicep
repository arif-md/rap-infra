// =============================================================================
// Combined SQL Setup — Role Assignments + Schema Bootstrap
// =============================================================================
// Runs in a SINGLE ACI container (instead of two sequential ones) to cut
// deployment time by ~4-5 minutes.
//
// Step 1: Creates database users for managed identities and grants roles
//         (uses SID + TYPE = E/X to avoid Directory Readers requirement)
// Step 2: Bootstraps schemas, base tables, views & seed data
//         (fully idempotent — IF NOT EXISTS / MERGE)
//
// Execution order (Bicep dependsOn):
//   sqlDatabase → THIS → container apps
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

@description('Backend managed identity name (for setting default schema)')
param backendIdentityName string = ''

@description('Processes managed identity name (for setting default schema)')
param processesIdentityName string = ''

// Serialize inputs for script consumption and change detection
var identityGrantsJson = string(identityGrants)
var adAdminGroupJson = string(adAdminGroup)
var sqlScriptContent = loadTextContent('../scripts/sql/bootstrap-schemas.sql')
var dbUserSqlTemplate = loadTextContent('../scripts/sql/create-db-user.sql')
var adGroupSqlTemplate = loadTextContent('../scripts/sql/create-ad-group-user.sql')

// Content-based forceUpdateTag: only re-runs when inputs actually change.
// Eliminates the ~4-5 min ACI spin-up on unchanged re-deploys.
var changeDetectionTag = uniqueString(identityGrantsJson, adAdminGroupJson, sqlScriptContent, dbUserSqlTemplate, adGroupSqlTemplate, backendIdentityName, processesIdentityName)

resource sqlSetup 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'sql-setup'
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
    forceUpdateTag: changeDetectionTag
    cleanupPreference: 'OnSuccess'
    arguments: '-SqlServerFqdn \'${sqlServerFqdn}\' -DatabaseName \'${sqlDatabaseName}\' -ResourceGroupName \'${resourceGroup().name}\''
    environmentVariables: [
      {
        name: 'IDENTITY_GRANTS_JSON'
        value: identityGrantsJson
      }
      {
        name: 'AD_ADMIN_GROUP_JSON'
        value: adAdminGroupJson
      }
      {
        name: 'BACKEND_IDENTITY_NAME'
        value: backendIdentityName
      }
      {
        name: 'PROCESSES_IDENTITY_NAME'
        value: processesIdentityName
      }
      {
        name: 'SQL_SCRIPT_CONTENT'
        value: sqlScriptContent
      }
      {
        name: 'DB_USER_SQL_TEMPLATE'
        value: dbUserSqlTemplate
      }
      {
        name: 'AD_GROUP_SQL_TEMPLATE'
        value: adGroupSqlTemplate
      }
    ]
    scriptContent: loadTextContent('../scripts/sql-setup.ps1')
  }
}

output scriptOutput string = sqlSetup.properties.outputs.result
