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

@description('Key Vault name to use (if empty, will use default naming pattern). Key Vault is never deleted by azd down.')
param keyVaultName string = ''

@description('SQL Server administrator login')
param sqlAdminLogin string = 'sqladmin'

@description('SQL Server administrator password')
@secure()
param sqlAdminPassword string

@description('Azure AD admin object ID (for SQL Server Azure AD admin)')
param sqlAzureAdAdminObjectId string = ''

@description('Azure AD admin login name (display name or email)')
param sqlAzureAdAdminLogin string = ''

@description('Azure AD admin principal type: Application (for service principals), User, or Group')
param sqlAzureAdAdminPrincipalType string = 'Application'

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

@description('OIDC Client ID (Public client - no secret needed for PKCE)')
param oidcClientId string = ''

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

// Key Vault for storing secrets (OIDC client secret, JWT secret)
// Key Vault is NEVER deployed or deleted by azd - it's managed externally
// If it doesn't exist, create it manually using docs/MANUAL-KEYVAULT-SETUP.md
// This prevents soft-delete conflicts and preserves secrets across azd down/up cycles
var isProduction = environmentName == 'prod' || environmentName == 'production'
var keyVaultSoftDeleteRetention = isProduction ? 90 : 7
var keyVaultEnablePurgeProtection = true  // Required by Azure policy - cannot be disabled
var resolvedKeyVaultName = !empty(keyVaultName) ? keyVaultName : '${abbrs.keyVaultVaults}${resourceToken}-v10'

// Reference existing Key Vault (not deployed by this template)
resource existingKeyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: resolvedKeyVaultName
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
    // Azure AD admin configuration (for managed identity authentication)
    azureAdAdminObjectId: sqlAzureAdAdminObjectId
    azureAdAdminLogin: sqlAzureAdAdminLogin
    azureAdAdminPrincipalType: sqlAzureAdAdminPrincipalType
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
    // Key Vault configuration for OIDC and JWT secrets
    // Key Vault name is resolved from parameter or default naming pattern
    keyVaultName: resolvedKeyVaultName
    keyVaultEndpoint: existingKeyVault.properties.vaultUri
    // OIDC configuration
    oidcAuthorizationEndpoint: oidcAuthorizationEndpoint
    oidcTokenEndpoint: oidcTokenEndpoint
    oidcUserInfoEndpoint: oidcUserInfoEndpoint
    oidcJwkSetUri: oidcJwkSetUri
    oidcClientId: oidcClientId
    // JWT configuration
    jwtIssuer: jwtIssuer
    jwtAccessTokenExpirationMinutes: jwtAccessTokenExpirationMinutes
    jwtRefreshTokenExpirationDays: jwtRefreshTokenExpirationDays
    // CORS: Use provided origins or allow all during initial deployment (updated via workflow)
    corsAllowedOrigins: !empty(corsAllowedOrigins) ? corsAllowedOrigins : '*'
    frontendUrl: '' // Not needed for CORS, can be set via env var if backend needs it
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
        value: 'https://${backend.outputs.fqdn}'
      }
    ]
    tags: tags
  }
  dependsOn: [
    containerAppsEnvironment
  ]
}

// Useful outputs for azd and diagnostics
// Derive login server from the provided ACR name to avoid cross-RG coupling
output containerRegistryLoginServer string = '${resolvedAcrName}.azurecr.io'
output frontendFqdn string = frontend.outputs.fqdn
output backendFqdn string = backend.outputs.fqdn
output sqlServerFqdn string = enableSqlDatabase ? sqlDatabase!.outputs.sqlServerFqdn : ''
output sqlDatabaseName string = enableSqlDatabase ? sqlDatabase!.outputs.sqlDatabaseName : ''
output backendIdentityName string = backendIdentityName
output backendIdentityPrincipalId string = backend.outputs.identityPrincipalId

// SQL permission grant script for manual execution via Azure Portal
output sqlPermissionScript string = enableSqlDatabase ? replace(replace('''
-- ========================================
-- SQL Permissions for Backend Managed Identity
-- ========================================
-- Execute this script in Azure Portal Query Editor after deployment
-- Connect to database: __DATABASE_NAME__
--
-- IMPORTANT: Replace the variable placeholder below with the actual value:
-- Variable: backendIdentityName
-- Value: __IDENTITY_VALUE__
--
-- Instructions:
-- 1. Go to Azure Portal > SQL Database > __DATABASE_NAME__
-- 2. Click "Query editor" in left menu
-- 3. Sign in with Azure AD (use the SQL Server Azure AD admin account)
-- 4. Copy this entire script
-- 5. Replace ${backendIdentityName} with the value shown above
-- 6. Click "Run"
-- ========================================

-- Create user for backend managed identity
CREATE USER [${backendIdentityName}] FROM EXTERNAL PROVIDER;
GO

-- Grant read permissions
ALTER ROLE db_datareader ADD MEMBER [${backendIdentityName}];
GO

-- Grant write permissions
ALTER ROLE db_datawriter ADD MEMBER [${backendIdentityName}];
GO

-- Grant DDL permissions (for Flyway migrations)
ALTER ROLE db_ddladmin ADD MEMBER [${backendIdentityName}];
GO

-- Verify the user was created
SELECT 
    name as UserName,
    type_desc as UserType,
    create_date as CreatedDate
FROM sys.database_principals 
WHERE name = '${backendIdentityName}';
GO

-- ========================================
-- Script execution complete!
-- ========================================
''', '__DATABASE_NAME__', sqlDatabase!.outputs.sqlDatabaseName), '__IDENTITY_VALUE__', backendIdentityName) : ''

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
