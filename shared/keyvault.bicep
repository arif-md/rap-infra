param name string
param location string = resourceGroup().location
param tags object = {}

@description('Service principal that should be granted read access to the KeyVault. If unset, no service principal is granted access by default')
param principalId string = ''

@description('Secrets to create in Key Vault (array of { name, value })')
param secrets array = []

var defaultAccessPolicies = !empty(principalId) ? [
  {
    objectId: principalId
    permissions: { secrets: [ 'get', 'list' ] }
    tenantId: subscription().tenantId
  }
] : []

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enabledForTemplateDeployment: true
    accessPolicies: union(defaultAccessPolicies, [
      // define access policies here
    ])
  }
}

// Create secrets in Key Vault
resource kvSecrets 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = [for secret in secrets: if (!empty(secret.value)) {
  name: secret.name
  parent: keyVault
  properties: {
    value: secret.value
  }
}]

output endpoint string = keyVault.properties.vaultUri
output name string = keyVault.name
output keyVaultId string = keyVault.id
