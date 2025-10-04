targetScope = 'resourceGroup'

@description('Short environment name (e.g. dev, test, prod)')
@minLength(2)
@maxLength(12)
param environmentName string

@description('Azure location')
param location string = resourceGroup().location

@description('Container image (full ACR reference) for frontend (e.g. myacr.azurecr.io/rap-frontend:latest)')
param frontendImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

/* Removed backendImage and publicHostname parameters for simplicity */


@description('Optional override for ACR name (use existing)')
param acrNameOverride string = ''

@description('Skip creating AcrPull role assignment for the frontend identity (useful for local runs without RBAC)')
param skipAcrPullRoleAssignment bool = true

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

@description('Tags to apply to all resources')
param tags object = {
  environment: environmentName
  workload: 'rap'
}

var namePrefix = toLower('${environmentName}-rap')
var acrName    = !empty(acrNameOverride) ? acrNameOverride : toLower(replace('${environmentName}rapacr','-',''))
var frontendAppName = '${namePrefix}-fe'
var frontendIdentityName = '${abbrs.managedIdentityUserAssignedIdentities}${resourceToken}'

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

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.4.5' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
  }
}


// Treat ACR as an external dependency (created outside the stack via hook)
resource acrExisting 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

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
    containerRegistryName: acrName
    // Use provided image (from env via parameters file) or default placeholder
    image: frontendImage
  // Allow toggling AcrPull role assignment
  skipAcrPullRoleAssignment: skipAcrPullRoleAssignment
    // Compute sizing (exposed as parameters)
    cpu: frontendCpu
    memory: frontendMemory
    // Optional env vars (can be extended later)
    envVars: [
      {
        name: 'APP_ROLE'
        value: 'frontend'
      }
    ]
    tags: tags
  }
}
// Useful outputs for azd and diagnostics
output containerRegistryLoginServer string = acrExisting.properties.loginServer
output frontendFqdn string = frontend.outputs.fqdn

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
