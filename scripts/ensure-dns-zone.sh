#!/bin/bash

###############################################################################
# Pre-Provision: Ensure Azure DNS Zone exists
###############################################################################
# Creates the DNS Zone outside the Bicep deployment stack so it survives
# azd down/up cycles. This preserves nameserver assignments, keeping the
# domain delegation at your registrar valid across redeployments.
#
# DNS A + TXT records are created by the post-provision script
# (bind-custom-domain-tls.sh), NOT by Bicep, to keep them out of the
# deployment stack.
###############################################################################

set -e

CUSTOM_DOMAIN=$(azd env get-value CUSTOM_DOMAIN_NAME 2>/dev/null || true)
ENABLE_AZURE_DNS=$(azd env get-value ENABLE_AZURE_DNS 2>/dev/null || true)
RG=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || true)

if [ -z "$CUSTOM_DOMAIN" ] || [ "$ENABLE_AZURE_DNS" != "true" ]; then
    echo "  DNS Zone not needed (CUSTOM_DOMAIN_NAME='$CUSTOM_DOMAIN', ENABLE_AZURE_DNS='$ENABLE_AZURE_DNS')."
    exit 0
fi

if [ -z "$RG" ]; then
    echo "  AZURE_RESOURCE_GROUP not set. Skipping DNS Zone."
    exit 0
fi

# Check if resource group exists (it may not on first deploy)
if ! az group show -n "$RG" -o none 2>/dev/null; then
    LOCATION=$(azd env get-value AZURE_LOCATION 2>/dev/null || true)
    if [ -z "$LOCATION" ]; then LOCATION="eastus2"; fi
    echo "  Creating resource group '$RG' in '$LOCATION'..."
    az group create -n "$RG" -l "$LOCATION" --only-show-errors >/dev/null 2>&1
fi

# Check if DNS zone already exists
EXISTING=$(az network dns zone show -g "$RG" -n "$CUSTOM_DOMAIN" --query "name" -o tsv 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
    NS=$(az network dns zone show -g "$RG" -n "$CUSTOM_DOMAIN" --query "nameServers[0]" -o tsv 2>/dev/null || true)
    echo "  DNS Zone '$CUSTOM_DOMAIN' already exists (NS: $NS ...)."
    exit 0
fi

# Create the DNS zone
echo "  Creating DNS Zone '$CUSTOM_DOMAIN' in '$RG'..."
az network dns zone create -g "$RG" -n "$CUSTOM_DOMAIN" --only-show-errors >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "  Failed to create DNS Zone '$CUSTOM_DOMAIN'."
    exit 1
fi

NAMESERVERS=$(az network dns zone show -g "$RG" -n "$CUSTOM_DOMAIN" --query "nameServers" -o json 2>/dev/null || true)
echo "  DNS Zone created. Nameservers:"
echo "  $NAMESERVERS"
echo "  ACTION REQUIRED: Delegate '$CUSTOM_DOMAIN' to these nameservers at your registrar."
exit 0
