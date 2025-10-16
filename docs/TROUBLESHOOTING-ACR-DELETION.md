# Troubleshooting: ACR Repository Deletion

## Your Scenario

You deleted all repositories in both ACRs (ngraptordev, ngraptortest) and encountered this error:

```
ERROR: Failed to provision revision for container app 'dev-rap-fe'. 
Error details: The following field(s) are either invalid or missing. 
Field 'template.containers.dev-rap-fe.image' is invalid with details: 
'Invalid value: "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:185b66bfcad782d66738703d6e816928a32f10b8024369f06c2519e354184f77": 
GET https:: MANIFEST_UNKNOWN: manifest sha256:185b66bfcad782d66738703d6e816928a32f10b8024369f06c2519e354184f77 is not found
```

## Root Cause

The error shows Azure is trying to validate the **NEW image** (the one being deployed), not the old one. The problem is:

1. ❌ You triggered a deployment via **repository_dispatch** (from frontend repo)
2. ❌ The event payload contained an image reference that **no longer exists** in ACR
3. ❌ The workflow tried to deploy this non-existent image
4. ❌ Azure couldn't pull the image and failed validation

## Why This Happened

### Different Behavior for Different Triggers

The workflow has **two different image resolution strategies**:

1. **Push/Manual Runs** (✅ Has fallback):
   ```yaml
   - name: Resolve image from ACR (fallback to public)
     if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
   ```
   - Looks for latest image in ACR
   - If not found → Falls back to `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`
   - ✅ **This would have worked** even with deleted repositories

2. **Repository Dispatch** (❌ No fallback):
   ```yaml
   - name: Accept image from repository_dispatch (optional)
     if: github.event_name == 'repository_dispatch' && github.event.action == 'frontend-image-pushed'
   ```
   - Always uses the image from the event payload
   - ❌ **No fallback mechanism**
   - ❌ **This is what failed** - the image in the payload didn't exist

## Solution

You have **three options**:

### Option 1: Rebuild and Push Image (Recommended)
This is the proper workflow:

1. **In your frontend repo**, trigger a build and push:
   ```bash
   # This will build and push to ngraptordev ACR
   git commit --allow-empty -m "Rebuild after ACR cleanup"
   git push origin main
   ```

2. The frontend workflow will:
   - Build the Docker image
   - Push it to ACR (creating the repository again)
   - Trigger infra deployment via repository_dispatch with the new digest

3. Your infra workflow will deploy successfully with the new image

### Option 2: Manually Trigger with Fallback Image
Trigger the infra workflow **manually** to use the fallback:

1. Go to GitHub Actions → infra-azd.yaml workflow
2. Click "Run workflow" 
3. Select the branch
4. This will use the fallback image (`containerapps-helloworld:latest`)

### Option 3: Add Fallback for Repository Dispatch (Enhancement)
Modify the workflow to validate the image exists before deploying:

```yaml
- name: Accept image from repository_dispatch (optional)
  if: github.event_name == 'repository_dispatch' && github.event.action == 'frontend-image-pushed'
  run: |
    IMG='${{ github.event.client_payload.image }}'
    if [ -n "$IMG" ]; then
      # Extract registry and repository
      DOMAIN="${IMG%%/*}"
      if echo "$DOMAIN" | grep -q ".azurecr.io$"; then
        REG_NAME="${DOMAIN%.azurecr.io}"
        PATH="${IMG#*/}"
        REPO="${PATH%@*}"
        DIGEST="${IMG#*@}"
        
        # Check if image exists
        EXISTS=$(az acr repository show-manifests -n "$REG_NAME" --repository "$REPO" \
          --query "[?digest=='$DIGEST'].digest | [0]" -o tsv 2>/dev/null || true)
        
        if [ -n "$EXISTS" ]; then
          echo "Using pre-built image: $IMG"
          azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMG"
          azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
        else
          echo "Image not found in ACR, falling back to public image"
          FALLBACK="mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
          azd env set SERVICE_FRONTEND_IMAGE_NAME "$FALLBACK"
          azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
        fi
      fi
    fi
```

## What I Fixed

I made one improvement to handle the **old image** validation issue:

### Before
```bash
# Only checked if digest exists
DIGEST_EXISTS=$(az acr repository show-manifests -n "$CURRENT_REG" --repository "$CURRENT_REPO" ...)
```

**Problem:** If repository is deleted, `show-manifests` fails before checking digest

### After
```bash
# First check if repository exists
REPO_EXISTS=$(az acr repository show -n "$CURRENT_REG" --repository "$CURRENT_REPO" ...)
if [ -z "$REPO_EXISTS" ]; then
  USE_REVISION_COPY=true
else
  # Then check if specific digest exists
  DIGEST_EXISTS=$(az acr repository show-manifests ...)
fi
```

**Benefit:** Gracefully handles both deleted repositories AND deleted digests

## Recommended Next Steps

1. ✅ **Rebuild your frontend image** (Option 1 above)
2. ✅ **Let the normal flow work** - frontend push → infra deployment
3. ✅ Consider adding validation fallback (Option 3) if you want extra safety

## Prevention

To avoid this in the future:
- Don't delete ACR repositories while Container Apps still reference them
- If you need to clean up, deploy a fresh image first, then delete old images
- Or use manual trigger with fallback image before deleting repositories
