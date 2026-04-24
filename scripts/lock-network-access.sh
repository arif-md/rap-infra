#!/bin/bash

# =============================================================================
# Post-Provision: Lock public network access for App Config + Key Vault
# =============================================================================
# When VNet integration is enabled, both services are reachable via private
# endpoints from within the VNet. Public access is kept open during the Bicep
# deployment (so ARM can write App Config key-values), then locked down here.
#
# When VNet is disabled, this script is a no-op — public access stays open
# and the free-tier App Config SKU is used (no private endpoint overhead).
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

# ── App Configuration ────────────────────────────────────────────────────────
APP_CONFIG_NAME=$(azd env get-value appConfigName 2>/dev/null || true)
if [ -n "$APP_CONFIG_NAME" ]; then
    echo "  Disabling App Config public access: $APP_CONFIG_NAME"
    az appconfig update \
        --name "$APP_CONFIG_NAME" \
        --resource-group "$RG" \
        --public-network-access Disabled \
        --output none
    echo "  ✅ App Config public access disabled."
else
    echo "  WARNING: appConfigName not in azd env — skipping App Config lockdown."
fi

# ── Key Vault ────────────────────────────────────────────────────────────────
KV_NAME=$(azd env get-value keyVaultName 2>/dev/null || true)
if [ -n "$KV_NAME" ]; then
    echo "  Disabling Key Vault public access: $KV_NAME"
    az keyvault update \
        --name "$KV_NAME" \
        --resource-group "$RG" \
        --public-network-access Disabled \
        --output none
    echo "  ✅ Key Vault public access disabled."
else
    echo "  WARNING: keyVaultName not in azd env — skipping Key Vault lockdown."
fi

echo "==> Network lockdown complete."
