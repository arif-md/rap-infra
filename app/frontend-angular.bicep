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

@description('Resource group containing the ACR (for cross-RG reference)')
param containerRegistryResourceGroup string

@description('Existing image reference (e.g. myacr.azurecr.io/rap-frontend:latest)')
param image string

@description('Environment variables: array of { name, value }')
param envVars array = []

@description('Skip creating AcrPull role assignment for the user-assigned identity (useful when current principal lacks permissions).')
param skipAcrPullRoleAssignment bool = false

// App Insights wiring can be added later via Service Connector or env vars

// Application Insights injection omitted for simplicity; enable via env or Service Connector later


@description('vCPU allocation (fractional values allowed, e.g. 0.25, 0.5, 1)')
param cpu int = 1

@description('Memory allocation (valid combos per Container Apps sizing; e.g. 2Gi for 1 vCPU)')
@allowed([
  '0.5Gi'
  '1Gi'
  '2Gi'
  '4Gi'
])
param memory string = '2Gi'

param minReplicas int = 1
param maxReplicas int = 3
param enableSessionAffinity bool = false

// Existing (shared) resources
resource cai 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

// We won't directly reference ACR here to avoid cross-scope constraints; we'll pass login server via image

// Optional App Insights omitted

// User-assigned identity (for ACR pull / future use)
resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
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

// Combine base env + optional App Insights + caller-provided env vars
var combinedEnv = concat(baseEnvArray, envVars)


module frontend '../modules/containerApp.bicep' = {
  name: 'frontendContainer'
  // Ensure role assignment is in place before the app tries to pull the image
  dependsOn: [
    acrPull
  ]
  params: {
    name: name
    location: location
    environmentId: cai.id
    image: image    
    targetPort: 80
    ingressExternal: true
    enableSessionAffinity: enableSessionAffinity
    userAssignedIdentity: uai.id
  // Determine if the image is coming from the configured ACR using the provided name
  acrLoginServer: split(image, '/')[0] == '${containerRegistryName}.azurecr.io' ? '${containerRegistryName}.azurecr.io' : ''
    cpu: cpu
    memory: memory
    minReplicas: minReplicas
  maxReplicas: maxReplicas    
    //ingressHostname: empty(publicHostname) ? '' : publicHostname
    envVars: combinedEnv
    tags: union(tags, {
      'azd-service-name': 'frontend'
    })
  }
}

// Grant AcrPull to the user-assigned identity on the ACR via cross-RG module scoped to the ACR RG
module acrPull '../modules/acrPullRoleAssignment.bicep' = if (!skipAcrPullRoleAssignment) {
  name: 'acrPullAssignment'
  scope: resourceGroup(containerRegistryResourceGroup)
  params: {
    acrName: containerRegistryName
    principalId: uai.properties.principalId
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

output name string = name
output fqdn string = frontend.outputs.fqdn
output identityResourceId string = uai.id
output imageUsed string = image
