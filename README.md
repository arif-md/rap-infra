# Initialize, provision resources and deploy app to Azure using AZD
## Prerequisites
* Install AZD client

```
winget install microsoft.azd
winget upgrade microsoft.azd
azd version
```

* setup the AZD environment. Note: Deployment stack feature requires az CLI >= 2.61.0

```
azd config set alpha.deployment.stacks on 
azd env new test
azd env select test
azd env list
azd env set AZURE_SUBSCRIPTION_ID <subsription ID>
azd env set AZURE_LOCATION eastus2
azd env set AZURE_CLIENT_ID <service principal ID>
azd env set AZURE_CLIENT_SECRET <service principal password>
azd env set AZURE_TENANT_ID <tenant ID>
```

## Provision and deploy the app resources
```
azd auth login
azd up
```
