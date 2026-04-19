// Grants SQL Server Contributor role to a principal on a SQL server.
// Separated into its own module so the caller can use dependsOn to ensure
// the SQL server exists before the 'existing' reference is resolved.

param sqlServerName string
param principalId string

var sqlServerContributorRoleId = '6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437'

resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' existing = {
  name: sqlServerName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sqlServer.id, principalId, sqlServerContributorRoleId)
  scope: sqlServer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sqlServerContributorRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
