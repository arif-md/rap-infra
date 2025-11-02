# Backend Migration: Azure Functions to Spring Boot Container App

**Date**: November 1, 2025  
**Status**: ✅ Complete

## Overview

Successfully converted the backend service from Azure Functions to a Spring Boot container application deployed on Azure Container Apps, following the same design patterns as the frontend Angular service.

## Changes Summary

### 1. New Bicep Template

**Created**: `infra/app/backend-springboot.bicep`

Replaced `backend-azure-functions.bicep` with a new template that:
- Deploys Spring Boot as a Container App (not Azure Functions)
- Follows the same structure as `frontend-angular.bicep`
- Uses shared `containerApp.bicep` module
- Supports Application Insights integration
- Configures Spring Boot specific environment variables
- Exposes backend API on port 8080
- Implements Azure Verified Modules (AVM) patterns

**Key Parameters**:
```bicep
param image string                        // Backend container image
param cpu int = 1                         // 1 vCPU
param memory string = '2Gi'               // 2 GB memory
param minReplicas int = 1                 // Min scale
param maxReplicas int = 10                // Max scale
param applicationInsightsName string      // App Insights for monitoring
param enableAppInsights bool = true       // Enable monitoring
```

**Environment Variables Set**:
- `SPRING_PROFILES_ACTIVE=azure`
- `SERVER_PORT=8080`
- `APP_ROLE=backend`
- `AZURE_ENV_NAME={environmentName}`
- `APPLICATIONINSIGHTS_CONNECTION_STRING={connectionString}` (if enabled)

### 2. Main Bicep Updates

**File**: `infra/main.bicep`

**Changes**:
1. Added `backendImage` parameter
2. Added `backendCpu` and `backendMemory` parameters
3. Added backend-specific variables (`backendAppName`, `backendIdentityName`)
4. Replaced `backend-azure-functions.bicep` module with `backend-springboot.bicep`
5. Updated backend module parameters to match frontend pattern
6. Added `backendFqdn` output

**Before**:
```bicep
module backend 'app/backend-azure-functions.bicep' = {
  // ... Azure Functions specific config
}
```

**After**:
```bicep
module backend 'app/backend-springboot.bicep' = {
  name: 'backendApp'
  params: {
    name: backendAppName
    image: backendImage
    cpu: backendCpu
    memory: backendMemory
    containerAppsEnvironmentName: '${abbrs.appManagedEnvironments}${resourceToken}'
    // ... follows frontend pattern
  }
}
```

### 3. Parameters File

**File**: `infra/main.parameters.json`

**Added**:
```json
"backendImage": {
  "value": "${SERVICE_BACKEND_IMAGE_NAME}"
}
```

This enables azd to inject the backend image from environment variables during deployment.

### 4. Backend Image Build Workflow

**Created**: `backend/.github/workflows/backend-image.yaml`

A new GitHub Actions workflow in the backend repository that:
- Builds Spring Boot container image using Maven
- Pushes to Azure Container Registry (ACR)
- Tags with commit SHA and OCI labels
- Dispatches to infra repo for deployment

**Key Differences from Frontend**:
- Uses `actions/setup-java@v4` instead of `actions/setup-node@v4`
- Java 17 (Temurin distribution)
- Runs `git update-index --chmod=+x mvnw` to set Maven wrapper permissions
- Extracts version from `pom.xml` using Maven
- Monitors backend-specific files (`pom.xml`, `src/**`, `Dockerfile`, Maven wrapper)

**OCI Labels**:
- `org.opencontainers.image.revision` - Git commit SHA
- `org.opencontainers.image.source` - GitHub repository
- `org.opencontainers.image.ref.name` - Git branch/tag
- `org.opencontainers.image.version` - Maven project version

### 5. Deployment Workflow Update

**File**: `infra/.github/workflows/deploy-backend.yaml`

**Updated**:
Changed monitored path from `backend-azure-functions.bicep` to `backend-springboot.bicep`:

```yaml
paths:
  - 'app/backend-springboot.bicep'  # Changed from backend-azure-functions.bicep
```

This ensures deployments trigger when the new template changes.

### 6. Concurrency Controls

**Files Modified**: 
- `infra/.github/workflows/provision-infrastructure.yaml`
- `infra/.github/workflows/deploy-backend.yaml`
- `infra/.github/workflows/deploy-frontend.yaml`

**Added Concurrency Group**:
```yaml
concurrency:
  group: azure-deployment-${{ inputs.environment || 'dev' }}
  cancel-in-progress: false
```

**Purpose**: Prevents `DeploymentStackInNonTerminalState` errors when multiple workflows modify the same Azure deployment stack simultaneously. Workflows queue instead of running concurrently, ensuring sequential deployments.

**Behavior**: 
- When multiple workflows trigger (e.g., large commits touching both main.bicep and app/*.bicep), they queue and run in order
- Environment isolation: Different environments (dev/test/train/prod) can deploy simultaneously
- See [WORKFLOWS.md](./WORKFLOWS.md#concurrency-controls) for detailed explanation

### 6. Documentation

**Created**:
1. `infra/docs/BACKEND-SERVICE.md` - Comprehensive backend service documentation
2. `infra/docs/FRONTEND-SERVICE.md` - Comprehensive frontend service documentation (for consistency)

Both documents cover:
- Service configuration and naming conventions
- Infrastructure details (Bicep templates, resources)
- Deployment procedures (local and GitHub Actions)
- Image build process
- Promotion workflows
- Configuration and environment variables
- Monitoring and logging
- Troubleshooting guide
- AVM compliance verification
- **Concurrency controls** for preventing deployment conflicts

### 7. Abbreviations

**File**: `infra/abbreviations.json`

No changes required - already contains all necessary abbreviations:
- `appContainerApps: "ca-"`
- `managedIdentityUserAssignedIdentities: "uai-"`
- `containerRegistryRegistries: "cr"`

## Architecture Comparison

### Before (Azure Functions)
```
Backend Service
├── Azure Functions Host
├── Consumption/Premium plan
├── Function App runtime
└── Custom configuration via appDefinition
```

### After (Container Apps)
```
Backend Service
├── Spring Boot Application
├── Container Apps (managed Kubernetes)
├── User-assigned managed identity
├── Auto-scaling (1-10 replicas)
└── Application Insights integration
```

## Benefits of Container Apps

1. **Consistency**: Same deployment pattern for frontend and backend
2. **Flexibility**: Any containerized application (not limited to Functions runtime)
3. **Scaling**: Horizontal auto-scaling with KEDA
4. **Cost**: Pay per active second, better for variable workloads
5. **DevOps**: Simpler CI/CD with container images
6. **Portability**: Container images work across environments
7. **Monitoring**: Native Application Insights integration
8. **Networking**: Full ingress/egress control

## Deployment Flow

### Image Build (Backend Repo)
```
1. Push code to main branch
2. GitHub Actions workflow triggered
3. Build Spring Boot app with Maven
4. Create Docker image
5. Push to ACR with digest
6. Dispatch to infra repo
```

### Deployment (Infra Repo)
```
1. Receive image digest event
2. Run preprovision hooks
   - Ensure ACR exists
   - Resolve images
   - Validate ACR bindings
3. Fast-path update (if infrastructure exists)
   OR full azd up (if new)
4. Persist deployment metadata
5. Dispatch promotion event (if dev)
```

### Promotion
```
Dev → Test → Train → Prod

For each environment:
1. Generate release notes from commits
2. Send email notification
3. Check for approval requirements
4. Import image to target ACR
5. Deploy to Container App
6. Update deployment tags
```

## Testing Checklist

- [ ] Backend image builds successfully in rap-backend repo
- [ ] Image pushed to ACR with correct tags and digest
- [ ] Deployment to dev environment succeeds
- [ ] Backend Container App accessible at FQDN
- [ ] Spring Boot actuator endpoints respond
- [ ] Application Insights receiving telemetry
- [ ] Logs visible in Log Analytics
- [ ] Fast-path update works (image-only)
- [ ] Promotion to test environment succeeds
- [ ] Release notes generated correctly
- [ ] Email notifications sent
- [ ] Approval gate triggered for train/prod (if configured)

## Configuration Steps

### 1. Backend Repository (rap-backend)

Set repository variables (Actions → Variables):
- `AZURE_ACR_NAME` - ACR name (e.g., `ngraptordev`)
- `AZURE_ENV_NAME` - Environment name (`dev`)
- `INFRA_REPO` - Infra repo name (e.g., `arif-md/rap-infra`)

Set environment secrets (Actions → Environments → dev):
- `AZURE_CLIENT_ID` - OIDC client ID
- `AZURE_TENANT_ID` - Tenant ID
- `AZURE_SUBSCRIPTION_ID` - Subscription ID
- `GH_PAT_REPO_DISPATCH` - PAT for cross-repo dispatch (if needed)

### 2. Infra Repository (rap-infra)

Set environment variables per environment (test, train, prod):
- `AZURE_ENV_NAME` - `test` / `train` / `prod`
- `AZURE_RESOURCE_GROUP` - Resource group name
- `AZURE_ACR_NAME` - ACR name
- `AZURE_ACR_RESOURCE_GROUP` - ACR resource group (if different)

Set environment secrets:
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- `MAIL_SERVER`, `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_TO`, `MAIL_PORT`

### 3. First Deployment

```bash
# In backend repo
git add .github/workflows/backend-image.yaml
git commit -m "feat: Add backend image build workflow"
git push origin main

# Wait for image build to complete

# Image auto-deploys to dev via repository_dispatch

# Verify deployment
az containerapp show -n dev-rap-be -g rg-raptor-dev --query properties.configuration.ingress.fqdn -o tsv
```

## Azure Verified Modules (AVM) Compliance

✅ **Resource Modules**
- Uses `avm/res/app/managed-environment:0.4.5`
- Uses `avm/ptn/azd/monitoring:0.1.0`

✅ **Naming Conventions**
- Follows `abbreviations.json` standards
- Resource names derived from environment + token

✅ **Tagging**
- `azd-service-name: backend`
- `environment: {environmentName}`
- `workload: rap`

✅ **RBAC**
- User-assigned managed identities
- AcrPull role assignment (conditional)
- Least-privilege access

✅ **Parameters**
- Descriptive names and documentation
- Sensible defaults
- Type constraints and validation

✅ **Outputs**
- FQDN for accessing the service
- Identity resource ID for RBAC
- Deployed image for tracking

## Files Changed

### Created
1. `backend/.github/workflows/backend-image.yaml` - Image build workflow
2. `infra/app/backend-springboot.bicep` - Backend Container App template
3. `infra/docs/BACKEND-SERVICE.md` - Backend documentation
4. `infra/docs/FRONTEND-SERVICE.md` - Frontend documentation

### Modified
1. `infra/main.bicep` - Added backend parameters and module
2. `infra/main.parameters.json` - Added backendImage parameter
3. `infra/.github/workflows/deploy-backend.yaml` - Updated bicep path reference
4. `infra/.github/workflows/provision-infrastructure.yaml` - Added concurrency control
5. `infra/.github/workflows/deploy-frontend.yaml` - Added concurrency control
6. `infra/docs/WORKFLOWS.md` - Added comprehensive concurrency documentation

### Removed (Deprecated)
- `infra/app/backend-azure-functions.bicep` - Replaced by backend-springboot.bicep

## Next Steps

1. **Test Backend Build**: Trigger backend image workflow
2. **Verify Dev Deployment**: Check Container App and logs
3. **Configure Test Environment**: Set up GitHub environment variables
4. **Test Promotion**: Promote dev image to test
5. **Add Protection Rules**: Configure required reviewers for train/prod
6. **Monitor**: Set up Application Insights alerts
7. **Document**: Update team wiki with new backend deployment process
8. **Train**: Share documentation with team members

## Related Documentation

- [Backend Service Documentation](../infra/docs/BACKEND-SERVICE.md)
- [Frontend Service Documentation](../infra/docs/FRONTEND-SERVICE.md)
- [Quick Reference](../infra/docs/QUICK-REFERENCE.md)
- [Workflows](../infra/docs/WORKFLOWS.md)
- [Multi-Service Deployment](../infra/docs/MULTI-SERVICE-DEPLOYMENT.md)
- [Shell Script Permissions Fix](../infra/docs/SHELL-SCRIPT-PERMISSIONS-FIX.md)

## Support

For issues or questions:
1. Check troubleshooting section in BACKEND-SERVICE.md
2. Review GitHub Actions workflow logs
3. Check Container App logs via `az containerapp logs show`
4. Verify Application Insights for runtime errors
5. Review SHELL-SCRIPT-PERMISSIONS-FIX.md for permission issues
