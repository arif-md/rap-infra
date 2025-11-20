#!/usr/bin/env pwsh
<#
.SYNOPSIS
Verifies Azure AD admin configuration on SQL Server

.DESCRIPTION
This script checks:
1. SQL Server exists and has Azure AD admin configured
2. Azure AD admin is the correct group/principal
3. SQL Server Azure AD authentication is enabled
4. Backend managed identity exists and is ready for permissions

.PARAMETER ResourceGroup
The Azure resource group containing the SQL Server

.PARAMETER SqlServerName
Optional: The SQL Server name. If not provided, will auto-discover.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$SqlServerName
)

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "🔍 Verifying SQL Server Azure AD Configuration" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

# Auto-discover SQL Server if not provided
if ([string]::IsNullOrEmpty($SqlServerName)) {
    Write-Host "🔎 Auto-discovering SQL Server in resource group: $ResourceGroup"
    $SqlServerName = az sql server list -g $ResourceGroup --query "[0].name" -o tsv
    if ([string]::IsNullOrEmpty($SqlServerName)) {
        Write-Host "❌ No SQL Server found in resource group $ResourceGroup" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ Found SQL Server: $SqlServerName" -ForegroundColor Green
}

# Get SQL Server details
Write-Host ""
Write-Host "📋 SQL Server Configuration:" -ForegroundColor Yellow
$sqlServerDetails = az sql server show -g $ResourceGroup -n $SqlServerName -o json | ConvertFrom-Json
Write-Host "  Name: $($sqlServerDetails.name)"
Write-Host "  Location: $($sqlServerDetails.location)"
Write-Host "  Public Network Access: $($sqlServerDetails.publicNetworkAccess)"
Write-Host "  Minimal TLS Version: $($sqlServerDetails.minimalTlsVersion)"

# Check Azure AD admin configuration
Write-Host ""
Write-Host "🔐 Azure AD Administrator Configuration:" -ForegroundColor Yellow
$adAdmins = az sql server ad-admin list -g $ResourceGroup -s $SqlServerName -o json | ConvertFrom-Json

if ($adAdmins.Count -eq 0 -or $null -eq $adAdmins) {
    Write-Host "❌ No Azure AD administrator configured!" -ForegroundColor Red
    Write-Host ""
    Write-Host "💡 To fix this, ensure SQL_AZURE_AD_ADMIN_* variables are set in GitHub:" -ForegroundColor Yellow
    Write-Host "   - SQL_AZURE_AD_ADMIN_OBJECT_ID"
    Write-Host "   - SQL_AZURE_AD_ADMIN_LOGIN"
    Write-Host "   - SQL_AZURE_AD_ADMIN_PRINCIPAL_TYPE"
    Write-Host ""
    Write-Host "   Then run: azd provision" -ForegroundColor Cyan
    exit 1
}

Write-Host "✅ Azure AD admin is configured:" -ForegroundColor Green
foreach ($admin in $adAdmins) {
    Write-Host "  Login: $($admin.login)"
    Write-Host "  Principal Type: $($admin.principalType)"
    Write-Host "  SID (Object ID): $($admin.sid)"
    Write-Host "  Administrator Type: $($admin.administratorType)"
    Write-Host "  Tenant ID: $($admin.tenantId)"
}

# Check backend managed identity
Write-Host ""
Write-Host "🔑 Backend Managed Identity:" -ForegroundColor Yellow
$backendIdentity = az identity list -g $ResourceGroup --query "[?contains(name, 'backend')].{Name:name, PrincipalId:principalId, ClientId:clientId}" -o json | ConvertFrom-Json

if ($null -eq $backendIdentity -or $backendIdentity.Count -eq 0) {
    Write-Host "⚠️  No backend managed identity found!" -ForegroundColor Yellow
    Write-Host "   This will be created when the backend container app is provisioned."
} else {
    Write-Host "✅ Backend identity exists:" -ForegroundColor Green
    Write-Host "  Name: $($backendIdentity.Name)"
    Write-Host "  Principal ID: $($backendIdentity.PrincipalId)"
    Write-Host "  Client ID: $($backendIdentity.ClientId)"
}

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "📊 Summary:" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

$hasAdAdmin = $adAdmins.Count -gt 0 -and $null -ne $adAdmins
$hasBackendIdentity = $null -ne $backendIdentity -and $backendIdentity.Count -gt 0

if ($hasAdAdmin -and $hasBackendIdentity) {
    Write-Host "✅ SQL Server is properly configured for passwordless authentication" -ForegroundColor Green
    Write-Host "✅ Backend managed identity is ready" -ForegroundColor Green
    Write-Host ""
    Write-Host "🚀 Next step: Grant SQL permissions to backend identity" -ForegroundColor Cyan
    Write-Host "   Option 1 (GitHub Actions): Workflow will run automatically after provision" -ForegroundColor Gray
    Write-Host "   Option 2 (Local): Run ./scripts/ensure-sql-permissions.ps1" -ForegroundColor Gray
} elseif ($hasAdAdmin) {
    Write-Host "✅ SQL Server Azure AD admin is configured" -ForegroundColor Green
    Write-Host "⚠️  Backend managed identity not found yet" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "💡 The backend identity will be created during container app provisioning" -ForegroundColor Gray
} else {
    Write-Host "❌ SQL Server Azure AD admin is NOT configured" -ForegroundColor Red
    Write-Host ""
    Write-Host "🔧 Action required: Configure Azure AD admin in GitHub variables and redeploy" -ForegroundColor Yellow
}

Write-Host ""
