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

## Local authentication and az defaults

When running locally, ensure your CLI context matches CI and that no incorrect defaults are set in `az`.

### Check and clear `az` defaults

Sometimes `az` has a default resource group set (for example `group=rsg-raptor`). This can cause commands like `az acr show -n <acr>` to implicitly target the wrong RG and fail with `AuthorizationFailed`.

```powershell
# Show current subscription/tenant
az account show --output table

# List current defaults
az configure --list-defaults

# Clear an unwanted default group
az configure --defaults group=

# Verify defaults again (group should be empty)
az configure --list-defaults
```

If you need to query a specific ACR, prefer RG-scoped calls:

```powershell
az acr show -n <AZURE_ACR_NAME> -g <AZURE_ACR_RESOURCE_GROUP>
```

### Log in locally with the same service principal as CI

If you’re not authenticated (or on the wrong subscription), log in with the same service principal used in GitHub. Two options:

- Option A (use `az` only; `azd` will piggyback on the current az session)

```powershell
az login --service-principal `
	--username <AZURE_CLIENT_ID> `
	--password <AZURE_CLIENT_SECRET> `
	--tenant <AZURE_TENANT_ID>

az account set --subscription <AZURE_SUBSCRIPTION_ID>
```

- Option B (explicitly log in `azd` with the SP as well)

```powershell
azd auth login `
	--client-id <AZURE_CLIENT_ID> `
	--client-secret <AZURE_CLIENT_SECRET> `
	--tenant-id <AZURE_TENANT_ID>

# Still set the az subscription
az account set --subscription <AZURE_SUBSCRIPTION_ID>
```

### Verify local environment values

Make sure your local `azd` environment mirrors the GitHub Environment values you expect.

```powershell
azd env select test
azd env get-value AZURE_ENV_NAME              # e.g., test
azd env get-value AZURE_RESOURCE_GROUP        # e.g., rg-raptor-test
azd env get-value AZURE_ACR_NAME              # e.g., ngraptortest
azd env get-value AZURE_ACR_RESOURCE_GROUP    # ACR's RG (may differ from the app RG)
```

If needed, set or correct them:

```powershell
azd env set AZURE_ENV_NAME test
azd env set AZURE_RESOURCE_GROUP rg-raptor-test
azd env set AZURE_ACR_NAME ngraptortest
azd env set AZURE_ACR_RESOURCE_GROUP <acr-resource-group>
```

### Run deployment

```powershell
azd up --no-prompt --environment test
```

If your identity cannot read ACR via ARM but can pull images (data plane), the tooling will warn and continue. If role assignment on ACR is required, ensure your principal has Owner or User Access Administrator on the ACR’s resource group, or temporarily set:

```powershell
azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
```

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

Optional (recommended for private frontend repo): FRONTEND_REPO_READ_TOKEN

To populate the release notes with a commit list when your frontend repository is private, the promotion workflow uses an optional secret `FRONTEND_REPO_READ_TOKEN` to call the GitHub Compare API against the frontend repo.

- What it does: Enables the workflow in this infra repo to fetch commits from your private frontend repo and render them in both the markdown notes and the approval email.
- Where it’s used: `.github/workflows/promote-image.yaml` in the `prepare-and-notify` job. If the secret is not provided, the workflow falls back to the default token (which usually cannot read a different private repo), and the commit table may be empty—though the compare link will still work for authorized viewers.

How to create and add the token

1) Create a Fine-grained personal access token (recommended)
	- GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token
	- Repository access: Only select your frontend repository (e.g., `arif-md/rap-frontend`)
	- Permissions → Repository permissions:
	  - Contents: Read
	  - Metadata: Read (typically included by default)
	- Set an expiration date and keep it minimal.

2) Add the token as a secret
	- In the infra repo (this repository): Settings → Secrets and variables → Actions → New repository secret
	- Name: `FRONTEND_REPO_READ_TOKEN`
	- Value: paste the token
	- Alternatively, you can store it as an Environment secret under the `preflight` environment; the workflow references `${{ secrets.FRONTEND_REPO_READ_TOKEN }}` which resolves environment or repo secrets with the same name.

3) Verify
	- Trigger a promotion to `test`. In the job summary and the approval email, the “List of changes” section should include a commit list/table instead of being empty.

Recommended: stamp OCI labels in the frontend build

To make changelog resolution resilient even when registry tags are pruned, stamp these OCI labels when building the frontend image. The promotion workflow can recover the commit directly from the image config (no tag lookups required):

- org.opencontainers.image.revision = the full git SHA
- org.opencontainers.image.source = owner/repo (e.g., `arif-md/rap-frontend`)
- org.opencontainers.image.ref.name = branch or ref (e.g., `main`)

Example (GitHub Actions using docker/build-push-action):

```yaml
- name: Build and push frontend image
	uses: docker/build-push-action@v6
	with:
		context: .
		platforms: linux/amd64
		push: true
		tags: |
			${{ env.ACR_NAME }}.azurecr.io/raptor/frontend-dev:${{ github.sha }}
			${{ env.ACR_NAME }}.azurecr.io/raptor/frontend-dev:${{ github.sha || github.ref_name }}
			${{ env.ACR_NAME }}.azurecr.io/raptor/frontend-dev:build-${{ github.run_id }}
		labels: |
			org.opencontainers.image.title=rap-frontend
			org.opencontainers.image.source=${{ github.repository }}
			org.opencontainers.image.revision=${{ github.sha }}
			org.opencontainers.image.ref.name=${{ github.ref_name }}
```

Example (plain Docker CLI):

```bash
docker build \
	--label org.opencontainers.image.title=rap-frontend \
	--label org.opencontainers.image.source=$GITHUB_REPOSITORY \
	--label org.opencontainers.image.revision=$GITHUB_SHA \
	--label org.opencontainers.image.ref.name=${GITHUB_REF_NAME:-main} \
	-t $ACR_NAME.azurecr.io/raptor/frontend-dev:$GITHUB_SHA \
	-t $ACR_NAME.azurecr.io/raptor/frontend-dev:build-$GITHUB_RUN_ID \
	.

docker push $ACR_NAME.azurecr.io/raptor/frontend-dev:$GITHUB_SHA
docker push $ACR_NAME.azurecr.io/raptor/frontend-dev:build-$GITHUB_RUN_ID
```

How it’s used

- The promotion workflow first tries to map digest → commit using ACR tags (fast path).
- If tags are missing/pruned, it falls back to reading `org.opencontainers.image.revision` from the image config in ACR and uses that SHA to generate the compare link and commit list.
- No changes are needed in the infra repo once the labels are stamped during build.

Manual trigger

- You can run the promotion workflow manually via GitHub UI and provide an `image@digest` input.

Cross-repo dispatch

- If your frontend and infra are in different repositories, ensure the frontend repo has a PAT secret `GH_PAT_REPO_DISPATCH` in its `dev` environment. That PAT must have access to this infra repo with Actions Read/Write to send repository_dispatch events (`frontend-image-pushed` and `frontend-image-promote`).

Note: `FRONTEND_REPO_READ_TOKEN` (read access from infra → frontend for changelog) is separate from `GH_PAT_REPO_DISPATCH` (write permission from frontend → infra to trigger workflows). Use distinct tokens with the minimum scopes needed.

Prod later:

- The promotion workflow includes a guard `ENABLE_PROD_PROMOTION` repo variable. Leave it unset/false for now. When your admin creates prod RG/ACR, add the corresponding variables (in the `prod` environment), secrets for the `prod` environment, enable required reviewers, and set `ENABLE_PROD_PROMOTION=true` to include prod in the pipeline.
