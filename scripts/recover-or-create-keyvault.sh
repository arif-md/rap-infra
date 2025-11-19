#!/bin/bash

# Recovers soft-deleted Key Vault if it exists, otherwise allows creation to proceed.
# This enables frequent azd up/down cycles even with purge protection enabled.

set -e

ENVIRONMENT_NAME="${AZURE_ENV_NAME}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
LOCATION="${AZURE_LOCATION}"

echo -e "\033[36mChecking for soft-deleted Key Vaults...\033[0m"

# Calculate the expected Key Vault name based on the naming convention in main.bicep
# This is a simplified version - Azure's uniqueString uses a specific hash algorithm
RESOURCE_TOKEN_INPUT="${SUBSCRIPTION_ID}${ENVIRONMENT_NAME}"
RESOURCE_TOKEN_HASH=$(echo -n "$RESOURCE_TOKEN_INPUT" | sha256sum | cut -c1-13)
RESOURCE_TOKEN="${ENVIRONMENT_NAME,,}-${RESOURCE_TOKEN_HASH}"
KEY_VAULT_NAME="kv-${RESOURCE_TOKEN}-v1"

echo -e "\033[33mExpected Key Vault name: ${KEY_VAULT_NAME}\033[0m"

# Check if the Key Vault exists in soft-deleted state
echo -e "\033[90mChecking if Key Vault '${KEY_VAULT_NAME}' is soft-deleted...\033[0m"

DELETED_VAULT=$(az keyvault show-deleted --name "${KEY_VAULT_NAME}" --location "${LOCATION}" 2>&1 || true)

if echo "$DELETED_VAULT" | grep -q "scheduledPurgeDate"; then
    echo -e "\033[32m✓ Found soft-deleted Key Vault: ${KEY_VAULT_NAME}\033[0m"
    PURGE_DATE=$(echo "$DELETED_VAULT" | jq -r '.properties.scheduledPurgeDate' 2>/dev/null || echo "Unknown")
    echo -e "\033[90m  Scheduled purge date: ${PURGE_DATE}\033[0m"
    echo ""
    echo -e "\033[36mRecovering Key Vault...\033[0m"
    
    if az keyvault recover --name "${KEY_VAULT_NAME}" --location "${LOCATION}" 2>&1; then
        echo -e "\033[32m✓ Successfully recovered Key Vault: ${KEY_VAULT_NAME}\033[0m"
        echo -e "\033[90m  The vault is now active and ready for use.\033[0m"
    else
        echo -e "\033[33m⚠ Recovery initiated but may take a few moments to complete.\033[0m"
        echo -e "\033[90m  If deployment fails, wait 1-2 minutes and retry.\033[0m"
    fi
elif echo "$DELETED_VAULT" | grep -q "AuthorizationFailed"; then
    echo -e "\033[33m⚠ Cannot check soft-deleted vaults due to permissions.\033[0m"
    echo -e "\033[90m  If deployment fails with 'vault already exists in deleted state':\033[0m"
    echo -e "\033[90m  1. Ask admin to recover: az keyvault recover --name ${KEY_VAULT_NAME}\033[0m"
    echo -e "\033[90m  2. Or wait for auto-purge (7 days for dev environments)\033[0m"
elif echo "$DELETED_VAULT" | grep -q -i "not found\|ResourceNotFound"; then
    echo -e "\033[32m✓ No soft-deleted Key Vault found. Deployment will create new vault.\033[0m"
else
    echo -e "\033[90mℹ Could not determine vault status\033[0m"
    echo -e "\033[90m  Continuing with deployment...\033[0m"
fi

echo ""
echo -e "\033[36mKey Vault recovery check complete.\033[0m"
