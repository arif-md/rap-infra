// ============================================================================
// Key Vault Private Endpoint
// ============================================================================
// Creates a private endpoint for an EXISTING Key Vault (not managed by this
// deployment stack). This enables containers inside the VNet to reach Key Vault
// over the private IP without traversing the public internet.
//
// The private DNS zone link (privatelink.vaultcore.azure.net) causes all DNS
// lookups for *.vault.azure.net inside the VNet to resolve to the private IP,
// so containers automatically use the private path — no code changes needed.
//
// Public network access on Key Vault is intentionally left unchanged here
// because Key Vault is managed externally and may be needed from local dev.
// ============================================================================

@description('Name of the existing Key Vault')
param keyVaultName string

@description('Azure region')
param location string = resourceGroup().location

@description('Resource tags')
param tags object = {}

@description('Subnet resource ID for the private endpoint (private-endpoints-subnet)')
param subnetId string

@description('Private DNS zone resource ID for privatelink.vaultcore.azure.net')
param privateDnsZoneId string

// Reference the externally managed Key Vault
resource existingKeyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: keyVaultName
}

// Private endpoint in the private-endpoints-subnet
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-${keyVaultName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${keyVaultName}'
        properties: {
          privateLinkServiceId: existingKeyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

// DNS zone group — registers the private IP in the privatelink.vaultcore.azure.net zone
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

@description('Private endpoint resource ID')
output privateEndpointId string = privateEndpoint.id
