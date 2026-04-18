#!/usr/bin/env pwsh

# =============================================================================
# Post-Provision: Add Custom Domain + TLS Certificate to Route Config
# =============================================================================
# Bicep deploys httpRouteConfig with routing rules ONLY (no customDomains).
# ALL DNS and custom domain lifecycle is handled here:
#   1. Checks if TLS is already properly bound (skip if yes)
#   2. Creates/updates DNS A + TXT records in Azure DNS zone (if managed)
#   3. Waits for DNS TXT propagation
#   4. Adds the custom domain to the route config (bindingType=Disabled)
#   5. Creates or reuses a managed TLS certificate (TXT for internal CAE, HTTP otherwise)
#      For TXT validation: also creates _dnsauth DNS record with validation token
#   6. Binds the certificate to the route config (SniEnabled)
#
# Why not in Bicep?
#   - customDomains on httpRouteConfig triggers ARM domain validation that
#     queries public DNS. After azd down/up, DNS may not have propagated.
#   - DNS records in Bicep are managed by the deployment stack and get deleted
#     on azd down, causing propagation issues on the next azd up.
#   - Doing it here lets us create records, wait for propagation, and retry.
# =============================================================================

$ErrorActionPreference = "Stop"

$customDomain = azd env get-value CUSTOM_DOMAIN_NAME 2>$null
if (-not $customDomain) {
    Write-Host "CUSTOM_DOMAIN_NAME not set. Skipping custom domain setup." -ForegroundColor Yellow
    exit 0
}

$rg = azd env get-value AZURE_RESOURCE_GROUP 2>$null
if (-not $rg) {
    Write-Host "Missing AZURE_RESOURCE_GROUP. Skipping." -ForegroundColor Yellow
    exit 0
}

# Discover the CAE name from the resource group
$caeName = az containerapp env list -g $rg --query "[0].name" -o tsv 2>$null
if (-not $caeName) {
    Write-Host "No Container Apps Environment found in $rg. Skipping." -ForegroundColor Yellow
    exit 0
}

# Detect if CAE is internal (VNet-only, no public IP) → must use TXT cert validation
$caeInternal = az containerapp env show -g $rg -n $caeName `
    --query "properties.vnetConfiguration.internal" -o tsv 2>$null
$certValidationMethod = if ($caeInternal -eq "true") { "TXT" } else { "HTTP" }
Write-Host "  CAE internal=$caeInternal → cert validation: $certValidationMethod" -ForegroundColor Gray

# Check route config exists
$routeExists = az containerapp env http-route-config show -g $rg -n $caeName -r raptorrouting --query "name" -o tsv 2>$null
if (-not $routeExists) {
    Write-Host "Route config 'raptorrouting' not found. Skipping." -ForegroundColor Yellow
    exit 0
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "==> Setting up custom domain: $customDomain ..." -ForegroundColor Cyan

# ── Helper: Build YAML from current route config with specified domain settings ──
function Build-RouteYaml {
    param(
        [string]$Domain,
        [string]$BindingType,
        [string]$CertificateId = $null
    )
    $routeJson = az containerapp env http-route-config show -g $rg -n $caeName -r raptorrouting -o json 2>$null | ConvertFrom-Json
    $yamlLines = @()
    $yamlLines += "customDomains:"
    $yamlLines += "  - name: $Domain"
    $yamlLines += "    bindingType: $BindingType"
    if ($CertificateId) {
        $yamlLines += "    certificateId: $CertificateId"
    }
    $yamlLines += "rules:"
    foreach ($rule in $routeJson.properties.rules) {
        $yamlLines += "  - description: `"$($rule.description)`""
        $yamlLines += "    routes:"
        foreach ($route in $rule.routes) {
            $match = $route.match
            if ($match.pathSeparatedPrefix) {
                $yamlLines += "      - match:"
                $yamlLines += "          pathSeparatedPrefix: $($match.pathSeparatedPrefix)"
            } elseif ($match.prefix) {
                $yamlLines += "      - match:"
                $yamlLines += "          prefix: $($match.prefix)"
            }
            if ($route.action -and $route.action.prefixRewrite) {
                $yamlLines += "        action:"
                $yamlLines += "          prefixRewrite: $($route.action.prefixRewrite)"
            }
        }
        $yamlLines += "    targets:"
        foreach ($target in $rule.targets) {
            $yamlLines += "      - containerApp: $($target.containerApp)"
        }
    }
    return ($yamlLines -join "`n")
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Check if TLS is already properly bound
# ══════════════════════════════════════════════════════════════════════════════
$routeConfig = az containerapp env http-route-config show `
    -g $rg -n $caeName -r raptorrouting `
    --query "properties.customDomains[?name=='$customDomain']" -o json 2>$null | ConvertFrom-Json

if ($routeConfig -and $routeConfig.Count -gt 0) {
    $currentBinding = $routeConfig[0].bindingType
    $currentCertId = $routeConfig[0].certificateId

    if ($currentBinding -eq "SniEnabled" -and $currentCertId) {
        $certExists = az containerapp env certificate list `
            -g $rg -n $caeName `
            --query "[?id=='$currentCertId' && properties.provisioningState=='Succeeded'].id" -o tsv 2>$null

        if ($certExists) {
            Write-Host "==> TLS already bound with valid certificate. Nothing to do. ($([int]$stopwatch.Elapsed.TotalSeconds)s)" -ForegroundColor Green
            exit 0
        }
        Write-Host "  Route binding references missing/invalid certificate. Re-binding..." -ForegroundColor Yellow
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Create/update DNS records in Azure DNS zone (if managed)
# ══════════════════════════════════════════════════════════════════════════════
$verificationId = az containerapp env show -g $rg -n $caeName `
    --query "properties.customDomainConfiguration.customDomainVerificationId" -o tsv 2>$null

$enableAzureDns = azd env get-value ENABLE_AZURE_DNS 2>$null
if ($enableAzureDns -eq "true") {
    $staticIp = az containerapp env show -g $rg -n $caeName `
        --query "properties.staticIp" -o tsv 2>$null

    if (-not $staticIp -or -not $verificationId) {
        Write-Host "ERROR: Could not retrieve CAE static IP or verification ID." -ForegroundColor Red
        exit 1
    }

    Write-Host "  Creating/updating DNS records in Azure DNS zone..." -ForegroundColor Yellow

    # A record: customDomain → CAE static IP
    # Delete entire record set and recreate to avoid stale IPs accumulating
    # (add-record appends; after azd down/up the CAE IP changes)
    $existingARecords = az network dns record-set a show -g $rg -z $customDomain -n "@" --query "ARecords[].ipv4Address" -o tsv 2>$null
    $aRecordList = if ($existingARecords) { ($existingARecords -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
    $aRecordCorrect = ($aRecordList.Count -eq 1) -and ($aRecordList[0] -eq $staticIp)

    if (-not $aRecordCorrect) {
        if ($aRecordList.Count -gt 0) {
            az network dns record-set a delete -g $rg -z $customDomain -n "@" --yes --only-show-errors 2>$null
        }
        az network dns record-set a add-record -g $rg -z $customDomain -n "@" -a $staticIp --only-show-errors 2>$null
        Write-Host "    A record: $customDomain → $staticIp" -ForegroundColor Gray
    } else {
        Write-Host "    A record already correct: $customDomain → $staticIp" -ForegroundColor Gray
    }

    # TXT record: asuid.customDomain → verification ID
    # Same approach: delete entire record set and recreate to avoid stale values
    $existingTxtRecords = az network dns record-set txt show -g $rg -z $customDomain -n "asuid" --query "TXTRecords[].value[0]" -o tsv 2>$null
    $txtRecordList = if ($existingTxtRecords) { ($existingTxtRecords -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
    $txtRecordCorrect = ($txtRecordList.Count -eq 1) -and ($txtRecordList[0] -eq $verificationId)

    if (-not $txtRecordCorrect) {
        if ($txtRecordList.Count -gt 0) {
            az network dns record-set txt delete -g $rg -z $customDomain -n "asuid" --yes --only-show-errors 2>$null
        }
        az network dns record-set txt add-record -g $rg -z $customDomain -n "asuid" -v $verificationId --only-show-errors 2>$null
        Write-Host "    TXT record: asuid.$customDomain → $($verificationId.Substring(0,16))..." -ForegroundColor Gray
    } else {
        Write-Host "    TXT record already correct." -ForegroundColor Gray
    }

    Write-Host "  DNS records ready. ($([int]$stopwatch.Elapsed.TotalSeconds)s)" -ForegroundColor Green
} else {
    Write-Host "  Azure DNS not managed (ENABLE_AZURE_DNS != true). Expecting manual DNS." -ForegroundColor Gray
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Ensure DNS TXT record is resolvable (wait for propagation)
# ══════════════════════════════════════════════════════════════════════════════

Write-Host "  Checking DNS TXT record for asuid.$customDomain ..." -ForegroundColor Yellow
$dnsReady = $false
$dnsAttempts = 0
$maxDnsAttempts = 24  # 2 minutes max (24 * 5s)

while (-not $dnsReady -and $dnsAttempts -lt $maxDnsAttempts) {
    $txtResult = (Resolve-DnsName -Name "asuid.$customDomain" -Type TXT -ErrorAction SilentlyContinue)
    if ($txtResult -and ($txtResult | Where-Object { $_.Strings -contains $verificationId })) {
        $dnsReady = $true
    } else {
        $dnsAttempts++
        if ($dnsAttempts -eq 1) {
            Write-Host "  Waiting for DNS propagation..." -ForegroundColor Gray
        }
        if ($dnsAttempts % 6 -eq 0) {
            Write-Host "  Still waiting... ($([int]$stopwatch.Elapsed.TotalSeconds)s)" -ForegroundColor Gray
        }
        Start-Sleep -Seconds 5
    }
}

if (-not $dnsReady) {
    Write-Host "WARNING: DNS TXT record not resolvable after 2 minutes." -ForegroundColor Yellow
    Write-Host "  Expected: asuid.$customDomain TXT $verificationId" -ForegroundColor White
    Write-Host "  Custom domain setup will be skipped. Re-run after DNS propagates:" -ForegroundColor White
    Write-Host "  ./scripts/bind-custom-domain-tls.ps1" -ForegroundColor White
    exit 0
}
Write-Host "  DNS TXT record verified. ($([int]$stopwatch.Elapsed.TotalSeconds)s)" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Add custom domain to route config (if not already present)
# ══════════════════════════════════════════════════════════════════════════════
$domainOnRoute = az containerapp env http-route-config show `
    -g $rg -n $caeName -r raptorrouting `
    --query "properties.customDomains[?name=='$customDomain'].name" -o tsv 2>$null

if (-not $domainOnRoute) {
    Write-Host "  Adding custom domain to route config (Disabled)..." -ForegroundColor Yellow
    $yaml = Build-RouteYaml -Domain $customDomain -BindingType "Disabled"
    $yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) "route-config-domain.yaml"
    $yaml | Set-Content -Path $yamlPath -Encoding utf8
    az containerapp env http-route-config update `
        -g $rg -n $caeName -r raptorrouting `
        --yaml $yamlPath --only-show-errors 2>$null
    Remove-Item $yamlPath -ErrorAction SilentlyContinue
    Write-Host "  Custom domain added. ($([int]$stopwatch.Elapsed.TotalSeconds)s)" -ForegroundColor Green
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create or reuse TLS certificate
# ══════════════════════════════════════════════════════════════════════════════
$existingCert = az containerapp env certificate list `
    -g $rg -n $caeName `
    --query "[?properties.subjectName=='$customDomain' && properties.provisioningState=='Succeeded'].id" -o tsv 2>$null

if (-not $existingCert) {
    # Clean up stuck/failed/pending certificates
    $badCerts = az containerapp env certificate list `
        -g $rg -n $caeName `
        --query "[?properties.subjectName=='$customDomain' && properties.provisioningState!='Succeeded'].id" -o tsv 2>$null

    if ($badCerts) {
        foreach ($certId in ($badCerts -split "`n" | Where-Object { $_.Trim() })) {
            Write-Host "  Removing stale certificate: $($certId.Trim() | Split-Path -Leaf)" -ForegroundColor Yellow
            az containerapp env certificate delete -g $rg -n $caeName --certificate $certId.Trim() --yes 2>$null
        }
    }

    Write-Host "  Creating managed certificate ($certValidationMethod validation)..." -ForegroundColor Yellow
    $certOutput = az containerapp env certificate create `
        -g $rg -n $caeName `
        --hostname $customDomain `
        --validation-method $certValidationMethod `
        --only-show-errors 2>$null

    # For TXT validation: create the _dnsauth DNS record with the validation token
    if ($certValidationMethod -eq "TXT" -and $enableAzureDns -eq "true") {
        $validationToken = ($certOutput | ConvertFrom-Json).properties.validationToken
        if ($validationToken) {
            Write-Host "  Creating _dnsauth TXT record for cert validation..." -ForegroundColor Yellow
            az network dns record-set txt delete -g $rg -z $customDomain -n "_dnsauth" --yes --only-show-errors 2>$null
            az network dns record-set txt add-record -g $rg -z $customDomain -n "_dnsauth" -v $validationToken --only-show-errors 2>$null
            Write-Host "    TXT record: _dnsauth.$customDomain → $validationToken" -ForegroundColor Gray
        } else {
            Write-Host "  WARNING: Could not extract validationToken from cert output." -ForegroundColor Yellow
        }
    }

    # Poll for provisioning (5s interval, max 5 minutes)
    $maxAttempts = 60
    $attempt = 0
    $certState = "Pending"

    while ($certState -ne "Succeeded" -and $attempt -lt $maxAttempts) {
        $attempt++
        Start-Sleep -Seconds 5
        $certState = az containerapp env certificate list `
            -g $rg -n $caeName `
            --query "[?properties.subjectName=='$customDomain'].properties.provisioningState" -o tsv 2>$null

        if ($attempt % 6 -eq 0) {
            Write-Host "  Certificate: $certState ($([int]$stopwatch.Elapsed.TotalSeconds)s elapsed)" -ForegroundColor Gray
        }

        if ($certState -eq "Failed") {
            Write-Host "ERROR: Certificate provisioning failed." -ForegroundColor Red
            Write-Host "  Check: az containerapp env certificate list -g $rg -n $caeName -o table" -ForegroundColor White
            exit 1
        }
    }

    if ($certState -ne "Succeeded") {
        Write-Host "WARNING: Certificate did not provision within 5 minutes." -ForegroundColor Yellow
        Write-Host "  Re-run: ./scripts/bind-custom-domain-tls.ps1" -ForegroundColor White
        exit 0
    }

    $existingCert = az containerapp env certificate list `
        -g $rg -n $caeName `
        --query "[?properties.subjectName=='$customDomain' && properties.provisioningState=='Succeeded'].id" -o tsv 2>$null
}

Write-Host "  Certificate ready: $($existingCert | Split-Path -Leaf) ($([int]$stopwatch.Elapsed.TotalSeconds)s)" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Bind TLS certificate (SniEnabled)
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "  Updating route config to SniEnabled..." -ForegroundColor Yellow
$yaml = Build-RouteYaml -Domain $customDomain -BindingType "SniEnabled" -CertificateId $existingCert
$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) "route-config-tls.yaml"
$yaml | Set-Content -Path $yamlPath -Encoding utf8
az containerapp env http-route-config update `
    -g $rg -n $caeName -r raptorrouting `
    --yaml $yamlPath --only-show-errors 2>$null
Remove-Item $yamlPath -ErrorAction SilentlyContinue

# ── Verify binding ──
$finalBinding = az containerapp env http-route-config show `
    -g $rg -n $caeName -r raptorrouting `
    --query "properties.customDomains[?name=='$customDomain'].bindingType" -o tsv 2>$null

if ($finalBinding -eq "SniEnabled") {
    Write-Host "==> TLS bound! https://$customDomain is ready. (total: $([int]$stopwatch.Elapsed.TotalSeconds)s)" -ForegroundColor Green
} else {
    Write-Host "WARNING: Binding state: $finalBinding (expected SniEnabled)" -ForegroundColor Yellow
    Write-Host "  Check: az containerapp env http-route-config show -g $rg -n $caeName -r raptorrouting" -ForegroundColor White
}
