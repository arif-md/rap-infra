param(
    [Parameter(Mandatory)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory)]
    [string]$DatabaseName,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'

Write-Host "==> SQL Setup — permissions + schema bootstrap (combined)"
Write-Host "    Server  : $SqlServerFqdn"
Write-Host "    Database: $DatabaseName"
Write-Host "    RG      : $ResourceGroupName"

# --------------------------------------------------------------------------
# Acquire Azure AD access token for SQL (via managed identity)
# --------------------------------------------------------------------------
Write-Host "Acquiring access token for Azure SQL..."
$tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F'
$tokenResponse = Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = 'true' } -ErrorAction Stop
$accessToken = $tokenResponse.access_token
Write-Host "Access token acquired."

# --------------------------------------------------------------------------
# Temporary firewall rule for this ACI container's outbound IP
# --------------------------------------------------------------------------
# Deployment Script ACI containers sometimes have outbound IPs that are NOT
# covered by the "Allow Azure services" (0.0.0.0) firewall rule. We detect
# the outbound IP and add a temporary firewall rule, then clean it up on exit.
# Uses Az.Sql cmdlets (pre-authenticated via the deployment script identity).
# --------------------------------------------------------------------------
$sqlServerShortName = ($SqlServerFqdn -split '\.')[0]
$tempRuleName = $null

try {
    # Detect outbound IP (try multiple services for resilience)
    $myIp = $null
    $ipServices = @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')
    foreach ($svc in $ipServices) {
        try {
            $myIp = (Invoke-RestMethod -Uri $svc -TimeoutSec 10).Trim()
            if ($myIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { break }
            $myIp = $null
        } catch { continue }
    }

    if ($myIp) {
        Write-Host "Deployment script outbound IP: $myIp"
        $tempRuleName = "AllowDeployScript-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Write-Host "Adding temporary firewall rule '$tempRuleName' for IP $myIp..."

        # Az PowerShell is pre-authenticated with the managed identity in deployment scripts
        New-AzSqlServerFirewallRule `
            -ResourceGroupName $ResourceGroupName `
            -ServerName $sqlServerShortName `
            -FirewallRuleName $tempRuleName `
            -StartIpAddress $myIp `
            -EndIpAddress $myIp `
            -ErrorAction Stop | Out-Null

        Write-Host "Temporary firewall rule added. Waiting 5s for propagation..."
        Start-Sleep -Seconds 5
    } else {
        Write-Host "WARNING: Could not detect outbound IP. Skipping temporary firewall rule."
    }
} catch {
    Write-Host "WARNING: Could not add temporary firewall rule: $_"
    Write-Host "Proceeding anyway (AllowAzureServices rule may cover this IP)."
    $tempRuleName = $null
}

# --------------------------------------------------------------------------
# Install SqlServer module ONCE (biggest per-script cost)
# --------------------------------------------------------------------------
Write-Host "Installing SqlServer PowerShell module..."
Install-Module -Name SqlServer -Force -Scope CurrentUser -AllowClobber | Out-Null
Import-Module SqlServer
Write-Host "SqlServer module ready."

# --------------------------------------------------------------------------
# Helper: Convert GUID to SQL SID hex string
# --------------------------------------------------------------------------
function ConvertTo-SqlSidHex([string]$guidString) {
    $guid = [System.Guid]::Parse($guidString)
    $bytes = $guid.ToByteArray()
    return '0x' + [System.BitConverter]::ToString($bytes).Replace('-', '')
}

# --------------------------------------------------------------------------
# Helper: Execute a SQL query with standard connection params
# --------------------------------------------------------------------------
function Invoke-Sql {
    param(
        [string]$Query,
        [int]$QueryTimeout = 60
    )
    Invoke-Sqlcmd `
        -ServerInstance $SqlServerFqdn `
        -Database $DatabaseName `
        -AccessToken $accessToken `
        -Query $Query `
        -ConnectionTimeout 30 `
        -QueryTimeout $QueryTimeout `
        -Verbose `
        -ErrorAction Stop 4>&1
}

# --------------------------------------------------------------------------
# Helper: Execute a SQL script that may contain GO batch separators
# --------------------------------------------------------------------------
function Invoke-SqlBatches {
    param(
        [string]$Script,
        [string]$Label = 'SQL'
    )
    $batches = $Script -split '(?m)^\s*GO\s*$' | Where-Object { $_.Trim() -ne '' }
    Write-Host "Executing $($batches.Count) $Label batches..."
    $batchNum = 0
    foreach ($batch in $batches) {
        $batchNum++
        try {
            $result = Invoke-Sql -Query $batch -QueryTimeout 120
            if ($result) { Write-Host "  Batch $batchNum output: $result" }
        } catch {
            Write-Host "ERROR in $Label batch $batchNum : $_"
            Write-Host "Batch content: $($batch.Substring(0, [Math]::Min(200, $batch.Length)))..."
            throw
        }
    }
}

# ==========================================================================
# STEP 1: Grant SQL permissions to managed identities
# ==========================================================================
# SQL templates are loaded from .sql files by Bicep (loadTextContent) and
# passed as environment variables. Edit the .sql files to change SQL logic:
#   - sql/create-db-user.sql       — per managed identity
#   - sql/create-ad-group-user.sql — per Azure AD group
# ==========================================================================
Write-Host ""
Write-Host "========== STEP 1: SQL Role Assignments =========="

$identityGrantsJson = $env:IDENTITY_GRANTS_JSON
$adAdminGroupJson   = $env:AD_ADMIN_GROUP_JSON
$dbUserTemplate     = $env:DB_USER_SQL_TEMPLATE
$adGroupTemplate    = $env:AD_GROUP_SQL_TEMPLATE

if ([string]::IsNullOrWhiteSpace($identityGrantsJson) -or $identityGrantsJson -eq '[]') {
    Write-Host "No identity grants provided. Skipping role assignments."
} else {
    $identityGrants = $identityGrantsJson | ConvertFrom-Json
    $adAdminGroup = if (![string]::IsNullOrWhiteSpace($adAdminGroupJson) -and $adAdminGroupJson -ne '{}') {
        $adAdminGroupJson | ConvertFrom-Json
    } else {
        $null
    }

    $sqlParts = @()

    # --- Managed Identity users (from create-db-user.sql template) ---
    foreach ($grant in $identityGrants) {
        $name     = $grant.name
        $clientId = $grant.clientId
        $roles    = $grant.roles
        $hexSid   = ConvertTo-SqlSidHex $clientId

        # Build role grant lines for this identity
        $roleLines = foreach ($role in $roles) {
            "IF IS_ROLEMEMBER('$role', '$name') = 0 ALTER ROLE $role ADD MEMBER [$name];"
        }

        # Substitute template variables
        $sql = $dbUserTemplate `
            -replace '\$\(UserName\)', $name `
            -replace '\$\(UserSid\)',  $hexSid
        $sql = $sql.Replace('-- ROLE_GRANTS_PLACEHOLDER', ($roleLines -join "`n"))

        $sqlParts += $sql
    }

    # --- Azure AD group (from create-ad-group-user.sql template) ---
    if ($adAdminGroup -and $adAdminGroup.name -and $adAdminGroup.objectId) {
        $groupName     = $adAdminGroup.name
        $groupObjectId = $adAdminGroup.objectId
        $hexSid        = ConvertTo-SqlSidHex $groupObjectId

        $sql = $adGroupTemplate `
            -replace '\$\(GroupName\)', $groupName `
            -replace '\$\(GroupSid\)',  $hexSid

        $sqlParts += $sql
    }

    $roleScript = $sqlParts -join "`n`n"
    Write-Host "Executing role assignment SQL..."
    try {
        $result = Invoke-Sql -Query $roleScript
        if ($result) { Write-Host "Role assignment output: $result" }

        # Verify users
        Write-Host "Verifying database users..."
        $users = Invoke-Sql -Query "SELECT name, type_desc, SID, create_date FROM sys.database_principals WHERE type IN ('E','X') AND name NOT LIKE '##%' ORDER BY name"
        if ($users) {
            Write-Host "==> Database users found:"
            foreach ($u in $users) {
                $sidHex = '0x' + [System.BitConverter]::ToString($u.SID).Replace('-','')
                Write-Host "    $($u.name) | $($u.type_desc) | SID=$sidHex | Created=$($u.create_date)"
            }
        } else {
            Write-Host "WARNING: No external users found in database!"
        }
        Write-Host "==> Role assignments completed!"
    } catch {
        Write-Host "ERROR: Failed to execute role assignment SQL: $_"
        throw
    }
}

# ==========================================================================
# STEP 2: Schema bootstrap — schemas, base tables, views & seed data
# ==========================================================================
# SQL loaded from: sql/bootstrap-schemas.sql
# ==========================================================================
Write-Host ""
Write-Host "========== STEP 2: Schema Bootstrap =========="

$backendIdentityName   = $env:BACKEND_IDENTITY_NAME
$processesIdentityName = $env:PROCESSES_IDENTITY_NAME
$sqlScript             = $env:SQL_SCRIPT_CONTENT

Write-Host "    Backend Identity  : $backendIdentityName"
Write-Host "    Processes Identity: $processesIdentityName"

if ([string]::IsNullOrWhiteSpace($sqlScript)) {
    Write-Host "WARNING: SQL_SCRIPT_CONTENT is empty. Skipping schema bootstrap."
} else {
    # Replace SQLCMD-style variables with actual values
    $sqlScript = $sqlScript.Replace('$(BackendIdentityName)', $backendIdentityName)
    $sqlScript = $sqlScript.Replace('$(ProcessesIdentityName)', $processesIdentityName)

    Write-Host "SQL script length: $($sqlScript.Length) characters"
    Invoke-SqlBatches -Script $sqlScript -Label 'schema-bootstrap'

    # Verify schemas
    Write-Host "Verifying schemas..."
    $schemas = Invoke-Sql -Query "SELECT name FROM sys.schemas WHERE name IN ('RAP','JBPM') ORDER BY name"
    foreach ($s in $schemas) { Write-Host "  Schema found: $($s.name)" }

    # Verify base tables
    Write-Host "Verifying base tables..."
    $tables = Invoke-Sql -Query "SELECT s.name AS [schema], t.name AS [table] FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name IN ('RAP','JBPM') ORDER BY s.name, t.name"
    foreach ($t in $tables) { Write-Host "  [$($t.schema)].[$($t.table)]" }

    Write-Host "==> Schema bootstrap completed! Schemas: $($schemas.Count), Tables: $($tables.Count)"
}

Write-Host ""
Write-Host "==> SQL Setup completed successfully!"

# --------------------------------------------------------------------------
# Cleanup: Remove temporary firewall rule
# --------------------------------------------------------------------------
if ($tempRuleName) {
    try {
        Write-Host "Removing temporary firewall rule '$tempRuleName'..."
        Remove-AzSqlServerFirewallRule `
            -ResourceGroupName $ResourceGroupName `
            -ServerName $sqlServerShortName `
            -FirewallRuleName $tempRuleName `
            -Force `
            -ErrorAction Stop
        Write-Host "Temporary firewall rule removed."
    } catch {
        Write-Host "WARNING: Could not remove temporary firewall rule '$tempRuleName': $_"
        Write-Host "Please remove it manually from the SQL Server firewall rules."
    }
}

$DeploymentScriptOutputs = @{ result = 'success' }
