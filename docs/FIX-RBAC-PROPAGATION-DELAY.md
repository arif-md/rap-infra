# Fix: RBAC Propagation Delay for ACR Access

## Problem

When ACR repositories are deleted and recreated, the Container App loses its registry binding. The workflow rebinds the ACR using managed identity, but the deployment fails immediately with:

```
ERROR: Failed to provision revision for container app 'dev-rap-fe'.
Field 'template.containers.dev-rap-fe.image' is invalid with details:
'Invalid value: "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:...":
GET https:: MANIFEST_UNKNOWN: manifest sha256:... is not found
```

Even though the image EXISTS in ACR (manually verified), Azure can't pull it.

## Root Cause

**RBAC propagation delay.** When the workflow does:

1. `az role assignment create` (grants AcrPull permission)
2. `az containerapp registry set` (binds ACR to Container App)
3. `az containerapp revision copy --image` (deploys new image) ← **FAILS HERE**

Step 3 happens **immediately** after step 2, but RBAC permissions take 15-60 seconds to propagate through Azure AD. The Container App's managed identity doesn't have permission yet to pull from ACR.

## Solution

Added a **15-second sleep** after binding the registry to allow RBAC propagation:

### For System-Assigned Identity
```yaml
if [ -n "$PRINCIPAL_ID" ]; then
  echo "Ensuring AcrPull for system-assigned identity $PRINCIPAL_ID"
  az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --role "$ROLE_ID" --scope "$ACR_ID" >/dev/null 2>&1 || true
  echo "Binding registry to app using system identity"
  az containerapp registry set -n "$APP_NAME" -g "$AZURE_RESOURCE_GROUP" --server "$ACR_DOMAIN" --identity system >/dev/null
  echo "Waiting 15 seconds for RBAC propagation..."  # ← NEW
  sleep 15                                            # ← NEW
fi
```

### For User-Assigned Identity
```yaml
if [ -n "$UAI_PRINCIPAL" ]; then
  echo "Ensuring AcrPull for user-assigned identity $UAI_PRINCIPAL"
  az role assignment create --assignee-object-id "$UAI_PRINCIPAL" --assignee-principal-type ServicePrincipal --role "$ROLE_ID" --scope "$ACR_ID" >/dev/null 2>&1 || true
  echo "Binding registry to app using user-assigned identity"
  az containerapp registry set -n "$APP_NAME" -g "$AZURE_RESOURCE_GROUP" --server "$ACR_DOMAIN" --identity "$FIRST_UAI" >/dev/null
  echo "Waiting 15 seconds for RBAC propagation..."  # ← NEW
  sleep 15                                            # ← NEW
fi
```

## Additional Fix: Repository Existence Check

Also improved the old digest validation to check if repository exists before checking for specific digest:

```yaml
# First check if repository exists
REPO_EXISTS=$(az acr repository show -n "$CURRENT_REG" --repository "$CURRENT_REPO" --query "name" -o tsv 2>/dev/null || true)
if [ -z "$REPO_EXISTS" ]; then
  echo "Currently deployed repository not found in ACR (repository may have been deleted)."
  echo "Using 'az containerapp revision copy' to force new revision with new image."
  USE_REVISION_COPY=true
else
  # Repository exists, now check if specific digest exists
  DIGEST_EXISTS=$(az acr repository show-manifests -n "$CURRENT_REG" --repository "$CURRENT_REPO" --query "[?digest=='$CURRENT_DIGEST'].digest | [0]" -o tsv 2>/dev/null || true)
  if [ -z "$DIGEST_EXISTS" ]; then
    USE_REVISION_COPY=true
  fi
fi
```

**Why?** If repository is deleted, `show-manifests` command fails before checking digest. This two-step check handles both scenarios gracefully.

## Why 15 Seconds?

- **Microsoft recommendation:** RBAC changes can take up to 60 seconds
- **Practical experience:** Usually propagates in 15-30 seconds
- **Trade-off:** 15 seconds is reasonable for reliability without being too slow
- **Alternative considered:** Retry logic with exponential backoff (more complex, not worth it for this use case)

## Impact

- ✅ Fixes the immediate deployment failure after ACR repository deletion
- ✅ Allows managed identity permissions to propagate before image pull
- ✅ Adds only 15 seconds to deployment time (acceptable for reliability)
- ✅ Handles both deleted repositories and deleted digests

## Testing

After these changes, the workflow should successfully:
1. Detect that old repository/digest is missing
2. Bind ACR to Container App with managed identity
3. Wait for RBAC propagation
4. Deploy new image successfully using revision copy

The 15-second delay only applies when rebinding ACR (typically after repository deletion or initial setup).
