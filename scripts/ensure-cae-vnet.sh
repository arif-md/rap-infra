#!/bin/bash
###############################################################################
# Detects and removes a stranded Container Apps Environment (CAE) that exists
# without VNet configuration when VNet integration is required.
#
# Root cause: When `azd down` deletes the VNet before the CAE (or the CAE
# deletion fails), the CAE survives with vnetSubnetId=null. On the next
# provision, Bicep tries to set infrastructureSubnetId on the existing CAE
# which Azure rejects with ManagedEnvironmentCannotAddVnetToExistingEnv.
#
# Fix: Delete the stranded CAE so Bicep can recreate it with VNet from scratch.
# The container apps inside it are also deleted by Azure automatically; Bicep
# will recreate all of them in the same provision run.
###############################################################################

set -e

info()    { echo -e "\033[1;34mℹ $1\033[0m"; }
success() { echo -e "\033[1;32m✓ $1\033[0m"; }
warning() { echo -e "\033[1;33m⚠ $1\033[0m"; }
error()   { echo -e "\033[1;31m✗ $1\033[0m"; }
header()  { echo -e "\n\033[1;36m=== $1 ===\033[0m"; }

header "CAE VNet Guard"

# Only relevant when VNet integration is enabled
VNET_ENABLED="${ENABLE_VNET_INTEGRATION:-false}"
if [ "$VNET_ENABLED" != "true" ]; then
    success "VNet integration disabled — CAE VNet guard skipped."
    exit 0
fi

RG="${AZURE_RESOURCE_GROUP:-}"
ENV="${AZURE_ENV_NAME:-}"

if [ -z "$RG" ] || [ -z "$ENV" ]; then
    warning "AZURE_RESOURCE_GROUP or AZURE_ENV_NAME not set — skipping CAE VNet guard."
    exit 0
fi

# Find any CAE in the resource group that has no VNet subnet configured
info "Checking for stranded CAE (exists without VNet config)..."

STRANDED=$(az containerapp env list -g "$RG" \
    --query "[?properties.vnetConfiguration.infrastructureSubnetId==null].name" \
    -o tsv 2>/dev/null || true)

if [ -z "$STRANDED" ]; then
    success "No stranded CAE found."
    exit 0
fi

while IFS= read -r CAE_NAME; do
    [ -z "$CAE_NAME" ] && continue
    warning "Found stranded CAE '$CAE_NAME' (no VNet config) — deleting so Bicep can recreate with VNet."

    # Container Apps must be deleted before the environment can be deleted.
    # Retrieve the full environment resource ID so we can filter apps by it.
    CAE_ID=$(az containerapp env show -g "$RG" -n "$CAE_NAME" --query id -o tsv 2>/dev/null || true)

    if [ -n "$CAE_ID" ]; then
        info "Deleting container apps in '$CAE_NAME' before removing the environment..."
        APPS=$(az containerapp list -g "$RG" --query "[?properties.managedEnvironmentId=='$CAE_ID'].name" -o tsv 2>/dev/null || true)

        while IFS= read -r APP_NAME; do
            [ -z "$APP_NAME" ] && continue
            info "  Deleting container app '$APP_NAME'..."
            az containerapp delete -g "$RG" -n "$APP_NAME" --yes 2>&1 \
                && success "  Deleted '$APP_NAME'." \
                || { error "  Failed to delete '$APP_NAME'."; exit 1; }
        done <<< "$APPS"
    fi

    warning "Deleting stranded CAE '$CAE_NAME'. All apps will be recreated by Bicep."
    if az containerapp env delete -g "$RG" -n "$CAE_NAME" --yes 2>&1; then
        success "Deleted stranded CAE '$CAE_NAME'."
    else
        error "Failed to delete stranded CAE '$CAE_NAME'."
        exit 1
    fi
done <<< "$STRANDED"

success "CAE VNet guard complete."
