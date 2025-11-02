@description('The name of the SQL Server instance')
param sqlServerName string

@description('The name of the SQL Database')
param sqlDatabaseName string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Tags to apply to resources')
param tags object = {}

@description('SQL Server administrator login name')
param administratorLogin string = 'sqladmin'

@description('SQL Server administrator password')
@secure()
param administratorPassword string

@description('Enable Azure AD authentication only (passwordless)')
param azureAdOnlyAuthentication bool = false

@description('Azure AD admin object ID (user or service principal)')
param azureAdAdminObjectId string = ''

@description('Azure AD admin login name')
param azureAdAdminLogin string = ''

@description('SKU name for the SQL Database (e.g., Basic, S0, P1, GP_S_Gen5_2)')
param skuName string = 'Basic'

@description('Tier for the SQL Database (e.g., Basic, Standard, Premium, GeneralPurpose)')
param skuTier string = 'Basic'

@description('Database collation')
param collation string = 'SQL_Latin1_General_CP1_CI_AS'

@description('Maximum size of the database in bytes (e.g., 2147483648 for 2GB)')
param maxSizeBytes int = 2147483648

@description('Subnet ID for private endpoint')
param privateEndpointSubnetId string

@description('Enable private endpoint')
param enablePrivateEndpoint bool = true

@description('Private DNS Zone ID for privatelink.database.windows.net')
param privateDnsZoneId string = ''

@description('Allowed IP addresses for firewall rules (array of {name, startIpAddress, endIpAddress})')
param firewallRules array = []

@description('Allow Azure services to access the server')
param allowAzureServices bool = true

// SQL Server resource
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: sqlServerName
  location: location
  tags: tags
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: enablePrivateEndpoint ? 'Disabled' : 'Enabled'
    administrators: !empty(azureAdAdminObjectId) ? {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: azureAdAdminLogin
      sid: azureAdAdminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: azureAdOnlyAuthentication
    } : null
  }
}

// SQL Database resource
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    collation: collation
    maxSizeBytes: maxSizeBytes
    catalogCollation: collation
    zoneRedundant: false
    readScale: 'Disabled'
    requestedBackupStorageRedundancy: 'Local'
  }
}

// Firewall rules
resource firewallRulesResource 'Microsoft.Sql/servers/firewallRules@2023-05-01-preview' = [for rule in firewallRules: {
  parent: sqlServer
  name: rule.name
  properties: {
    startIpAddress: rule.startIpAddress
    endIpAddress: rule.endIpAddress
  }
}]

// Allow Azure services rule
resource allowAzureServicesRule 'Microsoft.Sql/servers/firewallRules@2023-05-01-preview' = if (allowAzureServices && !enablePrivateEndpoint) {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Private Endpoint for SQL Server
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = if (enablePrivateEndpoint) {
  name: '${sqlServerName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${sqlServerName}-pls'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

// Private DNS Zone Group
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (enablePrivateEndpoint && !empty(privateDnsZoneId)) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

@description('SQL Server fully qualified domain name')
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName

@description('SQL Server name')
output sqlServerName string = sqlServer.name

@description('SQL Database name')
output sqlDatabaseName string = sqlDatabase.name

@description('SQL Server resource ID')
output sqlServerResourceId string = sqlServer.id

@description('SQL Database resource ID')
output sqlDatabaseResourceId string = sqlDatabase.id

@description('Connection string for SQL Database (without password)')
output connectionString string = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabaseName};'
