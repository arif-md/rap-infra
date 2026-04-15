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

$customDomain = azd env get-value CUSTOM_DOMAIN_NAME 2>$null
$enableAzureDns = azd env get-value ENABLE_AZURE_DNS 2>$null
$rg = azd env get-value AZURE_RESOURCE_GROUP 2>$null

if (-not $customDomain -or $enableAzureDns -ne "true") {
    Write-Host "  DNS Zone not needed (CUSTOM_DOMAIN_NAME='$customDomain', ENABLE_AZURE_DNS='$enableAzureDns')." -ForegroundColor Gray
    exit 0
}

if (-not $rg) {
    Write-Host "  AZURE_RESOURCE_GROUP not set. Skipping DNS Zone." -ForegroundColor Yellow
    exit 0
}

# Check if resource group exists (it may not on first deploy)
$rgExists = az group show -n $rg -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    # Create the resource group so the DNS zone can be placed in it
    $location = azd env get-value AZURE_LOCATION 2>$null
    if (-not $location) { $location = "eastus2" }
    Write-Host "  Creating resource group '$rg' in '$location'..." -ForegroundColor Yellow
    az group create -n $rg -l $location --only-show-errors 2>&1 | Out-Null
}

# Check if DNS zone already exists
$existing = az network dns zone show -g $rg -n $customDomain --query "name" -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
    $ns = az network dns zone show -g $rg -n $customDomain --query "nameServers[0]" -o tsv 2>$null
    Write-Host "  DNS Zone '$customDomain' already exists (NS: $ns ...)." -ForegroundColor Gray
    exit 0
}

# Create the DNS zone
Write-Host "  Creating DNS Zone '$customDomain' in '$rg'..." -ForegroundColor Yellow
az network dns zone create -g $rg -n $customDomain --only-show-errors 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Failed to create DNS Zone '$customDomain'." -ForegroundColor Red
    exit 1
}

$nameServers = az network dns zone show -g $rg -n $customDomain --query "nameServers" -o json 2>$null
Write-Host "  DNS Zone created. Nameservers:" -ForegroundColor Green
Write-Host "  $nameServers" -ForegroundColor White
Write-Host "  ACTION REQUIRED: Delegate '$customDomain' to these nameservers at your registrar." -ForegroundColor Yellow
exit 0
