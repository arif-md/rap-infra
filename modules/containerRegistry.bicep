param name string
param location string
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Basic'
param adminUserEnabled bool = false
param tags object = {}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: adminUserEnabled
    zoneRedundancy: 'Disabled'
    dataEndpointEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
  tags: tags
}

output loginServer string = acr.properties.loginServer
