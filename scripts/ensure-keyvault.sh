#!/bin/bash
###############################################################################
# Ensures Key Vault exists before deployment (creates if missing)
# and ensures required secrets are present (creates/updates if missing).
# This script checks if the Key Vault exists in the resource group.
# If it doesn't exist, it creates it with the appropriate configuration.
# This prevents soft-delete conflicts and allows Key Vault to persist across azd down/up cycles.
###############################################################################

set -e

# Color output functions
info() { echo -e "\033[1;34mℹ $1\033[0m"; }
success() { echo -e "\033[1;32m✓ $1\033[0m"; }
warning() { echo -e "\033[1;33m⚠ $1\033[0m"; }
error() { echo -e "\033[1;31m✗ $1\033[0m"; }
header() { echo -e "\n\033[1;36m=== $1 ===\033[0m"; }

###############################################################################
# Ensure a single secret exists in Key Vault (create or update if value provided)
###############################################################################
ensure_secret() {
    local vault_name="$1"
    local secret_name="$2"
    local secret_value="$3"
    
    if [ -z "$secret_value" ]; then
        return
    fi
    
    # Check if secret already exists
    local existing_value
    existing_value=$(az keyvault secret show --vault-name "$vault_name" --name "$secret_name" --query value -o tsv 2>/dev/null || true)
    
    if [ "$existing_value" = "$secret_value" ]; then
        success "Secret '$secret_name' already exists and is up to date"
        return
    fi
    
    if [ -n "$existing_value" ]; then
        info "Updating secret '$secret_name'..."
    else
        info "Creating secret '$secret_name'..."
    fi
    
    if az keyvault secret set \
        --vault-name "$vault_name" \
        --name "$secret_name" \
        --value "$secret_value" \
        >/dev/null 2>&1; then
        success "Secret '$secret_name' configured"
    else
        warning "Failed to set secret '$secret_name'"
    fi
}

###############################################################################
# Ensure all required secrets are present in Key Vault
###############################################################################
ensure_secrets() {
    local vault_name="$1"
    
    header "Ensuring Key Vault Secrets"
    
    ensure_secret "$vault_name" "oidc-client-secret" "$OIDC_CLIENT_SECRET"
    ensure_secret "$vault_name" "jwt-secret" "$JWT_SECRET"
    ensure_secret "$vault_name" "aad-client-secret" "$AZURE_AD_CLIENT_SECRET"
}

header "Key Vault Setup Check"

# Get environment variables
ENVIRONMENT_NAME="${AZURE_ENV_NAME}"
LOCATION="${AZURE_LOCATION}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
KEY_VAULT_NAME="${KEY_VAULT_NAME}"

if [ -z "$ENVIRONMENT_NAME" ]; then
    error "AZURE_ENV_NAME environment variable is not set"
    exit 1
fi

if [ -z "$LOCATION" ]; then
    error "AZURE_LOCATION environment variable is not set"
    exit 1
fi

if [ -z "$RESOURCE_GROUP" ]; then
    RESOURCE_GROUP="rg-raptor-$ENVIRONMENT_NAME"
    info "AZURE_RESOURCE_GROUP not set, using default: $RESOURCE_GROUP"
fi

# Calculate Key Vault name if not provided
if [ -z "$KEY_VAULT_NAME" ]; then
    info "Calculating Key Vault name..."
    
    # Get abbreviations
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    INFRA_DIR="$(dirname "$SCRIPT_DIR")"
    KV_PREFIX=$(jq -r '.keyVaultVaults' "$INFRA_DIR/abbreviations.json")
    
    # Calculate uniqueString using a simple hash-based approach
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    UNIQUE_STRING_INPUT="${SUBSCRIPTION_ID}${ENVIRONMENT_NAME}"
    
    # Use md5sum to generate a unique string (approximates Bicep's uniqueString)
    UNIQUE_STRING=$(echo -n "$UNIQUE_STRING_INPUT" | md5sum | cut -c1-13)
    
    RESOURCE_TOKEN=$(echo "${ENVIRONMENT_NAME}-${UNIQUE_STRING}" | tr '[:upper:]' '[:lower:]')
    KEY_VAULT_NAME="${KV_PREFIX}${RESOURCE_TOKEN}-v10"
    
    info "Calculated Key Vault name: $KEY_VAULT_NAME"
    info "Exporting KEY_VAULT_NAME to azd environment for Bicep consistency..."
    azd env set KEY_VAULT_NAME "$KEY_VAULT_NAME" >/dev/null
else
    info "Using provided Key Vault name: $KEY_VAULT_NAME"
fi

# Export the Key Vault name to azd environment variables
info "Setting KEY_VAULT_NAME=$KEY_VAULT_NAME in azd environment"
azd env set KEY_VAULT_NAME "$KEY_VAULT_NAME" >/dev/null

# Check if Key Vault exists
info "Checking if Key Vault exists..."
if az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    success "Key Vault '$KEY_VAULT_NAME' already exists"
    ensure_secrets "$KEY_VAULT_NAME"
    exit 0
fi

# Check if it's in soft-deleted state
info "Checking for soft-deleted vault..."
if az keyvault show-deleted --name "$KEY_VAULT_NAME" >/dev/null 2>&1; then
    warning "Key Vault '$KEY_VAULT_NAME' exists in soft-deleted state"
    info "Attempting to recover..."
    
    if az keyvault recover --name "$KEY_VAULT_NAME" --location "$LOCATION" >/dev/null 2>&1; then
        success "Key Vault recovered successfully"
        ensure_secrets "$KEY_VAULT_NAME"
        exit 0
    else
        warning "Could not recover Key Vault (may lack permissions)"
        info "Either wait for auto-purge (7-90 days) or ask admin to purge it"
        info "Or set KEY_VAULT_NAME to a different name in azd environment"
        exit 1
    fi
fi

# Create Key Vault
info "Creating Key Vault '$KEY_VAULT_NAME'..."

# Determine retention days based on environment
if [[ "$ENVIRONMENT_NAME" == "prod" ]] || [[ "$ENVIRONMENT_NAME" == "production" ]]; then
    RETENTION_DAYS=90
else
    RETENTION_DAYS=7
fi

info "Environment: $ENVIRONMENT_NAME (retention: $RETENTION_DAYS days)"

if az keyvault create \
    --name "$KEY_VAULT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --retention-days "$RETENTION_DAYS" \
    --enable-purge-protection true \
    --enable-rbac-authorization false \
    >/dev/null 2>&1; then
    
    success "Key Vault created successfully: $KEY_VAULT_NAME"
    
    # Grant the service principal access policies to manage secrets
    info "Granting access policies to service principal..."
    
    # Get current user/SP object ID
    CURRENT_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
    
    # If running as service principal, get its object ID differently
    if [ -z "$CURRENT_OBJECT_ID" ]; then
        ACCOUNT_TYPE=$(az account show --query user.type -o tsv)
        if [ "$ACCOUNT_TYPE" = "servicePrincipal" ]; then
            SP_APP_ID=$(az account show --query user.name -o tsv)
            CURRENT_OBJECT_ID=$(az ad sp show --id "$SP_APP_ID" --query id -o tsv 2>/dev/null || true)
        fi
    fi
    
    if [ -n "$CURRENT_OBJECT_ID" ]; then
        if az keyvault set-policy \
            --name "$KEY_VAULT_NAME" \
            --object-id "$CURRENT_OBJECT_ID" \
            --secret-permissions get list set delete \
            >/dev/null 2>&1; then
            success "Access policies granted"
        else
            warning "Failed to set access policies, but continuing..."
        fi
    else
        warning "Could not determine current identity, skipping access policy assignment"
    fi
    
    # Ensure all required secrets exist
    ensure_secrets "$KEY_VAULT_NAME"
    
    exit 0
else
    error "Failed to create Key Vault"
    exit 1
fi
