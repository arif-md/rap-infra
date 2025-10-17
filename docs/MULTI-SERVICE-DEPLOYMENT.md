# Generalized Service Deployment Scripts

This document explains how to use the generalized scripts for deploying multiple services (frontend, backend, and future services) across environments.

## Overview

We've created two generalized scripts that can handle **any service** (not just frontend):

1. **`deploy-service-image.sh`** - For base environment (dev) deployments
2. **`promote-service-image.sh`** - For promoting images between environments

## Architecture

### Service Naming Conventions

#### Container App Names
- Format: `{env}-rap-{suffix}`
- Examples:
  - Frontend: `dev-rap-fe`, `test-rap-fe`, `prod-rap-fe`
  - Backend: `dev-rap-be`, `test-rap-be`, `prod-rap-be`

#### ACR Repository Names
- Format: `raptor/{service-key}-{env}`
- Examples:
  - Frontend: `raptor/frontend-dev`, `raptor/frontend-test`
  - Backend: `raptor/backend-dev`, `raptor/backend-test`

#### Environment Variables
- Format: `SERVICE_{KEY}_IMAGE_NAME` (uppercase)
- Examples:
  - Frontend: `SERVICE_FRONTEND_IMAGE_NAME`
  - Backend: `SERVICE_BACKEND_IMAGE_NAME`

## Script 1: deploy-service-image.sh

### Purpose
Deploy or update a service image in the **base environment** (typically dev).

### Usage
```bash
./scripts/deploy-service-image.sh <service-key> <environment>
```

### Parameters
- `service-key`: Service identifier (`frontend`, `backend`, `api`, etc.)
- `environment`: Target environment name (`dev`, `test`, etc.)

### Required Environment Variables
- `AZURE_ENV_NAME` - Azure environment name
- `AZURE_RESOURCE_GROUP` - Target resource group
- `AZURE_ACR_NAME` - Azure Container Registry name

### azd Environment Variables
The script reads the image from azd environment:
- For frontend: `SERVICE_FRONTEND_IMAGE_NAME`
- For backend: `SERVICE_BACKEND_IMAGE_NAME`

### Examples

#### Deploy Frontend (Current Usage)
```yaml
- name: Fast image-only update - frontend
  shell: bash
  run: |
    chmod +x scripts/deploy-service-image.sh
    ./scripts/deploy-service-image.sh frontend "${AZURE_ENV_NAME}"
```

#### Deploy Backend (Future Usage)
```yaml
- name: Fast image-only update - backend
  shell: bash
  run: |
    chmod +x scripts/deploy-service-image.sh
    ./scripts/deploy-service-image.sh backend "${AZURE_ENV_NAME}"
```

#### Deploy Multiple Services
```yaml
- name: Fast image-only update - all services
  shell: bash
  run: |
    chmod +x scripts/deploy-service-image.sh
    SERVICES=("frontend" "backend")
    for service in "${SERVICES[@]}"; do
      echo "Deploying $service..."
      ./scripts/deploy-service-image.sh "$service" "${AZURE_ENV_NAME}" || echo "Failed to fast-path $service"
    done
```

## Script 2: promote-service-image.sh

### Purpose
Promote a service image from one environment to another (dev→test→train→prod).

### Usage
```bash
./scripts/promote-service-image.sh <service-key> <source-image> <target-env>
```

### Parameters
- `service-key`: Service identifier (`frontend`, `backend`, etc.)
- `source-image`: Source image with digest to promote
- `target-env`: Target environment (`test`, `train`, `prod`)

### Required Environment Variables
- `AZURE_RESOURCE_GROUP` - Target resource group
- `AZURE_ACR_NAME` - Target ACR name
- `AZURE_ACR_NAME_SRC` - Source ACR name (optional, defaults to target)

### What It Does
1. **Imports image** from source ACR to target ACR
2. **Tags** with timestamp (`promoted-{timestamp}`)
3. **Updates Container App** with the promoted image
4. Uses the same robust logic as dev deployments

### Examples

#### Promote Frontend (Current Usage)
```yaml
- name: Promote frontend to test
  env:
    AZURE_RESOURCE_GROUP: ${{ steps.prep.outputs.rg }}
    AZURE_ACR_NAME: ${{ steps.prep.outputs.acr }}
  shell: bash
  run: |
    chmod +x scripts/promote-service-image.sh
    ./scripts/promote-service-image.sh \
      frontend \
      "${{ env.SRC_IMAGE }}" \
      "${{ steps.prep.outputs.env }}"
```

#### Promote Backend (Future Usage)
```yaml
- name: Promote backend to prod
  env:
    AZURE_RESOURCE_GROUP: rg-raptor-prod
    AZURE_ACR_NAME: ngraptorprod
    AZURE_ACR_NAME_SRC: ngraptortest
  shell: bash
  run: |
    chmod +x scripts/promote-service-image.sh
    ./scripts/promote-service-image.sh \
      backend \
      "ngraptortest.azurecr.io/raptor/backend-test@sha256:abc..." \
      prod
```

#### Promote Multiple Services
```yaml
- name: Promote all services to production
  shell: bash
  run: |
    chmod +x scripts/promote-service-image.sh
    
    # Define services and their source images
    declare -A IMAGES
    IMAGES[frontend]="ngraptortest.azurecr.io/raptor/frontend-test@sha256:abc..."
    IMAGES[backend]="ngraptortest.azurecr.io/raptor/backend-test@sha256:def..."
    
    for service in "${!IMAGES[@]}"; do
      echo "Promoting $service to prod..."
      ./scripts/promote-service-image.sh "$service" "${IMAGES[$service]}" prod
    done
```

## Migration Guide

### Current State (Frontend Only)
Workflows have hardcoded frontend-specific logic:
- App name: `{env}-rap-fe`
- Repository: `raptor/frontend-{env}`
- Env var: `SERVICE_FRONTEND_IMAGE_NAME`

### Step 1: Update Dev Environment (infra-azd.yaml)
**Before:**
```yaml
- name: Fast image-only update (skip provision when possible)
  if: (github.event_name == 'repository_dispatch' && github.event.action == 'frontend-image-pushed')
  id: fastpath
  shell: bash
  run: |
    APP_NAME=$(echo "${AZURE_ENV_NAME}-rap-fe" | tr '[:upper:]' '[:lower:]')
    IMG=$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME || true)
    # ... 30 lines of logic ...
```

**After:**
```yaml
- name: Fast image-only update (skip provision when possible)
  if: (github.event_name == 'repository_dispatch' && github.event.action == 'frontend-image-pushed')
  id: fastpath
  shell: bash
  run: |
    chmod +x scripts/deploy-service-image.sh
    ./scripts/deploy-service-image.sh frontend "${AZURE_ENV_NAME}"
```

### Step 2: Update Promotion Workflows (promote-image.yaml)
**Before (3 steps per environment):**
```yaml
- name: Import manifest into target ACR repo
  # ... import logic ...

- name: Prepare azd env
  # ... prepare logic ...

- name: Fast image-only update (skip provision when possible)
  # ... update logic ...
```

**After (1 step per environment):**
```yaml
- name: Promote frontend image to test
  id: promote_test
  env:
    AZURE_RESOURCE_GROUP: ${{ steps.prep.outputs.rg }}
    AZURE_ACR_NAME: ${{ steps.prep.outputs.acr }}
  shell: bash
  run: |
    chmod +x scripts/promote-service-image.sh
    ./scripts/promote-service-image.sh \
      frontend \
      "${{ env.SRC_IMAGE }}" \
      "${{ steps.prep.outputs.env }}"
```

### Step 3: Add Backend Service
Once generalized, adding backend is simple:

1. **Set backend image in azd environment:**
   ```bash
   azd env set SERVICE_BACKEND_IMAGE_NAME "ngraptordev.azurecr.io/raptor/backend-dev@sha256:..."
   ```

2. **Add backend deployment trigger:**
   ```yaml
   repository_dispatch:
     types: 
       - frontend-image-pushed
       - backend-image-pushed  # NEW
   ```

3. **Add backend fast-path step:**
   ```yaml
   - name: Fast image-only update - backend
     if: github.event.action == 'backend-image-pushed'
     shell: bash
     run: |
       chmod +x scripts/deploy-service-image.sh
       ./scripts/deploy-service-image.sh backend "${AZURE_ENV_NAME}"
   ```

4. **Add backend promotion workflow** (copy/modify promote-image.yaml)

## Benefits

### ✅ Code Reusability
- Single script handles all services
- No duplication across services or environments

### ✅ Consistency
- Same deployment logic for all services
- Consistent error handling and logging

### ✅ Maintainability
- Fix once, apply everywhere
- Easy to add new services

### ✅ Scalability
- Add 10 services without 10x code growth
- Supports future services (API, worker, etc.)

## Testing

### Test Frontend Deployment (Existing)
```bash
# Set up environment
export AZURE_ENV_NAME="dev"
export AZURE_RESOURCE_GROUP="rg-raptor-dev"
export AZURE_ACR_NAME="ngraptordev"

# Set image in azd
azd env set SERVICE_FRONTEND_IMAGE_NAME "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:..."

# Deploy
./scripts/deploy-service-image.sh frontend dev
```

### Test Backend Deployment (Future)
```bash
# Set up environment (same as above)

# Set backend image
azd env set SERVICE_BACKEND_IMAGE_NAME "ngraptordev.azurecr.io/raptor/backend-dev@sha256:..."

# Deploy
./scripts/deploy-service-image.sh backend dev
```

### Test Promotion
```bash
# Set up environment
export AZURE_RESOURCE_GROUP="rg-raptor-test"
export AZURE_ACR_NAME="ngraptortest"
export AZURE_ACR_NAME_SRC="ngraptordev"

# Promote frontend
./scripts/promote-service-image.sh \
  frontend \
  "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:..." \
  test
```

## Troubleshooting

### Script Not Found
```bash
chmod +x scripts/deploy-service-image.sh
chmod +x scripts/promote-service-image.sh
```

### Permission Denied
Ensure GitHub Actions has execute permissions:
```yaml
- name: Make scripts executable
  run: |
    chmod +x scripts/*.sh
```

### Missing Environment Variable
Check that all required variables are set:
```yaml
env:
  AZURE_ENV_NAME: ${{ vars.AZURE_ENV_NAME }}
  AZURE_RESOURCE_GROUP: ${{ vars.AZURE_RESOURCE_GROUP }}
  AZURE_ACR_NAME: ${{ vars.AZURE_ACR_NAME }}
```

### Image Not Found in azd Environment
```bash
# Verify image is set
azd env get-value SERVICE_FRONTEND_IMAGE_NAME

# Set if missing
azd env set SERVICE_FRONTEND_IMAGE_NAME "registry.azurecr.io/repo@sha256:..."
```

## Next Steps

1. ✅ **Test current frontend deployment** with new scripts
2. 📝 **Document backend requirements** (Container Apps, Bicep templates)
3. 🔧 **Update all workflow files** to use generalized scripts
4. 🚀 **Add backend service** using the generalized approach
5. 📊 **Monitor and optimize** script performance

---

**Questions?** Check script comments or review the implementation in:
- `scripts/deploy-service-image.sh`
- `scripts/promote-service-image.sh`
- `scripts/update-containerapp-image.sh` (underlying implementation)
