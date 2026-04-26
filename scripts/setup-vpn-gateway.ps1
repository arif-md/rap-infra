#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Provisions an Azure VPN Gateway (Point-to-Site) connected to the RAP VNet.

.DESCRIPTION
    Creates an Azure VPN Gateway with Point-to-Site (P2S) connectivity so
    developers and admins can connect to the private VNet from their workstations
    as if on a corporate VPN.

    Once connected, your machine receives a private IP (from the VPN client
    address pool, e.g. 172.16.0.x) and all DNS lookups for private resources
    resolve to their private IPs via the linked private DNS zones:

        appcs-dev-*.azconfig.io         → 10.0.2.x  (App Config private endpoint)
        kv-dev-*.vault.azure.net        → 10.0.2.x  (Key Vault private endpoint)
        sql-dev-*.database.windows.net  → 10.0.2.x  (SQL private endpoint)

    This gives you:
      - Direct HTTPS access to Container App internal endpoints
      - Direct access to SQL via SSMS / Azure Data Studio (private IP, no firewall rules)
      - Direct access to App Config and Key Vault from local tools
      - No public ports opened on any resource

.PARAMETER ResourceGroup
    Resource group where the VNet lives. Defaults to 'rg-raptor-dev'.

.PARAMETER VNetName
    Name of the existing VNet. Auto-detected from the resource group if not provided.

.PARAMETER GatewaySubnetPrefix
    CIDR for the GatewaySubnet. Must be /27 or larger. Default: 10.0.3.0/27.
    Must not overlap with existing subnets (container-apps: 10.0.0.0/23,
    private-endpoints: 10.0.2.0/24).

.PARAMETER VpnClientAddressPool
    CIDR for the VPN client address pool (IPs assigned to connected devices).
    Must not overlap with the VNet CIDR (10.0.0.0/16). Default: 172.16.201.0/24.

.PARAMETER GatewaySku
    VPN Gateway SKU. Options: Basic, VpnGw1, VpnGw2.
    - Basic     : ~$27/mo. SSTP only. Max 10 P2S connections. No BGP.
                  Good for dev/admin access by a small team.
    - VpnGw1    : ~$140/mo. IKEv2 + SSTP + OpenVPN. Max 250 P2S connections.
                  Required for Azure AD (AAD) authentication instead of certificates.
    Default: Basic

.PARAMETER AuthMethod
    P2S authentication method:
    - Certificate : Self-signed root cert (works with Basic SKU). Easiest setup.
    - AzureAD     : Azure Entra ID authentication (requires VpnGw1+). More secure,
                    no cert management. Each user authenticates with their Azure AD credentials.
    Default: Certificate

.PARAMETER Location
    Azure region. Defaults to the VNet's location.

.EXAMPLE
    # Minimal — auto-detect VNet, use Basic SKU with certificate auth
    ./setup-vpn-gateway.ps1

.EXAMPLE
    # AAD auth with VpnGw1 (recommended for teams)
    ./setup-vpn-gateway.ps1 -GatewaySku VpnGw1 -AuthMethod AzureAD

.NOTES
    PROVISIONING TIME: The VPN Gateway takes 25-45 minutes to provision.
    This is an Azure platform constraint — the script will poll and wait.

    COST IMPACT:
      Basic SKU   : ~$27/month (gateway) + ~$0.10/GB egress
      VpnGw1 SKU  : ~$140/month (gateway) + ~$0.10/GB egress

    IDEMPOTENT: Safe to re-run. Skips steps that are already complete.

    CLEANUP: To remove the gateway (stop billing):
      az network vnet-gateway delete -g <rg> -n vpngw-<env> --no-wait
      az network public-ip delete -g <rg> -n pip-vpngw-<env>
      az network vnet subnet delete -g <rg> --vnet-name <vnet> -n GatewaySubnet
#>

param(
    [string] $ResourceGroup       = '',
    [string] $VNetName            = '',
    [string] $GatewaySubnetPrefix = '10.0.3.0/27',
    [string] $VpnClientAddressPool = '172.16.201.0/24',
    [ValidateSet('Basic','VpnGw1','VpnGw2')]
    [string] $GatewaySku          = 'Basic',
    [ValidateSet('Certificate','AzureAD')]
    [string] $AuthMethod          = 'Certificate',
    [string] $Location            = ''
)

$ErrorActionPreference = 'Stop'

function Write-Header  { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Success { param($m) Write-Host "  ✓ $m" -ForegroundColor Green }
function Write-Info    { param($m) Write-Host "  ℹ $m" -ForegroundColor Blue }
function Write-Warn    { param($m) Write-Host "  ⚠ $m" -ForegroundColor Yellow }
function Write-Fail    { param($m) Write-Host "  ✗ $m" -ForegroundColor Red }

###############################################################################
# Resolve environment from azd if not passed explicitly
###############################################################################
Write-Header "Resolving environment"

if (-not $ResourceGroup) {
    $ResourceGroup = azd env get-value AZURE_RESOURCE_GROUP 2>$null
    if (-not $ResourceGroup) { $ResourceGroup = 'rg-raptor-dev' }
}
Write-Info "Resource group : $ResourceGroup"

# Auto-detect VNet
if (-not $VNetName) {
    $VNetName = az network vnet list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $VNetName) {
        Write-Fail "No VNet found in '$ResourceGroup'. Is ENABLE_VNET_INTEGRATION=true and has 'azd provision' been run?"
        exit 1
    }
}
Write-Info "VNet           : $VNetName"

# Derive env token for naming consistency with Bicep resources
$envName = azd env get-value AZURE_ENV_NAME 2>$null
if (-not $envName) { $envName = 'dev' }
$gatewayName = "vpngw-$envName"
$publicIpName = "pip-vpngw-$envName"

# Resolve location from VNet if not provided
if (-not $Location) {
    $Location = az network vnet show -g $ResourceGroup -n $VNetName --query "location" -o tsv 2>$null
}
Write-Info "Location       : $Location"
Write-Info "Gateway name   : $gatewayName"
Write-Info "Gateway SKU    : $GatewaySku"
Write-Info "Auth method    : $AuthMethod"

# Validate: AAD auth requires VpnGw1+
if ($AuthMethod -eq 'AzureAD' -and $GatewaySku -eq 'Basic') {
    Write-Fail "AzureAD authentication requires VpnGw1 or higher. Use: -GatewaySku VpnGw1 -AuthMethod AzureAD"
    exit 1
}

###############################################################################
# Step 1 — GatewaySubnet
###############################################################################
Write-Header "Step 1/5 — GatewaySubnet"
# Azure requires the subnet to be named exactly 'GatewaySubnet'
$existingGwSubnet = az network vnet subnet show -g $ResourceGroup --vnet-name $VNetName -n GatewaySubnet -o json 2>$null | ConvertFrom-Json
if ($existingGwSubnet) {
    Write-Success "GatewaySubnet already exists ($($existingGwSubnet.addressPrefix))"
} else {
    Write-Info "Creating GatewaySubnet ($GatewaySubnetPrefix)..."
    az network vnet subnet create `
        -g $ResourceGroup `
        --vnet-name $VNetName `
        -n GatewaySubnet `
        --address-prefix $GatewaySubnetPrefix `
        --output none
    Write-Success "GatewaySubnet created"
}

###############################################################################
# Step 2 — Public IP for the gateway
###############################################################################
Write-Header "Step 2/5 — Public IP"
$existingPip = az network public-ip show -g $ResourceGroup -n $publicIpName -o json 2>$null | ConvertFrom-Json
if ($existingPip) {
    Write-Success "Public IP '$publicIpName' already exists ($($existingPip.ipAddress))"
} else {
    Write-Info "Creating public IP '$publicIpName'..."
    # Basic SKU gateway requires Basic public IP; VpnGw1+ needs Standard
    $pipSku = if ($GatewaySku -eq 'Basic') { 'Basic' } else { 'Standard' }
    $pipAlloc = if ($GatewaySku -eq 'Basic') { 'Dynamic' } else { 'Static' }
    az network public-ip create `
        -g $ResourceGroup `
        -n $publicIpName `
        -l $Location `
        --sku $pipSku `
        --allocation-method $pipAlloc `
        --output none
    Write-Success "Public IP created"
}

###############################################################################
# Step 3 — VPN Gateway (25-45 min to provision)
###############################################################################
Write-Header "Step 3/5 — VPN Gateway (this takes 25-45 minutes)"
$existingGw = az network vnet-gateway show -g $ResourceGroup -n $gatewayName -o json 2>$null | ConvertFrom-Json
if ($existingGw -and $existingGw.provisioningState -eq 'Succeeded') {
    Write-Success "VPN Gateway '$gatewayName' already exists and is Succeeded"
} else {
    Write-Info "Creating VPN Gateway '$gatewayName' (SKU: $GatewaySku)..."
    Write-Info "This is a long-running operation. The script will wait automatically."

    $gwArgs = @(
        '-g', $ResourceGroup,
        '-n', $gatewayName,
        '-l', $Location,
        '--gateway-type', 'Vpn',
        '--vnet', $VNetName,
        '--sku', $GatewaySku,
        '--vpn-type', 'RouteBased',
        '--address-prefixes', $VpnClientAddressPool,
        '--public-ip-address', $publicIpName,
        '--output', 'none'
    )

    if ($AuthMethod -eq 'Certificate') {
        $gwArgs += @('--client-protocol', 'SSTP')
    } else {
        # OpenVPN required for Azure AD auth
        $gwArgs += @('--client-protocol', 'OpenVPN')
    }

    az network vnet-gateway create @gwArgs
    Write-Success "VPN Gateway provisioned"
}

###############################################################################
# Step 4 — Authentication configuration
###############################################################################
Write-Header "Step 4/5 — Authentication ($AuthMethod)"

if ($AuthMethod -eq 'Certificate') {
    Write-Info "Certificate authentication selected."
    Write-Info ""
    Write-Info "You need to:"
    Write-Info "  1. Generate a self-signed root certificate (run once per team):"
    Write-Info "     \$cert = New-SelfSignedCertificate -Type Custom -KeySpec Signature \`"
    Write-Info "       -Subject 'CN=RaptorVPNRoot' -KeyExportPolicy Exportable \`"
    Write-Info "       -HashAlgorithm sha256 -KeyLength 2048 \`"
    Write-Info "       -CertStoreLocation 'Cert:\CurrentUser\My' -KeyUsageProperty Sign -KeyUsage CertSign"
    Write-Info ""
    Write-Info "  2. Export the root cert public key (Base64, no header/footer):"
    Write-Info "     \$certBase64 = [Convert]::ToBase64String(\$cert.RawData)"
    Write-Info ""
    Write-Info "  3. Upload the root cert to the gateway:"
    Write-Info "     az network vnet-gateway root-cert create -g $ResourceGroup \`"
    Write-Info "       --gateway-name $gatewayName --name RaptorVPNRoot \`"
    Write-Info "       --public-cert-data \$certBase64"
    Write-Info ""
    Write-Info "  4. Generate a client certificate signed by the root cert, export as .pfx,"
    Write-Info "     then download the VPN client package (see Step 5 below)."
    Write-Info ""
    Write-Warn "Re-run this script after uploading the root cert to proceed to Step 5."

} else {
    # AzureAD auth — requires VpnGw1+
    Write-Info "Configuring Azure AD authentication..."

    # The Azure VPN app ID is a well-known Microsoft application
    $azureVpnAppId   = '41b23e61-6c1e-4545-b367-cd054e0ed4b4'
    $tenantId = azd env get-value AZURE_AD_TENANT_ID 2>$null
    if (-not $tenantId) {
        $tenantId = az account show --query "tenantId" -o tsv 2>$null
    }
    $tenantUrl = "https://login.microsoftonline.com/$tenantId"

    az network vnet-gateway update `
        -g $ResourceGroup `
        -n $gatewayName `
        --aad-tenant $tenantUrl `
        --aad-audience $azureVpnAppId `
        --aad-issuer "$tenantUrl/" `
        --output none

    Write-Success "Azure AD authentication configured"
    Write-Info "Tenant: $tenantUrl"
    Write-Info "Users authenticate with their Azure AD credentials — no certificate management needed."
}

###############################################################################
# Step 5 — Download VPN client package
###############################################################################
Write-Header "Step 5/5 — VPN Client Package"

$existingGw2 = az network vnet-gateway show -g $ResourceGroup -n $gatewayName -o json 2>$null | ConvertFrom-Json
if ($existingGw2.provisioningState -eq 'Succeeded') {
    Write-Info "Generating VPN client package URL..."
    $vpnClientUrl = az network vnet-gateway vpn-client generate `
        -g $ResourceGroup -n $gatewayName -o tsv 2>$null
    if ($vpnClientUrl) {
        Write-Success "VPN client package ready. Download URL (valid 2 hours):"
        Write-Host "  $vpnClientUrl" -ForegroundColor White
        Write-Info ""
        Write-Info "Installation steps:"
        if ($AuthMethod -eq 'Certificate') {
            Write-Info "  1. Download and extract the ZIP."
            Write-Info "  2. Install the SSTP VPN client for your OS (WindowsAmd64\ folder)."
            Write-Info "  3. Import your client .pfx certificate into the current user certificate store."
            Write-Info "  4. Connect — you will get a 172.16.201.x IP."
        } else {
            Write-Info "  1. Install the Azure VPN Client from:"
            Write-Info "     https://aka.ms/azvpnclientdownload"
            Write-Info "  2. Download and import the VPN profile from the URL above."
            Write-Info "  3. Sign in with your Azure AD account."
            Write-Info "  4. Connect — you will get a 172.16.201.x IP."
        }
    } else {
        Write-Warn "Could not generate VPN client URL. Try manually:"
        Write-Info "  az network vnet-gateway vpn-client generate -g $ResourceGroup -n $gatewayName"
    }
} else {
    Write-Warn "Gateway is not yet in Succeeded state — re-run this script after provisioning completes."
}

###############################################################################
# Summary
###############################################################################
Write-Header "Summary"
Write-Info "Once connected to the VPN, your machine will:"
Write-Info "  • Resolve *.azconfig.io, *.vault.azure.net, *.database.windows.net to private IPs"
Write-Info "  • Be able to reach Container App internal FQDNs directly"
Write-Info "  • Appear as a VNet-internal host to all private endpoints"
Write-Info ""
Write-Info "Private endpoint IPs in this environment:"
az network private-endpoint list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json | ForEach-Object {
    $nicId = $_.networkInterfaces[0].id
    $ip = az network nic show --ids $nicId --query "ipConfigurations[0].privateIPAddress" -o tsv 2>$null
    Write-Info ("  {0,-40} -> {1}" -f $_.name, $ip)
}
Write-Info ""
Write-Warn "COST: ~`$27/mo (Basic) or ~`$140/mo (VpnGw1) — delete gateway when not needed:"
Write-Info "  az network vnet-gateway delete -g $ResourceGroup -n $gatewayName --no-wait"
