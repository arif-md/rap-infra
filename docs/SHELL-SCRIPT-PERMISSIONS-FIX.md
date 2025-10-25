# Shell Script Permissions Fix

**Date**: October 25, 2025  
**Issue**: GitHub Actions workflow failing with "Permission denied" when executing shell scripts  
**Commit**: `5355fa9`

## Problem

The promotion workflow failed with this error:

```
ERROR: error executing step command 'provision': failed running pre hooks: 'preprovision' hook 
failed with exit code: 126, Path: '/tmp/azd-preprovision-1702938397.sh'. : exit code: 126, 
stdout: , stderr: /tmp/azd-preprovision-1702938397.sh: 5: ./scripts/resolve-images.sh: 
Permission denied
```

## Root Cause

**Git on Windows doesn't track Unix execute permissions by default.**

When shell scripts (`.sh` files) are created or modified on Windows:
1. Windows filesystem doesn't use Unix execute bits
2. Git on Windows defaults to mode `100644` (non-executable) for new files
3. When checked out on Linux (GitHub Actions runners), scripts can't be executed
4. Result: "Permission denied" error

## Solution

Use `git update-index --chmod=+x` to set executable bit in Git's index:

```bash
# For each shell script
git update-index --chmod=+x scripts/resolve-images.sh
git update-index --chmod=+x scripts/ensure-acr.sh
# ... etc
```

This records the executable permission in Git, so it's preserved when cloned on Linux.

## Files Fixed

All shell scripts in `scripts/` directory:

```
✅ scripts/deploy-service-image.sh      (100644 → 100755)
✅ scripts/email-common.sh              (100644 → 100755)
✅ scripts/ensure-acr-binding.sh        (100644 → 100755)
✅ scripts/ensure-acr.sh                (100644 → 100755)
✅ scripts/get-commit-from-image.sh     (100644 → 100755)
✅ scripts/promote-service-image.sh     (100644 → 100755)
✅ scripts/relnotes.sh                  (100644 → 100755)
✅ scripts/resolve-images.sh            (100644 → 100755)
✅ scripts/update-containerapp-image.sh (100644 → 100755)
```

## Verification

Check file modes in Git:
```bash
git ls-files -s scripts/*.sh
```

Expected output (all should show `100755`):
```
100755 <hash> 0       scripts/deploy-service-image.sh
100755 <hash> 0       scripts/email-common.sh
...
```

## Why This Happens on Windows

### Git Configuration
Windows Git has a config option `core.fileMode`:
- Default on Windows: `false` (don't track execute bit changes)
- Default on Linux/Mac: `true` (track execute bit changes)

### Workaround for Future Scripts

**Option 1**: Use `git update-index --chmod=+x` (recommended)
```bash
# After creating a new .sh file
git add scripts/new-script.sh
git update-index --chmod=+x scripts/new-script.sh
git commit -m "Add new script with execute permission"
```

**Option 2**: Enable `core.fileMode` globally (not recommended on Windows)
```bash
git config core.fileMode true
# This may cause issues with other repos on Windows
```

**Option 3**: Set executable on Linux/Mac before committing
- Commit from WSL, Linux VM, or Mac
- Or use GitHub Codespaces

## Testing

After pushing this fix, the promotion workflow should succeed:

1. Push to remote:
   ```bash
   git push origin main
   ```

2. Trigger promotion workflow:
   ```bash
   gh workflow run promote-frontend.yaml
   ```

3. Verify "Deploy to test" step no longer fails with "Permission denied"

## Related Issues

- **Initial Error**: Promotion to test environment failing
- **Screenshot Evidence**: GitHub Actions run showing "Permission denied" at line 14
- **Affected Workflows**: 
  - `promote-frontend.yaml`
  - `promote-backend.yaml`
  - `deploy-frontend.yaml` (if using POSIX runners)
  - `deploy-backend.yaml` (if using POSIX runners)

## Prevention

When creating new shell scripts on Windows:

1. Create the script file
2. Add to Git: `git add scripts/new-script.sh`
3. **Before committing**, set executable: `git update-index --chmod=+x scripts/new-script.sh`
4. Commit: `git commit -m "Add new-script.sh"`
5. Verify: `git ls-files -s scripts/new-script.sh` should show `100755`

## References

- Git documentation: [git-update-index](https://git-scm.com/docs/git-update-index)
- Unix file permissions: `100755` = `-rwxr-xr-x` (owner can read/write/execute, others can read/execute)
- GitHub Actions runners: Use Ubuntu Linux by default (require execute permissions)
