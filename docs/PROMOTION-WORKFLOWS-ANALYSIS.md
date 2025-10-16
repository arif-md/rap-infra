# Analysis: Registry Binding in Promotion Workflows

## Question
Do test/train/prod promotion workflows need the same registry binding optimization as the dev workflow?

## Short Answer
**NO** - Promotion workflows don't need the registry binding logic at all.
**BUT YES** - They DO need the repository existence check for ACR deletion resilience.

## Why Promotion Workflows Are Different

### Dev Workflow (infra-azd.yaml)
**Trigger:** Repository dispatch from frontend build
**Image Source:** External ACR (could be `ngraptordev`, `ngraptortest`, etc.)
**Challenge:** Image comes from a **potentially different ACR** than the app's current configuration

**Flow:**
1. Frontend builds in dev environment → pushes to `ngraptordev`
2. Triggers infra workflow with image: `ngraptordev.azurecr.io/raptor/frontend-dev@sha256:...`
3. Container App might be configured for a different ACR (or not configured at all)
4. **Must ensure ACR binding exists** before deploying

**Why registry binding needed:**
- ✅ Container App may not be configured for this ACR yet
- ✅ Identity may need AcrPull permission granted
- ✅ Registry binding may need to be set

### Promotion Workflows (promote-image.yaml)
**Trigger:** Manual approval gates or automated after dev
**Image Source:** **Same ACR** that the environment is already configured for
**Challenge:** Just updating image digest in the same registry

**Flow (Test Environment Example):**
1. Dev image exists: `ngraptordev.azurecr.io/raptor/frontend-dev@sha256:abc`
2. Promotion imports to test: `ngraptortest.azurecr.io/raptor/frontend-test@sha256:abc`
3. Updates test Container App with new digest from **same ACR it's already using**

**Why registry binding NOT needed:**
- ✅ Container App already configured for `ngraptortest.azurecr.io`
- ✅ Identity already has AcrPull on `ngraptortest`
- ✅ Registry binding already set from initial deployment
- ✅ Just changing digest: `@sha256:old` → `@sha256:new`

## What Promotion Workflows Currently Do

### Current Code (Test Environment)
```yaml
- name: Fast image-only update (skip provision when possible)
  run: |
    APP_NAME=$(echo "test-rap-fe" | tr '[:upper:]' '[:lower:]')
    IMG="ngraptortest.azurecr.io/raptor/frontend-test@$DIGEST"
    
    # Simple check: does app exist?
    if ! az containerapp show -n "$APP_NAME" -g "$RG" >/dev/null 2>&1; then
      echo "Container App does not exist; cannot fast-path."
      exit 0
    fi
    
    # Direct update - no registry binding!
    az containerapp update -n "$APP_NAME" -g "$RG" --image "$IMG"
```

**This is correct!** Because:
1. Test Container App was provisioned by `azd up` which set up the ACR binding
2. The binding to `ngraptortest.azurecr.io` persists
3. Promotion just updates the digest in the same registry
4. No need to rebind or check RBAC

## What Promotion Workflows DO Need

### Missing: Repository Existence Check

Promotion workflows CAN fail if ACR repositories are deleted, but for a different reason:

**Scenario:**
1. Test Container App currently has: `ngraptortest.azurecr.io/raptor/frontend-test@sha256:OLD`
2. You delete the test ACR repository
3. Promotion imports new image: `ngraptortest.azurecr.io/raptor/frontend-test@sha256:NEW`
4. `az containerapp update --image` tries to validate OLD digest
5. ❌ **Fails** because OLD digest doesn't exist

### Solution: Add Repository Check to Promotions

Let me check if promotion workflows have the old digest validation:

```yaml
# In promote-image.yaml, line ~450
- name: Fast image-only update (skip provision when possible)
  run: |
    APP_NAME=$(echo "${{ steps.prep.outputs.env }}-rap-fe" | tr '[:upper:]' '[:lower:]')
    IMG="${{ steps.prep.outputs.acr }}.azurecr.io/raptor/frontend-${{ steps.prep.outputs.env }}@${{ steps.import.outputs.digest }}"
    
    # Missing: Check if old digest exists in ACR
    # Should use revision copy if old digest is missing
    
    az containerapp update -n "$APP_NAME" -g "${{ steps.prep.outputs.rg }}" --image "$IMG"
```

## What Needs to Be Added

Promotion workflows need the **old digest validation logic** from infra-azd.yaml:

1. Check if currently deployed image exists in ACR
2. If not → Use `az containerapp revision copy` instead of `update`
3. If yes → Use regular `az containerapp update`

This is the **same logic** we added to infra-azd.yaml for ACR deletion resilience.

## Summary Table

| Aspect | Dev Workflow | Promotion Workflows |
|--------|-------------|---------------------|
| **Registry binding check** | ✅ **YES - NEEDED** | ❌ **NO - NOT NEEDED** |
| **RBAC role assignment** | ✅ **YES - NEEDED** | ❌ **NO - NOT NEEDED** |
| **15-second RBAC wait** | ✅ **YES - IF REBINDING** | ❌ **NO - NEVER NEEDED** |
| **Old digest validation** | ✅ **YES - ALREADY ADDED** | ⚠️ **YES - MISSING!** |
| **Revision copy fallback** | ✅ **YES - ALREADY ADDED** | ⚠️ **YES - MISSING!** |

## Recommendation

**DO NOT** add registry binding logic to promotion workflows.
**DO** add old digest validation and revision copy fallback to promotion workflows.

### What to Add to Promotions

```yaml
# Before the update command, add:
CURRENT_IMG=$(az containerapp show -n "$APP_NAME" -g "$RG" \
  --query "properties.template.containers[0].image" -o tsv 2>/dev/null || true)
USE_REVISION_COPY=false

if [ -n "$CURRENT_IMG" ] && echo "$CURRENT_IMG" | grep -q "@sha256:"; then
  CURRENT_DOMAIN="${CURRENT_IMG%%/*}"
  if echo "$CURRENT_DOMAIN" | grep -q ".azurecr.io$"; then
    CURRENT_REG=$(echo "$CURRENT_DOMAIN" | sed 's/\.azurecr\.io$//')
    CURRENT_PATH="${CURRENT_IMG#*/}"
    CURRENT_REPO="${CURRENT_PATH%@*}"
    CURRENT_DIGEST="${CURRENT_IMG#*@}"
    
    # Check if repository exists
    REPO_EXISTS=$(az acr repository show -n "$CURRENT_REG" --repository "$CURRENT_REPO" \
      --query "name" -o tsv 2>/dev/null || true)
    
    if [ -z "$REPO_EXISTS" ]; then
      echo "Old repository not found, will use revision copy"
      USE_REVISION_COPY=true
    else
      # Check if specific digest exists
      DIGEST_EXISTS=$(az acr repository show-manifests -n "$CURRENT_REG" \
        --repository "$CURRENT_REPO" \
        --query "[?digest=='$CURRENT_DIGEST'].digest | [0]" \
        -o tsv 2>/dev/null || true)
      
      if [ -z "$DIGEST_EXISTS" ]; then
        echo "Old digest not found, will use revision copy"
        USE_REVISION_COPY=true
      fi
    fi
  fi
fi

# Use appropriate deployment method
if [ "$USE_REVISION_COPY" = "true" ]; then
  CURRENT_REVISION=$(az containerapp revision list -n "$APP_NAME" -g "$RG" \
    --query "[0].name" -o tsv 2>/dev/null || true)
  if [ -n "$CURRENT_REVISION" ]; then
    az containerapp revision copy -n "$APP_NAME" -g "$RG" \
      --from-revision "$CURRENT_REVISION" --image "$IMG"
  else
    az containerapp update -n "$APP_NAME" -g "$RG" --image "$IMG"
  fi
else
  az containerapp update -n "$APP_NAME" -g "$RG" --image "$IMG"
fi
```

This gives promotions the same ACR deletion resilience as dev, without the unnecessary registry binding overhead.
