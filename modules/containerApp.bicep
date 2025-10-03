param name string
param location string
param environmentId string
param image string
param targetPort int
param ingressExternal bool = true
param enableSessionAffinity bool = false
param userAssignedIdentity string
/*@description('Optional custom hostname (requires DNS + cert config separately)')
param ingressHostname string = ''*/
@description('Environment variables array: [{ name: string; value: string }]')
param envVars array = []
param tags object = {}
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
param acrLoginServer string

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity}': {}
    }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      ingress: {
        external: ingressExternal
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
        //fqdn: empty(ingressHostname) ? null : ingressHostname
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
          server: acrLoginServer
          identity: userAssignedIdentity
        }
      ]      
      activeRevisionsMode: 'single'
      dapr: {
        enabled: false
      }
      secrets: []
      /*runtime: {
        containerAppRuntimePlatform: {
          osType: 'Linux'
        }
      }*/
    }
    template: {
      containers: [
        {
          name: name
          image: image
          env: envVars
          resources: {
            cpu: cpu
            memory: memory
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: []
      }
    }
  }  
}

output fqdn string = app.properties.configuration.ingress.fqdn
