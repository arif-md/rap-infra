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

# ---------------------------------------------------------------------------
# Helper: safely read a value from azd env.
# azd env get-value writes "ERROR: key not found" to STDOUT (not stderr) when
# a key is missing, so 2>/dev/null alone does not suppress it — the error text
# flows into the variable. We check the exit code instead.
# ---------------------------------------------------------------------------
get_azd_value() {
    local val
    val=$(azd env get-value "$1" 2>/dev/null) || { echo ""; return 0; }
    echo "$val"
}

# Ensure the correct azd env is selected (AZURE_ENV_NAME is set as a job-level
# env var in the workflow, so it's available as a shell variable here).
if [ -n "${AZURE_ENV_NAME:-}" ]; then
    azd env select "$AZURE_ENV_NAME" 2>/dev/null || true
fi

CUSTOM_DOMAIN=$(get_azd_value CUSTOM_DOMAIN_NAME)
ENABLE_AZURE_DNS=$(get_azd_value ENABLE_AZURE_DNS)
RG=$(get_azd_value AZURE_RESOURCE_GROUP)
SUB=$(get_azd_value AZURE_SUBSCRIPTION_ID)

# DNS_ZONE_NAME: the parent Azure DNS zone (e.g. "nexgeninc-dev.com").
# Set this when CUSTOM_DOMAIN_NAME is a subdomain (e.g. "dev.nexgeninc-dev.com").
# Defaults to CUSTOM_DOMAIN_NAME (root domain scenario).
DNS_ZONE=$(get_azd_value DNS_ZONE_NAME)
[ -z "$DNS_ZONE" ] && DNS_ZONE="$CUSTOM_DOMAIN"

# DNS_RESOURCE_GROUP: resource group that owns the Azure DNS zone.
# Set to a shared RG (e.g. "rg-raptor-common") to share one zone across environments.
# Defaults to AZURE_RESOURCE_GROUP.
DNS_RG=$(get_azd_value DNS_RESOURCE_GROUP)
[ -z "$DNS_RG" ] && DNS_RG="$RG"

# Build optional --subscription flag so all az commands target the right sub.
SUB_ARG=""
if [ -n "$SUB" ]; then
  SUB_ARG="--subscription $SUB"
  az account set --subscription "$SUB" 2>/dev/null || true
fi

if [ -z "$CUSTOM_DOMAIN" ] || [ "$ENABLE_AZURE_DNS" != "true" ]; then
    echo "  DNS Zone not needed (CUSTOM_DOMAIN_NAME='$CUSTOM_DOMAIN', ENABLE_AZURE_DNS='$ENABLE_AZURE_DNS')."
    exit 0
fi

if [ -z "$DNS_RG" ]; then
    echo "  AZURE_RESOURCE_GROUP not set. Skipping DNS Zone."
    exit 0
fi

# Verify the DNS resource group exists. Fail immediately if it does not —
# this prevents proceeding to zone operations that would also fail, and makes
# the root cause explicit. rg-raptor-common (or whatever DNS_RESOURCE_GROUP
# is set to) must be created manually before running this workflow.
if ! az group show -n "$DNS_RG" $SUB_ARG -o none 2>/dev/null; then
    echo "  ERROR: Resource group '$DNS_RG' does not exist or is not accessible"
    echo "  in subscription '${SUB:-<not set>}'."
    echo "  Create the resource group manually before re-running this workflow."
    exit 1
fi

# Check if DNS zone already exists
EXISTING=$(az network dns zone show -g "$DNS_RG" -n "$DNS_ZONE" $SUB_ARG --query "name" -o tsv 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
    NS=$(az network dns zone show -g "$DNS_RG" -n "$DNS_ZONE" $SUB_ARG --query "nameServers[0]" -o tsv 2>/dev/null || true)
    echo "  DNS Zone '$DNS_ZONE' already exists in '$DNS_RG' (NS: $NS ...)."
    exit 0
fi

# Create the DNS zone
echo "  Creating DNS Zone '$DNS_ZONE' in '$DNS_RG'..."
az network dns zone create -g "$DNS_RG" -n "$DNS_ZONE" $SUB_ARG --only-show-errors >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "  Failed to create DNS Zone '$DNS_ZONE'."
    exit 1
fi

NAMESERVERS=$(az network dns zone show -g "$DNS_RG" -n "$DNS_ZONE" $SUB_ARG --query "nameServers" -o json 2>/dev/null || true)
echo "  DNS Zone created. Nameservers:"
echo "  $NAMESERVERS"
echo "  ACTION REQUIRED: Delegate '$DNS_ZONE' to these nameservers at your registrar."
exit 0
