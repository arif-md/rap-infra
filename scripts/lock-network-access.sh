#!/bin/bash

# =============================================================================
# Post-Provision: Lock public network access for Key Vault
# =============================================================================
# When VNet integration is enabled, Key Vault is reachable via a private
# endpoint from within the VNet. Public access can be safely disabled after
# deployment — containers use private routing via the DNS zone.
#
# App Config public access is intentionally NOT locked here. ARM (Bicep) writes
# key-values over the public endpoint (App Config has no 'trusted Azure services'
# bypass). Locking public access creates a Forbidden race condition on the next
# deployment. RBAC (Managed Identity Data Reader) protects the data plane.
#
# When VNet is disabled, this script is a no-op.
# =============================================================================

set -euo pipefail

VNET_ENABLED=$(azd env get-value ENABLE_VNET_INTEGRATION 2>/dev/null || true)
if [ "$VNET_ENABLED" != "true" ]; then
    echo "VNet not enabled — network lockdown skipped."
    exit 0
fi

RG=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || true)
if [ -z "$RG" ]; then
    echo "AZURE_RESOURCE_GROUP not set — skipping network lockdown."
    exit 0
fi

echo "==> Locking public network access (VNet mode)..."

# ── Key Vault ────────────────────────────────────────────────────────────────
# Key Vault has a private endpoint (pe-kv-*) and a linked private DNS zone
# (privatelink.vaultcore.azure.net). Containers inside the VNet resolve the KV
# hostname to the private endpoint IP, so public access can be safely disabled.
#
# Guard: verify the private endpoint actually exists before locking — this
# prevents startup failures if someone runs the script against an environment
# where the KV private endpoint was not provisioned.
# Note: azd env get-value writes its "not found" error to stdout, not stderr.
# Check exit code separately so a missing key doesn't populate KV_NAME with error text.
if KV_NAME=$(azd env get-value keyVaultName 2>/dev/null); then
    : # KV_NAME is valid
else
    KV_NAME=""
fi
if [ -n "$KV_NAME" ]; then
    KV_PE_NAME="pe-${KV_NAME}"
    KV_PE_STATE=$(az network private-endpoint show -g "$RG" -n "$KV_PE_NAME" \
        --query "provisioningState" -o tsv 2>/dev/null || true)
    if [ "$KV_PE_STATE" = "Succeeded" ]; then
        echo "  Disabling Key Vault public access: $KV_NAME"
        if az keyvault update \
            --name "$KV_NAME" \
            --resource-group "$RG" \
            --public-network-access Disabled \
            --output none 2>/dev/null; then
            echo "  ✅ Key Vault public access disabled."
        else
            echo "  WARNING: Could not disable Key Vault public access (permission issue) — continuing."
        fi
    else
        echo "  Key Vault: private endpoint '$KV_PE_NAME' not found or not Succeeded — public access left enabled."
        echo "             Run 'azd provision' to create the private endpoint, then re-run this script."
    fi
else
    echo "  WARNING: kvName not in azd env — skipping Key Vault lockdown."
fi

echo "==> Network lockdown complete."
