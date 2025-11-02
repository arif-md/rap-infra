@description('Name of the virtual network')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Tags to apply to resources')
param tags object = {}

@description('Address prefix for the virtual network (e.g., 10.0.0.0/16)')
param addressPrefix string = '10.0.0.0/16'

@description('Subnet configuration array')
param subnets array = [
  {
    name: 'container-apps-subnet'
    addressPrefix: '10.0.0.0/23'
    delegation: 'Microsoft.App/environments'
  }
  {
    name: 'private-endpoints-subnet'
    addressPrefix: '10.0.2.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
  }
]

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [for subnet in subnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.addressPrefix
        delegations: contains(subnet, 'delegation') ? [
          {
            name: subnet.delegation
            properties: {
              serviceName: subnet.delegation
            }
          }
        ] : []
        privateEndpointNetworkPolicies: contains(subnet, 'privateEndpointNetworkPolicies') ? subnet.privateEndpointNetworkPolicies : 'Enabled'
      }
    }]
  }
}

@description('Virtual Network resource ID')
output vnetId string = vnet.id

@description('Virtual Network name')
output vnetName string = vnet.name

@description('Subnet resource IDs (array)')
output subnetIds array = [for (subnet, i) in subnets: vnet.properties.subnets[i].id]

@description('Container Apps subnet ID')
output containerAppsSubnetId string = vnet.properties.subnets[0].id

@description('Private Endpoints subnet ID')
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id
