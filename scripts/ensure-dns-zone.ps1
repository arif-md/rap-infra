#!/usr/bin/env pwsh

# =============================================================================
# Pre-Provision: Ensure Azure DNS Zone exists
# =============================================================================
# Creates the DNS Zone outside the Bicep deployment stack so it survives
# azd down/up cycles. This preserves nameserver assignments, keeping the
# domain delegation at your registrar valid across redeployments.
#
# DNS A + TXT records are created by the post-provision script
# (bind-custom-domain-tls.ps1), NOT by Bicep, to keep them out of the
# deployment stack.
# =============================================================================

$ErrorActionPreference = "Stop"

$customDomain    = azd env get-value CUSTOM_DOMAIN_NAME 2>$null
$enableAzureDns  = azd env get-value ENABLE_AZURE_DNS 2>$null
$rg              = azd env get-value AZURE_RESOURCE_GROUP 2>$null

# DNS_ZONE_NAME: the parent Azure DNS zone (e.g. "nexgeninc-dev.com").
# Set this when CUSTOM_DOMAIN_NAME is a subdomain (e.g. "dev.nexgeninc-dev.com").
# Defaults to CUSTOM_DOMAIN_NAME (root domain scenario).
$dnsZone = azd env get-value DNS_ZONE_NAME 2>$null
if (-not $dnsZone) { $dnsZone = $customDomain }

# DNS_RESOURCE_GROUP: resource group that owns the Azure DNS zone.
# Set to a shared RG (e.g. "rg-raptor-common") to share one zone across environments.
# Defaults to AZURE_RESOURCE_GROUP.
$dnsRg = azd env get-value DNS_RESOURCE_GROUP 2>$null
if (-not $dnsRg) { $dnsRg = $rg }

if (-not $customDomain -or $enableAzureDns -ne "true") {
    Write-Host "  DNS Zone not needed (CUSTOM_DOMAIN_NAME='$customDomain', ENABLE_AZURE_DNS='$enableAzureDns')." -ForegroundColor Gray
    exit 0
}

if (-not $dnsRg) {
    Write-Host "  AZURE_RESOURCE_GROUP not set. Skipping DNS Zone." -ForegroundColor Yellow
    exit 0
}

# Verify the resource group exists — this script will NOT create it.
# The deploying principal typically lacks RG create/delete permissions.
az group show -n $dnsRg -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Resource group '$dnsRg' does not exist." -ForegroundColor Red
    Write-Host "  Create it first (requires Owner/Contributor on the subscription), then re-run." -ForegroundColor Red
    exit 1
}

# Check if DNS zone already exists
$existing = az network dns zone show -g $dnsRg -n $dnsZone --query "name" -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
    $ns = az network dns zone show -g $dnsRg -n $dnsZone --query "nameServers[0]" -o tsv 2>$null
    Write-Host "  DNS Zone '$dnsZone' already exists in '$dnsRg' (NS: $ns ...)." -ForegroundColor Gray
    exit 0
}

# Create the DNS zone
Write-Host "  Creating DNS Zone '$dnsZone' in '$dnsRg'..." -ForegroundColor Yellow
az network dns zone create -g $dnsRg -n $dnsZone --only-show-errors 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Failed to create DNS Zone '$dnsZone'." -ForegroundColor Red
    exit 1
}

$nameServers = az network dns zone show -g $dnsRg -n $dnsZone --query "nameServers" -o json 2>$null
Write-Host "  DNS Zone created. Nameservers:" -ForegroundColor Green
Write-Host "  $nameServers" -ForegroundColor White
Write-Host "  ACTION REQUIRED: Delegate '$dnsZone' to these nameservers at your registrar." -ForegroundColor Yellow
exit 0
