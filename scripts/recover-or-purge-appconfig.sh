#!/bin/bash

# =============================================================================
# Pre-Provision: Recover or purge soft-deleted App Configuration store
# =============================================================================
# Standard-tier App Config stores go into soft-delete when removed (e.g. azd down).
# During that retention window (1 day for non-prod) the name is reserved, so
# a subsequent azd provision with the same deterministic name would fail.
#
# This script runs BEFORE Bicep and:
#   - If VNet is disabled → SKU will be Free (no soft-delete), skip entirely
#   - If VNet is enabled  → SKU will be Standard; check for a soft-deleted store
#     with the expected name and purge it so Bicep can create a fresh one.
#
# Note: purge protection is disabled in non-prod, so purge is always allowed.
# =============================================================================

set -euo pipefail

# Only Standard/Premium SKUs support soft-delete — Free tier is an immediate hard-delete.
VNET_ENABLED=$(azd env get-value ENABLE_VNET_INTEGRATION 2>/dev/null || true)
if [ "$VNET_ENABLED" != "true" ]; then
    echo "VNet not enabled (Free SKU) — App Config soft-delete check skipped."
    exit 0
fi

RG=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || true)
LOCATION=$(azd env get-value AZURE_LOCATION 2>/dev/null || true)

if [ -z "$RG" ] || [ -z "$LOCATION" ]; then
    echo "AZURE_RESOURCE_GROUP or AZURE_LOCATION not set — skipping App Config purge check."
    exit 0
fi

echo "Checking for soft-deleted App Configuration stores in '$RG' ($LOCATION)..."

# Query all soft-deleted stores in this location; filter to our naming convention (appcs-)
DELETED=$(az appconfig list-deleted \
    --query "[?location=='$LOCATION' && starts_with(name,'appcs-')].name" \
    -o tsv 2>/dev/null || true)

if [ -z "$DELETED" ]; then
    echo "  No soft-deleted App Config stores found."
    exit 0
fi

echo "$DELETED" | while IFS= read -r STORE_NAME; do
    [ -z "$STORE_NAME" ] && continue
    echo "  Found soft-deleted store: $STORE_NAME — purging..."
    az appconfig purge \
        --name "$STORE_NAME" \
        --location "$LOCATION" \
        --yes \
        --output none
    echo "  ✅ Purged: $STORE_NAME"
done

echo "App Config soft-delete check complete."
