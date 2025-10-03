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

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

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
    envVars: combinedEnv
    tags: union(tags, {
      'azd-service-name': 'frontend'
    })
  }
}

// Grant AcrPull to the user-assigned identity on the ACR
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipAcrPullRoleAssignment) {
  name: guid(acr.id, 'AcrPull', uai.id)
  scope: acr
  properties: {
    principalId: uai.properties.principalId
    // Specify principalType to mitigate replication delay issues when the identity is newly created
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
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
