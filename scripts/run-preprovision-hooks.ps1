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
Write-Host "`n[1/4] Setting up Key Vault..." -ForegroundColor Yellow
& "$PSScriptRoot\ensure-keyvault.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Key Vault setup failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Key Vault setup completed" -ForegroundColor Green

# Resolve container images
Write-Host "`n[2/4] Resolving container images..." -ForegroundColor Yellow
& "$PSScriptRoot\resolve-images.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Image resolution failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Image resolution completed" -ForegroundColor Green

# Validate ACR binding
Write-Host "`n[3/4] Validating ACR binding..." -ForegroundColor Yellow
& "$PSScriptRoot\validate-acr-binding.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ ACR validation failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ ACR validation completed" -ForegroundColor Green

# Ensure ACR exists
Write-Host "`n[4/4] Ensuring ACR exists..." -ForegroundColor Yellow
& "$PSScriptRoot\ensure-acr.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ ACR setup failed!" -ForegroundColor Red
    exit 1
}
Write-Host "✓ ACR setup completed" -ForegroundColor Green

Write-Host "`n=== Pre-Provision Hooks Completed Successfully ===" -ForegroundColor Cyan
exit 0
