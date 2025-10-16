#!/bin/bash
# ensure-acr-binding.sh
# Ensures Container App has ACR registry binding configured with proper RBAC permissions.
# This script is idempotent - if ACR is already configured, it skips the setup to save time.
#
# Usage: ./ensure-acr-binding.sh <app-name> <resource-group> <acr-name> <acr-domain>
#
# Arguments:
#   app-name: Name of the Container App (e.g., "dev-rap-fe")
#   resource-group: Azure resource group name
#   acr-name: Azure Container Registry name (e.g., "ngraptortest")
#   acr-domain: Full ACR domain (e.g., "ngraptortest.azurecr.io")
#
# Returns:
#   Exit 0: ACR binding successful or already configured
#   Exit 1: Error occurred (e.g., app doesn't exist, ACR not found)
#
# Example:
#   ./ensure-acr-binding.sh "dev-rap-fe" "rg-raptor-dev" "ngraptortest" "ngraptortest.azurecr.io"

set -euo pipefail

# Validate arguments
if [ $# -ne 4 ]; then
  echo "Error: Invalid number of arguments" >&2
  echo "Usage: $0 <app-name> <resource-group> <acr-name> <acr-domain>" >&2
  exit 1
fi

APP_NAME="$1"
RG="$2"
ACR_NAME="$3"
ACR_DOMAIN="$4"

# Check if Container App exists
if ! az containerapp show -n "$APP_NAME" -g "$RG" >/dev/null 2>&1; then
  echo "Error: Container App '$APP_NAME' not found in resource group '$RG'" >&2
  exit 1
fi

# Get Container App configuration
APP_JSON=$(az containerapp show -n "$APP_NAME" -g "$RG" -o json)

# Check if ACR is already configured
EXISTING_REGISTRY=$(echo "$APP_JSON" | jq -r ".properties.configuration.registries[]? | select(.server==\"$ACR_DOMAIN\") | .server" 2>/dev/null || true)

if [ -n "$EXISTING_REGISTRY" ]; then
  echo "✓ ACR already configured for Container App: $EXISTING_REGISTRY"
  exit 0
fi

echo "ACR not configured for Container App, setting up registry binding..."

# Resolve ACR resource ID
ACR_ID=$(az acr show -n "$ACR_NAME" -g "$RG" --query id -o tsv 2>/dev/null || true)
if [ -z "$ACR_ID" ]; then
  echo "Error: Could not resolve ACR resource ID for '$ACR_NAME'" >&2
  exit 1
fi

# Get identity information
ID_TYPE=$(echo "$APP_JSON" | jq -r '.identity.type // "None"')
ROLE_ID="$(az role definition list --name AcrPull --query "[0].name" -o tsv)"

# Bind using system-assigned identity if available
if [ "$ID_TYPE" = "SystemAssigned" ] || [ "$ID_TYPE" = "SystemAssigned,UserAssigned" ]; then
  PRINCIPAL_ID=$(echo "$APP_JSON" | jq -r '.identity.principalId // empty')
  if [ -n "$PRINCIPAL_ID" ]; then
    echo "Ensuring AcrPull role for system-assigned identity: $PRINCIPAL_ID"
    az role assignment create \
      --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$ROLE_ID" \
      --scope "$ACR_ID" >/dev/null 2>&1 || true
    
    echo "Binding registry to Container App using system-assigned identity"
    az containerapp registry set \
      -n "$APP_NAME" \
      -g "$RG" \
      --server "$ACR_DOMAIN" \
      --identity system >/dev/null
    
    echo "✓ Registry binding configured successfully"
    echo "Waiting 15 seconds for RBAC propagation..."
    sleep 15
    exit 0
  fi
fi

# If user-assigned identities exist, bind the first one
UAI_KEYS=$(echo "$APP_JSON" | jq -r '.identity.userAssignedIdentities | keys[]?' 2>/dev/null || true)
if [ -n "$UAI_KEYS" ]; then
  FIRST_UAI=$(echo "$UAI_KEYS" | head -n 1)
  if [ -n "$FIRST_UAI" ]; then
    UAI_PRINCIPAL=$(az identity show --ids "$FIRST_UAI" --query principalId -o tsv 2>/dev/null || true)
    if [ -n "$UAI_PRINCIPAL" ]; then
      echo "Ensuring AcrPull role for user-assigned identity: $UAI_PRINCIPAL"
      az role assignment create \
        --assignee-object-id "$UAI_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --role "$ROLE_ID" \
        --scope "$ACR_ID" >/dev/null 2>&1 || true
      
      echo "Binding registry to Container App using user-assigned identity"
      az containerapp registry set \
        -n "$APP_NAME" \
        -g "$RG" \
        --server "$ACR_DOMAIN" \
        --identity "$FIRST_UAI" >/dev/null
      
      echo "✓ Registry binding configured successfully"
      echo "Waiting 15 seconds for RBAC propagation..."
      sleep 15
      exit 0
    fi
  fi
fi

echo "Warning: No managed identity found to bind ACR" >&2
exit 1
