# Pre-provision hook: Resolve container images from ACR or fallback to public images
# This ensures azd up works even if the configured image digest is stale/missing

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
    
    # Check if current image is valid (exists in ACR)
    $CURRENT_IMAGE = azd env get-value $IMAGE_VAR 2>$null
    
    if ([string]::IsNullOrEmpty($CURRENT_IMAGE) -or $CURRENT_IMAGE -match 'ERROR:') {
        Write-Host "   No current image configured for $ServiceKey" -ForegroundColor Gray
        # Will attempt to resolve from ACR below
    }
    elseif ($CURRENT_IMAGE -match '@sha256:') {
            $CURRENT_DIGEST = ($CURRENT_IMAGE -split '@')[1]
            $ACR_FROM_IMAGE = ($CURRENT_IMAGE -split '/')[0]
            
            # Only validate if image is from the expected ACR
            if ($ACR_FROM_IMAGE -eq $REGISTRY) {
                Write-Host "   Current image: $CURRENT_IMAGE" -ForegroundColor Gray
                Write-Host "   Validating digest in ACR..." -ForegroundColor Gray
                
                # Try to get manifest for this specific digest
                $manifestCheck = az acr repository show-manifests -n $AZURE_ACR_NAME --repository $REPO --query "[?digest=='$CURRENT_DIGEST']" -o tsv 2>$null
                if (-not [string]::IsNullOrEmpty($manifestCheck)) {
                    Write-Host "   ✅ Current image digest is valid in ACR" -ForegroundColor Green
                    return
                } else {
                    Write-Host "   ⚠️  Current image digest not found in ACR, will resolve latest..." -ForegroundColor Yellow
                }
            } else {
                Write-Host "   Current image is from different registry or public image: $CURRENT_IMAGE" -ForegroundColor Gray
                return
            }
    } else {
        Write-Host "   Current image is not a digest reference: $CURRENT_IMAGE" -ForegroundColor Gray
        return
    }
    
    # Try to get latest image from ACR
    Write-Host "   Querying ACR for latest image in $REGISTRY/$REPO..." -ForegroundColor Gray
    $DIGEST = az acr repository show-manifests -n $AZURE_ACR_NAME --repository $REPO --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>$null
    
    if (-not [string]::IsNullOrEmpty($DIGEST)) {
        $NEW_IMAGE = "$REGISTRY/$REPO@$DIGEST"
        Write-Host "   ✅ Found latest image in ACR: $NEW_IMAGE" -ForegroundColor Green
        azd env set $IMAGE_VAR $NEW_IMAGE
        azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
    } else {
        Write-Host "   ⚠️  No images found in ACR repository '$REPO'" -ForegroundColor Yellow
        Write-Host "   ℹ️  Using fallback public image: $FALLBACK_IMAGE" -ForegroundColor Cyan
        azd env set $IMAGE_VAR $FALLBACK_IMAGE
        azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
    }
}

# Resolve images for all services
Resolve-ServiceImage -ServiceKey "frontend"
Resolve-ServiceImage -ServiceKey "backend"

Write-Host ""
Write-Host "✅ Image resolution complete" -ForegroundColor Green
