# Quick Reference - Multi-Service Deployment

## Command Cheat Sheet

### Deploy Service to Dev
```bash
# Frontend
./scripts/deploy-service-image.sh frontend dev

# Backend
./scripts/deploy-service-image.sh backend dev

# Any service
./scripts/deploy-service-image.sh <service-key> <environment>
```

### Promote Service Between Environments
```bash
# Promote frontend from dev to test
export AZURE_RESOURCE_GROUP="rg-raptor-test"
export AZURE_ACR_NAME="ngraptortest"
./scripts/promote-service-image.sh frontend \
  "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:abc..." test

# Promote backend from test to prod
export AZURE_RESOURCE_GROUP="rg-raptor-prod"
export AZURE_ACR_NAME="ngraptorprod"
./scripts/promote-service-image.sh backend \
  "ngraptortest.azurecr.io/raptor/backend-test@sha256:def..." prod
```

### Set Service Image in azd Environment
```bash
# Frontend
azd env set SERVICE_FRONTEND_IMAGE_NAME \
  "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:..."

# Backend
azd env set SERVICE_BACKEND_IMAGE_NAME \
  "ngraptordev.azurecr.io/raptor/backend-dev@sha256:..."
```

## Workflow Snippets

### GitHub Actions - Dev Deployment
```yaml
- name: Deploy frontend to dev
  shell: bash
  run: |
    chmod +x scripts/deploy-service-image.sh
    ./scripts/deploy-service-image.sh frontend "${AZURE_ENV_NAME}"

- name: Deploy backend to dev
  shell: bash
  run: |
    chmod +x scripts/deploy-service-image.sh
    ./scripts/deploy-service-image.sh backend "${AZURE_ENV_NAME}"
```

### GitHub Actions - Promotion
```yaml
- name: Promote frontend to test
  env:
    AZURE_RESOURCE_GROUP: ${{ vars.AZURE_RESOURCE_GROUP_TEST }}
    AZURE_ACR_NAME: ${{ vars.AZURE_ACR_NAME_TEST }}
  shell: bash
  run: |
    chmod +x scripts/promote-service-image.sh
    ./scripts/promote-service-image.sh \
      frontend \
      "${{ env.SOURCE_IMAGE }}" \
      test
```

### Deploy Multiple Services (Loop)
```yaml
- name: Deploy all services
  shell: bash
  run: |
    chmod +x scripts/deploy-service-image.sh
    
    for service in frontend backend api; do
      echo "Deploying $service..."
      ./scripts/deploy-service-image.sh "$service" "${AZURE_ENV_NAME}" || true
    done
```

## Naming Reference

### Container App Names
```
{environment}-rap-{suffix}

Examples:
- dev-rap-fe        (frontend in dev)
- test-rap-be       (backend in test)
- prod-rap-api      (api in prod)
```

### ACR Repository Names
```
raptor/{service-key}-{environment}

Examples:
- raptor/frontend-dev
- raptor/backend-test
- raptor/api-prod
```

### Environment Variables
```
SERVICE_{UPPERCASE_KEY}_IMAGE_NAME

Examples:
- SERVICE_FRONTEND_IMAGE_NAME
- SERVICE_BACKEND_IMAGE_NAME
- SERVICE_API_IMAGE_NAME
```

## Common Tasks

### Add New Service
1. Create Bicep module in `app/{service}.bicep`
2. Set image in azd environment
3. Add workflow trigger
4. Call deployment script

### Check Deployment Status
```bash
# Check Container App
az containerapp show -n dev-rap-fe -g rg-raptor-dev

# Check current image
az containerapp show -n dev-rap-fe -g rg-raptor-dev \
  --query "properties.template.containers[0].image" -o tsv

# Check ACR repository
az acr repository show-tags -n ngraptordev --repository raptor/frontend-dev
```

### Troubleshoot Failed Deployment
```bash
# Check Container App logs
az containerapp logs show -n dev-rap-fe -g rg-raptor-dev --tail 100

# Check revision status
az containerapp revision list -n dev-rap-fe -g rg-raptor-dev -o table

# Verify image exists in ACR
az acr repository show-manifests -n ngraptordev \
  --repository raptor/frontend-dev \
  --query "[0]"
```

## Service Suffix Mapping

| Service Key | Suffix | Container App Name (dev) |
|-------------|--------|--------------------------|
| frontend    | fe     | dev-rap-fe               |
| backend     | be     | dev-rap-be               |
| api         | api    | dev-rap-api              |
| worker      | wor    | dev-rap-wor              |
| scheduler   | sch    | dev-rap-sch              |

## Environment Flow

```
Dev → Test → Train → Prod

1. Build image in source repo
2. Push to dev ACR (raptor/{service}-dev)
3. Deploy to dev Container App (dev-rap-{suffix})
4. Promote to test ACR (raptor/{service}-test)
5. Deploy to test Container App (test-rap-{suffix})
6. Repeat for train and prod
```

## Script Exit Codes

| Exit Code | Meaning                                    | GitHub Output     |
|-----------|--------------------------------------------| ------------------|
| 0         | Success - fast-path update completed       | didFastPath=true  |
| 1         | Failed or cannot fast-path (full provision needed) | didFastPath=false |

## Required Permissions

### Azure
- **Contributor** on resource group (Container Apps)
- **AcrPull** role on ACR (data-plane access)
- **AcrPush** role on ACR (for promotion/import)

### GitHub
- **Workflow dispatch** permission
- **Repository dispatch** permission
- **Secrets access** (AZURE_CLIENT_ID, AZURE_TENANT_ID, etc.)

## Files Reference

| File | Purpose |
|------|---------|
| `scripts/deploy-service-image.sh` | Deploy/update service in base env |
| `scripts/promote-service-image.sh` | Promote service between envs |
| `scripts/update-containerapp-image.sh` | Low-level Container App update |
| `scripts/ensure-acr-binding.sh` | Ensure ACR access configured |
| `docs/MULTI-SERVICE-DEPLOYMENT.md` | Complete documentation |
| `docs/GENERALIZATION-SUMMARY.md` | Migration summary |

---

**More Details:** See [`MULTI-SERVICE-DEPLOYMENT.md`](./MULTI-SERVICE-DEPLOYMENT.md)
