// This template calculates the Key Vault name for a given environment
// It uses the same naming logic as the main deployment (main.bicep)
//
// Usage:
//   az deployment group create \
//     --resource-group rg-raptor-test \
//     --template-file docs/calculate-keyvault-name.bicep \
//     --parameters environmentName=dev \
//     --query properties.outputs.keyVaultName.value \
//     -o tsv

param environmentName string

output resourceToken string = toLower('${environmentName}-${uniqueString(subscription().id, environmentName)}')
output keyVaultName string = 'kv-${toLower(environmentName)}-${uniqueString(subscription().id, environmentName)}-v1'
