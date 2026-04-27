#!/usr/bin/env pwsh
# =============================================================================
# fix-sql-permissions.ps1 — Emergency: grant SQL permissions to managed identities
# =============================================================================
# Run this when the SQL database was recreated (after azd down/up) but the
# sql-setup ACI was a NO-OP because managed identity client IDs did not change.
#
# Uses Azure AD token auth (az login) — no SQL admin password needed.
#
# Prerequisites:
#   - Azure CLI authenticated (az login)
#   - Run from infra/ directory (azd env readable)
#   - SqlServer PowerShell module (auto-installed if missing)
#
# After this script succeeds, the ensure-sql-setup.ps1 preprovision hook will
# automatically set FORCE_SQL_SETUP_TAG on the next azd up to keep Bicep in sync.
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host "==> fix-sql-permissions.ps1 — granting SQL permissions to managed identities" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# Helper: read azd env value, return $null if key missing (never throws)
# azd env get-value writes "ERROR: key not found..." to stdout when missing,
# so we must check the exit code rather than trusting the string content.
# --------------------------------------------------------------------------
function Get-AzdEnvValue([string]$key) {
    $val = azd env get-value $key 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($val | Out-String).Trim()
}

# --------------------------------------------------------------------------
# Collect values — azd env first, fall back to az CLI discovery
# --------------------------------------------------------------------------
$rg       = Get-AzdEnvValue "AZURE_RESOURCE_GROUP"
$envName  = Get-AzdEnvValue "AZURE_ENV_NAME"
if (-not $rg) { Write-Error "AZURE_RESOURCE_GROUP not set. Run from infra/ directory."; exit 1 }

# SQL_SERVER_FQDN / SQL_DATABASE_NAME are azd *outputs* — only present after a
# successful azd up. Fall back to az CLI discovery when they are absent.
$sqlFqdn = Get-AzdEnvValue "SQL_SERVER_FQDN"
$sqlDb   = Get-AzdEnvValue "SQL_DATABASE_NAME"

if (-not $sqlFqdn -or -not $sqlDb) {
    Write-Host "  SQL Server / Database not in azd env — discovering via az CLI..." -ForegroundColor Yellow
    $sqlServerShortName = az sql server list --resource-group $rg --query "[0].name" -o tsv 2>$null
    if (-not $sqlServerShortName) {
        Write-Error "No SQL server found in resource group '$rg'. Has azd up been run?"
        exit 1
    }
    if (-not $sqlFqdn) {
        $sqlFqdn = az sql server show --resource-group $rg --name $sqlServerShortName --query "fullyQualifiedDomainName" -o tsv 2>$null
    }
    if (-not $sqlDb) {
        # Try canonical name first; fall back to listing
        if ($envName) {
            $candidateDb = "sqldb-raptor-$envName"
            $dbExists = az sql db show --resource-group $rg --server $sqlServerShortName --name $candidateDb --query name -o tsv 2>$null
            if ($dbExists) { $sqlDb = $candidateDb }
        }
        if (-not $sqlDb) {
            $sqlDb = az sql db list --resource-group $rg --server $sqlServerShortName --query "[?name!='master'].name | [0]" -o tsv 2>$null
        }
    }
}

if (-not $sqlFqdn) { Write-Error "Could not resolve SQL server FQDN."; exit 1 }
if (-not $sqlDb)   { Write-Error "Could not resolve SQL database name."; exit 1 }

$beMiName   = Get-AzdEnvValue "BACKEND_IDENTITY_NAME"
$procMiName = Get-AzdEnvValue "PROCESSES_IDENTITY_NAME"
if (-not $beMiName)   { Write-Error "BACKEND_IDENTITY_NAME not set. Run ensure-identities.ps1 first."; exit 1 }
if (-not $procMiName) { Write-Error "PROCESSES_IDENTITY_NAME not set. Run ensure-identities.ps1 first."; exit 1 }

Write-Host "  SQL Server  : $sqlFqdn" -ForegroundColor Gray
Write-Host "  SQL Database: $sqlDb"   -ForegroundColor Gray

# --------------------------------------------------------------------------
# Resolve managed identity clientIds from the identity resources
# --------------------------------------------------------------------------
Write-Host "  Resolving managed identity clientIds..." -ForegroundColor Gray

$beClientId = az identity show --resource-group $rg --name $beMiName --query clientId -o tsv 2>$null
if (-not $beClientId) { Write-Error "Could not resolve clientId for '$beMiName'. Check the identity exists in '$rg'."; exit 1 }

$procClientId = az identity show --resource-group $rg --name $procMiName --query clientId -o tsv 2>$null
if (-not $procClientId) { Write-Error "Could not resolve clientId for '$procMiName'. Check the identity exists in '$rg'."; exit 1 }

Write-Host "  Backend MI  : $beMiName (clientId=$beClientId)"   -ForegroundColor Gray
Write-Host "  Processes MI: $procMiName (clientId=$procClientId)" -ForegroundColor Gray

# --------------------------------------------------------------------------
# Helper: convert GUID to SQL SID hex (matches SID + TYPE = E behaviour)
# --------------------------------------------------------------------------
function ConvertTo-SqlSidHex([string]$guidString) {
    $guid  = [System.Guid]::Parse($guidString)
    $bytes = $guid.ToByteArray()
    return '0x' + [System.BitConverter]::ToString($bytes).Replace('-', '')
}

$beSid   = ConvertTo-SqlSidHex $beClientId
$procSid = ConvertTo-SqlSidHex $procClientId

# --------------------------------------------------------------------------
# Build SQL grant script
# --------------------------------------------------------------------------
$sql = @"
PRINT 'Granting permissions to: $beMiName';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$beMiName')
    CREATE USER [$beMiName] WITH SID = $beSid, TYPE = E;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$beMiName' AND SID <> $beSid)
BEGIN
    PRINT 'SID mismatch - recreating user with correct SID';
    DROP USER [$beMiName];
    CREATE USER [$beMiName] WITH SID = $beSid, TYPE = E;
END
IF IS_ROLEMEMBER('db_datareader', '$beMiName') = 0 ALTER ROLE db_datareader ADD MEMBER [$beMiName];
IF IS_ROLEMEMBER('db_datawriter', '$beMiName') = 0 ALTER ROLE db_datawriter ADD MEMBER [$beMiName];
IF IS_ROLEMEMBER('db_ddladmin',   '$beMiName') = 0 ALTER ROLE db_ddladmin   ADD MEMBER [$beMiName];
PRINT 'Done: $beMiName';

PRINT 'Granting permissions to: $procMiName';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$procMiName')
    CREATE USER [$procMiName] WITH SID = $procSid, TYPE = E;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$procMiName' AND SID <> $procSid)
BEGIN
    PRINT 'SID mismatch - recreating user with correct SID';
    DROP USER [$procMiName];
    CREATE USER [$procMiName] WITH SID = $procSid, TYPE = E;
END
IF IS_ROLEMEMBER('db_datareader', '$procMiName') = 0 ALTER ROLE db_datareader ADD MEMBER [$procMiName];
IF IS_ROLEMEMBER('db_datawriter', '$procMiName') = 0 ALTER ROLE db_datawriter ADD MEMBER [$procMiName];
IF IS_ROLEMEMBER('db_ddladmin',   '$procMiName') = 0 ALTER ROLE db_ddladmin   ADD MEMBER [$procMiName];
PRINT 'Done: $procMiName';

SELECT name, type_desc, create_date FROM sys.database_principals
WHERE type IN ('E','X') AND name NOT LIKE '##%'
ORDER BY name;
"@

# --------------------------------------------------------------------------
# Acquire Azure AD access token (uses current az login session — no password needed)
# --------------------------------------------------------------------------
Write-Host "  Acquiring Azure AD access token for SQL..." -ForegroundColor Gray
$accessToken = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv 2>$null
if (-not $accessToken) {
    Write-Error "Could not acquire Azure AD access token. Run 'az login' first."
    exit 1
}

# --------------------------------------------------------------------------
# Ensure current user is the SQL server Entra admin so the token is accepted.
# The normal server admin is the sqladmin managed identity — the current az
# login user has no DB access until SQL users exist (chicken-and-egg).
# We temporarily promote the current user, run the grants, then restore.
# --------------------------------------------------------------------------
$sqlServerShortName = ($sqlFqdn -split '\.')[0]

$currentUserUpn      = az ad signed-in-user show --query userPrincipalName -o tsv 2>$null
$currentUserObjectId = az ad signed-in-user show --query id -o tsv 2>$null

# Capture the existing Entra admin so we can restore it afterward
$existingAdminJson = az sql server ad-admin list `
    --resource-group $rg --server $sqlServerShortName -o json 2>$null
$existingAdmin = $existingAdminJson | ConvertFrom-Json | Select-Object -First 1

$adminPromoted = $false
if ($currentUserObjectId) {
    Write-Host "  Temporarily setting '$currentUserUpn' as SQL Entra admin..." -ForegroundColor Yellow
    az sql server ad-admin create `
        --resource-group $rg `
        --server $sqlServerShortName `
        --display-name "FixScriptAdmin" `
        --object-id $currentUserObjectId `
        --only-show-errors | Out-Null
    $adminPromoted = $true
    Write-Host "  Waiting 10s for admin propagation..." -ForegroundColor Gray
    Start-Sleep -Seconds 10
} else {
    Write-Host "  WARNING: Could not determine current user object ID. Token auth may fail." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# Add temporary firewall rule for this machine's IP
# --------------------------------------------------------------------------
$tempRuleName = $null
try {
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim()
    if ($myIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $tempRuleName = "AllowFixScript-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Write-Host "  Adding temporary firewall rule '$tempRuleName' for $myIp..." -ForegroundColor Yellow
        az sql server firewall-rule create `
            --resource-group $rg `
            --server $sqlServerShortName `
            --name $tempRuleName `
            --start-ip-address $myIp `
            --end-ip-address $myIp `
            --only-show-errors | Out-Null
        Write-Host "  Firewall rule added. Waiting 5s for propagation..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
} catch {
    Write-Host "  WARNING: Could not add firewall rule: $_" -ForegroundColor Yellow
    Write-Host "  Proceeding — ensure your IP is allowed or use Azure Portal Query Editor." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# Execute SQL via Azure AD token
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "  Executing SQL permission grants..." -ForegroundColor Cyan

$sqlSuccess = $false
try {
    if (-not (Get-Module -ListAvailable -Name SqlServer)) {
        Write-Host "  Installing SqlServer module..." -ForegroundColor Gray
        Install-Module SqlServer -Force -Scope CurrentUser -AllowClobber | Out-Null
    }
    Import-Module SqlServer -ErrorAction Stop

    # Re-acquire token after admin promotion
    $accessToken = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv 2>$null

    $result = Invoke-Sqlcmd `
        -ServerInstance $sqlFqdn `
        -Database $sqlDb `
        -AccessToken $accessToken `
        -Query $sql `
        -ConnectionTimeout 30 `
        -QueryTimeout 60 `
        -Verbose `
        -ErrorAction Stop 4>&1

    $sqlSuccess = $true
    Write-Host ""
    Write-Host "==> SQL permissions granted successfully!" -ForegroundColor Green
    if ($result) {
        Write-Host "  Database users now in ${sqlDb}:" -ForegroundColor Gray
        foreach ($row in $result) {
            Write-Host "    $($row.name) | $($row.type_desc) | created=$($row.create_date)" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "ERROR: $($_)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Alternative: use Azure Portal → SQL Database '$sqlDb' → Query Editor (sign in as Entra admin)" -ForegroundColor Yellow
    Write-Host $sql -ForegroundColor White
} finally {
    # Always clean up firewall rule
    if ($tempRuleName) {
        try {
            az sql server firewall-rule delete `
                --resource-group $rg `
                --server $sqlServerShortName `
                --name $tempRuleName `
                --yes --only-show-errors 2>$null | Out-Null
            Write-Host "  Temporary firewall rule removed." -ForegroundColor Gray
        } catch {
            Write-Host "  WARNING: Could not remove firewall rule '$tempRuleName'. Remove it manually." -ForegroundColor Yellow
        }
    }

    # Restore the original Entra admin (sqladmin managed identity)
    if ($adminPromoted) {
        try {
            if ($existingAdmin -and $existingAdmin.sid) {
                Write-Host "  Restoring original SQL Entra admin '$($existingAdmin.login)'..." -ForegroundColor Yellow
                az sql server ad-admin create `
                    --resource-group $rg `
                    --server $sqlServerShortName `
                    --display-name $existingAdmin.login `
                    --object-id $existingAdmin.sid `
                    --only-show-errors | Out-Null
                Write-Host "  SQL Entra admin restored." -ForegroundColor Gray
            } else {
                Write-Host "  WARNING: No previous Entra admin captured — cannot restore automatically." -ForegroundColor Yellow
                Write-Host "  Run 'azd up' to let Bicep restore the sqladmin managed identity as server admin." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  WARNING: Could not restore original SQL Entra admin: $_" -ForegroundColor Yellow
            Write-Host "  Run 'azd up' to let Bicep restore the sqladmin managed identity as server admin." -ForegroundColor Yellow
        }
    }
}

if (-not $sqlSuccess) { exit 1 }

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Restart the backend container app to pick up the new SQL users:" -ForegroundColor White
$beApp = az containerapp list -g $rg --query "[].name" -o tsv 2>$null | Where-Object { $_ -like '*-be' } | Select-Object -First 1
if ($beApp) {
    $revision = az containerapp revision list -g $rg -n $beApp --query "[0].name" -o tsv 2>$null
    Write-Host "     az containerapp revision restart -g $rg -n $beApp --revision $revision" -ForegroundColor Gray
}
Write-Host "  2. The ensure-sql-setup.ps1 preprovision hook will automatically" -ForegroundColor White
Write-Host "     set FORCE_SQL_SETUP_TAG on the next 'azd up' to keep Bicep in sync." -ForegroundColor White
