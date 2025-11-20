#!/usr/bin/env pwsh
<#
.SYNOPSIS
Grants Directory Readers role to SQL Server's managed identity

.DESCRIPTION
This script allows SQL Server to expand Azure AD group membership when authenticating users.
Required when using an Azure AD Group as the SQL Server administrator.

.NOTES
Requires: RoleManagement.ReadWrite.Directory permission or Privileged Role Administrator role
#>

param()

$ErrorActionPreference = "Stop"

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "🔐 Granting Directory Readers role to SQL Server" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

# Get SQL Server details from azd environment
$resourceGroup = azd env get-value AZURE_RESOURCE_GROUP
$sqlServerName = azd env get-value sqlServerName 2>$null

if ([string]::IsNullOrEmpty($sqlServerName)) {
    Write-Host "⚠️  SQL Server name not found in azd environment, attempting auto-discovery..." -ForegroundColor Yellow
    $sqlServerName = az sql server list -g $resourceGroup --query "[0].name" -o tsv
    
    if ([string]::IsNullOrEmpty($sqlServerName)) {
        Write-Host "❌ No SQL Server found in resource group $resourceGroup" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ Found SQL Server: $sqlServerName" -ForegroundColor Green
}

# Get SQL Server managed identity principal ID
Write-Host ""
Write-Host "📋 Retrieving SQL Server managed identity..." -ForegroundColor Yellow
$identityPrincipalId = az sql server show `
    -g $resourceGroup `
    -n $sqlServerName `
    --query "identity.principalId" -o tsv

if ([string]::IsNullOrEmpty($identityPrincipalId) -or $identityPrincipalId -eq "null") {
    Write-Host "❌ SQL Server does not have a system-assigned managed identity" -ForegroundColor Red
    Write-Host "💡 The Bicep template should enable identity: { type: 'SystemAssigned' }" -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ SQL Server managed identity: $identityPrincipalId" -ForegroundColor Green

# Get Directory Readers role ID
Write-Host ""
Write-Host "🔍 Looking up Directory Readers role..." -ForegroundColor Yellow
$directoryReadersRoleId = az rest `
    --method GET `
    --uri 'https://graph.microsoft.com/v1.0/directoryRoles' `
    --query "value[?displayName=='Directory Readers'].id | [0]" -o tsv

if ([string]::IsNullOrEmpty($directoryReadersRoleId)) {
    Write-Host "❌ Directory Readers role not found" -ForegroundColor Red
    Write-Host "💡 The role may need to be activated first" -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ Directory Readers role ID: $directoryReadersRoleId" -ForegroundColor Green

# Check if already a member
Write-Host ""
Write-Host "🔍 Checking if SQL Server identity is already a Directory Reader..." -ForegroundColor Yellow
try {
    $isMember = az rest `
        --method GET `
        --uri "https://graph.microsoft.com/v1.0/directoryRoles/$directoryReadersRoleId/members" `
        --query "value[?id=='$identityPrincipalId'].id | [0]" -o tsv 2>$null
    
    if (-not [string]::IsNullOrEmpty($isMember)) {
        Write-Host "✅ SQL Server identity is already a member of Directory Readers role" -ForegroundColor Green
        Write-Host "   No action needed."
        exit 0
    }
} catch {
    # Continue to grant if check fails
}

# Grant Directory Readers role
Write-Host ""
Write-Host "➕ Adding SQL Server identity to Directory Readers role..." -ForegroundColor Yellow

# Create JSON body
$body = @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$identityPrincipalId"
} | ConvertTo-Json

$tempFile = Join-Path $env:TEMP "grant-directory-readers.json"
$body | Out-File -FilePath $tempFile -Encoding UTF8

try {
    # Add to role
    az rest `
        --method POST `
        --uri "https://graph.microsoft.com/v1.0/directoryRoles/$directoryReadersRoleId/members/`$ref" `
        --body "@$tempFile" `
        --headers "Content-Type=application/json" 2>&1 | Tee-Object -Variable result
    
    if ($result -match "Forbidden|Authorization_RequestDenied") {
        Write-Host ""
        Write-Host "❌ Insufficient permissions to grant Directory Readers role" -ForegroundColor Red
        Write-Host ""
        Write-Host "📋 Required permission: RoleManagement.ReadWrite.Directory or Privileged Role Administrator" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "🔧 Manual steps to fix:" -ForegroundColor Yellow
        Write-Host "   1. Go to Azure Portal → Azure Active Directory → Roles and administrators"
        Write-Host "   2. Select 'Directory Readers' role"
        Write-Host "   3. Click 'Add assignment'"
        Write-Host "   4. Search for and select: $sqlServerName"
        Write-Host "   5. Click 'Add'"
        Write-Host ""
        Write-Host "⚠️  Continuing without Directory Readers role..." -ForegroundColor Yellow
        Write-Host "   Azure AD group admin will NOT work for service principals."
        Write-Host "   Consider using service principal directly as Azure AD admin instead."
        exit 0  # Don't fail the deployment
    } elseif ($result -match "already exists|already a member") {
        Write-Host "✅ SQL Server identity is already a member (confirmed)" -ForegroundColor Green
    } else {
        Write-Host "✅ Successfully granted Directory Readers role to SQL Server identity" -ForegroundColor Green
    }
} catch {
    Write-Host "⚠️  Error granting Directory Readers role: $_" -ForegroundColor Yellow
    Write-Host "   Continuing anyway..." -ForegroundColor Yellow
    exit 0
} finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "✅ Directory Readers configuration complete" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
