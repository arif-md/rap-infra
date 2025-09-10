targetScope = 'resourceGroup'

@description('Short environment name (e.g. dev, test, prod)')
@minLength(2)
@maxLength(12)
param environmentName string

@description('Azure location')
param location string = resourceGroup().location

@description('Container image (full ACR reference) for frontend (e.g. myacr.azurecr.io/rap-frontend:latest)')
param frontendImage string

@description('Container image (full ACR reference) for backend (e.g. myacr.azurecr.io/rap-backend:latest)')
param backendImage string

@description('Ingress target hostname (optional, if using custom domain later)')
@minLength(0)
param publicHostname string = ''

@description('Enable diagnostics (Log Analytics linkage)')
param enableDiagnostics bool = true

@description('Tags to apply to all resources')
param tags object = {
  environment: environmentName
  workload: 'rap'
}

var namePrefix = toLower('${environmentName}-rap')
var lawName    = '${namePrefix}-log'
var acrName    = toLower(replace('${environmentName}rapacr','-',''))
var caeName    = '${namePrefix}-cae'
var frontendAppName = '${namePrefix}-fe'
var backendAppName  = '${namePrefix}-be'

module logAnalytics 'modules/logAnalytics.bicep' = if (enableDiagnostics) {
  name: 'lawDeploy'
  params: {
    name: lawName
    location: location
    tags: tags
  }
}

module acr 'modules/containerRegistry.bicep' = {
  name: 'acrDeploy'
  params: {
    name: acrName
    location: location
    sku: 'Basic'
    adminUserEnabled: false
    tags: tags
  }
}

module cae 'modules/containerAppsEnv.bicep' = {
  name: 'caeDeploy'
  params: {
    name: caeName
    location: location
    logAnalyticsWorkspaceId: enableDiagnostics ? logAnalytics.outputs.workspaceId : ''
    tags: tags
  }
}

module frontend 'app/frontend-angular.bicep' = {
  name: 'frontendApp'
  params: {
    name: frontendAppName
    location: location
    containerAppsEnvironmentName: cae.outputs.environmentName
    image: frontendImage
    targetPort: 80
    ingressExternal: true
    ingressHostname: empty(publicHostname) ? '' : publicHostname
    envVars: [
      {
        name: 'APP_ROLE'
        value: 'frontend'
      }
    ]
    tags: tags
  }
}

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

output acrLoginServer string = acr.outputs.loginServer
output frontendUrl string = frontend.outputs.fqdn
