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

LOCATION=${AZURE_LOCATION}
if [ -z "$LOCATION" ]; then
  LOCATION=$(az group show -n "$AZURE_RESOURCE_GROUP" --query location -o tsv 2>/dev/null || true)
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
