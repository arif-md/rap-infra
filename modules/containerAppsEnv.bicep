param name string
param location string
@description('Optional Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string = ''
param tags object = {}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  properties: union({
      workloadProfiles: [
        {
          name: 'Consumption'
          workloadProfileType: 'Consumption'
        }
      ]
    },
    empty(logAnalyticsWorkspaceId)
      ? {}
      : {
          appLogsConfiguration: {
            destination: 'log-analytics'
            logAnalyticsConfiguration: {
              customerId: reference(logAnalyticsWorkspaceId, '2022-10-01').customerId
              sharedKey: listKeys(logAnalyticsWorkspaceId, '2022-10-01').primarySharedKey
            }
          }
        }
  )
  tags: tags
}

output environmentName string = env.name
