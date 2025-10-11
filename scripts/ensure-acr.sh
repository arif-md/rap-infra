#!/usr/bin/env sh
set -e

if [ -z "$AZURE_RESOURCE_GROUP" ]; then
  if [ -n "$AZURE_ENV_NAME" ]; then
    AZURE_RESOURCE_GROUP="rg-raptor-$AZURE_ENV_NAME"
    azd env set AZURE_RESOURCE_GROUP "$AZURE_RESOURCE_GROUP" >/dev/null
  else
    echo "AZURE_RESOURCE_GROUP not set and AZURE_ENV_NAME unavailable. Set AZURE_RESOURCE_GROUP via 'azd env set AZURE_RESOURCE_GROUP <name>'." >&2
    exit 1
  fi
fi

if [ -z "$AZURE_ACR_NAME" ]; then
  if [ -z "$AZURE_ENV_NAME" ]; then
    echo "AZURE_ACR_NAME not set and AZURE_ENV_NAME unavailable. Set AZURE_ACR_NAME via 'azd env set AZURE_ACR_NAME <acrName>'." >&2
    exit 1
  fi
  # derive a stable default from env name
  AZURE_ACR_NAME=$(echo "$AZURE_ENV_NAME-rap-acr" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-50)
  azd env set AZURE_ACR_NAME "$AZURE_ACR_NAME" >/dev/null
fi

LOCATION=$(az group show -n "$AZURE_RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
if [ -z "$LOCATION" ]; then
  echo "Could not resolve location for resource group '$AZURE_RESOURCE_GROUP'." >&2
  exit 1
fi

# Ensure resource group exists (do not create it)
if ! az group show -n "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Resource group '$AZURE_RESOURCE_GROUP' not found. Set AZURE_RESOURCE_GROUP to an existing RG (azd env set AZURE_RESOURCE_GROUP <name>) or pre-create it." >&2
  exit 1
fi

if ! az acr show -n "$AZURE_ACR_NAME" -g "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Creating ACR '$AZURE_ACR_NAME' in RG '$AZURE_RESOURCE_GROUP'..."
  az acr create -n "$AZURE_ACR_NAME" -g "$AZURE_RESOURCE_GROUP" -l "$LOCATION" --sku Standard --admin-enabled false --only-show-errors >/dev/null
else
  echo "ACR '$AZURE_ACR_NAME' already exists in RG '$AZURE_RESOURCE_GROUP'."
fi

# If SERVICE_FRONTEND_IMAGE_NAME isn't set, try to resolve the latest image from ACR for this env
CURRENT_IMAGE="$(azd env get-value SERVICE_FRONTEND_IMAGE_NAME 2>/dev/null || true)"
ACR_DOMAIN="${AZURE_ACR_NAME}.azurecr.io"
CURRENT_DOMAIN="${CURRENT_IMAGE%%/*}"
if [ -z "$CURRENT_IMAGE" ]; then
  REGISTRY="${AZURE_ACR_NAME}.azurecr.io"
  REPO="raptor/frontend-${AZURE_ENV_NAME}"
  echo "Attempting to resolve latest image from ACR: $REGISTRY/$REPO"
  DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
  if [ -n "$DIGEST" ]; then
    IMAGE="$REGISTRY/$REPO@$DIGEST"
    echo "Resolved ACR image: $IMAGE"
    azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMAGE" >/dev/null
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false >/dev/null
  else
    FALLBACK="mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
    echo "No image found in ACR repo '$REPO'. Using fallback public image: $FALLBACK"
    azd env set SERVICE_FRONTEND_IMAGE_NAME "$FALLBACK" >/dev/null
    azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT true >/dev/null
  fi
else
  if [ "$CURRENT_DOMAIN" != "$ACR_DOMAIN" ]; then
    # If a non-ACR (likely public) image was set earlier, try to upgrade to the latest ACR image if available
    REGISTRY="$ACR_DOMAIN"
    REPO="raptor/frontend-${AZURE_ENV_NAME}"
    echo "Current image domain '$CURRENT_DOMAIN' differs from ACR '$ACR_DOMAIN'. Checking ACR for newer image: $REGISTRY/$REPO"
    DIGEST=$(az acr repository show-manifests -n "$AZURE_ACR_NAME" --repository "$REPO" --orderby time_desc --top 1 --query "[0].digest" -o tsv 2>/dev/null || true)
    if [ -n "$DIGEST" ]; then
      IMAGE="$REGISTRY/$REPO@$DIGEST"
      echo "Switching to ACR image: $IMAGE"
      azd env set SERVICE_FRONTEND_IMAGE_NAME "$IMAGE" >/dev/null
      azd env set SKIP_ACR_PULL_ROLE_ASSIGNMENT false >/dev/null
    else
      echo "No ACR image found; keeping existing image: $CURRENT_IMAGE"
    fi
  else
    echo "SERVICE_FRONTEND_IMAGE_NAME already set to ACR image; leaving as-is."
  fi
fi
