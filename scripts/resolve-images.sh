#!/usr/bin/env bash
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
  
  # Check if current image is already set with a digest
  CURRENT_IMAGE=$(azd env get-value "$IMAGE_VAR" 2>/dev/null || echo "")
  
  if [ -z "$CURRENT_IMAGE" ] || echo "$CURRENT_IMAGE" | grep -q "ERROR:"; then
    echo "   No current image configured for ${SERVICE_KEY}"
    # Will attempt to resolve from ACR below
  elif [[ "$CURRENT_IMAGE" == *"@sha256:"* ]]; then
    # Image already has a digest - trust it (workflow-configured or previously resolved)
    echo "   ✓ Image already configured with digest: $CURRENT_IMAGE"
    echo "     Keeping existing image (no validation needed)"
    
    # Set SKIP_ACR_PULL_ROLE_ASSIGNMENT based on whether image is from our ACR
    DOMAIN="${CURRENT_IMAGE%%/*}"
    if [ "$DOMAIN" = "$REGISTRY" ]; then
      echo "     Image is from configured ACR - enabling ACR pull role assignment"
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
    else
      echo "     Image is from external registry - skipping ACR pull role assignment"
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
    fi
    return 0
  elif [ -n "$CURRENT_IMAGE" ]; then
    # Has an image but not a digest (e.g., tag-based)
    echo "   Current image is not a digest reference: $CURRENT_IMAGE"
    echo "   Keeping tag-based image reference"
    
    # Set SKIP flag for tag-based images too
    DOMAIN="${CURRENT_IMAGE%%/*}"
    if [ "$DOMAIN" = "$REGISTRY" ]; then
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false
    else
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true
    fi
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
