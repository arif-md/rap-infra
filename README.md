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
azd env new dev
azd env select dev
# Required env values used by Bicep/parameters
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION eastus2
azd env set AZURE_ENV_NAME dev
azd env set AZURE_RESOURCE_GROUP rg-raptor-dev
azd env set AZURE_ACR_NAME ngraptordev
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
azd env select dev
azd down
```

Tip
- Verify you’re on the expected subscription/tenant before running down:
	- `az account show --output table`
	- `azd env list`

## Image promotion (dev → test → prod)

We promote the exact built image by digest to higher environments to avoid drift.

- The frontend workflow builds and pushes an image to the dev ACR and produces an image by digest, for example: `ngraptordev.azurecr.io/raptor/frontend-dev@sha256:...`.
- It dispatches two events to this repo:
	- `frontend-image-pushed` → triggers infra deploy for the current environment.
	- `frontend-image-promote` → triggers `.github/workflows/promote-image.yaml` to promote to `test` then `prod`.

What promotion does per environment:

1) Uses OIDC to login to Azure and azd.
2) Imports the manifest by digest into the target environment ACR repo using `az acr import` (no rebuild):
	 - Source: the `image@digest` from the dev build
	 - Target: `<AZURE_ACR_NAME_<ENV>>.azurecr.io/raptor/frontend-<env>:promoted-<runId>`
3) Deploys by digest in that environment by setting `SERVICE_FRONTEND_IMAGE_NAME` to `<acr>.azurecr.io/raptor/frontend-<env>@<digest>` and forcing `SKIP_ACR_PULL_ROLE_ASSIGNMENT=false`.

Approvals

- Jobs are bound to environment scopes (`dev`, `test`, and later `prod`). Configure required reviewers in GitHub Environments to enforce manual approvals before each stage runs. For now, set approvals on `test`; `prod` can be enabled later.

Required variables/secrets

- Environment-scoped variables (define these in each GitHub Environment):
	- dev: `AZURE_ACR_NAME=ngraptordev`, `AZURE_RESOURCE_GROUP=rg-raptor-dev`, `AZURE_LOCATION=<region>`
	- test: `AZURE_ACR_NAME=ngraptortest`, `AZURE_RESOURCE_GROUP=rg-raptor-test`, `AZURE_LOCATION=<region>`
- Environment secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` must exist for each environment (`dev`, `test`, and later `prod`).

Manual trigger

- You can run the promotion workflow manually via GitHub UI and provide an `image@digest` input.

Cross-repo dispatch

- If your frontend and infra are in different repositories, ensure the frontend repo has a PAT secret `GH_PAT_REPO_DISPATCH` in its `dev` environment. That PAT must have access to this infra repo with Actions Read/Write to send repository_dispatch events (`frontend-image-pushed` and `frontend-image-promote`).

Prod later:

- The promotion workflow includes a guard `ENABLE_PROD_PROMOTION` repo variable. Leave it unset/false for now. When your admin creates prod RG/ACR, add the corresponding variables (in the `prod` environment), secrets for the `prod` environment, enable required reviewers, and set `ENABLE_PROD_PROMOTION=true` to include prod in the pipeline.
