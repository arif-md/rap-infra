param name string
param location string = resourceGroup().location
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: name
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
    features: {
      searchVersion: 2
    }
  }
  tags: tags
}

output workspaceId string = workspace.id
