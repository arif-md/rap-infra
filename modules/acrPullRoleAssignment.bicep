targetScope = 'resourceGroup'

@description('Name of the Azure Container Registry')
param acrName string

@description('Principal ID of the user-assigned managed identity to grant AcrPull')
param principalId string

// Existing ACR in this resource group
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// Grant AcrPull role at the ACR scope
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, 'AcrPull', principalId)
  scope: acr
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}
