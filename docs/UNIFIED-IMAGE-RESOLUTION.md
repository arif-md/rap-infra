# Unified Image Resolution Logic

**Date**: October 26, 2025  
**Status**: Active  
**Change Type**: Simplification - Removed duplicate logic

## Summary

Both **local `azd up`** and **GitHub Actions workflows** now use the SAME image resolution logic via the `scripts/resolve-images.sh` preprovision hook. This eliminates code duplication and ensures consistent behavior across all deployment paths.

## The Problem We Had

Previously, we maintained **two separate implementations** of image resolution:

### 1. Workflow-specific logic (in `.github/workflows/deploy-frontend.yaml`)
```yaml
- name: Resolve image from ACR (fallback to public)
  run: |
    DIGEST=$(az acr repository show-manifests ...)
    azd env set SERVICE_FRONTEND_IMAGE_NAME "$REGISTRY/$REPO@$DIGEST"
```

### 2. Preprovision hook (in `scripts/resolve-images.sh`)
```bash
resolve_service_image() {
  DIGEST=$(az acr repository show-manifests ...)
  azd env set "$IMAGE_VAR" "$NEW_IMAGE"
}
```

**Issues:**
- ❌ Code duplication - same logic in two places
- ❌ Potential inconsistencies between local and CI/CD deployments
- ❌ Maintenance burden - changes need to be made twice
- ❌ Race conditions when both tried to set the same environment variable

## The Solution: Single Source of Truth

The `scripts/resolve-images.sh` preprovision hook is now the **ONLY** place where image resolution happens. It's smart enough to handle all scenarios:

### Script Behavior

```bash
#!/usr/bin/env bash
# This script runs automatically during 'azd up' (local AND GitHub Actions)

resolve_service_image() {
  # 1. Check if image is already configured
  CURRENT_IMAGE=$(azd env get-value "$IMAGE_VAR")
  
  # 2. If digest-based image exists, KEEP IT (workflow-configured)
  if [[ "$CURRENT_IMAGE" == *"@sha256:"* ]]; then
    echo "✓ Keeping existing image: $CURRENT_IMAGE"
    # Set SKIP_ACR_PULL_ROLE_ASSIGNMENT based on domain
    if [ "$DOMAIN" = "$REGISTRY" ]; then
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
    else
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
    fi
    return 0
  fi
  
  # 3. If no image or invalid, query ACR for latest
  DIGEST=$(az acr repository show-manifests ...)
  if [ -n "$DIGEST" ]; then
    azd env set "$IMAGE_VAR" "$REGISTRY/$REPO@$DIGEST"
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
  else
    # 4. Fall back to public image if ACR is empty
    azd env set "$IMAGE_VAR" "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
  fi
}
```

## How It Works in Different Scenarios

### Scenario 1: Local `azd up` (no image configured)
```bash
$ azd up
# ↓ Preprovision hook runs
🔍 Resolving container images from ACR...
📦 Resolving frontend image...
   No current image configured for frontend
   Querying ACR for latest image...
   ✅ Found latest image: ngraptordev.azurecr.io/raptor/frontend-dev@sha256:abc123...
# ↓ Deployment proceeds with resolved image
```

### Scenario 2: Local `azd up` (stale digest)
```bash
$ azd env get-value SERVICE_FRONTEND_IMAGE_NAME
# ngraptordev.azurecr.io/raptor/frontend-dev@sha256:old-stale-digest

$ azd up
# ↓ Preprovision hook runs
🔍 Resolving container images from ACR...
📦 Resolving frontend image...
   ✓ Image already configured with digest: ...@sha256:old-stale-digest
     Keeping existing image (no validation needed)
# ↓ Uses the configured digest (even if stale - no overriding!)
```

**Note**: If you want to force-resolve latest, clear the variable first:
```bash
azd env set SERVICE_FRONTEND_IMAGE_NAME ""
azd up
```

### Scenario 3: GitHub Actions - Push event (no specific image)
```yaml
# Workflow triggered by push to main
on: push

jobs:
  deploy:
    steps:
      # No image pre-configured in workflow
      
      - name: azd up
        run: azd up --no-prompt
        # ↓ Preprovision hook runs
        # ↓ No image configured → queries ACR for latest
        # ↓ Sets: SERVICE_FRONTEND_IMAGE_NAME=ngraptordev.azurecr.io/raptor/frontend-dev@sha256:latest...
```

### Scenario 4: GitHub Actions - Repository Dispatch (specific image)
```yaml
# Frontend repo pushed new image, triggers this workflow with image digest
on:
  repository_dispatch:
    types: [frontend-image-pushed]

jobs:
  deploy:
    steps:
      - name: Accept image from repository_dispatch
        run: |
          # Workflow sets the EXACT image to deploy
          azd env set SERVICE_FRONTEND_IMAGE_NAME "${{ github.event.client_payload.image }}"
          # → ngraptordev.azurecr.io/raptor/frontend-dev@sha256:new-digest-from-push
      
      - name: azd up
        run: azd up --no-prompt
        # ↓ Preprovision hook runs
        # ↓ Image already set with digest → KEEPS IT (lines 48-68)
        # ↓ Sets SKIP_ACR_PULL_ROLE_ASSIGNMENT=false (ACR domain detected)
        # ↓ Deployment uses the exact image from the push event ✅
```

## Key Benefits

### ✅ Single Source of Truth
- Image resolution logic exists in ONE place: `scripts/resolve-images.sh`
- Changes only need to be made once
- Consistent behavior across local and CI/CD deployments

### ✅ Workflow-Friendly
- Workflows can **pre-configure** images (repository_dispatch events)
- Script respects workflow-set images (doesn't override digest-based images)
- Automatic `SKIP_ACR_PULL_ROLE_ASSIGNMENT` flag management

### ✅ Developer-Friendly
- Local `azd up` "just works" - auto-resolves latest image
- No manual image configuration needed
- Clear console output shows what's happening

### ✅ Maintainable
- Less code duplication
- Easier to debug (single code path)
- Changes benefit both local and CI/CD deployments

## What Changed

### Removed from Workflows
```yaml
# ❌ REMOVED - No longer needed
- name: Resolve image from ACR (fallback to public)
  if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
  run: |
    DIGEST=$(az acr repository show-manifests ...)
    azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMAGE"
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
```

### Kept in Workflows (for repository_dispatch)
```yaml
# ✅ KEPT - Sets specific image when triggered by frontend push
- name: Accept image from repository_dispatch
  if: github.event_name == 'repository_dispatch'
  run: |
    azd env set SERVICE_FRONTEND_IMAGE_NAME "${{ github.event.client_payload.image }}"
    # The preprovision hook will keep this digest and set SKIP flag appropriately
```

### Enhanced in Preprovision Hook
```bash
# ✅ ENHANCED - Now sets SKIP_ACR_PULL_ROLE_ASSIGNMENT for existing images
elif [[ "$CURRENT_IMAGE" == *"@sha256:"* ]]; then
  echo "✓ Keeping existing image: $CURRENT_IMAGE"
  
  # NEW: Set SKIP flag based on image domain
  DOMAIN="${CURRENT_IMAGE%%/*}"
  if [ "$DOMAIN" = "$REGISTRY" ]; then
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
  else
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
  fi
  return 0
```

## Migration Notes

### For Developers
- **No changes needed** - `azd up` continues to work as before
- Stale digest handling: Clear the environment variable to force re-resolution
  ```bash
  azd env set SERVICE_FRONTEND_IMAGE_NAME ""
  azd up
  ```

### For CI/CD
- **No changes needed** - Workflows continue to work as before
- `repository_dispatch` events still set specific images
- `push` events now rely on preprovision hook (same behavior)

## Troubleshooting

### Issue: "I want to deploy the latest image but it's using an old digest"

**Cause**: The environment variable is already set with a digest, and the script keeps it.

**Solution**: Clear the variable first:
```bash
azd env set SERVICE_FRONTEND_IMAGE_NAME ""
azd up
```

### Issue: "Workflow deployed the wrong image"

**Cause**: Check if another step in the workflow set the image before `azd up`.

**Solution**: Verify workflow logs for "Accept image from repository_dispatch" step. The script will keep whatever was set there.

### Issue: "SKIP_ACR_PULL_ROLE_ASSIGNMENT is wrong"

**Cause**: The script now auto-detects based on image domain.

**Solution**: Check the image domain matches your ACR:
```bash
azd env get-value SERVICE_FRONTEND_IMAGE_NAME
# Should start with: ngraptordev.azurecr.io (for dev environment)
```

## Related Documentation

- [Image Resolution](IMAGE-RESOLUTION.md) - Original documentation (superseded by this)
- [Workflows](WORKFLOWS.md) - Workflow architecture and flow
- [Architecture Strategies](ARCHITECTURE-STRATEGIES.md) - Overall deployment architecture

## References

- **Commit**: (pending) - "Unify image resolution logic across local and CI/CD"
- **Previous Commit**: 38905ac - "Skip automatic image resolution in GitHub Actions" (REVERTED)
- **Script**: [`scripts/resolve-images.sh`](../scripts/resolve-images.sh)
- **Script (PowerShell)**: [`scripts/resolve-images.ps1`](../scripts/resolve-images.ps1)
- **Workflow**: [`.github/workflows/deploy-frontend.yaml`](../.github/workflows/deploy-frontend.yaml)
