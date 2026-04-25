@description('Container App name')
param name string
param location string = resourceGroup().location
param tags object = {}

@description('User-assigned managed identity name')
param identityName string

@description('Container Apps Environment name')
param containerAppsEnvironmentName string

@description('ACR name (for image pull binding)')
param containerRegistryName string

@description('Resource group of the ACR (for cross-RG role assignment); defaults to current RG')
param containerRegistryResourceGroup string = resourceGroup().name

@description('Existing image reference (e.g. myacr.azurecr.io/rap-backend:latest)')
param image string

@description('Environment variables: array of { name, value }')
param envVars array = []

@description('Skip creating AcrPull role assignment for the user-assigned identity (useful when current principal lacks permissions).')
param skipAcrPullRoleAssignment bool = false

@description('Application Insights name for monitoring (optional)')
param applicationInsightsName string = ''

@description('Enable Application Insights integration')
param enableAppInsights bool = true

@description('vCPU allocation (fractional values allowed, e.g. 0.25, 0.5, 1, 2)')
param cpu int = 1

@description('Memory allocation (valid combos per Container Apps sizing; e.g. 2Gi for 1 vCPU)')
@allowed([
  '0.5Gi'
  '1Gi'
  '2Gi'
  '4Gi'
])
param memory string = '2Gi'

@description('Minimum number of replicas')
param minReplicas int = 1

@description('Maximum number of replicas')
param maxReplicas int = 10

@description('Enable session affinity (sticky sessions)')
param enableSessionAffinity bool = false

@description('Enable SQL Database connection')
param enableSqlDatabase bool = false

@description('SQL Server FQDN')
param sqlServerFqdn string = ''

@description('SQL Database name')
param sqlDatabaseName string = ''

@description('SQL admin login username')
param sqlAdminLogin string = ''

@description('Key Vault name for secrets (OIDC client secret, JWT secret)')
param keyVaultName string = ''

@description('Key Vault endpoint URI (e.g., https://myvault.vault.azure.net/)')
param keyVaultEndpoint string = ''

@description('Azure App Configuration endpoint (centralised non-secret config)')
param appConfigEndpoint string = ''

@description('JWT signing secret (stays in Key Vault — not in App Config)')
@secure()
param jwtSecret string = ''

@description('Azure AD client secret (stays in Key Vault — not in App Config)')
@secure()
param aadClientSecret string = ''

@description('CORS Allowed Origins (for Container App ingress-level CORS)')
param corsAllowedOrigins string = ''

// Existing (shared) resources
resource cai 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

// Determine if the provided image comes from the configured ACR (compile-time string comparison)
var isImageFromConfiguredAcr = split(image, '/')[0] == '${containerRegistryName}.azurecr.io'

// Optional App Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (enableAppInsights && !empty(applicationInsightsName)) {
  name: applicationInsightsName
}

// User-assigned identity (created in main.bicep — referenced as existing here)
resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

// Base env vars for Spring Boot
var baseEnvArray = [
  {
    name: 'SPRING_PROFILES_ACTIVE'
    value: 'azure'
  }
  {
    name: 'SERVER_PORT'
    value: '8080'
  }
  {
    name: 'AZURE_CLIENT_ID'
    value: uai.properties.clientId
  }
  // CORS_ALLOWED_ORIGINS needed by Spring Security CorsFilter (reads from env var)
  // App Config also stores this value, but the env var ensures it's available immediately
  // without depending on App Config refresh timing
  {
    name: 'CORS_ALLOWED_ORIGINS'
    value: corsAllowedOrigins
  }
  {
    name: 'FRONTEND_URL'
    value: corsAllowedOrigins
  }
]

// App Insights env vars (if enabled)
var appInsightsEnv = (enableAppInsights && !empty(applicationInsightsName)) ? [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights!.properties.ConnectionString
  }
] : []

// SQL Database env vars (if enabled) - using Azure AD managed identity authentication
// For user-assigned managed identity, msiClientId parameter is REQUIRED in Container Apps
var sqlEnv = enableSqlDatabase ? [
  {
    name: 'SPRING_DATASOURCE_URL'
    value: 'jdbc:sqlserver://${sqlServerFqdn}:1433;database=${sqlDatabaseName};encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;authentication=ActiveDirectoryMSI;msiClientId=${uai.properties.clientId};'
  }
  {
    name: 'SPRING_DATASOURCE_DRIVER_CLASS_NAME'
    value: 'com.microsoft.sqlserver.jdbc.SQLServerDriver'
  }
  {
    name: 'SQL_SERVER_FQDN'
    value: sqlServerFqdn
  }
  {
    name: 'SQL_DATABASE_NAME'
    value: sqlDatabaseName
  }
] : []

// Azure App Configuration endpoint (non-secret config loaded at Spring Boot startup)
var appConfigEnv = !empty(appConfigEndpoint) ? [
  {
    name: 'APP_CONFIG_ENDPOINT'
    value: appConfigEndpoint
  }
] : []

// AAD client secret (stays in Key Vault via secretRef — NOT in App Config)
var aadSecretEnv = (!empty(keyVaultName) && !empty(aadClientSecret)) ? [
  {
    name: 'AZURE_AD_CLIENT_SECRET'
    secretRef: 'aad-client-secret'
  }
] : []

// JWT secret (stays in Key Vault via secretRef — only when jwtSecret param is provided)
var jwtSecretEnv = (!empty(keyVaultName) && !empty(jwtSecret)) ? [
  {
    name: 'JWT_SECRET'
    secretRef: 'jwt-secret'
  }
] : []

// Combine base env + App Config + App Insights + SQL + secrets + caller-provided env vars
var combinedEnv = concat(baseEnvArray, appConfigEnv, appInsightsEnv, sqlEnv, jwtSecretEnv, aadSecretEnv, envVars)

// Key Vault secrets to reference — only include each secret if the value was provided
// (prevents Container Apps deployment failure when secrets don't exist in KV)
var jwtKvSecret = (!empty(keyVaultName) && !empty(jwtSecret)) ? [
  { name: 'jwt-secret' }
] : []

var aadSecret = (!empty(keyVaultName) && !empty(aadClientSecret)) ? [
  { name: 'aad-client-secret' }
] : []

var kvSecrets = concat(jwtKvSecret, aadSecret)

module backend '../modules/containerApp.bicep' = {
  name: 'backendContainer'
  // Ensure ACR role assignment is in place before the app tries to pull the image.
  // Key Vault access policy is managed by ensure-identities.sh (pre-provision hook)
  // and fully propagated before Bicep runs — no Bicep-side policy resource needed.
  dependsOn: [
    acrPull
  ]
  params: {
    name: name
    location: location
    environmentId: cai.id
    image: image    
    targetPort: 8080
    ingressExternal: true
    enableSessionAffinity: enableSessionAffinity
    userAssignedIdentity: uai.id
    // Determine if the image is coming from the configured ACR
    // Bind registry for pulls only when the source of the image matches this ACR
    acrLoginServer: isImageFromConfiguredAcr ? '${containerRegistryName}.azurecr.io' : ''
    cpu: cpu
    memory: memory
    minReplicas: minReplicas
    maxReplicas: maxReplicas    
    envVars: combinedEnv
    // CORS handled by Spring Boot CorsFilter (not ingress level) to avoid double-CORS conflicts
    // corsAllowedOrigins is instead passed as CORS_ALLOWED_ORIGINS env var above
    // Key Vault configuration for secret references
    keyVaultName: keyVaultName
    keyVaultEndpoint: keyVaultEndpoint
    keyVaultSecrets: kvSecrets
    tags: union(tags, {
      'azd-service-name': 'backend'
    })
  }
}

// Grant AcrPull to the user-assigned identity on the ACR
module acrPull '../modules/acrPullRoleAssignment.bicep' = if (!skipAcrPullRoleAssignment && isImageFromConfiguredAcr) {
  name: 'acrPullAssignBackend'
  scope: resourceGroup(containerRegistryResourceGroup)
  params: {
    acrName: containerRegistryName
    principalId: uai.properties.principalId
  }
}

output name string = name
output fqdn string = backend.outputs.fqdn
output identityResourceId string = uai.id
output identityPrincipalId string = uai.properties.principalId
output imageUsed string = image
