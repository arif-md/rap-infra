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

    Also handles CAEs still in ScheduledForDelete/Deleting state from a prior
    manual or automated delete, by waiting for them to fully disappear before
    allowing Bicep to proceed (prevents ManagedEnvironmentNotReadyForAppCreation).
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

###############################################################################
# Helper: poll until the named CAE no longer appears in the list.
###############################################################################
function Wait-CaeGone {
    param([string]$CaeName)
    $Timeout  = 300  # seconds
    $Elapsed  = 0
    $Interval = 20

    Write-Host "ℹ Waiting for CAE '$CaeName' to finish deleting (timeout ${Timeout}s)..." -ForegroundColor Blue
    while ($Elapsed -lt $Timeout) {
        $StillExists = az containerapp env list -g $RG `
            --query "[?name=='$CaeName'].name" -o tsv 2>$null
        if (-not $StillExists) {
            Write-Host "✓ CAE '$CaeName' is fully deleted." -ForegroundColor Green
            return
        }
        Write-Host "  Still deleting... (${Elapsed}s elapsed, checking again in ${Interval}s)" -ForegroundColor Blue
        Start-Sleep -Seconds $Interval
        $Elapsed += $Interval
    }
    Write-Host "✗ CAE '$CaeName' did not finish deleting within ${Timeout}s." -ForegroundColor Red
    exit 1
}

###############################################################################
# Fetch all CAEs once and classify them.
###############################################################################
$AllCaesJson = az containerapp env list -g $RG `
    --query "[].{name:name,state:properties.provisioningState,subnet:properties.vnetConfiguration.infrastructureSubnetId}" `
    -o json 2>$null

if ($LASTEXITCODE -ne 0 -or -not $AllCaesJson) { $AllCaesJson = "[]" }
$AllCaes = $AllCaesJson | ConvertFrom-Json

###############################################################################
# Step 1: Wait for CAEs already in a deleting state (ScheduledForDelete /
# Deleting / Canceled). Prevents ManagedEnvironmentNotReadyForAppCreation.
###############################################################################
Write-Host "ℹ Checking for CAEs currently being deleted..." -ForegroundColor Blue

$DeletingStates = @('ScheduledForDelete', 'Deleting', 'Canceled')
$FoundDeleting  = $false

foreach ($Cae in $AllCaes) {
    if ($DeletingStates -contains $Cae.state) {
        $FoundDeleting = $true
        Write-Host "⚠ CAE '$($Cae.name)' is in state '$($Cae.state)' — waiting for it to disappear..." -ForegroundColor Yellow
        Wait-CaeGone -CaeName $Cae.name
    }
}

# Re-query if we waited for anything
if ($FoundDeleting) {
    $AllCaesJson = az containerapp env list -g $RG `
        --query "[].{name:name,state:properties.provisioningState,subnet:properties.vnetConfiguration.infrastructureSubnetId}" `
        -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $AllCaesJson) { $AllCaesJson = "[]" }
    $AllCaes = $AllCaesJson | ConvertFrom-Json
}

###############################################################################
# Step 2: Detect stranded CAEs (Succeeded but no VNet subnet) and delete them.
###############################################################################
Write-Host "ℹ Checking for stranded CAE (Succeeded but no VNet config)..." -ForegroundColor Blue

$StrandedCaes = $AllCaes | Where-Object { $_.state -eq 'Succeeded' -and -not $_.subnet }

if (-not $StrandedCaes) {
    Write-Host "✓ No stranded CAE found." -ForegroundColor Green
    exit 0
}

foreach ($Cae in $StrandedCaes) {
    $CaeName = $Cae.name
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

    Wait-CaeGone -CaeName $CaeName
}

Write-Host "✓ CAE VNet guard complete." -ForegroundColor Green
exit 0
