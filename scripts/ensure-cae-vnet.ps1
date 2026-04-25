#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Detects and removes a stranded Container Apps Environment (CAE) that
    exists without VNet configuration when VNet integration is required.

.DESCRIPTION
    Root cause: When 'azd down' deletes the VNet before the CAE (or the CAE
    deletion fails), the CAE survives with vnetSubnetId=null. On the next
    provision, Bicep tries to set infrastructureSubnetId on the existing CAE
    which Azure rejects with ManagedEnvironmentCannotAddVnetToExistingEnv.

    Fix: Delete the stranded CAE (and its container apps) so Bicep can
    recreate it with VNet from scratch. All apps are also recreated by Bicep.
#>

param()

$ErrorActionPreference = "Stop"

Write-Host "`n=== CAE VNet Guard ===" -ForegroundColor Cyan

# Only relevant when VNet integration is enabled
$VnetEnabled = $env:ENABLE_VNET_INTEGRATION
if ($VnetEnabled -ne "true") {
    Write-Host "✓ VNet integration disabled — CAE VNet guard skipped." -ForegroundColor Green
    exit 0
}

$RG  = $env:AZURE_RESOURCE_GROUP
$Env = $env:AZURE_ENV_NAME

if (-not $RG -or -not $Env) {
    Write-Host "⚠ AZURE_RESOURCE_GROUP or AZURE_ENV_NAME not set — skipping CAE VNet guard." -ForegroundColor Yellow
    exit 0
}

# Find any CAE in the resource group that has no VNet subnet configured
Write-Host "ℹ Checking for stranded CAE (exists without VNet config)..." -ForegroundColor Blue

$StrandedCaes = az containerapp env list -g $RG `
    --query "[?properties.vnetConfiguration.infrastructureSubnetId==null].name" `
    -o tsv 2>$null

if ($LASTEXITCODE -ne 0 -or -not $StrandedCaes) {
    Write-Host "✓ No stranded CAE found." -ForegroundColor Green
    exit 0
}

foreach ($CaeName in ($StrandedCaes -split "`n" | Where-Object { $_ -ne "" })) {
    Write-Host "⚠ Found stranded CAE '$CaeName' (no VNet config) — deleting so Bicep can recreate with VNet." -ForegroundColor Yellow

    # Container Apps must be deleted before the environment can be deleted.
    $CaeId = az containerapp env show -g $RG -n $CaeName --query id -o tsv 2>$null

    if ($CaeId) {
        Write-Host "ℹ Deleting container apps in '$CaeName' before removing the environment..." -ForegroundColor Blue

        $Apps = az containerapp list -g $RG `
            --query "[?properties.managedEnvironmentId=='$CaeId'].name" `
            -o tsv 2>$null

        foreach ($AppName in ($Apps -split "`n" | Where-Object { $_ -ne "" })) {
            Write-Host "  Deleting container app '$AppName'..." -ForegroundColor Yellow
            az containerapp delete -g $RG -n $AppName --yes 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "✗ Failed to delete container app '$AppName'." -ForegroundColor Red
                exit 1
            }
            Write-Host "  ✓ Deleted '$AppName'." -ForegroundColor Green
        }
    }

    Write-Host "⚠ Deleting stranded CAE '$CaeName'. All apps will be recreated by Bicep." -ForegroundColor Yellow
    az containerapp env delete -g $RG -n $CaeName --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Failed to delete stranded CAE '$CaeName'." -ForegroundColor Red
        exit 1
    }
    Write-Host "✓ Deleted stranded CAE '$CaeName'." -ForegroundColor Green
}

Write-Host "✓ CAE VNet guard complete." -ForegroundColor Green
exit 0
