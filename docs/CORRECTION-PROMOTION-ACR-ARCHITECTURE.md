# Correction: Promotion Workflows ACR Architecture

## My Mistake

I incorrectly assumed that test/train/prod each had their own dedicated ACR. 

**Wrong assumption:**
- Test → `ngraptortest.azurecr.io`
- Train → `ngraptortrain.azurecr.io`
- Prod → `ngraptorprod.azurecr.io`

## Actual Architecture

### Current Setup (Shared ACR)
All environments **share the same ACR** with different repositories:

```
ngraptortest.azurecr.io/
├── raptor/frontend-dev
├── raptor/frontend-test
├── raptor/frontend-train
└── raptor/frontend-prod
```

**Environment variables:**
- `AZURE_ACR_NAME` = `ngraptortest` (shared by all)
- Each environment uses different repository within same ACR

**Image promotion flow:**
```
Dev:   ngraptortest.azurecr.io/raptor/frontend-dev@sha256:abc
  ↓ import
Test:  ngraptortest.azurecr.io/raptor/frontend-test@sha256:abc
  ↓ import  
Train: ngraptortest.azurecr.io/raptor/frontend-train@sha256:abc
  ↓ import
Prod:  ngraptortest.azurecr.io/raptor/frontend-prod@sha256:abc
```

### Future Flexibility (Per-Environment ACRs)

The workflow supports per-environment ACRs via fallback chain:

```yaml
case "${TARGET_ENV^^}" in
  TEST)
    ACR_NAME='${{ vars.AZURE_ACR_NAME_TEST || vars.AZURE_ACR_NAME || '' }}'
    ;;
  TRAIN)
    ACR_NAME='${{ vars.AZURE_ACR_NAME_TRAIN || vars.AZURE_ACR_NAME || '' }}'
    ;;
  PROD)
    ACR_NAME='${{ vars.AZURE_ACR_NAME_PROD || vars.AZURE_ACR_NAME || '' }}'
    ;;
esac
```

**Fallback priority:**
1. Environment-specific: `AZURE_ACR_NAME_TEST`
2. Global: `AZURE_ACR_NAME`
3. Empty (will fail)

**This means you can configure:**
- **Option A (current):** Single `AZURE_ACR_NAME=ngraptortest` for all
- **Option B (future):** Per-env variables with different ACRs

## Why Registry Binding IS Needed for Promotions

Given this architecture, promotion workflows **DO need registry binding logic** because:

### Scenario 1: Initial Deployment
Container App created with `azd up` might not have ACR configured yet:
- App exists but no registry binding
- Promotion needs to bind ACR before deploying
- Needs RBAC role assignment

### Scenario 2: ACR Migration
If you change `AZURE_ACR_NAME` from one ACR to another:
- Old: `ngraptordev` 
- New: `ngraptortest`
- Container App still bound to old ACR
- Promotion needs to rebind to new ACR

### Scenario 3: Manual Cleanup
If someone manually removes registry binding:
- `az containerapp registry remove ...`
- Next promotion needs to restore binding

### Scenario 4: Cross-Environment Promotions
If test/train/prod use different ACRs in the future:
- Test Container App bound to `ngraptortest`
- Train promotion deploys from `ngraptortrain`
- Needs to rebind to different ACR

## What Needs To Be Added

Promotion workflows need **BOTH**:

1. ✅ **ACR deletion resilience** - Already added
2. ⚠️ **Registry binding logic** - Still missing!

The registry binding logic should:
- Check if ACR already configured for Container App
- If not configured → Bind it (with RBAC wait)
- If configured → Skip (no wait)

This is the **same logic** from infra-azd.yaml that checks:
```yaml
EXISTING_REGISTRY=$(az containerapp show -n "$APP_NAME" -g "$RG" \
  --query "properties.configuration.registries[?server=='$ACR_DOMAIN'].server | [0]" \
  -o tsv 2>/dev/null || true)

if [ -n "$EXISTING_REGISTRY" ]; then
  echo "✓ ACR already configured, skipping"
else
  # Bind ACR with RBAC
  az role assignment create ...
  az containerapp registry set ...
  sleep 15
fi
```

## Implications

Since all environments **currently share the same ACR**, the registry binding logic will:
- **First promotion:** Bind `ngraptortest` to Container App (15 second wait)
- **Subsequent promotions:** Skip (ACR already bound, no wait)

This is efficient because:
- Test promotion binds `ngraptortest` → waits 15 seconds
- Train promotion sees `ngraptortest` already bound → skips
- Prod promotion sees `ngraptortest` already bound → skips

Only the **first promotion** to a new Container App pays the 15-second cost.

## Apology

I apologize for the confusion. You were correct that:
1. ✅ All environments share the same ACR (currently)
2. ✅ Different repositories within that ACR separate the environments
3. ✅ Future flexibility exists for per-environment ACRs
4. ✅ Registry binding logic IS needed for promotions

I should have examined the actual environment variable configuration more carefully before making assumptions.
