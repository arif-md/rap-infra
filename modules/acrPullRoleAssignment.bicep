@description('ACR name to grant AcrPull on')
param acrName string

@description('Principal (object) id to assign AcrPull role to')
param principalId string

// Existing ACR in the module's scope RG
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// Assign AcrPull on the ACR to the specified principal
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, 'AcrPull', principalId)
  scope: acr
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}
