# Summary: ACR Deletion Resilience Added to Promotion Workflows

## Question Asked
"Do we need a similar fix for promotion workflows (test/train/prod)?"

## Answer
**Partially YES** - Promotion workflows needed ACR deletion resilience but NOT registry binding logic.

## What Was Added

Added ACR deletion resilience to all three promotion environments:
- ✅ Test environment fast-path (line ~452)
- ✅ Train environment fast-path (line ~913)
- ✅ Prod environment fast-path (line ~1375)

## What Was NOT Added (And Why)

❌ **Registry binding logic** - Not needed because:
- Promotion workflows always deploy to the **same ACR** already configured
- Test promotes to `ngraptortest` (already bound)
- Train promotes to `ngraptortrain` (already bound)
- Prod promotes to `ngraptorprod` (already bound)
- ACR binding persists from initial deployment
- No need to rebind or wait for RBAC propagation

## The Logic Added

Each promotion fast-path now includes:

```yaml
# Check if currently deployed digest exists in ACR (ACR deletion resilience)
CURRENT_IMG=$(az containerapp show -n "$APP_NAME" -g "$RG" \
  --query "properties.template.containers[0].image" -o tsv)
USE_REVISION_COPY=false

if [ -n "$CURRENT_IMG" ] && echo "$CURRENT_IMG" | grep -q "@sha256:"; then
  CURRENT_DOMAIN="${CURRENT_IMG%%/*}"
  if echo "$CURRENT_DOMAIN" | grep -q ".azurecr.io$"; then
    CURRENT_REG=$(echo "$CURRENT_DOMAIN" | sed 's/\.azurecr\.io$//')
    CURRENT_PATH="${CURRENT_IMG#*/}"
    CURRENT_REPO="${CURRENT_PATH%@*}"
    CURRENT_DIGEST="${CURRENT_IMG#*@}"
    
    # First check if repository exists
    REPO_EXISTS=$(az acr repository show -n "$CURRENT_REG" --repository "$CURRENT_REPO" \
      --query "name" -o tsv 2>/dev/null || true)
    
    if [ -z "$REPO_EXISTS" ]; then
      echo "Repository deleted, using revision copy"
      USE_REVISION_COPY=true
    else
      # Repository exists, check if specific digest exists
      DIGEST_EXISTS=$(az acr repository show-manifests -n "$CURRENT_REG" \
        --repository "$CURRENT_REPO" \
        --query "[?digest=='$CURRENT_DIGEST'].digest | [0]" \
        -o tsv 2>/dev/null || true)
      
      if [ -z "$DIGEST_EXISTS" ]; then
        echo "Digest deleted, using revision copy"
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

## Why This Was Needed

### Scenario That Would Fail Before

1. Test environment has: `ngraptortest.azurecr.io/raptor/frontend-test@sha256:OLD`
2. Administrator deletes test ACR repository for cleanup
3. Promotion imports new image: `ngraptortest.azurecr.io/raptor/frontend-test@sha256:NEW`
4. `az containerapp update --image` tries to validate OLD digest exists
5. ❌ **FAILS** with MANIFEST_UNKNOWN error

### What Happens Now

1. Test environment has OLD digest
2. Administrator deletes test ACR repository
3. Promotion imports NEW image
4. Fast-path detects OLD repository/digest is missing
5. Uses `az containerapp revision copy` instead of `update`
6. ✅ **SUCCEEDS** - revision copy bypasses old image validation

## Differences from Dev Workflow

| Feature | Dev Workflow (infra-azd.yaml) | Promotion Workflows (promote-image.yaml) |
|---------|------------------------------|------------------------------------------|
| **ACR deletion resilience** | ✅ Added | ✅ Added (now) |
| **Registry binding check** | ✅ Added | ❌ Not needed |
| **RBAC role assignment** | ✅ Added (with check) | ❌ Not needed |
| **15-second RBAC wait** | ✅ Added (if rebinding) | ❌ Not needed |
| **Revision copy fallback** | ✅ Added | ✅ Added (now) |

## Benefits

1. ✅ **ACR cleanup tolerance** - Can delete and recreate repositories without breaking promotions
2. ✅ **Consistent behavior** - All environments (dev/test/train/prod) handle ACR deletion the same way
3. ✅ **Fast deployments** - No unnecessary RBAC waits in promotions
4. ✅ **Clean logic** - Only added what's needed, nothing more

## Testing

To test the new resilience:

1. Deploy to test environment successfully
2. Delete test ACR repository: `az acr repository delete -n ngraptortest --repository raptor/frontend-test`
3. Trigger test promotion
4. Should succeed using revision copy instead of update

## Related Documentation

- `docs/ACR-DELETION-RESILIENCE.md` - Full explanation of ACR deletion scenarios
- `docs/PROMOTION-WORKFLOWS-ANALYSIS.md` - Analysis of why promotions are different
- `docs/IMPROVEMENT-SKIP-REGISTRY-REBINDING.md` - Registry binding optimization
