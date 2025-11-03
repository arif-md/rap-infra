# Infrastructure Documentation

## 📚 Quick Links

- **[SQL Connection Guide](./SQL-CONNECTION-GUIDE.md)** - Complete guide to SQL Database connectivity, authentication, and network modes
- **[SQL Permissions Automation](./SQL-PERMISSIONS-AUTOMATION.md)** - How managed identity SQL permissions are automatically configured
- **[VNet Integration Guide](./VNET-INTEGRATION-GUIDE.md)** - How to switch between public access and private endpoint modes
- **[Image Resolution](./docs/IMAGE-RESOLUTION.md)** - Container image resolution and ACR integration

---

# Provision the infrastructure and deploy

## Provision and deploy

```
azd auth login
azd up
```

**What happens during `azd up`:**
1. **Pre-provision hooks run automatically**:
   - `resolve-images.ps1`/`.sh` - Validates/resolves container images from ACR (auto-recovery for sta- Where it's used: `.github/workflows/promote-frontend.yaml` and `.github/workflows/promote-backend.yaml` in the `prepare-and-notify` job. If the secret is not provided, the workflow falls back to the default token (which usually cannot read a different private repo), and the commit table may be empty—though the compare link will still work for authorized viewers.e digests)
   - `ensure-acr.ps1`/`.sh` - Ensures Azure Container Registry exists
2. **Bicep deployment executes** with resolved images
3. **Services are provisioned** to Azure Container Apps

> 💡 **Automatic Image Resolution**: If configured image digests are missing or stale (e.g., after deleting resources), the hook automatically resolves the latest image from ACR or falls back to a public placeholder. See [docs/IMAGE-RESOLUTION.md](./docs/IMAGE-RESOLUTION.md) for details.

After a successful deploy, get the frontend URL:

```
azd env get-value frontendFqdn
```

In CI, the workflow prints the URL in the job logs as "Frontend URL: https://…", adds it to the job summary under "Deployment endpoints," and exposes it as `frontendFqdn` output.

## Prerequisites
- Azure CLI (az) 2.61.0 or newer (required for Deployment Stacks alpha)
- Azure Developer CLI (azd)
- Docker Desktop (optional; not required when deploying a 2) Add the token as a secret
	- In the infra repo (this repository): Settings → Secrets and variables → Actions → New repository secret
	- Name: `FRONTEND_REPO_READ_TOKEN`
	- Value: paste the token
	- Since this is defined at repository level, it's accessible to all jobs across all environments.

3) Verify
	- Trigger a promotion to `test`. In the job summary and the approval email, the "List of changes" section should include a commit list/table instead of being empty. image)

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
azd env set AZURE_ENV_NAME dev
azd env set AZURE_RESOURCE_GROUP rg-raptor-dev
azd env set AZURE_ACR_NAME ngraptordev
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

## Image promotion (dev → test → train → prod)

We promote the exact built image by digest to higher environments to avoid drift.

**Base environment (default: dev)**
- The frontend workflow builds and pushes an image to the base environment's ACR (configured via `DEFAULT_GITHUB_ENV` repository variable, defaults to `dev`)
- It produces an image by digest, for example: `ngraptordev.azurecr.io/raptor/frontend-dev@sha256:...`
- The image is automatically deployed to the base environment
- It dispatches two events to this repo:
	- `frontend-image-pushed` → triggers infra deploy for the base environment
	- `frontend-image-promote` → triggers `.github/workflows/promote-frontend.yaml` to promote to higher environments (`test` → `train` → `prod`)

**Promotion flow**
Images flow from the base environment through progressive stages: base → test → train → prod. To change the base environment (e.g., from `dev` to `staging`), update the repository variable `DEFAULT_GITHUB_ENV`.

What promotion does per environment:

1) Uses OIDC to login to Azure and azd.
2) Imports the manifest by digest into the target environment ACR repo using `az acr import` (no rebuild):
	 - Source: the `image@digest` from the source environment build
	 - Target: `<AZURE_ACR_NAME_<ENV>>.azurecr.io/raptor/frontend-<env>:promoted-<runId>`
3) Deploys by digest in that environment by setting `SERVICE_FRONTEND_IMAGE_NAME` to `<acr>.azurecr.io/raptor/frontend-<env>@<digest>` and forcing `SKIP_ACR_PULL_ROLE_ASSIGNMENT=false`.

Approvals

- Jobs are bound to environment scopes for deployment (`test`, `train`, `prod`). Configure required reviewers in GitHub Environments to enforce manual approvals before each promotion stage runs.
- The notification jobs (`prepare-and-notify-*`) run without environment scope and use repository-level federated identity, so they don't require additional federated identity credentials or approval gates.

Required variables/secrets

**Repository-level secrets** (shared across all jobs and environments):
- `AZURE_SUBSCRIPTION_ID` - Azure subscription ID
- `AZURE_TENANT_ID` - Azure AD tenant ID  
- `AZURE_CLIENT_ID` - Service principal client ID for OIDC authentication
- `FRONTEND_REPO_READ_TOKEN` - (Optional) PAT for reading commits from private frontend repo
- Email notification secrets (optional):
  - `MAIL_SERVER` - SMTP server hostname
  - `MAIL_PORT` - SMTP port (default 587)
  - `MAIL_FROM` - Sender email address
  - `MAIL_TO` - Recipient email address(es)
  - `MAIL_USERNAME` - SMTP authentication username
  - `MAIL_PASSWORD` - SMTP authentication password

**Repository-level variables**:
- `DEFAULT_GITHUB_ENV` - (Optional) Specifies the base environment for initial image deployment (default: `dev`). When a frontend image is pushed to ACR, it's automatically deployed to this environment first, then promoted to higher environments (test → train → prod). Change this value to use a different base environment.

**Preflight environment variables** (used by notification jobs to query current deployments):
- `AZURE_ACR_NAME_DEV` - ACR name for dev environment (e.g., `ngraptordev`)
- `AZURE_ACR_NAME_TEST` - ACR name for test environment (e.g., `ngraptortest`)
- `AZURE_ACR_NAME_TRAIN` - ACR name for train environment (e.g., `ngraptortrain`)
- `AZURE_ACR_NAME_PROD` - ACR name for prod environment (e.g., `ngraptorprod`)
- `AZURE_RESOURCE_GROUP_DEV` - Resource group for dev environment (e.g., `rg-raptor-dev`)
- `AZURE_RESOURCE_GROUP_TEST` - Resource group for test environment (e.g., `rg-raptor-test`)
- `AZURE_RESOURCE_GROUP_TRAIN` - Resource group for train environment (e.g., `rg-raptor-test` or `rg-raptor-train`)
- `AZURE_RESOURCE_GROUP_PROD` - Resource group for prod environment (e.g., `rg-raptor-prod`)

**Note:** The notification jobs use the `preflight` environment to access these configuration variables without requiring separate federated identities per environment.

**Environment-specific configuration** (define in each GitHub Environment):

For the preflight environment (used by notification jobs):
- `preflight`: Configure the 8 environment-specific variables listed above (AZURE_ACR_NAME_* and AZURE_RESOURCE_GROUP_*)

For deployment environments (configure with protection rules/required reviewers):
- `dev`: Optionally add required reviewers for approval gate
- `test`: Add required reviewers for approval gate
- `train`: Add required reviewers for approval gate
- `prod`: Add required reviewers for approval gate

**Federated Identity Setup**

The workflow uses OIDC (OpenID Connect) for secure authentication to Azure without storing credentials. You need to configure federated identity credentials in Azure:

1. **Preflight environment federated identity** (for notification jobs):
   - Subject identifier: `repo:arif-md/rap-infra:environment:preflight`
   - Used by: `prepare-and-notify-*` jobs that generate release notes and send emails

2. **Environment-specific federated identities** (for deployment jobs):
   - `dev` environment: `repo:arif-md/rap-infra:environment:dev`
   - `test` environment: `repo:arif-md/rap-infra:environment:test`
   - `train` environment: `repo:arif-md/rap-infra:environment:train`
   - `prod` environment: `repo:arif-md/rap-infra:environment:prod`
   - Used by: `promote-to-*` jobs that actually deploy to Azure

This approach requires only 5 federated identity credentials total (1 for preflight + 4 for deployments).

**Why separate notification and deployment jobs?**

The workflow uses a two-phase approach per environment:
1. `prepare-and-notify-{env}` job (uses `preflight` environment, no approval needed)
   - Uses preflight federated identity
   - Accesses environment-specific configuration variables
   - Captures current deployment state
   - Generates release notes with commit changelog
   - Sends email notification
2. `promote-to-{env}` job (uses `{env}` environment, requires approval if configured)
   - Uses environment-specific federated identity
   - Waits for manual approval
   - Executes actual deployment

This design allows stakeholders to receive release notes and review changes immediately, then approve the deployment when ready, without blocking the notification phase.

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

## Approval email and release notes generation

This section explains how the promotion workflow prepares the email content and the release notes that appear in the approval email and job summary.

### Inputs

- New image to promote (by digest): `SRC_IMAGE` (for example, `ngraptordev.azurecr.io/raptor/frontend-dev@sha256:<...>`)
- Target environment metadata resolved in the job:
	- `AZURE_RESOURCE_GROUP`, `AZURE_ACR_NAME` (optionally `AZURE_ACR_RESOURCE_GROUP`)
	- Subscription ID and resolved location
- Email settings (optional, only if you want email notifications):
	- `MAIL_SERVER`, `MAIL_PORT` (default 587), `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_TO`, `MAIL_FROM`

### Data sources used to build release notes

1) Current deployed image/digest in the target environment
	 - Reads from the existing Container App: `properties.template.containers[0].image`
	 - If the image is `repo@digest`, we capture that digest.
	 - If the image is `repo:tag`, we try to resolve a digest in the target ACR by matching the tag to the repo’s manifest list.

2) Commit SHAs via OCI labels (preferred)
	 - Uses the registry’s HTTP API with a temporary ACR token to fetch the image manifest and its config blob.
	 - Reads the `org.opencontainers.image.revision` label from the config to get a commit SHA.
	 - Handles manifest lists by following the first child manifest (multi-arch images); if the top manifest is a list, we fetch the first child’s config.

3) Durable fallbacks via Container App tags
	 - If commit resolution fails, we consult resource tags on the Container App itself:
		 - `raptor.lastDigest`
		 - `raptor.lastCommit`
	 - These are written during successful deployments to persist baseline metadata even if registry tags are later pruned.

### Resolution order and fallbacks

- Previous digest (`PREV_DIGEST`):
	1. From the currently deployed image in the Container App (preferred).
	2. If the current image is tag-form only, attempt to resolve the digest in the target ACR for that repo.
	3. If still unresolved on a manual run, fall back to the latest digest in the target repo.
	4. If nothing is found, treat this as the first promotion (no previous digest).

- Previous commit (`PREV_SHA`):
	1. Resolve from OCI labels using the actual previous image’s registry/repo/digest.
	2. Fall back to the target ACR/repo.
	3. Fall back to the source image’s registry/repo.
	4. Fall back to Container App tags `raptor.lastCommit`.
	5. If still not found, we proceed with digest-only notes (no commit compare).

- New commit (`NEW_SHA`):
	- Resolved from `SRC_IMAGE`’s config labels in its source registry.

### Outputs produced

- A markdown file and an HTML fragment (attached to the email and appended to the job summary) that contain:
	- Target environment
	- New image (`image@digest`)
	- Previously deployed digest (or “none – first promotion” if unavailable)
	- Changes section:
		- If both commits are available: a GitHub compare link (`previous…new`).
		- Otherwise: a digest change summary (`prevDigest → newDigest`) with a note that commit SHAs were not available.

### Email delivery

- If the `MAIL_*` variables are present, the job sends an approval email that includes:
	- A header indicating the target environment
	- The new image
	- Links to build details and the approval page
	- The rendered HTML release notes fragment described above

### Notes and edge cases

- Labels and ACR import: `az acr import` preserves manifests and config blobs, so OCI labels stamped at build time should be retained. If commit resolution fails, it’s typically due to querying the wrong repo/digest, insufficient data-plane scope for registry HTTP calls, or multi-arch manifests where the first child lacks the label.
- Digest-only fallback: even when commit SHAs are not resolvable, the workflow now keeps and displays the previous digest so release notes are still informative.
- First promotion: if we cannot determine a previous digest, the notes explicitly state “none – first promotion.”
- Durability: Container App tags (`raptor.lastDigest`/`raptor.lastCommit`) provide a baseline even if the registry later purges old tags/manifests.

### Commit table in emails (optional)

When both NEW and PREV commit SHAs are resolved from the image labels and they differ, the promotion workflow calls the GitHub Compare API and renders a small commit table (SHA, message, author, date) inside the email and job summary.

- Tokens used
	- Same repo: the built-in `GITHUB_TOKEN` (contents: read) is used automatically.
	- Cross-repo: set `FRONTEND_REPO_READ_TOKEN` with read access to the frontend repo; the workflow will use it when the source repo differs from this infra repo.
- Fallbacks
	- If the API call fails (rate limit, permissions, etc.), the email still includes the digest delta and a clickable compare link.
	- The workflow logs will include a brief diagnostic line with the HTTP status if fetching commits fails.

## Documentation

- **[IMAGE-RESOLUTION.md](./docs/IMAGE-RESOLUTION.md)** - Automatic image resolution feature (handles stale digests, ACR queries, fallback images)
- **[WORKFLOWS.md](./docs/WORKFLOWS.md)** - Service-specific workflow guide (deployment, promotion, adding new services)
- **[ARCHITECTURE-STRATEGIES.md](./docs/ARCHITECTURE-STRATEGIES.md)** - Multi-service infrastructure patterns and evolution paths

