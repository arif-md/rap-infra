# Script Consolidation: get-commit-from-image.sh

## Overview
Extracted duplicate `get_commit_from_labels()` function into a reusable script to maintain DRY principles and ensure consistency across all environments.

## Changes Made

### 1. Created Reusable Script
**File:** `scripts/get-commit-from-image.sh`

**Purpose:** Extract git commit SHA from OCI image labels in Azure Container Registry

**Usage:**
```bash
SHA=$(./scripts/get-commit-from-image.sh <registry-name> <repository> <digest>)
```

**Key Features:**
- OAuth2 token exchange (refresh → access token with repository scope)
- Multi-platform manifest handling (OCI image index / Docker manifest list)
- Robust error handling with silent failures (returns empty string on errors)
- Detailed warning messages to stderr for debugging
- Follows bash best practices (set -euo pipefail, proper quoting)

### 2. Updated Workflows

#### infra-azd.yaml (dev environment)
**Before:** 60-line inline function with debug logging
**After:** Single line script call
```bash
NEW_SHA=$(bash "${GITHUB_WORKSPACE}/scripts/get-commit-from-image.sh" "$REG_NAME" "$REPO_NAME" "$DIGEST" 2>&1 | tee /dev/stderr | tail -n1)
```

#### promote-image.yaml (test/train/prod environments)
**Before:** 3 identical 30-line inline functions (90 lines total)
**After:** 3 single-line script calls
```bash
NEW_SHA=$(bash "${GITHUB_WORKSPACE}/scripts/get-commit-from-image.sh" "$SRC_REG_NAME" "$SRC_REPO" "$NEW_DIGEST" 2>&1)
```

**Reduction:** 6,873 characters removed from promote-image.yaml

## Benefits

1. **Single Source of Truth**
   - Fix bugs once instead of 4 times
   - Consistent OAuth2 token exchange logic across all environments

2. **Maintainability**
   - Easier to update error handling or add features
   - Clear separation of concerns (script does one thing well)

3. **Testability**
   - Can test the script independently
   - Can add unit tests or manual verification

4. **Follows Project Patterns**
   - Consistent with existing `relnotes.sh` script
   - Follows project's script organization in `scripts/` folder

5. **Debugging**
   - Script writes warnings to stderr for troubleshooting
   - Workflow captures both stdout (result) and stderr (diagnostics)

## Testing Checklist

- [ ] Dev environment: Verify `raptor.lastCommit` tag still set correctly
- [ ] Test environment: Trigger promotion, verify tag persistence
- [ ] Train environment: Trigger promotion, verify tag persistence
- [ ] Prod environment: Trigger promotion, verify tag persistence
- [ ] Error handling: Test with invalid digest/repository
- [ ] ACR deletion scenario: Verify graceful failure (empty string returned)

## Technical Details

### OAuth2 Token Exchange
The script implements proper ACR data plane authentication:

1. **Get refresh token:** `az acr login --expose-token`
2. **Exchange for access token:** POST to `/oauth2/token` with:
   - `grant_type=refresh_token`
   - `service=${registry}.azurecr.io`
   - `scope=repository:${repo}:pull`
   - `refresh_token=${refresh}`
3. **Use access token:** For manifest/blob API calls with `Authorization: Bearer ${access}`

### Multi-Platform Support
Handles both single-arch and multi-arch images:
- Detects OCI image index / Docker manifest list
- Automatically follows reference to first platform-specific manifest
- Extracts config from platform manifest

### Label Extraction
Reads OCI standard label from image config blob:
- Label: `org.opencontainers.image.revision`
- Source: `.config.Labels["org.opencontainers.image.revision"]` in config JSON
- Fallback: Returns empty string if label not found

## Related Documentation
- `docs/ACR-DELETION-RESILIENCE.md` - ACR repository deletion handling
- `scripts/relnotes.sh` - Related changelog generation script
- `.github/copilot-instructions.md` - Project patterns and conventions
