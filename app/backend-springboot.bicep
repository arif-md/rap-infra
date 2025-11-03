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

// User-assigned identity (for ACR pull / future use)
resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
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
]

// App Insights env vars (if enabled)
var appInsightsEnv = (enableAppInsights && !empty(applicationInsightsName)) ? [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights!.properties.ConnectionString
  }
] : []

// SQL Database env vars (if enabled) - using Azure AD managed identity authentication
var sqlEnv = enableSqlDatabase ? [
  {
    name: 'SPRING_DATASOURCE_URL'
    value: 'jdbc:sqlserver://${sqlServerFqdn}:1433;database=${sqlDatabaseName};encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;authentication=ActiveDirectoryMSI;'
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

// Combine base env + optional App Insights + SQL + caller-provided env vars
var combinedEnv = concat(baseEnvArray, appInsightsEnv, sqlEnv, envVars)

module backend '../modules/containerApp.bicep' = {
  name: 'backendContainer'
  // Ensure role assignment is in place before the app tries to pull the image
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
