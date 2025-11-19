# Dev Environment Setup - Completed

## Summary

Fixed and completed the `dev` environment configuration so `azd up` deploys to `rg-raptor-dev`.

## Issues Found and Fixed

### 1. Missing Resource Group Variable
**Problem**: `dev` environment was missing `AZURE_RESOURCE_GROUP`
```bash
# Before
AZURE_ENV_NAME="dev"
AZURE_ACR_NAME="ngraptordev"
# ❌ AZURE_RESOURCE_GROUP was missing
```

**Solution**: Added the missing variable
```bash
azd env set AZURE_RESOURCE_GROUP rg-raptor-dev
```

### 2. Stale Image Digest
**Problem**: Configured frontend image digest didn't exist in ACR
```bash
# Before
SERVICE_FRONTEND_IMAGE_NAME="...@sha256:68da46d4..."
# This digest didn't exist in ngraptordev ACR
```

**Solution**: Ran `resolve-images.ps1` script which auto-resolved to latest
```bash
# After
SERVICE_FRONTEND_IMAGE_NAME="...@sha256:bdb65eeb..."
# Latest image from ACR (exists and valid)
```

### 3. Wrong Default Environment
**Problem**: `test` was set as default, so `azd up` deployed to `rg-raptor-test`
```bash
# Before
NAME      DEFAULT   LOCAL     REMOTE
dev       false     true      false
test      true      true      false  ← DEFAULT
```

**Solution**: Selecting `dev` automatically made it default
```bash
azd env select dev

# After
NAME      DEFAULT   LOCAL     REMOTE
dev       true      true      false  ← NOW DEFAULT
test      false     true      false
```

### 4. Script Syntax Error
**Problem**: Duplicate `else` blocks in `resolve-images.ps1` and `resolve-images.sh`

**Solution**: Fixed both scripts by removing duplicate else clauses

### 5. ACR Pull Role Assignment Flag
**Problem**: `SKIP_ACR_PULL_ROLE_ASSIGNMENT=true` prevented the managed identity from getting AcrPull role

**Solution**: Set to `false` when using ACR images
```bash
azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
```

**Note**: The `resolve-images` script should set this automatically, but if pre-provision hooks don't run (or run before the variable is set), you may need to set it manually.

## Final Dev Environment Configuration

```bash
AZURE_ENV_NAME="dev"
AZURE_RESOURCE_GROUP="rg-raptor-dev"
AZURE_ACR_NAME="ngraptordev"
AZURE_LOCATION="eastus2"
AZURE_SUBSCRIPTION_ID="<subscription-id>"

# Images (auto-resolved)
SERVICE_FRONTEND_IMAGE_NAME="ngraptordev.azurecr.io/raptor/frontend-dev@sha256:bdb65eeb..."
SERVICE_BACKEND_IMAGE_NAME="mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
SKIP_ACR_PULL_ROLE_ASSIGNMENT="false"
```

## Verification

✅ **Resource Group**: Set to `rg-raptor-dev`  
✅ **Default Environment**: `dev` (not `test`)  
✅ **Frontend Image**: Valid digest from `ngraptordev` ACR  
✅ **Backend Image**: Public fallback (no custom image in ACR yet)  
✅ **Scripts**: Fixed syntax errors in both PowerShell and bash versions  
✅ **ACR Pull Role**: `SKIP_ACR_PULL_ROLE_ASSIGNMENT=false` for ACR images  
✅ **Deployment**: Successfully deployed to `rg-raptor-dev`  
✅ **Container App**: `dev-rap-fe` running at `https://dev-rap-fe.orangesand-0e346649.eastus2.azurecontainerapps.io/`  
✅ **Status**: HTTP 200 (working!)  

## Next Steps

Now you can deploy to dev:
```bash
azd up
# Will deploy to rg-raptor-dev with latest frontend image
```

To switch back to test:
```bash
azd env select test
azd up
# Will deploy to rg-raptor-test
```

To see all environments:
```bash
azd env list
```

## What the Resolution Script Did

1. **Detected stale digest**: `sha256:68da46d4...` not found in `ngraptordev` ACR
2. **Queried ACR**: Found 3 images in `raptor/frontend-dev`
3. **Selected latest**: `sha256:bdb65eeb...` (most recent by timestamp)
4. **Updated azd env**: Set `SERVICE_FRONTEND_IMAGE_NAME` to valid image
5. **Backend**: No images in `raptor/backend-dev`, used public fallback

This is exactly what will happen automatically on every `azd up` thanks to the pre-provision hook!
