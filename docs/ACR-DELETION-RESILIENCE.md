# ACR Repository Deletion Resilience

This document explains how the workflows handle the scenario where ACR repositories are deleted and recreated.

## Scenario

When you delete an ACR repository (e.g., `raptor/frontend-dev`) and then push a new image:
1. The Container App still references the old digest in its template
2. The old digest no longer exists in ACR (manifest deleted)
3. Container App tags (`raptor.lastCommit`, `raptor.lastDigest`) still have values from previous deployment

## Problem Without Resilience

Without resilience measures, the workflow would fail with:
```
ERROR: Failed to provision revision for container app 'dev-rap-fe'. 
Error details: The following field(s) are either invalid or missing. 
Field 'template.containers.dev-rap-fe.image' is invalid with details: 
'Invalid value: "ngraptordev.azurecr.io/raptor/frontend-dev@sha256:OLD_DIGEST": 
GET https:: MANIFEST_UNKNOWN: manifest sha256:OLD_DIGEST is not found
```

This happens because `az containerapp update --image` validates that Azure can pull ALL images in the template, including the currently deployed one.

## Solution 1: Smart Fast-Path Detection (infra-azd.yaml)

### Location
`.github/workflows/infra-azd.yaml` - "Fast image-only update" step

### Logic
Before attempting `az containerapp update --image`:

1. **Check if currently deployed digest exists in ACR**:
   ```bash
   CURRENT_IMG=$(az containerapp show -n "$APP_NAME" ...)
   CURRENT_DIGEST="${CURRENT_IMG#*@}"
   DIGEST_EXISTS=$(az acr repository show-manifests -n "$REG" --repository "$REPO" \
     --query "[?digest=='$CURRENT_DIGEST'].digest | [0]" -o tsv)
   ```

2. **If digest not found** → Skip fast-path:
   ```bash
   if [ -z "$DIGEST_EXISTS" ]; then
     echo "Currently deployed digest not found in ACR (repository may have been deleted)."
     echo "Skipping fast-path to avoid validation errors - will use full azd up instead."
     echo "didFastPath=false" >> $GITHUB_OUTPUT
     exit 0
   fi
   ```

3. **Fall back to `azd up`**:
   - `azd up` provisions via Bicep templates
   - Bicep creates a **new revision** with only the new image
   - Azure doesn't validate the old digest (it's not referenced anywhere)
   - Deployment succeeds!

### Benefits
- ✅ Workflow doesn't fail when ACR repo is deleted
- ✅ Automatically uses full provision instead of fast-path
- ✅ Clean deployment with new image
- ✅ No manual intervention required

## Solution 2: Fallback to Container App Tags for Changelog (relnotes.sh)

### Location
`scripts/relnotes.sh` - Commit SHA resolution

### Problem
When generating release notes for promotions (test/train/prod), the script needs to find the **previous commit SHA** to generate a changelog. It tries to:
1. Read OCI labels from the previous digest in ACR
2. Extract `org.opencontainers.image.revision` label

But if the ACR repository was deleted, the digest doesn't exist anymore, so it can't read the labels.

### Logic
Added fallback to Container App tags:

```bash
# Fallback: If we couldn't get PREV_SHA from image labels (e.g., ACR repo was deleted),
# try reading from Container App tags where we persist raptor.lastCommit
if [[ -z "$PREV_SHA" && -n "$RG" && "$AZ_READY" -eq 1 ]]; then
  APP_NAME="${TARGET_ENV}-rap-fe"
  PREV_SHA_FROM_TAG=$(az resource show -n "$APP_NAME" -g "$RG" \
    --resource-type "Microsoft.App/containerApps" \
    --query "tags.\"raptor.lastCommit\"" -o tsv)
  if [[ -n "$PREV_SHA_FROM_TAG" ]]; then
    PREV_SHA="$PREV_SHA_FROM_TAG"
    PREV_COMMIT_SHORT="${PREV_SHA:0:7}"
  fi
fi
```

### Fallback Chain
1. **Try ACR image labels** (primary) - Read from `org.opencontainers.image.revision`
2. **Try Container App tags** (fallback) - Read from `raptor.lastCommit` tag
3. **Give up gracefully** - Show "Commit SHAs not available" message

### Benefits
- ✅ Changelog generation still works after ACR deletion
- ✅ Uses persistent metadata from Container App tags
- ✅ No "first promotion" message when there was actually a previous deployment
- ✅ Maintains commit history across ACR repository recreations

## How Container App Tags Are Populated

The `infra-azd.yaml` workflow has a step **"Persist deployment metadata to tags"** that runs after successful deployments:

```bash
IMG='${{ steps.effective_image.outputs.configuredImage }}'
DIGEST="${IMG#*@}"

# Extract commit from OCI labels
NEW_SHA=$(get_commit_from_labels "$REG_NAME" "$REPO_NAME" "$DIGEST")

# Persist to Container App tags
TAG_ARGS=("raptor.lastDigest=${DIGEST}")
if [ -n "$NEW_SHA" ]; then TAG_ARGS+=("raptor.lastCommit=${NEW_SHA}"); fi

az resource tag -n "$APP_NAME" -g "$RG" \
  --resource-type "Microsoft.App/containerApps" \
  --is-incremental \
  --tags "${TAG_ARGS[@]}"
```

This ensures that even if ACR is deleted later, we still have the commit SHA preserved in Container App tags.

## Testing the Resilience

### Test Case 1: Delete ACR Repository and Push New Image

1. Delete ACR repository:
   ```bash
   az acr repository delete -n ngraptordev --repository raptor/frontend-dev --yes
   ```

2. Push new frontend image (from frontend repo)
   - This triggers `frontend-image-pushed` event
   - Workflow runs in infra repo

3. Expected behavior:
   - ✅ Fast-path detects old digest is missing
   - ✅ Skips fast-path, runs `azd up` instead
   - ✅ Deployment succeeds with new image
   - ✅ Container App tags updated with new commit

### Test Case 2: Promote After ACR Deletion

1. Assume ACR repo was deleted and recreated (from Test Case 1)
2. Trigger promotion to test:
   ```bash
   gh workflow run promote-image.yaml
   ```

3. Expected behavior:
   - ✅ `relnotes.sh` tries to read commit from ACR labels (fails)
   - ✅ Falls back to Container App tags
   - ✅ Finds `raptor.lastCommit` from previous deployment
   - ✅ Generates changelog correctly
   - ✅ Email shows commit log, not "first promotion"

## Architecture Decision

### Why Not Force ACR Digest Availability?

We could have prevented ACR repository deletion, but that's not realistic:
- Developers may need to clean up old images for cost/compliance
- ACR policies may auto-delete old manifests
- Repository may be accidentally deleted

### Why Container App Tags Are Reliable

- ✅ **Persistent**: Tags survive ACR deletions
- ✅ **Durable**: Stored in Azure Resource Manager, not ACR
- ✅ **Incremental**: `--is-incremental` flag preserves other tags
- ✅ **Queryable**: Accessible via `az resource show`
- ✅ **Atomic**: Updated only after successful deployment

## Limitations

1. **First deployment**: If Container App is completely deleted and recreated, tags are lost
   - Acceptable: This is truly a "first deployment" scenario
   - Workaround: Manual tag restoration if needed

2. **Tag quotas**: Azure has limits on number/size of tags per resource
   - Current usage: 2 tags per Container App (`raptor.lastDigest`, `raptor.lastCommit`)
   - Well within limits (50 tags per resource)

3. **Cross-environment**: Tags are per-Container App, not shared
   - Acceptable: Each environment has its own deployment history
   - Promotion reads from source environment's Container App

## Summary

The workflows are now resilient to ACR repository deletion:
- **Deployment**: Automatically falls back to full provision
- **Changelog**: Falls back to Container App tags for commit history
- **No manual intervention**: Everything is automatic
- **No data loss**: Commit history preserved in tags

This design follows the principle of **graceful degradation** - when the primary data source (ACR labels) is unavailable, the system falls back to secondary sources (Container App tags) and continues to function correctly.
