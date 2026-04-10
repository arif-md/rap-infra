// =============================================================================
// SQL Schema Bootstrap via Deployment Script
// =============================================================================
// Creates foundational database objects (schemas, base tables, views, seed data)
// BEFORE any container starts. Runs after SQL role assignments so that managed
// identity users exist and can have their default schemas set.
//
// Execution order (Bicep dependsOn):
//   sqlDatabase → sqlRoleAssignments → THIS → container apps
//
// The SQL script is fully idempotent (IF NOT EXISTS / MERGE) and safe to
// re-run on every deployment.
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

@description('Backend managed identity name (for setting default schema)')
param backendIdentityName string = ''

@description('Processes managed identity name (for setting default schema)')
param processesIdentityName string = ''

@description('Force script re-execution by changing this value (e.g., utcNow)')
param forceUpdateTag string = utcNow()

// Load the SQL script at compile time (Bicep embeds it in the ARM template)
var sqlScriptContent = loadTextContent('../scripts/sql/bootstrap-schemas.sql')

resource bootstrapSchema 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'bootstrap-sql-schema'
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
    ]
    scriptContent: loadTextContent('../scripts/bootstrap-schema.ps1')
  }
}

output scriptOutput string = bootstrapSchema.properties.outputs.result
