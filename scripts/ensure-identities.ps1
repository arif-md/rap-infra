#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-provisions all managed identities and grants the backend identity Key
    Vault access BEFORE the main Bicep deployment runs.

.DESCRIPTION
    Container Apps validates Key Vault URL secret references at deployment time
    by calling the KV data plane using the managed identity. If the identity is
    freshly created in the same Bicep deployment, the KV access policy may not
    have propagated to the KV data plane yet when Container Apps runs that
    validation, causing:

        "unable to fetch secret 'jwt-secret' using Managed identity"

    This script pre-creates ALL managed identities (same names Bicep will use)
    minutes before Bicep runs. Bicep references them as 'existing' resources
    (excluded from the deployment stack, so they survive 'azd down').
    The backend identity is granted KV secret access, and the ARM control plane
    is polled to confirm propagation before returning.

    NAMING
    ------
    Identity names are computed here using SHA-256 over (subscriptionId +
    resourceGroup + environmentName), then exported as azd env vars. main.bicep
    reads them via override parameters (same pattern as KEY_VAULT_NAME). This
    makes identity names unique per resource group, satisfying the design rule
    that each environment lives in its own RG.
#>

$ErrorActionPreference = "Stop"

function Write-Info    { param($m) Write-Host "ℹ $m" -ForegroundColor Blue }
function Write-Success { param($m) Write-Host "✓ $m" -ForegroundColor Green }
function Write-Warn    { param($m) Write-Host "⚠ $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "✗ $m" -ForegroundColor Red }

$EnvironmentName = $env:AZURE_ENV_NAME
$ResourceGroup   = $env:AZURE_RESOURCE_GROUP
$Location        = $env:AZURE_LOCATION
$KeyVaultName    = $env:KEY_VAULT_NAME

if (-not $EnvironmentName) { Write-Err "AZURE_ENV_NAME is not set"; exit 1 }
if (-not $ResourceGroup)   { Write-Err "AZURE_RESOURCE_GROUP is not set"; exit 1 }
if (-not $Location)        { Write-Err "AZURE_LOCATION is not set"; exit 1 }

# ---------------------------------------------------------------------------
# Compute identity resource token.
#
# Formula: sha256(subscriptionId + resourceGroupName + environmentName)
# truncated to 13 hex chars. Including the resource group ensures identity
# names are unique per RG (each environment lives in its own RG).
#
# Note: this hash deliberately differs from Bicep's uniqueString (base36).
# Identity names are exported to azd env and Bicep reads them as parameters,
# so Bicep does not re-derive them independently.
# ---------------------------------------------------------------------------
$SubscriptionId = az account show --query id -o tsv
$HashInput = "$SubscriptionId$ResourceGroup$EnvironmentName"
$Bytes     = [System.Text.Encoding]::UTF8.GetBytes($HashInput)
$Sha256    = [System.Security.Cryptography.SHA256]::Create()
$Hash      = $Sha256.ComputeHash($Bytes)
$UniqueString = (($Hash | ForEach-Object { $_.ToString("x2") }) -join '').Substring(0, 13)
$ResourceToken = "$($EnvironmentName.ToLower())-$UniqueString"

# Read the managed identity prefix from abbreviations.json (same source as main.bicep)
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfraDir   = Split-Path -Parent $ScriptDir
$AbbrFile   = Join-Path $InfraDir 'abbreviations.json'
$IdPrefix   = if (Test-Path $AbbrFile) {
    (Get-Content $AbbrFile -Raw | ConvertFrom-Json).managedIdentityUserAssignedIdentities
} else { 'id-' }

$BackendIdentityName   = "${IdPrefix}backend-$ResourceToken"
$FrontendIdentityName  = "${IdPrefix}frontend-$ResourceToken"
$ProcessesIdentityName = "${IdPrefix}processes-$ResourceToken"
$SqlAdminIdentityName  = "${IdPrefix}sqladmin-$ResourceToken"

Write-Info "Environment    : $EnvironmentName"
Write-Info "Resource group : $ResourceGroup"
Write-Info "Identity token : $ResourceToken"
Write-Info "Backend        : $BackendIdentityName"
Write-Info "Frontend       : $FrontendIdentityName"
Write-Info "Processes      : $ProcessesIdentityName"
Write-Info "SQL admin      : $SqlAdminIdentityName"

# ---------------------------------------------------------------------------
# Helper: create a managed identity if it does not already exist.
# Returns the principal ID.
# ---------------------------------------------------------------------------
function Ensure-Identity {
    param(
        [string]$IdentityName,
        [string]$Label
    )

    $Exists = az identity show --name $IdentityName --resource-group $ResourceGroup --query name -o tsv 2>$null
    if ($Exists) {
        Write-Success "$Label identity '$IdentityName' already exists"
    } else {
        Write-Info "Creating $Label managed identity '$IdentityName'..."
        az identity create `
            --name $IdentityName `
            --resource-group $ResourceGroup `
            --location $Location `
            --output none
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to create $Label identity"; exit 1 }
        Write-Success "$Label identity created"
    }

    return (az identity show `
        --name $IdentityName `
        --resource-group $ResourceGroup `
        --query principalId -o tsv)
}

# ---------------------------------------------------------------------------
# Create all identities and capture principal IDs
# ---------------------------------------------------------------------------
$BackendPrincipalId   = Ensure-Identity -IdentityName $BackendIdentityName   -Label "Backend"
$FrontendPrincipalId  = Ensure-Identity -IdentityName $FrontendIdentityName  -Label "Frontend"
$ProcessesPrincipalId = Ensure-Identity -IdentityName $ProcessesIdentityName -Label "Processes"

$EnableSql = $env:ENABLE_SQL_DATABASE
if ($EnableSql -ne "false") {
    $SqlAdminPrincipalId = Ensure-Identity -IdentityName $SqlAdminIdentityName -Label "SQL admin"
} else {
    Write-Info "SQL Database disabled — skipping SQL admin identity creation"
}

# ---------------------------------------------------------------------------
# Export identity names to azd environment.
# These are read by main.bicep via main.parameters.json override parameters.
# ---------------------------------------------------------------------------
Write-Info "Exporting identity names to azd environment..."
azd env set BACKEND_IDENTITY_NAME   $BackendIdentityName   | Out-Null
azd env set FRONTEND_IDENTITY_NAME  $FrontendIdentityName  | Out-Null
azd env set PROCESSES_IDENTITY_NAME $ProcessesIdentityName | Out-Null
if ($EnableSql -ne "false") {
    azd env set SQL_ADMIN_IDENTITY_NAME $SqlAdminIdentityName | Out-Null
}
Write-Success "Identity names exported"

# ---------------------------------------------------------------------------
# Resolve Key Vault name (should have been set by ensure-keyvault.ps1)
# ---------------------------------------------------------------------------
if (-not $KeyVaultName) {
    # Fallback: derive using same formula as ensure-keyvault.ps1 (md5, no RG)
    $KvHashInput = "$SubscriptionId$EnvironmentName"
    $Md5      = [System.Security.Cryptography.MD5]::Create()
    $KvBytes  = [System.Text.Encoding]::UTF8.GetBytes($KvHashInput)
    $KvHash   = $Md5.ComputeHash($KvBytes)
    $KvUnique = (($KvHash | ForEach-Object { $_.ToString("x2") }) -join '').Substring(0, 13)
    $KvToken  = "$($EnvironmentName.ToLower())-$KvUnique"
    $KeyVaultName = "kv-$KvToken-v10"
    Write-Warn "KEY_VAULT_NAME not set — derived fallback: $KeyVaultName"
} else {
    Write-Info "Using Key Vault: $KeyVaultName"
}

# ---------------------------------------------------------------------------
# Verify Key Vault exists before attempting policy operations
# ---------------------------------------------------------------------------
$KvExists = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query name -o tsv 2>$null
if (-not $KvExists) {
    Write-Warn "Key Vault '$KeyVaultName' not found in '$ResourceGroup'"
    Write-Warn "KV access policy cannot be set — Container Apps may fail to read secrets"
    Write-Warn "Ensure ensure-keyvault.ps1 ran successfully before this step"
    exit 0
}

# ---------------------------------------------------------------------------
# Grant backend identity Key Vault secret access (get + list).
# Only the backend Container App reads secrets from KV.
# ---------------------------------------------------------------------------
Write-Info "Granting Key Vault secret access (get, list) to backend identity..."
az keyvault set-policy `
    --name $KeyVaultName `
    --resource-group $ResourceGroup `
    --object-id $BackendPrincipalId `
    --secret-permissions get list `
    --output none 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "Key Vault access policy set for '$BackendIdentityName'"
} else {
    Write-Warn "Failed to set KV access policy — may lack permissions"
    Write-Warn "Container Apps may fail to read KV secrets if policy has not propagated"
}

# ---------------------------------------------------------------------------
# Poll ARM control plane until the access policy entry is confirmed.
#
# WHY POLL INSTEAD OF SLEEP
# -------------------------
# We cannot verify KV *data-plane* propagation from outside the managed
# identity. Polling the ARM control plane (az keyvault show → accessPolicies)
# confirms that Azure has committed the policy write. Once ARM confirms it,
# the KV data plane typically propagates within 5–10 seconds. A short fixed
# buffer after ARM confirmation is far more reliable than a blind sleep.
# ---------------------------------------------------------------------------
Write-Info "Polling ARM control plane until access policy is confirmed..."
$MaxWait  = 120
$Interval = 10
$Elapsed  = 0
$Confirmed = $false

while ($Elapsed -lt $MaxWait) {
    $PolicyCheck = az keyvault show `
        --name $KeyVaultName `
        --resource-group $ResourceGroup `
        --query "properties.accessPolicies[?objectId=='$BackendPrincipalId'].objectId" `
        -o tsv 2>$null

    if ($PolicyCheck) {
        Write-Success "Access policy confirmed in ARM control plane (${Elapsed}s elapsed)"
        $Confirmed = $true
        break
    }

    Write-Host "  Policy not yet visible in ARM (${Elapsed}s elapsed) — retrying in ${Interval}s..." -ForegroundColor Gray
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval
}

if (-not $Confirmed) {
    Write-Warn "Access policy not confirmed after ${MaxWait}s — proceeding anyway"
    Write-Warn "Container Apps may fail to read KV secrets if data-plane has not propagated"
}

# ---------------------------------------------------------------------------
# Fixed buffer: KV data plane finishes propagating after ARM confirmation.
# ---------------------------------------------------------------------------
Write-Info "Waiting 15 seconds for KV data plane to sync after ARM confirmation..."
Start-Sleep -Seconds 15
Write-Success "Identity pre-provisioning complete"

.DESCRIPTION
    Container Apps validates Key Vault URL secret references at deployment time
    by calling the KV data plane using the managed identity. If the identity is
    freshly created in the same Bicep deployment, the KV access policy may not
    have propagated to the KV data plane yet when Container Apps runs that
    validation, causing:

        "unable to fetch secret 'jwt-secret' using Managed identity"

    This race condition only manifests on a clean azd up (after azd down) when
    no VNet is configured — with VNet the parallel subnet/DNS/PE resources add
    enough time that propagation completes before Container Apps deploys.

    This script pre-creates the backend managed identity (same name Bicep will
    use) and grants it KV secret access, then waits 30 seconds for propagation.
    Bicep finds the identity already exists and updates it in-place (idempotent).
#>

$ErrorActionPreference = "Stop"

$EnvironmentName = $env:AZURE_ENV_NAME
$ResourceGroup   = $env:AZURE_RESOURCE_GROUP
$Location        = $env:AZURE_LOCATION
$KeyVaultName    = $env:KEY_VAULT_NAME

if (-not $EnvironmentName) { Write-Host "✗ AZURE_ENV_NAME is not set" -ForegroundColor Red; exit 1 }
if (-not $ResourceGroup)   { Write-Host "✗ AZURE_RESOURCE_GROUP is not set" -ForegroundColor Red; exit 1 }
if (-not $Location)        { Write-Host "✗ AZURE_LOCATION is not set" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Compute resource token — matches main.bicep:
#   resourceToken = toLower('${environmentName}-${uniqueString(subscription().id, environmentName)}')
# We approximate uniqueString with SHA-256 truncated to 13 hex chars, matching
# the same approach used in ensure-keyvault.ps1.
# ---------------------------------------------------------------------------
$SubscriptionId = az account show --query id -o tsv
$HashInput = "${SubscriptionId}${EnvironmentName}"
$Bytes = [System.Text.Encoding]::UTF8.GetBytes($HashInput)
$Sha256 = [System.Security.Cryptography.SHA256]::Create()
$Hash = $Sha256.ComputeHash($Bytes)
$UniqueString = ($Hash | ForEach-Object { $_.ToString("x2") }) -join '' | Select-Object -First 1
$UniqueString = (($Hash | ForEach-Object { $_.ToString("x2") }) -join '').Substring(0, 13)
$ResourceToken = "$($EnvironmentName.ToLower())-$UniqueString"

$BackendIdentityName = "id-backend-$ResourceToken"

Write-Host "ℹ Environment     : $EnvironmentName" -ForegroundColor Blue
Write-Host "ℹ Resource group  : $ResourceGroup" -ForegroundColor Blue
Write-Host "ℹ Backend identity: $BackendIdentityName" -ForegroundColor Blue

# ---------------------------------------------------------------------------
# Resolve Key Vault name
# ---------------------------------------------------------------------------
if (-not $KeyVaultName) {
    $KeyVaultName = "kv-$ResourceToken-v10"
    Write-Host "ℹ Calculated Key Vault name: $KeyVaultName" -ForegroundColor Blue
} else {
    Write-Host "ℹ Using provided Key Vault name: $KeyVaultName" -ForegroundColor Blue
}

# ---------------------------------------------------------------------------
# Verify Key Vault exists
# ---------------------------------------------------------------------------
$KvExists = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query name -o tsv 2>$null
if (-not $KvExists) {
    Write-Host "⚠ Key Vault '$KeyVaultName' not found — skipping identity pre-provision" -ForegroundColor Yellow
    Write-Host "⚠ KV access policy will be set by Bicep; race condition risk remains" -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# Create the backend managed identity if it doesn't exist
# ---------------------------------------------------------------------------
$IdentityExists = az identity show --name $BackendIdentityName --resource-group $ResourceGroup --query name -o tsv 2>$null
if ($IdentityExists) {
    Write-Host "✓ Backend identity '$BackendIdentityName' already exists" -ForegroundColor Green
} else {
    Write-Host "ℹ Creating backend managed identity '$BackendIdentityName'..." -ForegroundColor Blue
    az identity create `
        --name $BackendIdentityName `
        --resource-group $ResourceGroup `
        --location $Location `
        --output none
    Write-Host "✓ Backend identity created" -ForegroundColor Green
}

$PrincipalId = az identity show `
    --name $BackendIdentityName `
    --resource-group $ResourceGroup `
    --query principalId -o tsv

Write-Host "ℹ Principal ID: $PrincipalId" -ForegroundColor Blue

# ---------------------------------------------------------------------------
# Grant Key Vault secret access (get + list) — idempotent
# ---------------------------------------------------------------------------
Write-Host "ℹ Granting Key Vault secret access to backend identity..." -ForegroundColor Blue
$PolicyResult = az keyvault set-policy `
    --name $KeyVaultName `
    --resource-group $ResourceGroup `
    --object-id $PrincipalId `
    --secret-permissions get list `
    --output none 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Key Vault access policy set for '$BackendIdentityName'" -ForegroundColor Green
} else {
    Write-Host "⚠ Failed to set KV access policy — may lack permissions; continuing" -ForegroundColor Yellow
    Write-Host "⚠ Container Apps may fail to read KV secrets if policy hasn't propagated" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Poll ARM control plane until the access policy entry is confirmed.
#
# WHY POLL INSTEAD OF SLEEP
# We cannot verify KV *data-plane* propagation from outside the managed
# identity — that would require calling the KV REST endpoint as id-backend-*,
# which the script cannot do (it runs as the GitHub Actions SP). However,
# polling the ARM control plane (az keyvault show → accessPolicies) confirms
# that Azure has recorded the policy write. Once ARM confirms it, the KV data
# plane typically propagates within 5–10 seconds. A short fixed buffer after
# ARM confirmation is therefore far more reliable than a blind sleep, which
# starts the timer before ARM has even processed the write.
# ---------------------------------------------------------------------------
Write-Host "ℹ Polling ARM control plane until access policy is confirmed..." -ForegroundColor Blue
$MaxWait = 120
$Interval = 10
$Elapsed = 0
$Confirmed = $false

while ($Elapsed -lt $MaxWait) {
    $PolicyCheck = az keyvault show `
        --name $KeyVaultName `
        --resource-group $ResourceGroup `
        --query "properties.accessPolicies[?objectId=='$PrincipalId'].objectId" `
        -o tsv 2>$null

    if ($PolicyCheck) {
        Write-Host "✓ Access policy confirmed in ARM control plane (${Elapsed}s elapsed)" -ForegroundColor Green
        $Confirmed = $true
        break
    }

    Write-Host "  Policy not yet visible in ARM (${Elapsed}s elapsed) — retrying in ${Interval}s..." -ForegroundColor Gray
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval
}

if (-not $Confirmed) {
    Write-Host "⚠ Access policy not confirmed after ${MaxWait}s — proceeding anyway" -ForegroundColor Yellow
    Write-Host "⚠ Container Apps may fail to read KV secrets if data-plane hasn't propagated" -ForegroundColor Yellow
}

# Short fixed buffer after ARM confirmation so KV data plane can sync.
# ARM confirmation → data plane propagation is typically < 10 seconds.
Write-Host "ℹ Waiting 15 seconds for KV data plane to sync after ARM confirmation..." -ForegroundColor Blue
Start-Sleep -Seconds 15
Write-Host "✓ Identity pre-provisioning complete" -ForegroundColor Green
