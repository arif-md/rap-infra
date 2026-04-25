#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Runs all pre-provision hooks for Azure deployment
.DESCRIPTION
    Orchestrates the execution of all pre-provision scripts in the correct order.
    Fails fast if any script returns a non-zero exit code.
#>

param()

$ErrorActionPreference = "Stop"

Write-Host "=== Running Pre-Provision Hooks ===" -ForegroundColor Cyan

# Key Vault Setup - ensures Key Vault exists before deployment
Write-Host "`n[1/7] Setting up Key Vault..." -ForegroundColor Yellow
& "$PSScriptRoot\ensure-keyvault.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Key Vault setup failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Key Vault setup completed" -ForegroundColor Green

# Resolve container images
Write-Host "`n[2/7] Resolving container images..." -ForegroundColor Yellow
& "$PSScriptRoot\resolve-images.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Image resolution failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Image resolution completed" -ForegroundColor Green

# Validate ACR binding
Write-Host "`n[3/7] Validating ACR binding..." -ForegroundColor Yellow
& "$PSScriptRoot\validate-acr-binding.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ ACR validation failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ ACR validation completed" -ForegroundColor Green

# Ensure ACR exists
Write-Host "`n[4/7] Ensuring ACR exists..." -ForegroundColor Yellow
& "$PSScriptRoot\ensure-acr.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ ACR setup failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ ACR setup completed" -ForegroundColor Green

# Ensure DNS Zone exists (survives azd down/up — not in deployment stack)
Write-Host "`n[5/7] Ensuring DNS Zone exists..." -ForegroundColor Yellow
& "$PSScriptRoot\ensure-dns-zone.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ DNS Zone setup failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ DNS Zone setup completed" -ForegroundColor Green

# Purge any soft-deleted App Config store (Standard SKU + VNet only)
Write-Host "`n[6/7] Checking for soft-deleted App Config stores..." -ForegroundColor Yellow
& "$PSScriptRoot\recover-or-purge-appconfig.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ App Config purge check failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ App Config purge check completed" -ForegroundColor Green

# Remove stranded CAE that exists without VNet config (prevents ManagedEnvironmentCannotAddVnetToExistingEnv)
Write-Host "`n[7/7] Checking for stranded Container Apps Environment..." -ForegroundColor Yellow
& "$PSScriptRoot\ensure-cae-vnet.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ CAE VNet guard failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ CAE VNet guard completed" -ForegroundColor Green

Write-Host "`n=== Pre-Provision Hooks Completed Successfully ===" -ForegroundColor Cyan
exit 0
