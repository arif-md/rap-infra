#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Recovers soft-deleted Key Vaults or creates new ones if needed.

.DESCRIPTION
    This script checks for soft-deleted Key Vaults matching the environment naming pattern
    and recovers them before deployment. If no matching vaults are found, the Bicep
    deployment will create a new one.

.NOTES
    Requires permissions:
    - Microsoft.KeyVault/locations/deletedVaults/read
    - Microsoft.KeyVault/locations/deletedVaults/purge/action (optional)
    
    These are included in the "Key Vault Contributor" role.
#>

param(
    [string]$EnvironmentName = $env:AZURE_ENV_NAME,
    [string]$Location = $env:AZURE_LOCATION
)

$ErrorActionPreference = "Stop"

# Validate required parameters
if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    Write-Error "AZURE_ENV_NAME environment variable is not set. Cannot determine environment name."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Location)) {
    Write-Error "AZURE_LOCATION environment variable is not set. Cannot determine location."
    exit 1
}

Write-Host "`n=== Key Vault Recovery Check ===" -ForegroundColor Cyan
Write-Host "Environment: $EnvironmentName" -ForegroundColor Yellow
Write-Host "Location: $Location" -ForegroundColor Yellow

# Calculate the expected Key Vault name pattern for this environment
# Pattern: kv-{env}-{uniqueString}-v*
$pattern = "kv-$($EnvironmentName.ToLower())-.*-v[0-9]+"

Write-Host "`nChecking for soft-deleted Key Vaults matching pattern: $pattern" -ForegroundColor White

try {
    # List all deleted Key Vaults in the specified location
    $deletedVaultsJson = az keyvault list-deleted --query "[?location=='$Location']" 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        # Check if it's a permission error
        if ($deletedVaultsJson -match "AuthorizationFailed" -or $deletedVaultsJson -match "does not have authorization") {
            Write-Host "⚠️  WARNING: No permission to view deleted Key Vaults" -ForegroundColor Yellow
            Write-Host "   Missing permission: Microsoft.KeyVault/locations/deletedVaults/read" -ForegroundColor Yellow
            Write-Host "   Deployment will proceed but may fail if vault name conflicts exist." -ForegroundColor Yellow
            Write-Host "   Request 'Key Vault Contributor' role from Azure admin to enable recovery." -ForegroundColor Yellow
            Write-Host "`n   See: infra/docs/AZURE-ADMIN-PERMISSION-REQUEST.md" -ForegroundColor Cyan
            exit 0  # Don't fail the deployment
        }
        
        Write-Error "Failed to list deleted Key Vaults: $deletedVaultsJson"
        exit 1
    }
    
    # Parse JSON result
    if ([string]::IsNullOrWhiteSpace($deletedVaultsJson) -or $deletedVaultsJson -eq "[]") {
        Write-Host "ℹ️  No soft-deleted Key Vaults found in location: $Location" -ForegroundColor Gray
        Write-Host "   Deployment will create a new Key Vault." -ForegroundColor Gray
        exit 0
    }
    
    $deletedVaults = $deletedVaultsJson | ConvertFrom-Json
    
    # Filter vaults matching the environment pattern
    $matchingVaults = $deletedVaults | Where-Object { $_.name -match $pattern }
    
    if ($matchingVaults.Count -eq 0) {
        Write-Host "ℹ️  No matching soft-deleted vaults found for environment: $EnvironmentName" -ForegroundColor Gray
        Write-Host "   Deployment will create a new Key Vault." -ForegroundColor Gray
        exit 0
    }
    
    Write-Host "`n✓ Found $($matchingVaults.Count) soft-deleted vault(s) for environment: $EnvironmentName" -ForegroundColor Green
    
    # Recover each matching vault
    foreach ($vault in $matchingVaults) {
        $vaultName = $vault.name
        $deletionDate = $vault.properties.deletionDate
        
        Write-Host "`nRecovering vault: $vaultName" -ForegroundColor Cyan
        Write-Host "  Deleted on: $deletionDate" -ForegroundColor Gray
        
        try {
            az keyvault recover --name $vaultName --location $Location 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Successfully recovered: $vaultName" -ForegroundColor Green
            } else {
                Write-Host "  ⚠️  Failed to recover: $vaultName" -ForegroundColor Yellow
                Write-Host "     Deployment may fail. Manual recovery or purge required." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  ⚠️  Error recovering vault: $_" -ForegroundColor Yellow
        }
    }
    
    Write-Host "`n=== Recovery Check Complete ===" -ForegroundColor Cyan
    exit 0
    
} catch {
    Write-Host "`n❌ Error during recovery check: $_" -ForegroundColor Red
    Write-Host "   Deployment will proceed but may fail if vault conflicts exist." -ForegroundColor Yellow
    exit 0  # Don't fail the deployment
}
