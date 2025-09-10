@description('Container App name')
param name string
param location string
param tags object = {}

@description('User-assigned managed identity name')
param identityName string

@description('Container Apps Environment name')
param containerAppsEnvironmentName string

@description('ACR name (for image pull binding)')
param containerRegistryName string

@description('Existing image reference (e.g. myacr.azurecr.io/rap-frontend:latest)')
param image string

@description('Environment variables: array of { name, value }')
param envVars array = []

@description('Set to true to inject App Insights connection string')
param enableAppInsights bool = true

@description('App Insights resource name (ignored if enableAppInsights=false or empty)')
param applicationInsightsName string = ''

@description('Toggle deployment (skip if false)')
param exists bool = true

@description('vCPU allocation (fractional values allowed, e.g. 0.25, 0.5, 1)')
param cpu int = 1

@description('Memory allocation (e.g. 0.5Gi, 1Gi, 2Gi)')
@allowed([
  '0.5Gi'
  '1Gi'
  '2Gi'
  '4Gi'
])
param memory string = '0.5Gi'

param minReplicas int = 1
param maxReplicas int = 3
param enableSessionAffinity bool = false

// Existing (shared) resources
resource cai 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

// Optional App Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (enableAppInsights && !empty(applicationInsightsName)) {
  name: applicationInsightsName
}

// User-assigned identity (for ACR pull / future use)
resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (exists) {
  name: identityName
  location: location
  tags: tags
}

// Base env as array
var baseEnvArray = [
  {
    name: 'APP_ENV'
    value: 'angular'
  }
]


module frontend '../modules/containerApp.bicep' = {
  name: 'frontendContainer'
  params: {
    name: name
    location: location
    environmentId: cai.id
    image: image    
    targetPort: 80
    ingressExternal: true
    enableSessionAffinity: enableSessionAffinity
    userAssignedIdentity: uai.id
    acrLoginServer: acr.properties.loginServer
    cpu: cpu
    memory: memory
    minReplicas: minReplicas
    maxReplicas: maxReplicas    
    //ingressHostname: empty(publicHostname) ? '' : publicHostname
    envVars: [
      {
        name: 'APP_ROLE'
        value: 'frontend'
      }
    ]
    tags: tags
  }
}


/*resource containerApp 'Microsoft.App/containerApps@2024-03-01' = if (exists) {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: cai.id
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
        stickySessions: {
          affinity: enableSessionAffinity ? 'sticky' : 'none'
        }
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: uai.id
        }
      ]
      activeRevisionsMode: 'single'
    }
    template: {
      containers: [
        {
          name: 'web'
          image: image
          env: concat(
            baseEnvArray,
            (enableAppInsights && !empty(applicationInsightsName)) ? [
              {
                name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
                value: appInsights.properties.ConnectionString
              }
            ] : [],
            envVars
          )
          resources: {
            cpu: cpu
            memory: memory
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}*/

output name string = exists ? containerApp.name : ''
output fqdn string = exists ? containerApp.properties.configuration.ingress.fqdn : ''
output identityResourceId string = exists ? uai.id : ''
output imageUsed string = image
