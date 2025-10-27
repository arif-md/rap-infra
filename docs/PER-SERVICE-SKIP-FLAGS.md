# Per-Service SKIP Flags Refactoring (Option-1)

## Overview
Refactored from a global `SKIP_ACR_PULL_ROLE_ASSIGNMENT` flag to per-service flags (`SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT` and `SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT`). This resolves the issue where backend's public image was incorrectly being required to have an ACR role assignment.

## Problem Statement
The global SKIP flag caused validation failures when:
- Frontend uses ACR image (needs SKIP=false)
- Backend uses public image (needs SKIP=true)
- Both services shared the same global flag → Inconsistency

**Error seen in GitHub Actions**:
```
Inconsistent configuration: Image is NOT from ACR (mcr.microsoft.com) but SKIP_ACR_PULL_ROLE_ASSIGNMENT=false. 
Set SKIP=true or use an ACR image.
```

## Solution: Per-Service SKIP Flags

### Architecture Changes

#### 1. Environment Variables
**Before** (Global):
- `SKIP_ACR_PULL_ROLE_ASSIGNMENT` - Single flag for all services

**After** (Per-Service):
- `SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT` - Independent control for frontend
- `SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT` - Independent control for backend

#### 2. Resolution Logic (`scripts/resolve-images.ps1` and `.sh`)
**Before**:
```powershell
# Check if ANY service uses ACR → set global flag
if ($anyAcrImage) {
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
}
```

**After**:
```powershell
# Frontend: SKIP if image doesn't use ACR
if ($frontendImg -match "$REGISTRY") {
    azd env set SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT false
} else {
    azd env set SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT true
}

# Backend: Independent check
if ($backendImg -match "$REGISTRY") {
    azd env set SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT false
} else {
    azd env set SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT true
}
```

#### 3. Validation Logic (`scripts/validate-acr-binding.ps1` and `.sh`)
**Before**:
```powershell
# Global validation - checks if ANY image uses ACR
if ($ANY_ACR_IMAGE -and $SKIP -eq "true") {
    # Error
}
```

**After**:
```powershell
# Per-service validation
# Validate frontend
if ($FRONTEND_IMG -match $ACR_DOMAIN -and $SKIP_FRONTEND -eq "true") {
    Write-Host "❌ ERROR: Frontend uses ACR but SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true"
    $HAS_ERROR = $true
}

# Validate backend independently
if ($BACKEND_IMG -match $ACR_DOMAIN -and $SKIP_BACKEND -eq "true") {
    Write-Host "❌ ERROR: Backend uses ACR but SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true"
    $HAS_ERROR = $true
}
```

#### 4. Bicep Parameters (`main.bicep`)
**Before**:
```bicep
param skipAcrPullRoleAssignment bool = true

module frontend 'app/frontend-angular.bicep' = {
  params: {
    skipAcrPullRoleAssignment: skipAcrPullRoleAssignment  // Global flag
  }
}
```

**After**:
```bicep
param skipFrontendAcrPullRoleAssignment bool = true
param skipBackendAcrPullRoleAssignment bool = true

module frontend 'app/frontend-angular.bicep' = {
  params: {
    skipAcrPullRoleAssignment: skipFrontendAcrPullRoleAssignment  // Per-service flag
  }
}

module backend 'app/backend-azure-functions.bicep' = {
  params: {
    skipAcrPullRoleAssignment: skipBackendAcrPullRoleAssignment  // Independent flag
  }
}
```

#### 5. Parameter File (`main.parameters.json`)
**Before**:
```json
{
  "skipAcrPullRoleAssignment": {
    "value": "${SKIP_ACR_PULL_ROLE_ASSIGNMENT=true}"
  }
}
```

**After**:
```json
{
  "skipFrontendAcrPullRoleAssignment": {
    "value": "${SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true}"
  },
  "skipBackendAcrPullRoleAssignment": {
    "value": "${SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true}"
  }
}
```

#### 6. Backend Template (`app/backend-azure-functions.bicep`)
**Before**:
```bicep
// Always creates role assignment (unconditional)
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // ...
}
```

**After**:
```bicep
param skipAcrPullRoleAssignment bool = false

// Conditional role assignment based on SKIP flag
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipAcrPullRoleAssignment) {
  // ...
}
```

**Note**: Backend uses `fetchLatestImage` module which prevents compile-time image checks (unlike frontend which uses direct image parameter). Therefore, backend relies entirely on the SKIP flag set by `resolve-images` script.

## Benefits

1. **Granular Control**: Each service independently controls whether to create ACR role assignment
2. **Clear Semantics**: Flag name explicitly indicates which service it applies to
3. **No Cross-Service Interference**: Backend's public image doesn't affect frontend's ACR requirements
4. **Better Validation**: Per-service validation catches configuration errors specific to each service
5. **Scalability**: Easy to add more services without conflicts (SKIP_NEWSERVICE_ACR_PULL_ROLE_ASSIGNMENT)

## Expected Behavior

### Scenario 1: Frontend (ACR) + Backend (Public) - Our Current Setup
```
Frontend Image: ngraptordev.azurecr.io/raptor/frontend-dev@sha256:...
Backend Image:  mcr.microsoft.com/azuredocs/containerapps-helloworld:latest

Resolution:
  ✅ SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false → ACR role assignment created
  ✅ SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true → No role assignment (not needed)

Validation:
  ✅ Frontend: ACR image with SKIP=false (correct)
  ✅ Backend: Public image with SKIP=true (correct)
```

### Scenario 2: Both Services Use ACR
```
Frontend Image: ngraptordev.azurecr.io/raptor/frontend-dev@sha256:...
Backend Image:  ngraptordev.azurecr.io/raptor/backend-dev@sha256:...

Resolution:
  ✅ SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false → ACR role assignment created
  ✅ SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=false → ACR role assignment created

Validation:
  ✅ Both services: ACR images with SKIP=false (correct)
```

### Scenario 3: Both Services Use Public Images
```
Frontend Image: mcr.microsoft.com/azuredocs/aci-helloworld:latest
Backend Image:  mcr.microsoft.com/azuredocs/containerapps-helloworld:latest

Resolution:
  ✅ SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true → No role assignment
  ✅ SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true → No role assignment

Validation:
  ✅ Both services: Public images with SKIP=true (correct)
```

## Files Changed

1. **scripts/resolve-images.ps1** - Per-service flag logic
2. **scripts/resolve-images.sh** - Per-service flag logic (bash)
3. **scripts/validate-acr-binding.ps1** - Per-service validation
4. **scripts/validate-acr-binding.sh** - Per-service validation (bash)
5. **main.bicep** - Per-service parameters, added backend module
6. **main.parameters.json** - Per-service parameter mappings
7. **app/backend-azure-functions.bicep** - Added skipAcrPullRoleAssignment parameter, conditional role assignment

## Breaking Changes

⚠️ **Environment Variable Rename**:
- Old: `SKIP_ACR_PULL_ROLE_ASSIGNMENT`
- New: `SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT` and `SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT`

**Migration**: Run `./scripts/resolve-images.ps1` (or `.sh`) to set the new per-service flags. The script will auto-detect image sources and set correct values.

## Testing Results

### Local `azd up` Test
```
🔧 Setting per-service ACR pull role assignment flags...
   Frontend uses ACR - SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false
   Backend uses public/external image - SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true

✅ Per-service image vs ACR binding validation passed.

Deployment: SUCCESS
```

### GitHub Actions Workflow Test
Expected to succeed with same validation logic (pending commit and push).

## Conclusion

The per-service SKIP flag refactoring resolves the architectural limitation of the global flag. Each service now has independent control over ACR role assignment, preventing configuration conflicts between services with different image sources.
