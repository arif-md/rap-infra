@description('Name of the private DNS zone (e.g., privatelink.database.windows.net)')
param zoneName string

@description('Virtual Network ID to link the private DNS zone')
param vnetId string

@description('Tags to apply to resources')
param tags object = {}

@description('Auto-registration of VM DNS records')
param registrationEnabled bool = false

// Private DNS Zone
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
  properties: {}
}

// VNet Link
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${uniqueString(vnetId)}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: registrationEnabled
    virtualNetwork: {
      id: vnetId
    }
  }
}

@description('Private DNS Zone resource ID')
output privateDnsZoneId string = privateDnsZone.id

@description('Private DNS Zone name')
output privateDnsZoneName string = privateDnsZone.name
