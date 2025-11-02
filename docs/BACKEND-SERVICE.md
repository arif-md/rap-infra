# Backend Service - Spring Boot Container App

## Overview

The backend service is a Spring Boot application deployed as a Container App on Azure Container Apps. It follows the same deployment patterns as the frontend service and uses Azure Verified Modules (AVM) for infrastructure management.

## Service Configuration

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `SERVICE_KEY` | Service identifier | `backend` |
| `SERVICE_SUFFIX` | Container app name suffix | `be` |
| `IMAGE_REPO` | ACR repository pattern | `raptor/backend-{env}` |
| `TARGET_PORT` | Application port | `8080` |

### Resource Naming

```
Container App:     {environment}-rap-be
User Identity:     uai-backend-{resourceToken}
ACR Repository:    raptor/backend-{environment}
```

Examples:
- Dev: `dev-rap-be` → `ngraptordev.azurecr.io/raptor/backend-dev`
- Test: `test-rap-be` → `ngraptortest.azurecr.io/raptor/backend-test`
- Prod: `prod-rap-be` → `ngraptorprod.azurecr.io/raptor/backend-prod`

## Infrastructure

### Bicep Template

**File**: `infra/app/backend-springboot.bicep`

The template creates:
1. **User-Assigned Managed Identity** - For ACR pull and Azure service authentication
2. **Container App** - Spring Boot application container
3. **ACR Pull Role Assignment** - Grants AcrPull role to the managed identity (when image is from configured ACR)

### Key Features

- **Application Insights Integration**: Optional monitoring with connection string injection
- **Environment Variables**: Spring profiles, server port, custom env vars
- **Compute Sizing**: Configurable CPU/memory (1 vCPU, 2Gi default)
- **Auto-scaling**: Min 1 / Max 10 replicas
- **Session Affinity**: Optional sticky sessions support
- **Cross-RG ACR Support**: Can pull images from ACR in different resource groups

### Environment Variables

Default environment variables set by the template:

```bash
SPRING_PROFILES_ACTIVE=azure
SERVER_PORT=8080
APP_ROLE=backend
AZURE_ENV_NAME={environmentName}
APPLICATIONINSIGHTS_CONNECTION_STRING={if enabled}
```

## Deployment

### Prerequisites

1. **Azure CLI** with Container Apps extension
2. **Azure Developer CLI (azd)**
3. **Azure authentication** via OIDC or service principal
4. **ACR access** (AcrPull role or admin credentials)
5. **Backend container image** built and pushed to ACR

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

# Set backend image (from build workflow)
azd env set SERVICE_BACKEND_IMAGE_NAME \
  "ngraptordev.azurecr.io/raptor/backend-dev@sha256:abc..."

# Deploy using fast-path (image-only update)
./scripts/deploy-service-image.sh backend dev

# OR full provision + deploy
azd up --no-prompt --environment $AZURE_ENV_NAME
```

### GitHub Actions Deployment

**Workflow**: `.github/workflows/deploy-backend.yaml`

**Triggers**:
- Manual: `workflow_dispatch`
- Push to `main` (when backend bicep or scripts change)
- Repository dispatch: `backend-image-pushed` event

**Concurrency Control**:
```yaml
group: azure-deployment-{environment}
cancel-in-progress: false
```

All deployment workflows share the same concurrency group per environment. This prevents simultaneous modifications to Azure deployment stacks and avoids `DeploymentStackInNonTerminalState` errors. If multiple workflows are triggered, they queue and run sequentially. See [Concurrency Controls](WORKFLOWS.md#concurrency-controls) for details.

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
  - `repository_dispatch` with `backend-image-pushed`
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

**Repository**: `rap-backend` (submodule)
**Workflow**: `.github/workflows/backend-image.yaml`

**Triggers**:
- Manual: `workflow_dispatch`
- Push to `main` when backend code changes:
  - `Dockerfile`, `Dockerfile.buildkit`
  - `pom.xml`
  - `src/**`
  - Maven wrapper files

**Build Process**:
1. Checkout code
2. Setup Java 17 (Temurin)
3. Set mvnw executable permission
4. Extract Maven project version from `pom.xml`
5. Azure login (OIDC)
6. ACR login
7. Docker Buildx setup
8. Build and push image with:
   - Tag: `{ACR}.azurecr.io/raptor/backend-{env}:{shortSHA}`
   - Digest: `sha256:...`
   - OCI labels: commit SHA, repo, ref, version
   - Build cache: GitHub Actions cache
9. Dispatch to infra repo with image digest

### OCI Image Labels

```dockerfile
org.opencontainers.image.revision={GITHUB_SHA}
org.opencontainers.image.source={GITHUB_REPOSITORY}
org.opencontainers.image.ref.name={GITHUB_REF_NAME}
org.opencontainers.image.version={MAVEN_VERSION}
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

**Workflow**: `.github/workflows/promote-backend.yaml`

**Triggers**:
- Manual: `workflow_dispatch` with image digest
- Repository dispatch: `backend-image-promote` event

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

# Promote backend from dev to test
./scripts/promote-service-image.sh backend \
  "ngraptordev.azurecr.io/raptor/backend-dev@sha256:abc123..." \
  test
```

## Configuration

### Main Bicep Parameters

**File**: `infra/main.bicep`

```bicep
param backendImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param backendCpu int = 1
param backendMemory string = '2Gi'
param skipBackendAcrPullRoleAssignment bool = true
```

### azd Environment Variables

```bash
# Required
SERVICE_BACKEND_IMAGE_NAME    # Full image reference with digest
AZURE_ENV_NAME                 # Environment name (dev/test/train/prod)
AZURE_RESOURCE_GROUP           # Target resource group
AZURE_ACR_NAME                 # ACR name (for registry binding)

# Optional
AZURE_ACR_RESOURCE_GROUP       # ACR resource group (if different from app RG)
SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT  # Skip role assignment (default: true)
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

If `enableAppInsights=true` (default):
- Connection string injected via `APPLICATIONINSIGHTS_CONNECTION_STRING`
- Spring Boot auto-configures telemetry
- Metrics, traces, logs sent to Application Insights

### Container App Logs

```bash
# Stream logs
az containerapp logs show \
  -n dev-rap-be \
  -g rg-raptor-dev \
  --follow

# Query logs via Log Analytics
az monitor log-analytics query \
  -w {workspaceId} \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'dev-rap-be' | order by TimeGenerated desc | limit 100"
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
  -n dev-rap-be \
  -g rg-raptor-dev \
  --resource-type "Microsoft.App/containerApps" \
  --query tags
```

## Troubleshooting

### Common Issues

**1. Permission denied on mvnw**
```bash
# In backend repo, set executable permission
cd backend
git update-index --chmod=+x mvnw
git commit -m "fix: Set executable permission on mvnw"
git push
```

**2. Fast-path fails with "ManagedEnvironmentNotProvisioned"**
- Infrastructure not yet deployed
- Run full deployment: `azd up --no-prompt`

**3. ACR Pull fails**
```bash
# Check role assignment
az role assignment list \
  --scope /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ContainerRegistry/registries/{acr} \
  --query "[?principalId=='{identityPrincipalId}']"

# Grant AcrPull manually
BACKEND_IDENTITY_ID=$(az identity show -n uai-backend-{token} -g {rg} --query principalId -o tsv)
az role assignment create \
  --assignee $BACKEND_IDENTITY_ID \
  --role AcrPull \
  --scope /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ContainerRegistry/registries/{acr}
```

**4. Image not found in ACR**
```bash
# List images
az acr repository show-tags \
  -n ngraptordev \
  --repository raptor/backend-dev \
  --orderby time_desc

# Check specific digest
az acr repository show-manifests \
  -n ngraptordev \
  --repository raptor/backend-dev \
  --query "[?digest=='sha256:abc...']"
```

**5. Email notifications not sent**
- Check MAIL_* secrets in GitHub environment
- Verify SMTP server allows connections
- Review workflow logs for email step errors

## Azure Verified Modules (AVM) Compliance

The backend infrastructure follows AVM design principles:

1. **Resource Modules**: Uses `avm/res/app/managed-environment:0.4.5` for Container Apps Environment
2. **Pattern Modules**: Uses `avm/ptn/azd/monitoring:0.1.0` for monitoring stack
3. **Naming**: Follows Azure naming conventions via `abbreviations.json`
4. **Tagging**: Applies consistent tags (`azd-service-name`, `environment`, `workload`)
5. **RBAC**: Least-privilege principle via user-assigned managed identities
6. **Parameters**: Descriptive, with defaults and constraints
7. **Outputs**: Exports FQDN, identity resource ID, deployed image

## Next Steps

1. **Configure Environments**: Set up GitHub environments (test, train, prod) with variables and secrets
2. **Build Backend Image**: Trigger backend image build workflow in rap-backend repo
3. **Deploy to Dev**: Workflow automatically deploys to dev environment
4. **Promote to Test**: Review dev deployment, then promote to test
5. **Configure Approvals**: Add required reviewers to train/prod environments
6. **Monitor**: Check Application Insights dashboards and Container App logs

## Related Documentation

- [Quick Reference](QUICK-REFERENCE.md) - Command cheat sheet
- [Workflows](WORKFLOWS.md) - Detailed workflow documentation
- [Multi-Service Deployment](MULTI-SERVICE-DEPLOYMENT.md) - Multi-service patterns
- [Promotion Workflows Analysis](PROMOTION-WORKFLOWS-ANALYSIS.md) - Promotion architecture
- [Shell Script Permissions Fix](SHELL-SCRIPT-PERMISSIONS-FIX.md) - Fix for permission errors
