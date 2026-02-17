#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Ensures Key Vault exists before deployment (creates if missing)
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
    
    # Create required secrets if provided in environment
    $oidcSecret = $env:OIDC_CLIENT_SECRET
    $jwtSecret = $env:JWT_SECRET
    $aadClientSecret = $env:AZURE_AD_CLIENT_SECRET
    
    if (![string]::IsNullOrEmpty($oidcSecret)) {
        Write-Info "Creating oidc-client-secret..."
        az keyvault secret set --vault-name $keyVaultName --name "oidc-client-secret" --value $oidcSecret | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Secret 'oidc-client-secret' created"
        } else {
            Write-Warning "Failed to create oidc-client-secret"
        }
    }
    
    if (![string]::IsNullOrEmpty($jwtSecret)) {
        Write-Info "Creating jwt-secret..."
        az keyvault secret set --vault-name $keyVaultName --name "jwt-secret" --value $jwtSecret | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Secret 'jwt-secret' created"
        } else {
            Write-Warning "Failed to create jwt-secret"
        }
    }
    
    if (![string]::IsNullOrEmpty($aadClientSecret)) {
        Write-Info "Creating aad-client-secret..."
        az keyvault secret set --vault-name $keyVaultName --name "aad-client-secret" --value $aadClientSecret | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Secret 'aad-client-secret' created"
        } else {
            Write-Warning "Failed to create aad-client-secret"
        }
    }
    
    exit 0
} else {
    Write-Error "Failed to create Key Vault"
    Write-Error $createResult
    exit 1
}
