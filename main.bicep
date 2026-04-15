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

@description('Container image (full ACR reference) for processes (e.g. myacr.azurecr.io/rap-processes:latest)')
param processesImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

/* Removed publicHostname parameter for simplicity */


@description('Optional ACR name (use existing); when empty, a default is derived from environmentName')
param acrName string = ''

@description('Optional override for ACR resource group (when ACR is in a different RG)')
param acrResourceGroupOverride string = ''

@description('Skip creating AcrPull role assignment for frontend (useful for local runs without RBAC)')
param skipFrontendAcrPullRoleAssignment bool = true

@description('Skip creating AcrPull role assignment for backend (useful for local runs without RBAC)')
param skipBackendAcrPullRoleAssignment bool = true

@description('Skip creating AcrPull role assignment for processes (useful for local runs without RBAC)')
param skipProcessesAcrPullRoleAssignment bool = true

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

@description('vCPU allocation for processes container app (integer, default 1)')
param processesCpu int = 1

@description('Memory allocation for processes container app (valid combos with selected CPU; e.g., 2Gi for 1 vCPU)')
@allowed([
  '0.5Gi'
  '1Gi'
  '2Gi'
  '4Gi'
])
param processesMemory string = '2Gi'

@description('Enable Azure SQL Database')
param enableSqlDatabase bool = true

@description('Enable VNet integration for Container Apps and SQL Private Endpoints (requires Microsoft.ContainerService provider)')
param enableVnetIntegration bool = false

@description('Key Vault name to use (if empty, will use default naming pattern). Key Vault is never deleted by azd down.')
param keyVaultName string = ''

@description('SQL Server administrator login')
param sqlAdminLogin string = 'sqladmin'

@description('SQL Server administrator password')
@secure()
param sqlAdminPassword string

@description('Azure AD security group name to grant db_owner on the SQL database (for human admin access via portal)')
param sqlAdGroupName string = ''

@description('Azure AD security group object ID (required when sqlAdGroupName is set)')
param sqlAdGroupObjectId string = ''

@description('Flyway validate on migrate for processes service (set to false if migrations were removed/refactored)')
param flywayValidateOnMigrate string = 'true'

@description('Enable monitoring (Log Analytics Workspace + Application Insights). Disable for faster provisioning.')
param enableMonitoring bool = true

@description('Skip SQL setup ACI script (role assignments + schema bootstrap). Use after first successful deploy for faster iterations.')
param skipSqlSetup bool = false

@description('Custom domain name for rule-based routing (e.g., nexgeninc-dev.com). When empty, custom domain is not configured.')
param customDomainName string = ''

// Derived flag — true when a custom domain is configured
var enableCustomDomain = !empty(customDomainName)

@description('SQL Database SKU name')
param sqlDatabaseSku string = 'Basic'

@description('SQL Database tier')
param sqlDatabaseTier string = 'Basic'

@description('OIDC Provider Authorization Endpoint URL')
param oidcAuthorizationEndpoint string = ''

@description('OIDC Provider Token Endpoint URL')
param oidcTokenEndpoint string = ''

@description('OIDC Provider User Info Endpoint URL')
param oidcUserInfoEndpoint string = ''

@description('OIDC Provider JWK Set URI')
param oidcJwkSetUri string = ''

@description('OIDC Provider End Session Endpoint (for logout)')
param oidcEndSessionEndpoint string = ''

@description('OIDC Client ID (Public client - no secret needed for PKCE)')
param oidcClientId string = ''

@description('OIDC additional request parameters (optional - provider-specific)')
param oidcAcrValues string = ''
param oidcPrompt string = ''
param oidcResponseType string = ''

@description('Azure AD / Entra ID Configuration (Internal User Login - endpoints derived from tenant ID)')
param aadClientId string = ''
@secure()
param aadClientSecret string = ''
param aadTenantId string = ''

@description('JWT Secret Key for signing tokens (will be stored in Key Vault)')
@secure()
param jwtSecret string = ''

@description('JWT Issuer (default: raptor-app)')
param jwtIssuer string = 'raptor-app'

@description('JWT Access Token Expiration in Minutes (default: 15)')
param jwtAccessTokenExpirationMinutes int = 15

@description('JWT Refresh Token Expiration in Days (default: 7)')
param jwtRefreshTokenExpirationDays int = 7

@description('CORS Allowed Origins (comma-separated)')
param corsAllowedOrigins string = ''

@description('Frontend URL for OAuth2 redirects (single URL)')
param frontendUrl string = ''

@description('Tags to apply to all resources')
param tags object = {
  environment: environmentName
  workload: 'rap'
}

var namePrefix = toLower('${environmentName}-rap')
var resolvedAcrName = !empty(acrName) ? acrName : toLower(replace('${environmentName}rapacr','-',''))
var acrResourceGroup = empty(acrResourceGroupOverride) ? resourceGroup().name : acrResourceGroupOverride
var frontendAppName = '${namePrefix}-fe'
var frontendIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}frontend-${resourceToken}'
var backendAppName = '${namePrefix}-be'
var backendIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}backend-${resourceToken}'
var processesAppName = '${namePrefix}-proc'
var processesIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}processes-${resourceToken}'
var sqlAdminIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}sqladmin-${resourceToken}'
var sqlServerName = '${abbrs.sqlServers}${resourceToken}'
var sqlDatabaseName = '${abbrs.sqlServersDatabases}raptor-${environmentName}'
var vnetName = '${abbrs.networkVirtualNetworks}${resourceToken}'

var abbrs = loadJsonContent('./abbreviations.json')
// Use environment name for predictable, stable resource naming
// This ensures the same Key Vault is reused across deployments
var resourceToken = toLower('${environmentName}-${uniqueString(subscription().id, environmentName)}')

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

// Monitor application with Azure Monitor (optional — disable for faster provisioning)
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = if (enableMonitoring) {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    // Dashboard removed - causes deployment stack failures (known issue with Microsoft.Portal/dashboards in alpha stacks)
    // applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Key Vault for storing secrets (OIDC client secret, JWT secret)
// Key Vault is NEVER deployed or deleted by azd - it's managed externally
// If it doesn't exist, create it manually using docs/MANUAL-KEYVAULT-SETUP.md
// This prevents soft-delete conflicts and preserves secrets across azd down/up cycles
var isProduction = environmentName == 'prod' || environmentName == 'production'
var keyVaultSoftDeleteRetention = isProduction ? 90 : 7
var keyVaultEnablePurgeProtection = true  // Required by Azure policy - cannot be disabled
var resolvedKeyVaultName = !empty(keyVaultName) ? keyVaultName : '${abbrs.keyVaultVaults}${resourceToken}-v10'

// OIDC additional parameters are stored in Azure App Configuration (oidc.addl.req.param.*)
// They flow: azd env → main.parameters.json → app-configuration.bicep → App Config store → Spring Boot

// Reference existing Key Vault (not deployed by this template)
resource existingKeyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: resolvedKeyVaultName
}

// ============================================================================
// Backend Managed Identity (created here so App Config can grant access
// before the Container App starts)
// ============================================================================
resource backendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: backendIdentityName
  location: location
  tags: tags
}

// Processes identity created here (alongside backend) so the SQL role
// assignment deployment script can reference its principalId without
// creating a circular dependency with the processes container module.
resource processesIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: processesIdentityName
  location: location
  tags: tags
}

// ============================================================================
// SQL Admin Managed Identity — direct Azure AD admin for SQL Server
// ============================================================================
// Using a dedicated managed identity as the direct SQL AD admin avoids the
// "Directory Readers" problem: when an AD Group is the admin, SQL Server needs
// to resolve group membership but lacks the Azure AD role to do so.
// This identity is the direct admin (no group lookup) and is used by the
// deployment script to grant DB-level permissions to service identities.
// ============================================================================
resource sqlAdminIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (enableSqlDatabase) {
  name: sqlAdminIdentityName
  location: location
  tags: tags
}

// ============================================================================
// Azure App Configuration — centralised non-secret config
// ============================================================================
var appConfigName = '${abbrs.appConfigurationStores}${resourceToken}'

// Derive frontend URL from the Container App Environment's default domain.
// When a custom domain is configured, use that instead (same-origin for all services).
var defaultFrontendUrl = 'https://${frontendAppName}.${containerAppsEnvironment.properties.defaultDomain}'
var computedFrontendUrl = enableCustomDomain ? 'https://${customDomainName}' : defaultFrontendUrl
// When custom domain is active, backend is accessed via custom domain routing (same-origin).
// When not, use the direct backend URL.
var defaultBackendUrl = 'https://${backendAppName}.${containerAppsEnvironment.properties.defaultDomain}'
var computedBackendUrl = enableCustomDomain ? 'https://${customDomainName}' : defaultBackendUrl

module appConfiguration 'shared/app-configuration.bicep' = {
  name: 'appConfiguration'
  params: {
    name: appConfigName
    location: location
    tags: tags
    sku: 'free'
    // Grant backend managed identity read access
    readerPrincipalId: backendIdentity.properties.principalId
    // OIDC provider configuration
    oidcAuthorizationEndpoint: oidcAuthorizationEndpoint
    oidcTokenEndpoint: oidcTokenEndpoint
    oidcUserInfoEndpoint: oidcUserInfoEndpoint
    oidcJwkSetUri: oidcJwkSetUri
    oidcEndSessionEndpoint: oidcEndSessionEndpoint
    oidcClientId: oidcClientId
    oidcAcrValues: oidcAcrValues
    oidcPrompt: oidcPrompt
    oidcResponseType: oidcResponseType
    // Azure AD / Entra ID
    aadClientId: aadClientId
    aadTenantId: aadTenantId
    // JWT (non-secret settings)
    jwtIssuer: jwtIssuer
    jwtAccessTokenExpirationMinutes: jwtAccessTokenExpirationMinutes
    jwtRefreshTokenExpirationDays: jwtRefreshTokenExpirationDays
    // CORS & frontend — derived from CAE default domain to avoid stale azd env values
    // after azd down + up (Container App Environment domain suffix changes each time)
    corsAllowedOrigins: !empty(corsAllowedOrigins) ? corsAllowedOrigins : computedFrontendUrl
    frontendUrl: !empty(frontendUrl) ? frontendUrl : computedFrontendUrl
  }
}

/*
// Key Vault module - COMMENTED OUT to prevent azd from deleting it
// Create Key Vault manually using docs/MANUAL-KEYVAULT-SETUP.md or scripts/ensure-keyvault.ps1
module keyVault 'shared/keyvault.bicep' = {
  name: 'keyVault'
  params: {
    name: resolvedKeyVaultName
    location: location
    tags: tags
    principalId: ''
    softDeleteRetentionInDays: keyVaultSoftDeleteRetention
    enablePurgeProtection: keyVaultEnablePurgeProtection
    secrets: [
  
      {
        name: 'jwt-secret'
        value: jwtSecret
      }
    ]
  }
}
*/

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

// Container Apps Environment — deployed directly (not via AVM) for conditional monitoring support
resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${abbrs.appManagedEnvironments}${resourceToken}'
  location: location
  tags: tags
  properties: {
    // Only wire up Log Analytics when monitoring is enabled
    appLogsConfiguration: enableMonitoring ? {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace!.properties.customerId
        sharedKey: logAnalyticsWorkspace!.listKeys().primarySharedKey
      }
    } : null
    zoneRedundant: false
    vnetConfiguration: enableVnetIntegration ? {
      internal: true
      infrastructureSubnetId: vnet.outputs.containerAppsSubnetId
    } : null
  }
  dependsOn: enableVnetIntegration ? [vnet] : []
}

// Reference Log Analytics workspace (only when monitoring is enabled)
// Must be listed AFTER monitoring module so it exists before CAE reads its properties
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (enableMonitoring) {
  name: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
  dependsOn: [monitoring]
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
    // Azure AD admin: use the dedicated SQL admin managed identity (direct admin, no group lookup)
    azureAdAdminObjectId: sqlAdminIdentity!.properties.principalId
    azureAdAdminLogin: sqlAdminIdentityName
    azureAdAdminPrincipalType: 'Application'
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

// Backend Spring Boot Container App
module backend 'app/backend-springboot.bicep' = {
  name: 'backendApp'
  dependsOn: (enableSqlDatabase && !skipSqlSetup) ? [
    // containerAppsEnvironment dependency is auto-inferred by Bicep via containerAppsEnvironmentName param
    // appConfiguration dependency is implicit via appConfiguration.outputs.endpoint reference
    // Wait for combined SQL setup (role assignments + schema bootstrap)
    sqlSetup
  ] : []
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
    // Application Insights name for backend monitoring (only when monitoring is enabled)
    applicationInsightsName: enableMonitoring ? '${abbrs.insightsComponents}${resourceToken}' : ''
    enableAppInsights: enableMonitoring
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
    // Key Vault configuration for secrets only (jwt-secret, aad-client-secret)
    keyVaultName: resolvedKeyVaultName
    keyVaultEndpoint: existingKeyVault.properties.vaultUri
    // Azure App Configuration — non-secret config loaded by Spring Cloud Azure at startup
    appConfigEndpoint: appConfiguration.outputs.endpoint
    // AAD client secret (stays in Key Vault — not in App Config)
    aadClientSecret: aadClientSecret
    // CORS: Used at Container App ingress level (also stored in App Config for Spring Boot)
    corsAllowedOrigins: !empty(corsAllowedOrigins) ? corsAllowedOrigins : computedFrontendUrl
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

// Frontend Angular Container App (can deploy in parallel with backend if no dependency)
module frontend 'app/frontend-angular.bicep' = {
  name: 'frontendApp'
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
      {
        name: 'API_BASE_URL'
        value: computedBackendUrl
      }
    ]
    tags: tags
  }
  // containerAppsEnvironment dependency is auto-inferred by Bicep via containerAppsEnvironmentName param
}

// Processes jBPM Container App (can deploy in parallel with other services)
module processes 'app/processes-springboot.bicep' = {
  name: 'processesApp'
  params: {
    name: processesAppName
    location: location
    identityName: processesIdentityName
    // Managed environment name matches what we created above
    containerAppsEnvironmentName: '${abbrs.appManagedEnvironments}${resourceToken}'
    // ACR name for image pull identity binding
    containerRegistryName: resolvedAcrName
    // ACR resource group (for cross-RG role assignment)
    containerRegistryResourceGroup: acrResourceGroup
    // Use provided image (from env via parameters file) or default placeholder
    image: processesImage
    // Allow toggling AcrPull role assignment per service
    skipAcrPullRoleAssignment: skipProcessesAcrPullRoleAssignment
    // Application Insights name for processes monitoring (only when monitoring is enabled)
    applicationInsightsName: enableMonitoring ? '${abbrs.insightsComponents}${resourceToken}' : ''
    enableAppInsights: enableMonitoring
    // Compute sizing (exposed as parameters)
    cpu: processesCpu
    memory: processesMemory
    // Replicas configuration
    minReplicas: 1
    maxReplicas: 10
    // SQL connection configuration (if SQL is enabled)
    enableSqlDatabase: enableSqlDatabase
    sqlServerFqdn: enableSqlDatabase ? sqlDatabase!.outputs.sqlServerFqdn : ''
    sqlDatabaseName: enableSqlDatabase ? sqlDatabase!.outputs.sqlDatabaseName : ''
    sqlAdminLogin: sqlAdminLogin
    // Flyway configuration
    flywayValidateOnMigrate: flywayValidateOnMigrate
    // Optional env vars (can be extended later)
    envVars: [
      {
        name: 'APP_ROLE'
        value: 'processes'
      }
      {
        name: 'AZURE_ENV_NAME'
        value: environmentName
      }
    ]
    tags: tags
  }
  dependsOn: (enableSqlDatabase && !skipSqlSetup) ? [
    containerAppsEnvironment
    // Wait for combined SQL setup (role assignments + schema bootstrap)
    sqlSetup
  ] : [
    containerAppsEnvironment
  ]
}

// ============================================================================
// Combined SQL Setup — role assignments + schema bootstrap in ONE ACI container
// ============================================================================
// Merging two sequential ACI deployment scripts into one eliminates an entire
// container spin-up cycle (~4-5 min saved). Uses content-based forceUpdateTag
// so it only re-runs when inputs actually change.
// ============================================================================
module sqlSetup 'modules/sql-setup.bicep' = if (enableSqlDatabase && !skipSqlSetup) {
  name: 'sql-setup'
  params: {
    location: location
    tags: tags
    sqlServerFqdn: sqlDatabase!.outputs.sqlServerFqdn
    sqlDatabaseName: sqlDatabase!.outputs.sqlDatabaseName
    sqlAdminIdentityId: sqlAdminIdentity!.id
    identityGrants: [
      {
        name: backendIdentityName
        clientId: backendIdentity.properties.clientId
        roles: [ 'db_datareader', 'db_datawriter', 'db_ddladmin' ]
      }
      {
        name: processesIdentityName
        clientId: processesIdentity.properties.clientId
        roles: [ 'db_datareader', 'db_datawriter', 'db_ddladmin' ]
      }
    ]
    adAdminGroup: !empty(sqlAdGroupName) && !empty(sqlAdGroupObjectId) ? {
      name: sqlAdGroupName
      objectId: sqlAdGroupObjectId
    } : {}
    backendIdentityName: backendIdentityName
    processesIdentityName: processesIdentityName
  }
}

// ============================================================================
// Custom Domain with Rule-Based Routing (conditional)
// ============================================================================
module customDomain 'modules/custom-domain.bicep' = if (enableCustomDomain) {
  name: 'customDomain'
  params: {
    containerAppsEnvironmentName: containerAppsEnvironment.name
    frontendAppName: frontendAppName
    backendAppName: backendAppName
    processesAppName: processesAppName
  }
  dependsOn: [
    frontend
    backend
    processes
  ]
}

// Useful outputs for azd and diagnostics
// Derive login server from the provided ACR name to avoid cross-RG coupling
output containerRegistryLoginServer string = '${resolvedAcrName}.azurecr.io'
output frontendFqdn string = frontend.outputs.fqdn
output backendFqdn string = backend.outputs.fqdn
output processesFqdn string = processes.outputs.fqdn
output customDomainUrl string = enableCustomDomain ? 'https://${customDomainName}' : ''
output routeConfigFqdn string = enableCustomDomain ? customDomain!.outputs.routeConfigFqdn : ''
output sqlServerFqdn string = enableSqlDatabase ? sqlDatabase!.outputs.sqlServerFqdn : ''
output sqlDatabaseName string = enableSqlDatabase ? sqlDatabase!.outputs.sqlDatabaseName : ''
output backendIdentityName string = backendIdentityName
output backendIdentityPrincipalId string = backend.outputs.identityPrincipalId
output processesIdentityName string = processesIdentityName
output processesIdentityPrincipalId string = processesIdentity.properties.principalId
output appConfigEndpoint string = appConfiguration.outputs.endpoint
output appConfigName string = appConfiguration.outputs.name

// SQL setup status (combined — role assignments + schema bootstrap)
output sqlSetupStatus string = (enableSqlDatabase && !skipSqlSetup) ? sqlSetup!.outputs.scriptOutput : 'skipped'

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
