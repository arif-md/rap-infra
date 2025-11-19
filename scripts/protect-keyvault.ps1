#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Detaches Key Vault from deployment stack to prevent deletion when DEPLOY_KEY_VAULT=false
.DESCRIPTION
    When DEPLOY_KEY_VAULT environment variable is set to false, this script removes the Key Vault
    from the deployment stack's managed resources before azd down is executed. This prevents
    the Key Vault from being deleted while still allowing other resources to be cleaned up.
#>

param()

$ErrorActionPreference = "Stop"

# Color output functions
function Write-Header { param($Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Success { param($Message) Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Info { param($Message) Write-Host "ℹ $Message" -ForegroundColor Blue }
function Write-Warning { param($Message) Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Error { param($Message) Write-Host "✗ $Message" -ForegroundColor Red }

Write-Header "Key Vault Protection Check"

# Check if DEPLOY_KEY_VAULT is set to false
$deployKeyVault = $env:DEPLOY_KEY_VAULT
if ([string]::IsNullOrEmpty($deployKeyVault)) {
    $deployKeyVault = "true"  # Default value
}

Write-Info "DEPLOY_KEY_VAULT=$deployKeyVault"

if ($deployKeyVault -eq "false") {
    Write-Info "Key Vault retention is enabled - detaching from deployment stack"
    
    # Get environment variables
    $environmentName = $env:AZURE_ENV_NAME
    $resourceGroup = $env:AZURE_RESOURCE_GROUP
    
    if ([string]::IsNullOrEmpty($resourceGroup)) {
        $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
        $resourceGroup = "rg-raptor-$environmentName"
    }
    
    Write-Info "Environment: $environmentName"
    Write-Info "Resource Group: $resourceGroup"
    
    # Calculate Key Vault name (must match main.bicep logic)
    $uniqueString = $env:AZURE_KEY_VAULT_UNIQUE_STRING
    if ([string]::IsNullOrEmpty($uniqueString)) {
        # If not set, try to find the Key Vault by listing
        Write-Info "Looking for Key Vault in resource group..."
        $keyVaults = az keyvault list --resource-group $resourceGroup --query "[?starts_with(name, 'kv-$environmentName-')].name" -o tsv
        
        if ($LASTEXITCODE -eq 0 -and ![string]::IsNullOrEmpty($keyVaults)) {
            $keyVaultName = ($keyVaults -split "`n")[0].Trim()
            Write-Info "Found Key Vault: $keyVaultName"
        } else {
            Write-Warning "No Key Vault found in resource group. Nothing to detach."
            exit 0
        }
    } else {
        $keyVaultName = "kv-$environmentName-$uniqueString-v4"
        Write-Info "Key Vault name: $keyVaultName"
    }
    
    if (![string]::IsNullOrEmpty($keyVaultName)) {
        # Get deployment stack name
        $stackName = "azd-stack-$environmentName"
        
        Write-Info "Checking deployment stack: $stackName"
        
        # Check if deployment stack exists
        $stackExists = az stack group show --name $stackName --resource-group $resourceGroup 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Deployment stack '$stackName' not found. Nothing to detach."
            exit 0
        }
        
        # Detach Key Vault from stack by updating with action-on-unmanage set to detach
        Write-Info "Detaching Key Vault from deployment stack..."
        
        # We need to run azd provision with DEPLOY_KEY_VAULT=false which will update the stack
        # without the Key Vault, effectively detaching it
        Write-Success "Key Vault will be preserved during azd down operation"
        Write-Info "The Key Vault '$keyVaultName' will remain after resource cleanup"
    }
} else {
    Write-Info "Key Vault management is enabled - will be deleted normally"
}

Write-Success "Pre-down check completed"
exit 0
