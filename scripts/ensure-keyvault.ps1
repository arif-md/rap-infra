#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Ensures Key Vault exists before deployment (creates if missing)
    and ensures required secrets are present (creates/updates if missing).
.DESCRIPTION
    This script checks if the Key Vault exists in the resource group.
    If it doesn't exist, it creates it with the appropriate configuration.
    This prevents soft-delete conflicts and allows Key Vault to persist across azd down/up cycles.
#>

param()

$ErrorActionPreference = "Stop"

# Color output functions
function Write-Header { param($Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Success { param($Message) Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Info { param($Message) Write-Host "ℹ $Message" -ForegroundColor Blue }
function Write-Warning { param($Message) Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Error { param($Message) Write-Host "✗ $Message" -ForegroundColor Red }

###############################################################################
# Ensure a single secret exists in Key Vault (CREATE ONLY — never overwrites).
#
# Key Vault is the source of truth for secrets after initial seeding. If a
# secret already exists, this function skips it regardless of value. This
# preserves any rotation done directly in KV without being overwritten on the
# next 'azd provision' run.
#
# Rotation procedure:
#   1. Update the secret value directly in KV (Portal / az keyvault secret set)
#   2. Run 'azd provision' (or az containerapp revision copy) to create a new
#      Container App revision — the new revision fetches the latest KV value
#   3. The GitHub environment variable does NOT need to be updated for rotation
###############################################################################
function Ensure-Secret {
    param(
        [string]$VaultName,
        [string]$SecretName,
        [string]$SecretValue
    )
    
    if ([string]::IsNullOrEmpty($SecretValue)) { return }
    
    # Check if secret already exists — if it does, KV is the source of truth
    $existingValue = az keyvault secret show --vault-name $VaultName --name $SecretName --query value -o tsv 2>$null
    
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($existingValue)) {
        Write-Success "Secret '$SecretName' already exists — skipping (KV is source of truth)"
        return
    }
    
    Write-Info "Creating secret '$SecretName'..."
    az keyvault secret set --vault-name $VaultName --name $SecretName --value $SecretValue | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Secret '$SecretName' created"
    } else {
        Write-Warning "Failed to create secret '$SecretName'"
    }
}

###############################################################################
# Ensure all required secrets are present in Key Vault
###############################################################################
function Ensure-Secrets {
    param([string]$VaultName)
    
    Write-Header "Ensuring Key Vault Secrets"
    
    Ensure-Secret -VaultName $VaultName -SecretName "oidc-client-secret" -SecretValue $env:OIDC_CLIENT_SECRET
    Ensure-Secret -VaultName $VaultName -SecretName "jwt-secret" -SecretValue $env:JWT_SECRET
    Ensure-Secret -VaultName $VaultName -SecretName "aad-client-secret" -SecretValue $env:AZURE_AD_CLIENT_SECRET
}

Write-Header "Key Vault Setup Check"

# Get environment variables
$environmentName = $env:AZURE_ENV_NAME
$location = $env:AZURE_LOCATION
$resourceGroup = $env:AZURE_RESOURCE_GROUP
$keyVaultName = $env:KEY_VAULT_NAME

if ([string]::IsNullOrEmpty($environmentName)) {
    Write-Error "AZURE_ENV_NAME environment variable is not set"
    exit 1
}

if ([string]::IsNullOrEmpty($location)) {
    Write-Error "AZURE_LOCATION environment variable is not set"
    exit 1
}

if ([string]::IsNullOrEmpty($resourceGroup)) {
    $resourceGroup = "rg-raptor-$environmentName"
    Write-Info "AZURE_RESOURCE_GROUP not set, using default: $resourceGroup"
}

# Calculate Key Vault name if not provided
if ([string]::IsNullOrEmpty($keyVaultName)) {
    # Calculate using the same logic as main.bicep
    # Format: kv-{environmentName}-{uniqueString}-v10
    Write-Info "Calculating Key Vault name..."
    
    # Get abbreviations
    $infraDir = Split-Path -Parent $PSScriptRoot
    $abbreviationsPath = Join-Path $infraDir "abbreviations.json"
    $abbrs = Get-Content $abbreviationsPath | ConvertFrom-Json
    $kvPrefix = $abbrs.keyVaultVaults
    
    # Calculate uniqueString using a simple hash-based approach
    # Note: This approximates Bicep's uniqueString() but may not match exactly
    # If KEY_VAULT_NAME environment variable is set, it will override this calculation
    $subscriptionId = az account show --query id -o tsv
    $uniqueStringInput = "$subscriptionId$environmentName"
    
    # Use .NET's hash function to generate a unique string
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($uniqueStringInput))
    $uniqueString = [System.BitConverter]::ToString($hash).Replace("-", "").Substring(0, 13).ToLower()
    
    $resourceToken = "$environmentName-$uniqueString".ToLower()
    $keyVaultName = "$kvPrefix$resourceToken-v10"
    
    Write-Info "Calculated Key Vault name: $keyVaultName"
    Write-Info "Exporting KEY_VAULT_NAME to azd environment for Bicep consistency..."
    azd env set KEY_VAULT_NAME $keyVaultName | Out-Null
} else {
    Write-Info "Using provided Key Vault name: $keyVaultName"
}

# Export the Key Vault name to azd environment variables
# This ensures main.bicep uses the same name as the script
Write-Info "Setting KEY_VAULT_NAME=$keyVaultName in azd environment"
azd env set KEY_VAULT_NAME $keyVaultName | Out-Null

# Check if Key Vault exists
Write-Info "Checking if Key Vault exists..."
$vaultExists = az keyvault show --name $keyVaultName --resource-group $resourceGroup 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "Key Vault '$keyVaultName' already exists"

    # Enforce public network access — must be Enabled when VNet is not used.
    # Spring Cloud Azure App Config resolves KV references via the public endpoint
    # at container startup. 'Disabled' causes startup failures even when the
    # managed identity has the correct access policy.
    $vnetEnabled = azd env get-value ENABLE_VNET_INTEGRATION 2>$null
    if ($vnetEnabled -ne "true") {
        $currentPna = az keyvault show --name $keyVaultName --resource-group $resourceGroup --query properties.publicNetworkAccess -o tsv 2>$null
        if ($currentPna -ne "Enabled") {
            Write-Info "Key Vault public network access is '$currentPna' — re-enabling (required for non-VNet deployments)..."
            az keyvault update --name $keyVaultName --resource-group $resourceGroup --public-network-access Enabled --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Success "Public network access re-enabled" }
            else { Write-Warning "Could not update public network access — check manually" }
        } else {
            Write-Success "Key Vault public network access is already Enabled"
        }
    }

    Ensure-Secrets -VaultName $keyVaultName
    exit 0
}

# Check if it's in soft-deleted state
Write-Info "Checking for soft-deleted vault..."
$deletedVault = az keyvault show-deleted --name $keyVaultName 2>&1

if ($LASTEXITCODE -eq 0 -and ![string]::IsNullOrEmpty($deletedVault)) {
    Write-Warning "Key Vault '$keyVaultName' exists in soft-deleted state"
    Write-Info "Attempting to recover..."
    
    $recovery = az keyvault recover --name $keyVaultName --location $location 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Key Vault recovered successfully"
        Ensure-Secrets -VaultName $keyVaultName
        exit 0
    } else {
        Write-Warning "Could not recover Key Vault (may lack permissions)"
        Write-Info "Either wait for auto-purge (7-90 days) or ask admin to purge it"
        Write-Info "Or set KEY_VAULT_NAME to a different name in azd environment"
        exit 1
    }
}

# Create Key Vault
Write-Info "Creating Key Vault '$keyVaultName'..."

$isProduction = $environmentName -eq "prod" -or $environmentName -eq "production"
$retentionDays = if ($isProduction) { 90 } else { 7 }

Write-Info "Environment: $environmentName (retention: $retentionDays days)"

$createResult = az keyvault create `
    --name $keyVaultName `
    --resource-group $resourceGroup `
    --location $location `
    --retention-days $retentionDays `
    --enable-purge-protection true `
    --enable-rbac-authorization false `
    --public-network-access Enabled `
    2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "Key Vault created successfully: $keyVaultName"
    
    # Grant the service principal (ourselves) access to manage secrets
    Write-Info "Granting access policies to service principal..."
    $spObjectId = az account show --query user.name -o tsv
    
    # If running as service principal, get the object ID
    $accountType = az account show --query user.type -o tsv
    if ($accountType -eq "servicePrincipal") {
        $spObjectId = az account show --query user.name -o tsv
    }
    
    az keyvault set-policy `
        --name $keyVaultName `
        --object-id $spObjectId `
        --secret-permissions get list set delete `
        | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Access policies granted"
    } else {
        Write-Warning "Failed to set access policies, but continuing..."
    }
    
    # Ensure all required secrets exist
    Ensure-Secrets -VaultName $keyVaultName
    
    exit 0
} else {
    Write-Error "Failed to create Key Vault"
    Write-Error $createResult
    exit 1
}
