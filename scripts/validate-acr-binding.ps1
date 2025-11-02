# Validation script: Check consistency between image sources and per-service SKIP_ACR_PULL_ROLE_ASSIGNMENT flags
# This script is called from both local azd up and GitHub Actions workflows
#
# USAGE:
#   .\validate-acr-binding.ps1 [service-name]
#
# PARAMETERS:
#   service-name (optional) - Specific service to validate (e.g., "frontend", "backend")
#                             If omitted, validates ALL services

param(
    [string]$TargetService = ""
)

$ErrorActionPreference = 'Stop'

if ($TargetService) {
    Write-Host "🔍 Validating image vs ACR binding for service: $TargetService" -ForegroundColor Cyan
} else {
    Write-Host "🔍 Validating per-service image vs ACR binding consistency..." -ForegroundColor Cyan
}

# Get environment variables
$AZURE_ACR_NAME = azd env get-value AZURE_ACR_NAME 2>$null
$FRONTEND_IMG = azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>$null
$BACKEND_IMG = azd env get-value SERVICE_BACKEND_IMAGE_NAME 2>$null
$SKIP_FRONTEND = azd env get-value SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT 2>$null
$SKIP_BACKEND = azd env get-value SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT 2>$null

if ([string]::IsNullOrEmpty($SKIP_FRONTEND)) { $SKIP_FRONTEND = "true" }
if ([string]::IsNullOrEmpty($SKIP_BACKEND)) { $SKIP_BACKEND = "true" }

if ([string]::IsNullOrEmpty($AZURE_ACR_NAME)) {
    Write-Host "⚠️  AZURE_ACR_NAME not set. Skipping validation." -ForegroundColor Yellow
    exit 0
}

$ACR_DOMAIN = "$AZURE_ACR_NAME.azurecr.io"
$HAS_ERROR = $false

# Validate frontend
if ([string]::IsNullOrEmpty($TargetService) -or $TargetService -eq "frontend") {
    Write-Host ""
    Write-Host "📦 Validating frontend..." -ForegroundColor Cyan
    if (-not [string]::IsNullOrEmpty($FRONTEND_IMG) -and $FRONTEND_IMG -match $ACR_DOMAIN) {
        Write-Host "   Image: $FRONTEND_IMG (ACR)" -ForegroundColor Gray
        if ($SKIP_FRONTEND -eq "true") {
            Write-Host "   ❌ ERROR: Frontend uses ACR but SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true" -ForegroundColor Red
            Write-Host "      This will cause deployment failure - Container App won't be able to pull image." -ForegroundColor Red
            $HAS_ERROR = $true
        } else {
            Write-Host "   ✅ SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false (correct)" -ForegroundColor Green
        }
    } else {
        Write-Host "   Image: $FRONTEND_IMG (public/external)" -ForegroundColor Gray
        if ($SKIP_FRONTEND -eq "false") {
            Write-Host "   ⚠️  WARNING: Frontend uses public image but SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false" -ForegroundColor Yellow
            Write-Host "      This won't cause errors, but creates unnecessary role assignment." -ForegroundColor Yellow
        } else {
            Write-Host "   ✅ SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true (correct)" -ForegroundColor Green
        }
    }
}

# Validate backend
if ([string]::IsNullOrEmpty($TargetService) -or $TargetService -eq "backend") {
    Write-Host ""
    Write-Host "📦 Validating backend..." -ForegroundColor Cyan
    if (-not [string]::IsNullOrEmpty($BACKEND_IMG) -and $BACKEND_IMG -match $ACR_DOMAIN) {
        Write-Host "   Image: $BACKEND_IMG (ACR)" -ForegroundColor Gray
        if ($SKIP_BACKEND -eq "true") {
            Write-Host "   ❌ ERROR: Backend uses ACR but SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true" -ForegroundColor Red
            Write-Host "      This will cause deployment failure - Container App won't be able to pull image." -ForegroundColor Red
            $HAS_ERROR = $true
        } else {
            Write-Host "   ✅ SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=false (correct)" -ForegroundColor Green
        }
    } else {
        Write-Host "   Image: $BACKEND_IMG (public/external)" -ForegroundColor Gray
        if ($SKIP_BACKEND -eq "false") {
            Write-Host "   ⚠️  WARNING: Backend uses public image but SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=false" -ForegroundColor Yellow
            Write-Host "      This won't cause errors, but creates unnecessary role assignment." -ForegroundColor Yellow
        } else {
            Write-Host "   ✅ SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true (correct)" -ForegroundColor Green
        }
    }
}

if ($HAS_ERROR) {
    Write-Host ""
    Write-Host "❌ Validation failed! Fix: Run './scripts/resolve-images.ps1' to recalculate SKIP flags." -ForegroundColor Red
    exit 1
}

Write-Host ""
if ($TargetService) {
    Write-Host "✅ Image vs ACR binding validation passed for service: $TargetService" -ForegroundColor Green
} else {
    Write-Host "✅ Per-service image vs ACR binding validation passed." -ForegroundColor Green
}
