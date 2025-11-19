# RBAC Propagation Delay and ACR Authentication

## Overview

When deploying to Azure Container Apps with newly created managed identities, you may encounter ACR authentication failures during the first deployment. This is expected behavior due to RBAC propagation delays and has well-established workarounds.

## The Issue

### Error Message

During GitHub Actions deployments (particularly fast-path image updates), you may see:

```
ERROR: Fast image update failed: error pulling image configuration: Get "https://ngraptordev.azurecr.io/v2/raptor/backend-dev/manifests/sha256:...": 
UNAUTHORIZED: authentication required, visit https://aka.ms/acr/authorization for more information.
```

### Root Cause

When infrastructure is provisioned with new managed identities:

1. **Bicep creates resources** in this order:
   - Managed Identity (frontend and backend)
   - Role Assignment (AcrPull permission on ACR)
   - Container App (configured to use the managed identity)

2. **RBAC propagation delay occurs**:
   - Role assignments are created immediately in Azure Resource Manager
   - **5-10 minutes** required for permissions to propagate globally
   - During this window, managed identity cannot authenticate to ACR

3. **Fast-path deployment attempts immediately**:
   - GitHub Actions workflow tries to update container image
   - Uses `az containerapp update --image` for quick deployment
   - Fails because managed identity permissions haven't propagated yet

## Why This Happens

### First Deployment Only

This issue occurs **only on the first deployment** to a new environment because:
- Managed identities are created fresh
- Role assignments are brand new
- Container Apps have never pulled from ACR before

### Subsequent Deployments

After the initial 5-10 minute window:
- ✅ RBAC permissions fully propagated
- ✅ Managed identity can authenticate to ACR
- ✅ Fast-path deployments work perfectly

## Solutions and Workarounds

### Solution 1: Use `azd up` for First Deployment (Recommended)

**When**: First deployment to a new environment or after infrastructure changes

**Why**: `azd up` provisions infrastructure and waits for the deployment to complete, giving RBAC time to propagate.

**How**:

```bash
# Local development
azd up

# GitHub Actions (already configured)
- name: Provision and deploy
  run: azd up --no-prompt
```

**Benefits**:
- Handles full provisioning + deployment lifecycle
- Natural 5-10 minute window during Container App creation
- Reliable, no special timing logic needed

### Solution 2: Fast-Path Retry Logic (Already Implemented)

**What**: GitHub Actions workflows detect fast-path failures and fallback to full `azd up`

**Implementation** (from `deploy-backend.yaml` and `deploy-frontend.yaml`):

```yaml
- name: Fast image-only update (skip provision when possible)
  id: fastpath
  continue-on-error: true  # Don't fail workflow if fast-path fails
  run: |
    APP_NAME="dev-rap-be"
    IMG="${{ env.AZURE_ACR_NAME }}.azurecr.io/raptor/backend-dev@sha256:..."
    az containerapp update \
      --name "$APP_NAME" \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --image "$IMG"

- name: Fallback to full azd up if fast-path failed
  if: steps.fastpath.outcome == 'failure'
  run: |
    echo "Fast-path failed (likely RBAC propagation delay). Running full azd up..."
    azd up --no-prompt
```

**How it works**:
1. Try fast-path update first (fast, works 99% of the time)
2. If it fails, fall back to `azd up` (slower, but always works)
3. Gives RBAC time to propagate during full deployment

### Solution 3: Wait for RBAC Propagation (Not Recommended)

**Why not**: Adds artificial delays and complexity

```yaml
# Don't do this - use Solution 1 or 2 instead
- name: Wait for RBAC propagation
  run: sleep 600  # 10 minutes - wasteful
```

## Understanding the Timing

### Typical Deployment Timeline

| Time | Event | Status |
|------|-------|--------|
| T+0s | Infrastructure provisioned (managed identity + role assignment) | ✅ ARM resources created |
| T+0s | Fast-path deployment attempted | ❌ RBAC not propagated |
| T+30s | Fallback to `azd up` starts | 🔄 Starting full deployment |
| T+5m | Container App creation begins | 🔄 RBAC propagating |
| T+8m | Container App attempts image pull | ✅ RBAC propagated, pull succeeds |
| T+10m | Deployment completes | ✅ All working |

### Why Fast-Path Works After First Deployment

After initial deployment:
- Managed identity permissions already established
- No RBAC propagation delay
- Fast-path updates complete in 10-30 seconds

## When You'll See This Issue

### Scenarios

1. **New environment creation**
   ```bash
   azd env new test
   azd up  # First deployment - may see RBAC delay
   ```

2. **Infrastructure recreation**
   ```bash
   azd down --force  # Deletes managed identities
   azd up  # Recreates - RBAC delay occurs again
   ```

3. **GitHub Actions first deployment**
   - After merging frontend/backend changes to main
   - Workflow provisions new managed identity
   - Fast-path fails, falls back to full deployment

### Scenarios That Won't Trigger It

1. **Code-only changes** (no infrastructure changes)
2. **Subsequent deployments** to existing environments
3. **Image promotions** (using existing identities)

## Verification and Diagnostics

### Check RBAC Role Assignments

```bash
# Get managed identity principal ID
IDENTITY_ID=$(az identity show \
  --name id-backend-dev-rtzig3eodfdtu \
  --resource-group rg-raptor-dev \
  --query principalId -o tsv)

# Check ACR role assignments
az role assignment list \
  --assignee $IDENTITY_ID \
  --scope /subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.ContainerRegistry/registries/{acr} \
  --query "[].{Role:roleDefinitionName, Scope:scope}" -o table
```

**Expected output**:
```
Role     Scope
-------  ----------------------------------------------------------
AcrPull  /subscriptions/.../registries/ngraptordev
```

### Check Container App Configuration

```bash
# Verify managed identity assignment
az containerapp show \
  --name dev-rap-be \
  --resource-group rg-raptor-dev \
  --query "identity.userAssignedIdentities" -o json
```

### Test ACR Authentication

```bash
# Get managed identity token (from Container App environment)
TOKEN=$(az account get-access-token \
  --resource https://ngraptordev.azurecr.io \
  --query accessToken -o tsv)

# Try ACR authentication
curl -H "Authorization: Bearer $TOKEN" \
  https://ngraptordev.azurecr.io/v2/_catalog
```

## GitHub Actions Implementation

### Current Workflow Pattern

All deployment workflows (`deploy-backend.yaml`, `deploy-frontend.yaml`) implement:

```yaml
jobs:
  deploy:
    steps:
      # ... authentication, setup, etc. ...

      - name: Fast image-only update (skip provision when possible)
        id: fastpath
        continue-on-error: true
        shell: bash
        run: |
          # Quick update using az containerapp update
          # Fails if RBAC not propagated
        
      - name: Fallback to full azd up if fast-path failed
        if: steps.fastpath.outcome == 'failure'
        shell: bash
        run: |
          echo "Fast-path failed (likely RBAC propagation delay). Running full azd up..."
          azd up --no-prompt
```

### Why This Works

1. **Optimistic fast-path**: Try quick update first (works 99% of time)
2. **Graceful fallback**: If it fails, use full deployment (gives time for RBAC)
3. **No artificial delays**: Only waits when necessary
4. **User-transparent**: Workflow always succeeds, just takes longer on first run

## Related Azure Documentation

- [Azure RBAC Propagation](https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting#role-assignment-changes-are-not-being-detected)
- [Container Apps Managed Identity](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity)
- [ACR Authentication](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-authentication-managed-identity)

## Key Takeaways

1. **RBAC propagation takes 5-10 minutes** - this is normal Azure behavior
2. **Only affects first deployment** to new environments
3. **Already handled** by workflow retry logic (fast-path → fallback)
4. **Not an error** - workflows automatically recover
5. **No action needed** - system self-heals during full deployment

## FAQ

### Q: Can I speed up RBAC propagation?
**A**: No, this is an Azure platform limitation. 5-10 minutes is typical.

### Q: Will this break my CI/CD pipeline?
**A**: No, workflows implement automatic fallback to full deployment.

### Q: Should I disable fast-path deployments?
**A**: No, fast-path works fine after initial deployment. Fallback handles first-time case.

### Q: Is this a bug in the deployment scripts?
**A**: No, this is expected Azure behavior. Scripts are designed to handle it gracefully.

### Q: Can I test RBAC propagation locally?
**A**: Yes, run `azd down --force` then `azd up` - you may experience similar delay.
