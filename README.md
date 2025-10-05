# Provision the infrastructure and deploy the services

## Prerequisites
- Azure CLI (az) 2.61.0 or newer (required for Deployment Stacks alpha)
- Azure Developer CLI (azd)
- Docker Desktop (optional; not required when deploying a prebuilt image)

Windows install (PowerShell):

```
winget install microsoft.azd
winget upgrade microsoft.azd
azd version
az version
```

## One-time environment setup (local)
From this `infra/` folder:

```
azd config set alpha.deployment.stacks on
azd env new test
azd env select test
# Required env values used by Bicep/parameters
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION eastus2
azd env set AZURE_ENV_NAME test
azd env set AZURE_RESOURCE_GROUP rg-raptor-test
azd env set AZURE_ACR_NAME ngraptortest
# If your ACR name differs from the default mapping, set the override too
azd env set acrNameOverride ngraptortest
```

Notes
- Local auth uses your signed-in user by default. Run `azd auth login` (or `az login`) and ensure you’re targeting the same subscription as CI.
- The deployment uses a prebuilt container image parameter; Docker is not required to run `azd up` locally.

## Provision and deploy

```
azd auth login
azd up
```

After a successful deploy, get the frontend URL:

```
azd env get-value frontendFqdn
```

In CI, the workflow prints the URL in the job logs as “Frontend URL: https://…”, adds it to the job summary under “Deployment endpoints,” and exposes it as `frontendFqdn` output.

## Clean up resources (safe)

Deployment Stacks are enabled, so `azd down` deletes the managed resources it created while leaving the resource group itself intact (per template configuration).

```
azd env select test
azd down
```

Tip
- Verify you’re on the expected subscription/tenant before running down:
	- `az account show --output table`
	- `azd env list`
