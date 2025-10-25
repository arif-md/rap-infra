#!/usr/bin/env bash
# Pre-provision hook: Resolve container images from ACR or fallback to public images
# This ensures azd up works even if the configured image digest is stale/missing

set -euo pipefail

echo "🔍 Resolving container images from ACR..."

# Get environment variables from azd
AZURE_ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "")
AZURE_ACR_NAME=$(azd env get-value AZURE_ACR_NAME 2>/dev/null || echo "")

if [ -z "$AZURE_ENV_NAME" ] || [ -z "$AZURE_ACR_NAME" ]; then
  echo "⚠️  AZURE_ENV_NAME or AZURE_ACR_NAME not set. Skipping image resolution."
  exit 0
fi

REGISTRY="${AZURE_ACR_NAME}.azurecr.io"
FALLBACK_IMAGE="mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"

# Function to resolve image for a service
resolve_service_image() {
  local SERVICE_KEY=$1
  local SERVICE_KEY_UPPER=$(echo "$SERVICE_KEY" | tr '[:lower:]' '[:upper:]')
  local IMAGE_VAR="SERVICE_${SERVICE_KEY_UPPER}_IMAGE_NAME"
  local REPO="raptor/${SERVICE_KEY}-${AZURE_ENV_NAME}"
  
  echo ""
  echo "📦 Resolving ${SERVICE_KEY} image..."
  
  # Check if current image is valid (exists in ACR)
  CURRENT_IMAGE=$(azd env get-value "$IMAGE_VAR" 2>/dev/null || echo "")
  
  if [ -z "$CURRENT_IMAGE" ] || echo "$CURRENT_IMAGE" | grep -q "ERROR:"; then
    echo "   No current image configured for ${SERVICE_KEY}"
    # Will attempt to resolve from ACR below
  elif [[ "$CURRENT_IMAGE" == *"@sha256:"* ]]; then
      CURRENT_DIGEST="${CURRENT_IMAGE#*@}"
      ACR_FROM_IMAGE="${CURRENT_IMAGE%%/*}"
      
      # Only validate if image is from the expected ACR
      if [[ "$ACR_FROM_IMAGE" == "$REGISTRY" ]]; then
        echo "   Current image: $CURRENT_IMAGE"
        echo "   Validating digest in ACR..."
        
        # Try to get manifest for this specific digest
        if az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" --query "[?digest=='$CURRENT_DIGEST']" -o tsv 2>/dev/null | grep -q .; then
          echo "   ✅ Current image digest is valid in ACR"
          return 0
        else
          echo "   ⚠️  Current image digest not found in ACR, will resolve latest..."
        fi
      else
        echo "   Current image is from different registry or public image: $CURRENT_IMAGE"
        return 0
      fi
  elif [ -n "$CURRENT_IMAGE" ]; then
    echo "   Current image is not a digest reference: $CURRENT_IMAGE"
    return 0
  fi
  
  # Try to get latest image from ACR
  echo "   Querying ACR for latest image in $REGISTRY/$REPO..."
  DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
  
  if [ -n "$DIGEST" ]; then
    NEW_IMAGE="$REGISTRY/$REPO@$DIGEST"
    echo "   ✅ Found latest image in ACR: $NEW_IMAGE"
    azd env set "$IMAGE_VAR" "$NEW_IMAGE"
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
  else
    echo "   ⚠️  No images found in ACR repository '$REPO'"
    echo "   ℹ️  Using fallback public image: $FALLBACK_IMAGE"
    azd env set "$IMAGE_VAR" "$FALLBACK_IMAGE"
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
  fi
}

# Resolve images for all services
resolve_service_image "frontend"
resolve_service_image "backend"

echo ""
echo "✅ Image resolution complete"
