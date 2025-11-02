# Frontend Service - Angular Container App

## Overview

The frontend service is an Angular application deployed as a Container App on Azure Container Apps. It follows Azure Verified Modules (AVM) design principles and uses the same deployment patterns as other services in the platform.

## Service Configuration

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `SERVICE_KEY` | Service identifier | `frontend` |
| `SERVICE_SUFFIX` | Container app name suffix | `fe` |
| `IMAGE_REPO` | ACR repository pattern | `raptor/frontend-{env}` |
| `TARGET_PORT` | Application port | `80` |

### Resource Naming

```
Container App:     {environment}-rap-fe
User Identity:     uai-{resourceToken}
ACR Repository:    raptor/frontend-{environment}
```

Examples:
- Dev: `dev-rap-fe` → `ngraptordev.azurecr.io/raptor/frontend-dev`
- Test: `test-rap-fe` → `ngraptortest.azurecr.io/raptor/frontend-dev`
- Prod: `prod-rap-fe` → `ngraptorprod.azurecr.io/raptor/frontend-dev`

## Infrastructure

### Bicep Template

**File**: `infra/app/frontend-angular.bicep`

The template creates:
1. **User-Assigned Managed Identity** - For ACR pull and Azure service authentication
2. **Container App** - Angular application container (nginx)
3. **ACR Pull Role Assignment** - Grants AcrPull role to the managed identity (when image is from configured ACR)

### Key Features

- **Application Insights Integration**: Optional monitoring with connection string injection
- **Environment Variables**: Custom runtime config support
- **Compute Sizing**: Configurable CPU/memory (1 vCPU, 2Gi default)
- **Auto-scaling**: Min 1 / Max 3 replicas
- **Session Affinity**: Optional sticky sessions support
- **Cross-RG ACR Support**: Can pull images from ACR in different resource groups
- **External Ingress**: Public HTTPS endpoint with Container Apps domain

### Environment Variables

Default environment variables set by the template:

```bash
APP_ENV=angular
APP_ROLE=frontend
AZURE_ENV_NAME={environmentName}
```

## Deployment

### Prerequisites

1. **Azure CLI** with Container Apps extension
2. **Azure Developer CLI (azd)**
3. **Azure authentication** via OIDC or service principal
4. **ACR access** (AcrPull role or admin credentials)
5. **Frontend container image** built and pushed to ACR

### Local Deployment

```bash
# Set environment
export AZURE_ENV_NAME="dev"
export AZURE_RESOURCE_GROUP="rg-raptor-dev"
export AZURE_ACR_NAME="ngraptordev"

# Prepare azd environment
azd env new $AZURE_ENV_NAME --no-prompt || true
azd env set AZURE_ENV_NAME "$AZURE_ENV_NAME"
azd env set AZURE_RESOURCE_GROUP "$AZURE_RESOURCE_GROUP"
azd env set AZURE_ACR_NAME "$AZURE_ACR_NAME"

# Set frontend image (from build workflow)
azd env set SERVICE_FRONTEND_IMAGE_NAME \
  "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:abc..."

# Deploy using fast-path (image-only update)
./scripts/deploy-service-image.sh frontend dev

# OR full provision + deploy
azd up --no-prompt --environment $AZURE_ENV_NAME
```

### GitHub Actions Deployment

**Workflow**: `.github/workflows/deploy-frontend.yaml`

**Triggers**:
- Manual: `workflow_dispatch`
- Push to `main` (when frontend bicep or scripts change)
- Repository dispatch: `frontend-image-pushed` event

**Key Steps**:
1. Checkout code
2. Azure login (OIDC)
3. Setup azd
4. Prepare azd environment
5. Accept image from dispatch (if triggered by image push)
6. Run preprovision hooks (ensure ACR, resolve images, validate)
7. Fast-path update (if possible) OR full `azd up`
8. Persist deployment metadata to Container App tags
9. Dispatch promotion event (if successful dev deployment)

### Fast-Path vs Full Deployment

**Fast-Path** (`deploy-service-image.sh`):
- Only updates container image
- Uses `az containerapp update --image`
- ~30 seconds
- Triggered automatically when:
  - `repository_dispatch` with `frontend-image-pushed`
  - `workflow_dispatch` with existing infrastructure

**Full Deployment** (`azd up`):
- Provisions all infrastructure
- Deploys application
- ~3-5 minutes
- Triggered when:
  - Fast-path fails (missing resources)
  - Infrastructure changes detected
  - First deployment to environment

## Image Build

### GitHub Actions Workflow

**Repository**: `rap-frontend` (submodule)
**Workflow**: `.github/workflows/frontend-image.yaml`

**Triggers**:
- Manual: `workflow_dispatch`
- Push to `main` when frontend code changes:
  - `Dockerfile`
  - `package.json`, `angular.json`
  - `src/**`

**Build Process**:
1. Checkout code
2. Setup Node.js 22 with npm cache
3. Install dependencies: `npm ci`
4. Generate version info: `npm run set-version`
5. Azure login (OIDC)
6. ACR login
7. Docker Buildx setup
8. Build and push image with:
   - Tag: `{ACR}.azurecr.io/raptor/frontend-{env}:{shortSHA}`
   - Digest: `sha256:...`
   - OCI labels: commit SHA, repo, ref, version
   - Build cache: GitHub Actions cache
9. Dispatch to infra repo with image digest

### OCI Image Labels

```dockerfile
org.opencontainers.image.revision={GITHUB_SHA}
org.opencontainers.image.source={GITHUB_REPOSITORY}
org.opencontainers.image.ref.name={GITHUB_REF_NAME}
org.opencontainers.image.version={BUILD_VERSION}
```

These labels enable:
- Commit SHA resolution for release notes
- Source repository tracking
- Version metadata

## Promotion

### Promotion Flow

```
Dev → Test → Train → Prod
```

Each promotion:
1. Imports image to target ACR (across subscriptions if needed)
2. Re-tags image with target environment suffix
3. Deploys to target environment
4. Sends email notification with:
   - Release notes (commit history)
   - Deployment links
   - Approval requirements (if configured)

### GitHub Actions Promotion

**Workflow**: `.github/workflows/promote-frontend.yaml`

**Triggers**:
- Manual: `workflow_dispatch` with image digest
- Repository dispatch: `frontend-image-promote` event

**Jobs**:
1. **Plan**: Determine which environments to promote to
2. **Test Preflight**: Generate release notes, send email
3. **Promote to Test**: Import image, deploy
4. **Train Preflight**: Generate release notes, send email (with approval check)
5. **Promote to Train**: Import image, deploy
6. **Prod Preflight**: Generate release notes, send email (with approval check)
7. **Promote to Prod**: Import image, deploy

### Manual Promotion

```bash
# Set target environment variables
export AZURE_RESOURCE_GROUP="rg-raptor-test"
export AZURE_ACR_NAME="ngraptortest"
export AZURE_SUBSCRIPTION_ID="..."

# Promote frontend from dev to test
./scripts/promote-service-image.sh frontend \
  "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:abc123..." \
  test
```

## Configuration

### Main Bicep Parameters

**File**: `infra/main.bicep`

```bicep
param frontendImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param frontendCpu int = 1
param frontendMemory string = '2Gi'
param skipFrontendAcrPullRoleAssignment bool = true
```

### azd Environment Variables

```bash
# Required
SERVICE_FRONTEND_IMAGE_NAME    # Full image reference with digest
AZURE_ENV_NAME                 # Environment name (dev/test/train/prod)
AZURE_RESOURCE_GROUP           # Target resource group
AZURE_ACR_NAME                 # ACR name (for registry binding)

# Optional
AZURE_ACR_RESOURCE_GROUP       # ACR resource group (if different from app RG)
SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT  # Skip role assignment (default: true)
```

### GitHub Environments

Configure per environment (test, train, prod):

**Variables**:
- `AZURE_ENV_NAME` - Environment name
- `AZURE_RESOURCE_GROUP` - Resource group
- `AZURE_ACR_NAME` - ACR name
- `AZURE_ACR_RESOURCE_GROUP` - ACR resource group (if cross-RG)

**Secrets**:
- `AZURE_CLIENT_ID` - OIDC client ID
- `AZURE_TENANT_ID` - Azure tenant ID
- `AZURE_SUBSCRIPTION_ID` - Azure subscription ID
- `MAIL_SERVER`, `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_TO`, `MAIL_PORT` - Email notification config

**Protection Rules** (optional):
- Required reviewers - Triggers approval gate in promotion workflow
- Wait timer - Delay before deployment
- Deployment branches - Restrict to main/specific branches

## Monitoring

### Application Insights

If Application Insights is configured:
- Connection string can be injected via environment variables
- Client-side telemetry for user interactions
- Performance metrics, exceptions, custom events

### Container App Logs

```bash
# Stream logs
az containerapp logs show \
  -n dev-rap-fe \
  -g rg-raptor-dev \
  --follow

# Query logs via Log Analytics
az monitor log-analytics query \
  -w {workspaceId} \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'dev-rap-fe' | order by TimeGenerated desc | limit 100"
```

### Deployment Metadata

Container App tags store deployment history:

```bash
raptor.lastDigest   # Last deployed image digest
raptor.lastCommit   # Last deployed commit SHA (from OCI labels)
```

Query tags:
```bash
az resource show \
  -n dev-rap-fe \
  -g rg-raptor-dev \
  --resource-type "Microsoft.App/containerApps" \
  --query tags
```

## Troubleshooting

### Common Issues

**1. Fast-path fails with "ManagedEnvironmentNotProvisioned"**
- Infrastructure not yet deployed
- Run full deployment: `azd up --no-prompt`

**2. ACR Pull fails**
```bash
# Check role assignment
az role assignment list \
  --scope /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ContainerRegistry/registries/{acr} \
  --query "[?principalId=='{identityPrincipalId}']"

# Grant AcrPull manually
FRONTEND_IDENTITY_ID=$(az identity show -n uai-{token} -g {rg} --query principalId -o tsv)
az role assignment create \
  --assignee $FRONTEND_IDENTITY_ID \
  --role AcrPull \
  --scope /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ContainerRegistry/registries/{acr}
```

**3. Image not found in ACR**
```bash
# List images
az acr repository show-tags \
  -n ngraptordev \
  --repository raptor/frontend-dev \
  --orderby time_desc

# Check specific digest
az acr repository show-manifests \
  -n ngraptordev \
  --repository raptor/frontend-dev \
  --query "[?digest=='sha256:abc...']"
```

**4. Email notifications not sent**
- Check MAIL_* secrets in GitHub environment
- Verify SMTP server allows connections
- Review workflow logs for email step errors

**5. Angular runtime config not loading**
```bash
# Check if runtime-config.json was generated during build
# In frontend repo
npm run set-version

# Verify src/assets/runtime-config.json exists
cat src/assets/runtime-config.json
```

## Azure Verified Modules (AVM) Compliance

The frontend infrastructure follows AVM design principles:

1. **Resource Modules**: Uses `avm/res/app/managed-environment:0.4.5` for Container Apps Environment
2. **Pattern Modules**: Uses `avm/ptn/azd/monitoring:0.1.0` for monitoring stack
3. **Naming**: Follows Azure naming conventions via `abbreviations.json`
4. **Tagging**: Applies consistent tags (`azd-service-name`, `environment`, `workload`)
5. **RBAC**: Least-privilege principle via user-assigned managed identities
6. **Parameters**: Descriptive, with defaults and constraints
7. **Outputs**: Exports FQDN, identity resource ID, deployed image

## Next Steps

1. **Configure Environments**: Set up GitHub environments (test, train, prod) with variables and secrets
2. **Build Frontend Image**: Trigger frontend image build workflow in rap-frontend repo
3. **Deploy to Dev**: Workflow automatically deploys to dev environment
4. **Promote to Test**: Review dev deployment, then promote to test
5. **Configure Approvals**: Add required reviewers to train/prod environments
6. **Monitor**: Check Application Insights dashboards and Container App logs

## Related Documentation

- [Backend Service](BACKEND-SERVICE.md) - Backend Spring Boot service documentation
- [Quick Reference](QUICK-REFERENCE.md) - Command cheat sheet
- [Workflows](WORKFLOWS.md) - Detailed workflow documentation
- [Multi-Service Deployment](MULTI-SERVICE-DEPLOYMENT.md) - Multi-service patterns
- [Promotion Workflows Analysis](PROMOTION-WORKFLOWS-ANALYSIS.md) - Promotion architecture
