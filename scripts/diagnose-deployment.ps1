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
