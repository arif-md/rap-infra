# infra-azd.yaml Parameterization - Changes Summary

## Overview
Removed hardcoded frontend-specific values from `infra-azd.yaml` and replaced them with parameterized variables. This makes it easy to duplicate the workflow for other services (backend, API, etc.).

## Changes Made

### 1. Added Service Configuration Variables (Top of Job)

**Added:**
```yaml
env:
  # Service configuration - change these when duplicating for other services
  SERVICE_KEY: frontend              # Used for: SERVICE_{KEY}_IMAGE_NAME, raptor/{key}-{env}
  SERVICE_SUFFIX: fe                 # Used for: {env}-rap-{suffix}
  
  # Use environment-scoped variables...
  AZURE_ENV_NAME: ${{ vars.AZURE_ENV_NAME || 'dev' }}
  ...
```

**Benefit:** Single source of truth for service identity. To create a backend workflow, just change:
- `SERVICE_KEY: frontend` → `SERVICE_KEY: backend`
- `SERVICE_SUFFIX: fe` → `SERVICE_SUFFIX: be`

### 2. Parameterized "Resolve image from ACR" Step

**Before:**
```yaml
REPO="raptor/frontend-${AZURE_ENV_NAME}"
azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMAGE"
```

**After:**
```yaml
REPO="raptor/${SERVICE_KEY}-${AZURE_ENV_NAME}"
SERVICE_KEY_UPPER=$(echo "$SERVICE_KEY" | tr '[:lower:]' '[:upper:]')
IMAGE_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
azd env set "$IMAGE_VAR" "$IMAGE"
```

**Benefit:** 
- Repository name dynamically constructed: `raptor/frontend-dev` or `raptor/backend-dev`
- Environment variable dynamically constructed: `SERVICE_FRONTEND_IMAGE_NAME` or `SERVICE_BACKEND_IMAGE_NAME`

### 3. Parameterized "Accept image from repository_dispatch" Step

**Before:**
```yaml
azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMG"
```

**After:**
```yaml
SERVICE_KEY_UPPER=$(echo "$SERVICE_KEY" | tr '[:lower:]' '[:upper:]')
IMAGE_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
azd env set "$IMAGE_VAR" "$IMG"
```

**Benefit:** Uses correct environment variable based on service

### 4. Parameterized "Validate image vs ACR binding" Step

**Before:**
```yaml
IMG=$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME || true)
echo "SERVICE_FRONTEND_IMAGE_NAME is not set; nothing to validate."
```

**After:**
```yaml
SERVICE_KEY_UPPER=$(echo "$SERVICE_KEY" | tr '[:lower:]' '[:upper:]')
IMAGE_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
IMG=$(azd env get-value "$IMAGE_VAR" || true)
echo "$IMAGE_VAR is not set; nothing to validate."
```

**Benefit:** Validation works for any service

### 5. Parameterized "Fast image-only update" Step

**Before:**
```yaml
./scripts/deploy-service-image.sh frontend "${AZURE_ENV_NAME}"
```

**After:**
```yaml
./scripts/deploy-service-image.sh "$SERVICE_KEY" "${AZURE_ENV_NAME}"
```

**Benefit:** Uses service from environment variable (already parameterized script call!)

### 6. Parameterized "Show effective deployed image" Step

**Before:**
```yaml
CONFIGURED_IMG=$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME || true)
APP_NAME=$(echo "${AZURE_ENV_NAME}-rap-fe" | tr '[:upper:]' '[:lower:]')
echo "### Deployed image"
```

**After:**
```yaml
SERVICE_KEY_UPPER=$(echo "$SERVICE_KEY" | tr '[:lower:]' '[:upper:]')
IMAGE_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
APP_NAME=$(echo "${AZURE_ENV_NAME}-rap-${SERVICE_SUFFIX}" | tr '[:upper:]' '[:lower:]')
CONFIGURED_IMG=$(azd env get-value "$IMAGE_VAR" || true)
echo "### Deployed image ($SERVICE_KEY)"
```

**Benefit:** 
- App name constructed from `SERVICE_SUFFIX`
- Image variable derived from `SERVICE_KEY`
- Summary shows which service was deployed

### 7. Parameterized "Persist deployment metadata to tags" Step

**Before:**
```yaml
APP_NAME=$(echo "${AZURE_ENV_NAME}-rap-fe" | tr '[:upper:]' '[:lower:]')
```

**After:**
```yaml
APP_NAME=$(echo "${AZURE_ENV_NAME}-rap-${SERVICE_SUFFIX}" | tr '[:upper:]' '[:lower:]')
```

**Benefit:** Tags the correct Container App based on service

## What Stayed Hardcoded (Intentionally)

These items remain frontend-specific because this IS a frontend workflow:

| Item | Location | Reason |
|------|----------|--------|
| `frontend-image-pushed` | Line 21 (trigger) | Workflow trigger is service-specific |
| `frontendFqdn` | Line 37, 373+ | Workflow output name is service-specific |
| `frontend-image-promote` | Line 330, 358 | Promotion event is service-specific |
| `FRONTEND_SOURCE_REPO` | Line 303 | Variable name is service-specific |

**Note:** These are CORRECT as-is. When creating a backend workflow, these would become:
- `backend-image-pushed`
- `backendFqdn`
- `backend-image-promote`
- `BACKEND_SOURCE_REPO`

## How to Create Backend Workflow

Now that the internal logic is parameterized, creating a backend workflow is simple:

1. **Copy the file:**
   ```bash
   cp .github/workflows/infra-azd.yaml .github/workflows/infra-azd-backend.yaml
   ```

2. **Change service variables:**
   ```yaml
   env:
     SERVICE_KEY: backend    # Changed from 'frontend'
     SERVICE_SUFFIX: be      # Changed from 'fe'
   ```

3. **Update workflow-specific names:**
   - Workflow name: `Infra - Provision and Deploy (azd) - Backend`
   - Trigger: `backend-image-pushed`
   - Output: `backendFqdn`
   - Promotion event: `backend-image-promote`
   - Source repo var: `BACKEND_SOURCE_REPO`

4. **Done!** All internal logic (ACR resolution, validation, deployment, tagging) automatically works for backend.

## Benefits Achieved

### ✅ Single Source of Truth
All service-specific values defined at the top in one place:
```yaml
SERVICE_KEY: frontend
SERVICE_SUFFIX: fe
```

### ✅ Consistency
All steps use the same variables - no risk of mismatched names

### ✅ Easy Duplication
Creating a backend workflow requires only 2 variable changes + renaming

### ✅ Clear Separation
Workflow-level concerns (triggers, outputs) remain intentionally service-specific
Internal logic (deployment, validation) is fully parameterized

### ✅ Maintainability
Fix a bug once, easy to apply to all service workflows

## Testing Checklist

- [ ] Test frontend deployment (existing functionality should work unchanged)
- [ ] Verify correct app name used: `dev-rap-fe`
- [ ] Verify correct env var used: `SERVICE_FRONTEND_IMAGE_NAME`
- [ ] Verify correct ACR repo: `raptor/frontend-dev`
- [ ] Check deployment summary shows correct service name
- [ ] Verify tags persisted to correct Container App

## Variable Reference

### Service Identification
```yaml
SERVICE_KEY: frontend              # Lowercase, used in: raptor/{key}-{env}, SERVICE_{KEY}_IMAGE_NAME
SERVICE_SUFFIX: fe                 # Used in: {env}-rap-{suffix}
```

### Derived Values (Computed in Steps)
```bash
SERVICE_KEY_UPPER="FRONTEND"                          # Uppercase version of SERVICE_KEY
IMAGE_VAR="SERVICE_FRONTEND_IMAGE_NAME"               # Environment variable name
REPO="raptor/frontend-dev"                            # ACR repository name  
APP_NAME="dev-rap-fe"                                 # Container App name
```

### Example: Backend Values
```yaml
SERVICE_KEY: backend
SERVICE_SUFFIX: be
```
Would produce:
```bash
SERVICE_KEY_UPPER="BACKEND"
IMAGE_VAR="SERVICE_BACKEND_IMAGE_NAME"
REPO="raptor/backend-dev"
APP_NAME="dev-rap-be"
```

## Files Modified

- ✅ `.github/workflows/infra-azd.yaml` - Parameterized all service-specific internal logic

## Next Steps

1. **Test current changes** with frontend deployment
2. **If successful**, create backend workflow by copying and changing 2 variables
3. **Update documentation** with backend workflow creation guide
4. **Consider**: Create a workflow template for even easier service addition

---

**Summary:** The workflow is now **internally parameterized** while remaining **externally frontend-specific**. This is the correct pattern - the workflow identity stays service-specific (triggers, outputs), but internal logic is reusable.
