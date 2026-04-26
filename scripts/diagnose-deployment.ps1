#!/usr/bin/env pwsh
# Diagnose why the site is unreachable after provisioning.
# Checks containers, DNS, and TLS binding in order.

$rg = "rg-raptor-dev"

Write-Host "`n=== CAE Info ===" -ForegroundColor Cyan
$cae = az containerapp env list -g $rg --query "[0].name" -o tsv
if (-not $cae) { Write-Host "ERROR: No CAE found in $rg" -ForegroundColor Red; exit 1 }
Write-Host "CAE name: $cae"
az containerapp env show -g $rg -n $cae `
    --query "{staticIp:properties.staticIp, internal:properties.vnetConfiguration.internal, defaultDomain:properties.defaultDomain}" `
    -o table

Write-Host "`n=== Container App Provisioning States ===" -ForegroundColor Cyan
az containerapp list -g $rg `
    --query "[].{Name:name,State:properties.provisioningState}" `
    -o table

Write-Host "`n=== Backend Replica / Running Status ===" -ForegroundColor Cyan
# Filter in PowerShell instead of JMESPath to avoid Windows cmd.exe quoting issues
# (JMESPath [?contains()] with single quotes inside double quotes gets mangled by az.cmd)
$be = (az containerapp list -g $rg --query "[].name" -o tsv) -split "`n" |
    Where-Object { $_ -match '-be$' } | Select-Object -First 1
if ($be) {
    az containerapp show -g $rg -n $be `
        --query "{runningStatus:properties.runningStatus,minReplicas:properties.template.scale.minReplicas}" `
        -o table
    Write-Host "`n--- Last 30 backend log lines ---" -ForegroundColor Gray
    az containerapp logs show -n $be -g $rg --tail 30 2>$null
} else {
    Write-Host "WARNING: Could not find backend container app" -ForegroundColor Yellow
}

Write-Host "`n=== DNS A Record vs CAE Static IP ===" -ForegroundColor Cyan
$dnsIp = az network dns record-set a show -g $rg -z nexgeninc-dev.com -n "@" `
    --query "ARecords[0].ipv4Address" -o tsv 2>$null
$caeIp = az containerapp env show -g $rg -n $cae --query "properties.staticIp" -o tsv
Write-Host "DNS A record  : $dnsIp"
Write-Host "CAE static IP : $caeIp"
if ($dnsIp -eq $caeIp) {
    Write-Host "  -> MATCH (DNS is correct)" -ForegroundColor Green
} else {
    Write-Host "  -> MISMATCH — DNS is stale, needs updating to $caeIp" -ForegroundColor Red
}

Write-Host "`n=== Route Config Custom Domains ===" -ForegroundColor Cyan
az containerapp env http-route-config show -g $rg -n $cae -r raptorrouting `
    --query "properties.customDomains" -o table 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Route config 'raptorrouting' not found or has no custom domains" -ForegroundColor Yellow
}

Write-Host "`n=== TLS Certificates ===" -ForegroundColor Cyan
az containerapp env certificate list -g $rg -n $cae `
    --query "[].{Name:name,Domain:properties.subjectName,State:properties.provisioningState}" `
    -o table

# =============================================================================
# Private Endpoint / Network Access Diagnostics
# =============================================================================
# Verifies that App Config and Key Vault are reachable from containers via
# their private endpoints (private IP), not the public internet.
#
# How it works:
#   1. Resolve the DNS A-record for each service — if the private DNS zone is
#      linked to the VNet correctly, the resolved IP will be in 10.x.x.x (private).
#   2. Run `nslookup` inside the backend container itself via `az containerapp exec`.
#      This is the ground truth: it shows what DNS the container actually resolves.
#   3. Check whether public network access is disabled (locked down) on each service.
# =============================================================================
Write-Host "`n=== Private Endpoint / Network Access Diagnostics ===" -ForegroundColor Cyan

# --- Resolve resource names from the environment ---
$appConfigName = az appconfig list -g $rg --query "[0].name" -o tsv 2>$null
$kvName        = az keyvault list -g $rg --query "[0].name" -o tsv 2>$null

# Helper: check if an IP is RFC-1918 private
function IsPrivateIp([string]$ip) {
    if (-not $ip) { return $false }
    return ($ip -match '^10\.' -or $ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or $ip -match '^192\.168\.')
}

# --- 1. DNS resolution from the control plane (your workstation / pipeline) ---
Write-Host "`n-- 1. DNS resolution (from this machine) --" -ForegroundColor Yellow
Write-Host "   NOTE: Will resolve to PUBLIC IPs from outside the VNet — that is expected."
Write-Host "         What matters is what the container resolves (see section 2 below).`n"

foreach ($svc in @(
    @{ Label = "App Config"; Host = "$appConfigName.azconfig.io" },
    @{ Label = "Key Vault";  Host = "$kvName.vault.azure.net"    }
)) {
    if (-not $svc.Host.StartsWith('.')) {
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($svc.Host) | Select-Object -First 1
            $ip = $resolved.IPAddressToString
            $isPrivate = IsPrivateIp $ip
            $color = if ($isPrivate) { 'Green' } else { 'Yellow' }
            Write-Host ("  {0,-12}: {1,-45} -> {2,-16} {3}" -f $svc.Label, $svc.Host, $ip, $(if ($isPrivate) { '[PRIVATE ✓]' } else { '[PUBLIC — expected from outside VNet]' })) -ForegroundColor $color
        } catch {
            Write-Host "  $($svc.Label): DNS resolution failed — $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# --- 2. DNS resolution from INSIDE the backend container (ground truth) ---
Write-Host "`n-- 2. DNS resolution from inside the backend container (ground truth) --" -ForegroundColor Yellow
Write-Host "   A private IP (10.x.x.x) means the container uses the private endpoint."
Write-Host "   A public IP means the private DNS zone is not linked or VNet is not wired.`n"

# Ground truth approach: compare the private endpoint NIC IP against the
# private DNS zone A record. If they match, any container inside the VNet
# will resolve the hostname to that private IP — no exec into the container needed.
# (Spring Boot containers are JRE-only and have no nslookup/getent.)
Write-Host "  Method: compare private endpoint NIC IP with private DNS zone A record."
Write-Host "  If both match a 10.x.x.x address, containers inside the VNet will use the private endpoint.`n"

$checks = @(
    @{
        Label    = "App Config"
        PeName   = "pe-$appConfigName"
        DnsZone  = "privatelink.azconfig.io"
        DnsName  = $appConfigName
    },
    @{
        Label    = "Key Vault"
        PeName   = "pe-$kvName"
        DnsZone  = "privatelink.vaultcore.azure.net"
        DnsName  = $kvName
    }
)

foreach ($check in $checks) {
    Write-Host "  [$($check.Label)]" -ForegroundColor White

    # Get the private IP from the private endpoint NIC
    $pe = az network private-endpoint show -g $rg -n $check.PeName -o json 2>$null | ConvertFrom-Json
    if (-not $pe) {
        Write-Host "    Private endpoint '$($check.PeName)' not found — private access NOT configured." -ForegroundColor Red
        continue
    }
    $nicId   = $pe.networkInterfaces[0].id
    $peIp    = az network nic show --ids $nicId --query "ipConfigurations[0].privateIPAddress" -o tsv 2>$null
    $peState = $pe.provisioningState
    Write-Host ("    Private endpoint NIC IP : {0,-16} (state: {1})" -f $peIp, $peState)

    # Get the A record from the private DNS zone
    $dnsRecord = az network private-dns record-set a show `
        -g $rg -z $check.DnsZone -n $check.DnsName -o json 2>$null | ConvertFrom-Json
    $dnsIp = $dnsRecord.aRecords[0].ipv4Address
    Write-Host ("    Private DNS A record IP : {0,-16} (zone: {1})" -f $dnsIp, $check.DnsZone)

    if ($peIp -and $dnsIp -and $peIp -eq $dnsIp -and (IsPrivateIp $peIp)) {
        Write-Host "    RESULT: PRIVATE ✓ — DNS resolves to private endpoint IP inside VNet." -ForegroundColor Green
    } elseif (-not $dnsIp) {
        Write-Host "    RESULT: WARNING ✗ — No A record in private DNS zone. DNS zone group may not have registered yet." -ForegroundColor Red
        Write-Host "    Fix: re-run 'azd provision' or check the DNS zone group on the private endpoint." -ForegroundColor Yellow
    } elseif ($peIp -ne $dnsIp) {
        Write-Host "    RESULT: MISMATCH ✗ — NIC IP ($peIp) != DNS record ($dnsIp). DNS zone group is stale." -ForegroundColor Red
    } else {
        Write-Host "    RESULT: DNS IP is not RFC-1918 private — something is wrong." -ForegroundColor Red
    }
    Write-Host ""
}

# --- 3. Public network access status ---
Write-Host "`n-- 3. Public network access status (are services locked to VNet-only?) --" -ForegroundColor Yellow

if ($appConfigName) {
    $acPublic = az appconfig show -n $appConfigName -g $rg `
        --query "properties.publicNetworkAccess" -o tsv 2>$null
    $acColor = if ($acPublic -eq 'Disabled') { 'Green' } else { 'Yellow' }
    Write-Host ("  App Config public access : {0,-10}  {1}" -f $acPublic, $(if ($acPublic -eq 'Disabled') { '(locked to VNet ✓)' } else { '(open — lock with lock-network-access.ps1 if VNet mode is active)' })) -ForegroundColor $acColor
} else {
    Write-Host "  App Config: not found in $rg" -ForegroundColor Red
}

if ($kvName) {
    $kvPublic = az keyvault show -n $kvName -g $rg `
        --query "properties.publicNetworkAccess" -o tsv 2>$null
    $kvColor = if ($kvPublic -eq 'Disabled') { 'Green' } else { 'Yellow' }
    Write-Host ("  Key Vault  public access : {0,-10}  {1}" -f $kvPublic, $(if ($kvPublic -eq 'Disabled') { '(locked to VNet ✓)' } else { '(open — lock after confirming private endpoint works end-to-end)' })) -ForegroundColor $kvColor
} else {
    Write-Host "  Key Vault: not found in $rg" -ForegroundColor Red
}

# --- 4. Private endpoint provisioning states ---
Write-Host "`n-- 4. Private endpoint provisioning states --" -ForegroundColor Yellow
az network private-endpoint list -g $rg `
    --query "[].{Name:name, State:provisioningState, NIC:networkInterfaces[0].id}" `
    -o table 2>$null

# --- 5. Private DNS zone VNet links ---
Write-Host "`n-- 5. Private DNS zone VNet links --" -ForegroundColor Yellow
foreach ($zone in @('privatelink.azconfig.io', 'privatelink.vaultcore.azure.net', 'privatelink.database.windows.net')) {
    $links = az network private-dns link vnet list -g $rg -z $zone `
        --query "[].{Link:name, State:properties.provisioningState, AutoReg:properties.registrationEnabled}" `
        -o table 2>$null
    Write-Host "  Zone: $zone"
    if ($links) { Write-Host ($links | Out-String).TrimEnd() } else { Write-Host "    (no links found)" -ForegroundColor Red }
    Write-Host ""
}
