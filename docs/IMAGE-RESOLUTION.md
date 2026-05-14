# Automatic Image Resolution Feature

## Overview

The `resolve-images` pre-provision hook automatically resolves container images before deployment, ensuring `azd up` works even when configured image digests are stale or missing.

## How It Works

**Before every `azd up` deployment**, the hook:

1. **Validates Current Images**: Checks if configured image digests exist in ACR
2. **Resolves Latest Images**: If digest is missing, queries ACR for latest image
3. **Falls Back to Public Image**: If no images in ACR, uses placeholder image
4. **Updates azd Environment**: Sets resolved images in azd environment variables

## Scenarios Handled

### ✅ Scenario 1: Stale Digest (Your Case)

**Problem**: 
```
SERVICE_FRONTEND_IMAGE_NAME=ngraptortest.azurecr.io/raptor/frontend-test@sha256:ba372c9e...
# This digest doesn't exist anymore (resource was deleted)
```

**Solution**:
```
🔍 Resolving container images from ACR...
📦 Resolving frontend image...
   ⚠️  Current image digest not found in ACR, will resolve latest...
   ✅ Found latest image in ACR: ngraptortest.azurecr.io/raptor/frontend-test@sha256:bdb65eeb...
```

### ✅ Scenario 2: No Image Configured

**Problem**: Backend service has no image configured yet

**Solution**:
```
📦 Resolving backend image...
   No current image configured for backend
   ⚠️  No images found in ACR repository 'raptor/backend-test'
   ℹ️  Using fallback public image: mcr.microsoft.com/azuredocs/containerapps-helloworld:latest
```

### ✅ Scenario 3: Empty ACR Repository

**Problem**: ACR repository `raptor/frontend-dev` exists but has no images

**Solution**:
```
📦 Resolving frontend image...
   Querying ACR for latest image...
   ⚠️  No images found in ACR repository 'raptor/frontend-dev'
   ℹ️  Using fallback public image: mcr.microsoft.com/azuredocs/containerapps-helloworld:latest
```

### ✅ Scenario 4: Valid Digest

**Problem**: None - current image is valid

**Solution**:
```
📦 Resolving frontend image...
   Current image: ngraptortest.azurecr.io/raptor/frontend-test@sha256:bdb65eeb...
   Validating digest in ACR...
   ✅ Current image digest is valid in ACR
```
(No changes made)

## Integration with azure.yaml

The hook runs automatically as part of `azd up`:

```yaml
hooks:
  preprovision:
    windows:
      shell: pwsh
      run: |
        ./scripts/resolve-images.ps1   # ← Resolves images first
        ./scripts/ensure-acr.ps1        # Then ensures ACR exists
    posix:
      shell: sh
      run: |
        ./scripts/resolve-images.sh
        ./scripts/ensure-acr.sh
```

## Workflow Comparison

### Before (Manual Intervention Required)

```bash
$ azd up
ERROR: ContainerAppOperationError: Failed to provision revision
Field 'template.containers.test-rap-fe.image' is invalid with details:
'Invalid value: "ngraptortest.azurecr.io/raptor/frontend-test@sha256:ba372c9e..."

# User had to manually fix:
$ azd env set SERVICE_FRONTEND_IMAGE_NAME "ngraptortest.azurecr.io/raptor/frontend-test@sha256:bdb65eeb..."
$ azd up  # Try again
```

### After (Automatic Resolution)

```bash
$ azd up
🔍 Resolving container images from ACR...
📦 Resolving frontend image...
   ⚠️  Current image digest not found in ACR, will resolve latest...
   ✅ Found latest image in ACR: ngraptortest.azurecr.io/raptor/frontend-test@sha256:bdb65eeb...
✅ Image resolution complete

# Deployment continues automatically with correct image
```

## Script Logic

### Image Resolution Priority

```
1. Check current image configuration
   └─ If valid digest in ACR → Use current image ✅
   └─ If invalid/missing → Continue to step 2

2. Query ACR for latest image
   └─ If image found → Use latest digest ✅
   └─ If repo empty → Continue to step 3

3. Use fallback public image
   └─ mcr.microsoft.com/azuredocs/containerapps-helloworld:latest ✅
```

### Services Handled

- **Frontend**: `SERVICE_FRONTEND_IMAGE_NAME`
- **Backend**: `SERVICE_BACKEND_IMAGE_NAME`

Add more services by updating the script:
```powershell
Resolve-ServiceImage -ServiceKey "api"
Resolve-ServiceImage -ServiceKey "worker"
```

## Benefits

✅ **Resilient to Resource Cleanup**: Survive ACR/Container App deletions  
✅ **Fresh Starts**: `azd up` works even with empty environment  
✅ **Developer Friendly**: No manual image configuration needed  
✅ **CI/CD Compatible**: Works in both local and automated scenarios  
✅ **Graceful Degradation**: Falls back to placeholder if no images available  

## Limitations

⚠️ **Latest Digest Only**: Always uses most recent image, not a specific version  
⚠️ **ACR Dependency**: Requires `az` CLI and ACR access to resolve images  
⚠️ **Environment-Specific**: Uses `AZURE_ENV_NAME` to determine ACR repository  

## Attestation Manifest Problem and Fix

### Root Cause

When `az acr import --platform linux/amd64` imports a multi-arch image, the ACR may record
multiple manifests: the linux/amd64 image, the OCI manifest index, and an SLSA attestation
manifest. The attestation manifest has `os: unknown` and is written last, so a naive
`--orderby time_desc --top 1` query selects it.

Container Apps rejects attestation manifests with a cryptic `InvalidImage` error because
they have no runnable OS/architecture.

### Fix in `resolve-images.sh`

The script now queries specifically for a `linux/amd64` manifest:

```bash
# First try linux/amd64 manifest specifically (avoids attestation manifests)
DIGEST=$(az acr manifest list-metadata -r "$AZURE_ACR_NAME" -n "$REPO" \
  --query "[?architecture=='amd64' && os=='linux'] | [-1].digest" -o tsv 2>/dev/null || true)
# Fall back to time-ordered if architecture filter returns nothing
if [ -z "$DIGEST" ]; then
  DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" \
    --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
fi
```

Additionally, when an existing digest is configured, the script now validates it is a
runnable manifest (not an attestation) before trusting it:

```bash
# Check os field — attestations have os=unknown
IMG_OS=$(az acr manifest show-metadata -r "$ACR_NAME" -n "${REPO}@${DIGEST}" \
  --query "os" -o tsv 2>/dev/null || echo "")
if [[ "$IMG_OS" == "unknown" || "$IMG_OS" == "" ]]; then
  # Re-resolve the correct linux/amd64 manifest
fi
```

### Fix in `_promote-image.yaml`

The `promote-to-*` jobs in the reusable workflow pass `--platform linux/amd64` to
`az acr import` and then resolve the digest **from the target ACR** after import:

```bash
az acr import -n "$TARGET_ACR" \
  --source "$SRC_REGISTRY/$REPO@$SRC_DIGEST" \
  --image "$TARGET_REPO@$SRC_DIGEST" \
  --platform linux/amd64

# Resolve from target (not trust the source digest directly)
PROMOTED_DIGEST=$(az acr manifest list-metadata -r "$TARGET_ACR" -n "$TARGET_REPO" \
  --query "[?architecture=='amd64' && os=='linux'] | [-1].digest" -o tsv)
```



You can still manually set specific images:

```bash
# Set a specific digest
azd env set SERVICE_FRONTEND_IMAGE_NAME "myacr.azurecr.io/raptor/frontend-dev@sha256:abc123..."

# Use a tag (not recommended for production)
azd env set SERVICE_FRONTEND_IMAGE_NAME "myacr.azurecr.io/raptor/frontend-dev:v1.2.3"

# Use a public image
azd env set SERVICE_FRONTEND_IMAGE_NAME "nginx:alpine"
azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
```

The script will detect these are valid and not override them (unless the digest doesn't exist in ACR).

## Troubleshooting

### Script Fails with ACR Access Error

**Problem**: No permission to query ACR

**Solution**:
```bash
# Ensure you're logged in
az login
az account set --subscription <subscription-id>

# Verify ACR access
az acr repository list -n ngraptortest
```

### Script Uses Fallback When Images Exist

**Problem**: ACR repository naming mismatch

**Check**:
```bash
# Verify repository name
az acr repository list -n ngraptortest

# Should show: raptor/frontend-dev (not raptor-frontend-dev or frontend-dev)
```

**Fix**: Ensure ACR repository follows naming convention: `raptor/{service}-{env}`

### Want to Force Re-resolution

```bash
# Clear current image
azd env set SERVICE_FRONTEND_IMAGE_NAME ""

# Run azd up (or just the script)
azd up
```

## Testing the Script Standalone

```bash
# Test image resolution without deploying
./scripts/resolve-images.ps1  # Windows
./scripts/resolve-images.sh   # Linux/Mac

# Check what was resolved
azd env get-values | grep IMAGE_NAME
```

## See Also

- [Workflows Documentation](./WORKFLOWS.md) - Service-specific workflow details
- [Architecture Strategies](./ARCHITECTURE-STRATEGIES.md) - Multi-service patterns
- [ensure-acr scripts](../scripts/) - ACR provisioning logic
