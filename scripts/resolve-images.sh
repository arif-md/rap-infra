#!/usr/bin/env bash
# Pre-provision hook: Resolve container images from ACR or fallback to public images
# This ensures azd up works even if the configured image digest is stale/missing
#
# USAGE:
#   ./resolve-images.sh [service-name]
#
# PARAMETERS:
#   service-name (optional) - Specific service to resolve (e.g., "frontend", "backend", "processes")
#                             If omitted, resolves ALL services
#
# BEHAVIOR:
#   - If image is already set with a valid digest, keeps it (workflow-configured images)
#   - If image is missing or invalid, queries ACR for latest
#   - Falls back to public image if ACR repository is empty
#
# Sets per-service SKIP flags: SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT, SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT, SKIP_PROCESSES_ACR_PULL_ROLE_ASSIGNMENT
#
# This script is used by:
#   - Local azd up: ./resolve-images.sh (resolves all services)
#   - provision-infrastructure workflow: ./resolve-images.sh (resolves all services)
#   - deploy-frontend workflow: ./resolve-images.sh frontend (resolves only frontend)
#   - deploy-backend workflow: ./resolve-images.sh backend (resolves only backend)
#   - deploy-processes workflow: ./resolve-images.sh processes (resolves only processes)

set -euo pipefail

# Parse optional service parameter
TARGET_SERVICE="${1:-}"

if [ -n "$TARGET_SERVICE" ]; then
  echo "🔍 Resolving container image for service: $TARGET_SERVICE"
else
  echo "🔍 Resolving container images for all services from ACR..."
fi

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
    # Image has a digest — validate it is a runnable linux/amd64 manifest, not an attestation.
    # Attestation manifests (SLSA provenance) have os=unknown and cannot run on Container Apps.
    DIGEST_PART="${CURRENT_IMAGE#*@}"
    ACR_NAME_PART=$(echo "${CURRENT_IMAGE%%/*}" | sed 's/\.azurecr\.io$//')
    REPO_PART="${CURRENT_IMAGE#*/}"; REPO_PART="${REPO_PART%@*}"
    IMG_OS=$(az acr manifest show-metadata -r "$ACR_NAME_PART" -n "${REPO_PART}@${DIGEST_PART}" \
      --query "os" -o tsv 2>/dev/null || echo "")
    if [[ "$IMG_OS" == "unknown" || "$IMG_OS" == "" ]]; then
      # Digest points to an attestation or index — resolve the correct linux/amd64 manifest below
      echo "   ⚠️  Existing digest appears to be an attestation/index (os='${IMG_OS:-unknown}')"
      echo "      Will re-resolve linux/amd64 manifest from ACR"
    else
      echo "   ✓ Image already configured with digest (os=$IMG_OS): $CURRENT_IMAGE"
      echo "     Keeping existing image"
      return 0
    fi
  elif [ -n "$CURRENT_IMAGE" ]; then
    # Has an image but not a digest (e.g., tag-based)
    echo "   Current image is not a digest reference: $CURRENT_IMAGE"
    echo "   Keeping tag-based image reference"
    return 0
  fi
  
  # Try to get latest linux/amd64 image from ACR.
  # Query by architecture+os to avoid selecting attestation manifests (os: unknown),
  # which appear last in time order after az acr import and cannot run on Container Apps.
  echo "   Querying ACR for latest linux/amd64 image in $REGISTRY/$REPO..."
  DIGEST=$(az acr manifest list-metadata -r "$AZURE_ACR_NAME" -n "$REPO" \
    --orderby time_desc \
    --query "[?architecture=='amd64' && os=='linux'] | [0].digest" -o tsv 2>/dev/null || true)
  # Fallback: if manifest list-metadata is unavailable or returns nothing, use time-ordered query
  if [ -z "$DIGEST" ]; then
    echo "   Falling back to time-ordered manifest query..."
    DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" \
      --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
  fi
  
  if [ -n "$DIGEST" ]; then
    NEW_IMAGE="$REGISTRY/$REPO@$DIGEST"
    echo "   ✅ Found latest image in ACR: $NEW_IMAGE"
    azd env set "$IMAGE_VAR" "$NEW_IMAGE"
  else
    echo "   ⚠️  No images found in ACR repository '$REPO'"
    echo "   ℹ️  Using fallback public image: $FALLBACK_IMAGE"
    azd env set "$IMAGE_VAR" "$FALLBACK_IMAGE"
  fi
}

# Resolve images for all services or specific service
if [ -z "$TARGET_SERVICE" ] || [ "$TARGET_SERVICE" = "frontend" ]; then
  resolve_service_image "frontend"
fi

if [ -z "$TARGET_SERVICE" ] || [ "$TARGET_SERVICE" = "backend" ]; then
  resolve_service_image "backend"
fi

if [ -z "$TARGET_SERVICE" ] || [ "$TARGET_SERVICE" = "processes" ]; then
  resolve_service_image "processes"
fi

# Determine per-service SKIP_ACR_PULL_ROLE_ASSIGNMENT flags
# Each service has independent control over whether to create ACR role assignment
echo ""
echo "🔧 Setting per-service ACR pull role assignment flags..."

FRONTEND_IMG=$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>/dev/null || echo "")
BACKEND_IMG=$(azd env get-value SERVICE_BACKEND_IMAGE_NAME 2>/dev/null || echo "")
PROCESSES_IMG=$(azd env get-value SERVICE_PROCESSES_IMAGE_NAME 2>/dev/null || echo "")

# Frontend: SKIP if image doesn't use ACR
if [ -z "$TARGET_SERVICE" ] || [ "$TARGET_SERVICE" = "frontend" ]; then
  if [[ "$FRONTEND_IMG" == *"$REGISTRY"* ]]; then
    echo "   Frontend uses ACR - SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=false"
    azd env set SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT false
  else
    echo "   Frontend uses public/external image - SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT=true"
    azd env set SKIP_FRONTEND_ACR_PULL_ROLE_ASSIGNMENT true
  fi
fi

# Backend: SKIP if image doesn't use ACR
if [ -z "$TARGET_SERVICE" ] || [ "$TARGET_SERVICE" = "backend" ]; then
  if [[ "$BACKEND_IMG" == *"$REGISTRY"* ]]; then
    echo "   Backend uses ACR - SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=false"
    azd env set SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT false
  else
    echo "   Backend uses public/external image - SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT=true"
    azd env set SKIP_BACKEND_ACR_PULL_ROLE_ASSIGNMENT true
  fi
fi

# Processes: SKIP if image doesn't use ACR
if [ -z "$TARGET_SERVICE" ] || [ "$TARGET_SERVICE" = "processes" ]; then
  if [[ "$PROCESSES_IMG" == *"$REGISTRY"* ]]; then
    echo "   Processes uses ACR - SKIP_PROCESSES_ACR_PULL_ROLE_ASSIGNMENT=false"
    azd env set SKIP_PROCESSES_ACR_PULL_ROLE_ASSIGNMENT false
  else
    echo "   Processes uses public/external image - SKIP_PROCESSES_ACR_PULL_ROLE_ASSIGNMENT=true"
    azd env set SKIP_PROCESSES_ACR_PULL_ROLE_ASSIGNMENT true
  fi
fi

echo ""
if [ -n "$TARGET_SERVICE" ]; then
  echo "✅ Image resolution complete for service: $TARGET_SERVICE"
else
  echo "✅ Image resolution complete for all services"
fi

