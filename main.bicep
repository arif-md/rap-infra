targetScope = 'resourceGroup'

@description('Short environment name (e.g. dev, test, prod)')
@minLength(2)
@maxLength(12)
param environmentName string

@description('Azure location')
param location string = resourceGroup().location

@description('Container image (full ACR reference) for frontend (e.g. myacr.azurecr.io/rap-frontend:latest)')
param frontendImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Container image (full ACR reference) for backend (e.g. myacr.azurecr.io/rap-backend:latest)')
param backendImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

/* Removed publicHostname parameter for simplicity */


@description('Optional ACR name (use existing); when empty, a default is derived from environmentName')
param acrName string = ''

@description('Optional override for ACR resource group (when ACR is in a different RG)')
param acrResourceGroupOverride string = ''

@description('Skip creating AcrPull role assignment for frontend (useful for local runs without RBAC)')
param skipFrontendAcrPullRoleAssignment bool = true

@description('Skip creating AcrPull role assignment for backend (useful for local runs without RBAC)')
param skipBackendAcrPullRoleAssignment bool = true

@description('vCPU allocation for frontend container app (integer, default 1)')
param frontendCpu int = 1

@description('Memory allocation for frontend container app (valid combos with selected CPU; e.g., 2Gi for 1 vCPU)')
@allowed([
  '0.5Gi'
  '1Gi'
  '2Gi'
  '4Gi'
])
param frontendMemory string = '2Gi'

@description('vCPU allocation for backend container app (integer, default 1)')
param backendCpu int = 1

@description('Memory allocation for backend container app (valid combos with selected CPU; e.g., 2Gi for 1 vCPU)')
@allowed([
  '0.5Gi'
  '1Gi'
  '2Gi'
  '4Gi'
])
param backendMemory string = '2Gi'

@description('Enable Azure SQL Database')
param enableSqlDatabase bool = true

@description('Enable VNet integration for Container Apps and SQL Private Endpoints (requires Microsoft.ContainerService provider)')
param enableVnetIntegration bool = false

@description('SQL Server administrator login')
param sqlAdminLogin string = 'sqladmin'

@description('SQL Server administrator password')
@secure()
param sqlAdminPassword string

@description('SQL Database SKU name')
param sqlDatabaseSku string = 'Basic'

@description('SQL Database tier')
param sqlDatabaseTier string = 'Basic'

@description('Tags to apply to all resources')
param tags object = {
  environment: environmentName
  workload: 'rap'
}

var namePrefix = toLower('${environmentName}-rap')
var resolvedAcrName = !empty(acrName) ? acrName : toLower(replace('${environmentName}rapacr','-',''))
var acrResourceGroup = empty(acrResourceGroupOverride) ? resourceGroup().name : acrResourceGroupOverride
var frontendAppName = '${namePrefix}-fe'
var frontendIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}${resourceToken}'
var backendAppName = '${namePrefix}-be'
var backendIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}backend-${resourceToken}'
var sqlServerName = '${abbrs.sqlServers}${resourceToken}'
var sqlDatabaseName = '${abbrs.sqlServersDatabases}raptor-${environmentName}'
var vnetName = '${abbrs.networkVirtualNetworks}${resourceToken}'

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

/* Diagnostics module can be reintroduced later if needed */

/*module acr 'modules/containerRegistry.bicep' = {
  name: 'acrDeploy'
  params: {
    name: acrName
    location: location
    sku: 'Standard'
    adminUserEnabled: false
    tags: tags
  }
}*/

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Virtual Network for Container Apps and Private Endpoints
// Only deploy if VNet integration is enabled
module vnet 'shared/vnet.bicep' = if (enableVnetIntegration) {
  name: 'vnet'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefix: '10.0.0.0/16'
    subnets: [
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
  }
}

// Private DNS Zone for SQL Server private endpoints
module sqlPrivateDnsZone 'shared/privateDnsZone.bicep' = if (enableVnetIntegration && enableSqlDatabase) {
  name: 'sql-private-dns-zone'
  params: {
    zoneName: 'privatelink${environment().suffixes.sqlServerHostname}'
    vnetId: vnet.outputs.vnetId
    tags: tags
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.4.5' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
    // VNet integration controlled by enableVnetIntegration parameter
    infrastructureSubnetId: enableVnetIntegration ? vnet.outputs.containerAppsSubnetId : null
    internal: enableVnetIntegration
  }
  dependsOn: enableVnetIntegration ? [vnet] : []
}

// Azure SQL Database with private endpoint and managed identity
module sqlDatabase 'modules/sqlDatabase.bicep' = if (enableSqlDatabase) {
  name: 'sql-database'
  params: {
    sqlServerName: sqlServerName
    sqlDatabaseName: sqlDatabaseName
    location: location
    tags: tags
    administratorLogin: sqlAdminLogin
    administratorPassword: sqlAdminPassword
    skuName: sqlDatabaseSku
    skuTier: sqlDatabaseTier
    // Use private endpoint only if VNet integration is enabled
    enablePrivateEndpoint: enableVnetIntegration
    privateEndpointSubnetId: enableVnetIntegration ? vnet.outputs.privateEndpointsSubnetId : ''
    privateDnsZoneId: enableVnetIntegration ? sqlPrivateDnsZone.outputs.privateDnsZoneId : ''
    // Allow Azure services when NOT using private endpoints
    allowAzureServices: !enableVnetIntegration
  }
  dependsOn: enableVnetIntegration ? [
    vnet
    sqlPrivateDnsZone
  ] : []
}


// ACR is treated as external; avoid hard dependency at deploy time. Use name-derived login server when needed.

// Frontend Angular Container App
module frontend 'app/frontend-angular.bicep' = {
  name: 'frontendApp'
  dependsOn: [
    containerAppsEnvironment
  ]
  params: {
    name: frontendAppName
    location: location
    identityName: frontendIdentityName
    // Managed environment name matches what we created above
    containerAppsEnvironmentName: '${abbrs.appManagedEnvironments}${resourceToken}'
  // ACR name for image pull identity binding
  containerRegistryName: resolvedAcrName
  // ACR resource group (for cross-RG role assignment)
  containerRegistryResourceGroup: acrResourceGroup
    // Use provided image (from env via parameters file) or default placeholder
    image: frontendImage
  // Allow toggling AcrPull role assignment per service
  skipAcrPullRoleAssignment: skipFrontendAcrPullRoleAssignment
    // Compute sizing (exposed as parameters)
    cpu: frontendCpu
    memory: frontendMemory
    // Optional env vars (can be extended later)
    envVars: [
      {
        name: 'APP_ROLE'
        value: 'frontend'
      }
      {
        name: 'AZURE_ENV_NAME'
        value: environmentName
      }
    ]
    tags: tags
  }
}

// Backend Spring Boot Container App
module backend 'app/backend-springboot.bicep' = {
  name: 'backendApp'
  dependsOn: [
    containerAppsEnvironment
  ]
  params: {
    name: backendAppName
    location: location
    identityName: backendIdentityName
    // Managed environment name matches what we created above
    containerAppsEnvironmentName: '${abbrs.appManagedEnvironments}${resourceToken}'
    // ACR name for image pull identity binding
    containerRegistryName: resolvedAcrName
    // ACR resource group (for cross-RG role assignment)
    containerRegistryResourceGroup: acrResourceGroup
    // Use provided image (from env via parameters file) or default placeholder
    image: backendImage
    // Allow toggling AcrPull role assignment per service
    skipAcrPullRoleAssignment: skipBackendAcrPullRoleAssignment
    // Application Insights name for backend monitoring
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    enableAppInsights: true
    // Compute sizing (exposed as parameters)
    cpu: backendCpu
    memory: backendMemory
    // Replicas configuration
    minReplicas: 1
    maxReplicas: 10
    // SQL connection configuration (if SQL is enabled)
    enableSqlDatabase: enableSqlDatabase
    sqlServerFqdn: enableSqlDatabase ? sqlDatabase!.outputs.sqlServerFqdn : ''
    sqlDatabaseName: enableSqlDatabase ? sqlDatabase!.outputs.sqlDatabaseName : ''
    sqlAdminLogin: sqlAdminLogin
    // Optional env vars (can be extended later)
    envVars: [
      {
        name: 'APP_ROLE'
        value: 'backend'
      }
      {
        name: 'AZURE_ENV_NAME'
        value: environmentName
      }
    ]
    tags: tags
  }
}

// Useful outputs for azd and diagnostics
// Derive login server from the provided ACR name to avoid cross-RG coupling
output containerRegistryLoginServer string = '${resolvedAcrName}.azurecr.io'
output frontendFqdn string = frontend.outputs.fqdn
output backendFqdn string = backend.outputs.fqdn
output sqlServerFqdn string = enableSqlDatabase ? sqlDatabase!.outputs.sqlServerFqdn : ''
output sqlDatabaseName string = enableSqlDatabase ? sqlDatabase!.outputs.sqlDatabaseName : ''

/*module backend 'modules/containerApp.bicep' = {
  name: 'backendApp'
  params: {
    name: backendAppName
    location: location
    environmentId: cae.outputs.environmentId
    image: backendImage
    targetPort: 3000
    ingressExternal: false
    envVars: [
      {
        name: 'APP_ROLE'
        value: 'backend'
      }
    ]
    tags: tags
  }
}*/

//output acrLoginServer string = acr.outputs.loginServer
//output frontendUrl string = frontend.outputs.fqdn
