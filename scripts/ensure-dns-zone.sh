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

# DNS_ZONE_NAME: the parent Azure DNS zone (e.g. "nexgeninc-dev.com").
# Set this when CUSTOM_DOMAIN_NAME is a subdomain (e.g. "dev.nexgeninc-dev.com").
# Defaults to CUSTOM_DOMAIN_NAME (root domain scenario).
DNS_ZONE=$(azd env get-value DNS_ZONE_NAME 2>/dev/null || true)
[ -z "$DNS_ZONE" ] && DNS_ZONE="$CUSTOM_DOMAIN"

# DNS_RESOURCE_GROUP: resource group that owns the Azure DNS zone.
# Set to a shared RG (e.g. "rg-raptor-common") to share one zone across environments.
# Defaults to AZURE_RESOURCE_GROUP.
DNS_RG=$(azd env get-value DNS_RESOURCE_GROUP 2>/dev/null || true)
[ -z "$DNS_RG" ] && DNS_RG="$RG"

if [ -z "$CUSTOM_DOMAIN" ] || [ "$ENABLE_AZURE_DNS" != "true" ]; then
    echo "  DNS Zone not needed (CUSTOM_DOMAIN_NAME='$CUSTOM_DOMAIN', ENABLE_AZURE_DNS='$ENABLE_AZURE_DNS')."
    exit 0
fi

if [ -z "$DNS_RG" ]; then
    echo "  AZURE_RESOURCE_GROUP not set. Skipping DNS Zone."
    exit 0
fi

# Verify the resource group exists — this script will NOT create it.
# The deploying principal typically lacks RG create/delete permissions.
if ! az group show -n "$DNS_RG" -o none 2>/dev/null; then
    echo "  ERROR: Resource group '$DNS_RG' does not exist."
    echo "  Create it first (requires Owner/Contributor on the subscription), then re-run."
    exit 1
fi

# Check if DNS zone already exists
EXISTING=$(az network dns zone show -g "$DNS_RG" -n "$DNS_ZONE" --query "name" -o tsv 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
    NS=$(az network dns zone show -g "$DNS_RG" -n "$DNS_ZONE" --query "nameServers[0]" -o tsv 2>/dev/null || true)
    echo "  DNS Zone '$DNS_ZONE' already exists in '$DNS_RG' (NS: $NS ...)."
    exit 0
fi

# Create the DNS zone
echo "  Creating DNS Zone '$DNS_ZONE' in '$DNS_RG'..."
az network dns zone create -g "$DNS_RG" -n "$DNS_ZONE" --only-show-errors >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "  Failed to create DNS Zone '$DNS_ZONE'."
    exit 1
fi

NAMESERVERS=$(az network dns zone show -g "$DNS_RG" -n "$DNS_ZONE" --query "nameServers" -o json 2>/dev/null || true)
echo "  DNS Zone created. Nameservers:"
echo "  $NAMESERVERS"
echo "  ACTION REQUIRED: Delegate '$DNS_ZONE' to these nameservers at your registrar."
exit 0
