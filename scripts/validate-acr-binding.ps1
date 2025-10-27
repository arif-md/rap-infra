# Validation script: Check consistency between image sources and SKIP_ACR_PULL_ROLE_ASSIGNMENT
# This script is called from both local azd up and GitHub Actions workflows

$ErrorActionPreference = 'Stop'

Write-Host "🔍 Validating image vs ACR binding consistency..." -ForegroundColor Cyan

# Get environment variables
$AZURE_ACR_NAME = azd env get-value AZURE_ACR_NAME 2>$null
$FRONTEND_IMG = azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>$null
$BACKEND_IMG = azd env get-value SERVICE_BACKEND_IMAGE_NAME 2>$null
$SKIP = azd env get-value SKIP_ACR_PULL_ROLE_ASSIGNMENT 2>$null

if ([string]::IsNullOrEmpty($SKIP)) {
    $SKIP = "true"
}

if ([string]::IsNullOrEmpty($AZURE_ACR_NAME)) {
    Write-Host "⚠️  AZURE_ACR_NAME not set. Skipping validation." -ForegroundColor Yellow
    exit 0
}

$ACR_DOMAIN = "$AZURE_ACR_NAME.azurecr.io"

# Check if any image uses ACR
$ANY_ACR_IMAGE = $false
if (-not [string]::IsNullOrEmpty($FRONTEND_IMG) -and $FRONTEND_IMG -match $ACR_DOMAIN) {
    $ANY_ACR_IMAGE = $true
    Write-Host "   Frontend uses ACR: $FRONTEND_IMG" -ForegroundColor Gray
}
if (-not [string]::IsNullOrEmpty($BACKEND_IMG) -and $BACKEND_IMG -match $ACR_DOMAIN) {
    $ANY_ACR_IMAGE = $true
    Write-Host "   Backend uses ACR: $BACKEND_IMG" -ForegroundColor Gray
}

# Validate consistency
if ($ANY_ACR_IMAGE -and $SKIP -eq "true") {
    Write-Host "❌ Inconsistent configuration detected!" -ForegroundColor Red
    Write-Host "   At least one service uses ACR ($ACR_DOMAIN)" -ForegroundColor Red
    Write-Host "   But SKIP_ACR_PULL_ROLE_ASSIGNMENT=true" -ForegroundColor Red
    Write-Host "   This will cause deployment failure - Container Apps won't be able to pull images." -ForegroundColor Red
    Write-Host ""
    Write-Host "   Fix: Run './scripts/resolve-images.ps1' to recalculate the SKIP flag." -ForegroundColor Yellow
    exit 1
}

if (-not $ANY_ACR_IMAGE -and $SKIP -eq "false") {
    Write-Host "⚠️  Suboptimal configuration detected (non-fatal)" -ForegroundColor Yellow
    Write-Host "   No services use ACR (all use public/external images)" -ForegroundColor Yellow
    Write-Host "   But SKIP_ACR_PULL_ROLE_ASSIGNMENT=false" -ForegroundColor Yellow
    Write-Host "   This won't cause errors, but Bicep will create an unnecessary role assignment." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Recommendation: Run './scripts/resolve-images.ps1' to recalculate the SKIP flag." -ForegroundColor Yellow
    # Don't exit with error - this is just a warning
}

Write-Host "✅ Image vs ACR binding validation passed." -ForegroundColor Green
Write-Host "   SKIP_ACR_PULL_ROLE_ASSIGNMENT=$SKIP" -ForegroundColor Gray
Write-Host "   ACR images: $(if ($ANY_ACR_IMAGE) { 'Yes' } else { 'No' })" -ForegroundColor Gray
