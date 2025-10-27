# Pre-provision hook: Resolve container images from ACR or fallback to public images
# This ensures azd up works even if the configured image digest is stale/missing
#
# BEHAVIOR:
#   - If image is already set with a valid digest, keeps it (workflow-configured images)
#   - If image is missing or invalid, queries ACR for latest
#   - Falls back to public image if ACR repository is empty
#
# This script is used by BOTH:
#   - Local azd up (resolves latest image automatically)
#   - GitHub Actions workflows (keeps workflow-set images, resolves only if missing)

$ErrorActionPreference = 'Stop'

Write-Host "🔍 Resolving container images from ACR..." -ForegroundColor Cyan

# Get environment variables from azd
$AZURE_ENV_NAME = azd env get-value AZURE_ENV_NAME 2>$null
$AZURE_ACR_NAME = azd env get-value AZURE_ACR_NAME 2>$null

if ([string]::IsNullOrEmpty($AZURE_ENV_NAME) -or [string]::IsNullOrEmpty($AZURE_ACR_NAME)) {
    Write-Host "⚠️  AZURE_ENV_NAME or AZURE_ACR_NAME not set. Skipping image resolution." -ForegroundColor Yellow
    exit 0
}

$REGISTRY = "$AZURE_ACR_NAME.azurecr.io"
$FALLBACK_IMAGE = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"

# Function to resolve image for a service
function Resolve-ServiceImage {
    param(
        [string]$ServiceKey
    )
    
    $SERVICE_KEY_UPPER = $ServiceKey.ToUpper()
    $IMAGE_VAR = "SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
    $REPO = "raptor/$ServiceKey-$AZURE_ENV_NAME"
    
    Write-Host ""
    Write-Host "📦 Resolving $ServiceKey image..." -ForegroundColor Cyan
    
    # Check if current image is already set with a digest
    $CURRENT_IMAGE = azd env get-value $IMAGE_VAR 2>$null
    
    if ([string]::IsNullOrEmpty($CURRENT_IMAGE) -or $CURRENT_IMAGE -match 'ERROR:') {
        Write-Host "   No current image configured for $ServiceKey" -ForegroundColor Gray
        # Will attempt to resolve from ACR below
    }
    elseif ($CURRENT_IMAGE -match '@sha256:') {
        # Image already has a digest - trust it (workflow-configured or previously resolved)
        Write-Host "   ✓ Image already configured with digest: $CURRENT_IMAGE" -ForegroundColor Green
        Write-Host "     Keeping existing image (no validation needed)" -ForegroundColor Gray
        return
    } else {
        # Has an image but not a digest (e.g., tag-based)
        Write-Host "   Current image is not a digest reference: $CURRENT_IMAGE" -ForegroundColor Gray
        Write-Host "   Keeping tag-based image reference" -ForegroundColor Gray
        return
    }
    
    # Try to get latest image from ACR
    Write-Host "   Querying ACR for latest image in $REGISTRY/$REPO..." -ForegroundColor Gray
    $DIGEST = az acr repository show-manifests -n $AZURE_ACR_NAME --repository $REPO --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>$null
    
    if (-not [string]::IsNullOrEmpty($DIGEST)) {
        $NEW_IMAGE = "$REGISTRY/$REPO@$DIGEST"
        Write-Host "   ✅ Found latest image in ACR: $NEW_IMAGE" -ForegroundColor Green
        azd env set $IMAGE_VAR $NEW_IMAGE
    } else {
        Write-Host "   ⚠️  No images found in ACR repository '$REPO'" -ForegroundColor Yellow
        Write-Host "   ℹ️  Using fallback public image: $FALLBACK_IMAGE" -ForegroundColor Cyan
        azd env set $IMAGE_VAR $FALLBACK_IMAGE
    }
}

# Resolve images for all services
Resolve-ServiceImage -ServiceKey "frontend"
Resolve-ServiceImage -ServiceKey "backend"

# Determine per-service SKIP_ACR_PULL_ROLE_ASSIGNMENT flags
# Each service has independent control over whether to create ACR role assignment
Write-Host ""
Write-Host "🔧 Setting per-service ACR pull role assignment flags..." -ForegroundColor Cyan

$frontendImg = azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>$null
$backendImg = azd env get-value SERVICE_BACKEND_IMAGE_NAME 2>$null

# Frontend: SKIP if image doesn't use ACR
if (-not [string]::IsNullOrEmpty($frontendImg) -and $frontendImg -match "$REGISTRY") {
    Write-Host "   Frontend uses ACR - SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false" -ForegroundColor Green
    azd env set SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT false
} else {
    Write-Host "   Frontend uses public/external image - SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true" -ForegroundColor Yellow
    azd env set SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT true
}

# Backend: SKIP if image doesn't use ACR
if (-not [string]::IsNullOrEmpty($backendImg) -and $backendImg -match "$REGISTRY") {
    Write-Host "   Backend uses ACR - SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=false" -ForegroundColor Green
    azd env set SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT false
} else {
    Write-Host "   Backend uses public/external image - SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true" -ForegroundColor Yellow
    azd env set SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT true
}

Write-Host ""
Write-Host "✅ Image resolution complete" -ForegroundColor Green
