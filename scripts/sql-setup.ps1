param(
    [Parameter(Mandatory)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory)]
    [string]$DatabaseName
)

$ErrorActionPreference = 'Stop'

Write-Host "==> SQL Setup — permissions + schema bootstrap (combined)"
Write-Host "    Server  : $SqlServerFqdn"
Write-Host "    Database: $DatabaseName"

# --------------------------------------------------------------------------
# Acquire Azure AD access token for SQL (via managed identity)
# --------------------------------------------------------------------------
Write-Host "Acquiring access token for Azure SQL..."
$tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F'
$tokenResponse = Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = 'true' } -ErrorAction Stop
$accessToken = $tokenResponse.access_token
Write-Host "Access token acquired."

# --------------------------------------------------------------------------
# Install SqlServer module ONCE (biggest per-script cost)
# --------------------------------------------------------------------------
Write-Host "Installing SqlServer PowerShell module..."
Install-Module -Name SqlServer -Force -Scope CurrentUser -AllowClobber | Out-Null
Import-Module SqlServer
Write-Host "SqlServer module ready."

# ==========================================================================
# STEP 1: Grant SQL permissions to managed identities
# ==========================================================================
Write-Host ""
Write-Host "========== STEP 1: SQL Role Assignments =========="

$identityGrantsJson = $env:IDENTITY_GRANTS_JSON
$adAdminGroupJson = $env:AD_ADMIN_GROUP_JSON

if ([string]::IsNullOrWhiteSpace($identityGrantsJson) -or $identityGrantsJson -eq '[]') {
    Write-Host "No identity grants provided. Skipping role assignments."
} else {
    $identityGrants = $identityGrantsJson | ConvertFrom-Json
    $adAdminGroup = if (![string]::IsNullOrWhiteSpace($adAdminGroupJson) -and $adAdminGroupJson -ne '{}') {
        $adAdminGroupJson | ConvertFrom-Json
    } else {
        $null
    }

    function ConvertTo-SqlSidHex([string]$guidString) {
        $guid = [System.Guid]::Parse($guidString)
        $bytes = $guid.ToByteArray()
        return '0x' + [System.BitConverter]::ToString($bytes).Replace('-', '')
    }

    $sqlParts = @()

    foreach ($grant in $identityGrants) {
        $name = $grant.name
        $clientId = $grant.clientId
        $roles = $grant.roles
        $hexSid = ConvertTo-SqlSidHex $clientId

        $stmts = @()
        $stmts += "PRINT 'Granting permissions to: $name (clientId: $clientId)';"
        $stmts += "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$name')"
        $stmts += "  CREATE USER [$name] WITH SID = $hexSid, TYPE = E;"
        $stmts += "ELSE"
        $stmts += "  PRINT 'User already exists, recreating with correct SID...';"
        $stmts += "IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$name' AND SID <> $hexSid)"
        $stmts += "BEGIN"
        $stmts += "  DROP USER [$name];"
        $stmts += "  CREATE USER [$name] WITH SID = $hexSid, TYPE = E;"
        $stmts += "END"
        foreach ($role in $roles) {
            $stmts += "IF IS_ROLEMEMBER('$role', '$name') = 0 ALTER ROLE $role ADD MEMBER [$name];"
        }
        $stmts += "PRINT 'Done: $name';"
        $sqlParts += ($stmts -join "`n")
    }

    if ($adAdminGroup -and $adAdminGroup.name -and $adAdminGroup.objectId) {
        $groupName = $adAdminGroup.name
        $groupObjectId = $adAdminGroup.objectId
        $hexSid = ConvertTo-SqlSidHex $groupObjectId

        $stmts = @()
        $stmts += "PRINT 'Granting db_owner to AD group: $groupName';"
        $stmts += "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$groupName')"
        $stmts += "  CREATE USER [$groupName] WITH SID = $hexSid, TYPE = X;"
        $stmts += "IF IS_ROLEMEMBER('db_owner', '$groupName') = 0 ALTER ROLE db_owner ADD MEMBER [$groupName];"
        $stmts += "PRINT 'Done: $groupName';"
        $sqlParts += ($stmts -join "`n")
    }

    $roleScript = $sqlParts -join "`n`n"
    Write-Host "Executing role assignment SQL..."
    try {
        $result = Invoke-Sqlcmd `
            -ServerInstance $SqlServerFqdn `
            -Database $DatabaseName `
            -AccessToken $accessToken `
            -Query $roleScript `
            -ConnectionTimeout 30 `
            -QueryTimeout 60 `
            -Verbose `
            -ErrorAction Stop 4>&1
        if ($result) { Write-Host "Role assignment output: $result" }

        # Verify users
        Write-Host "Verifying database users..."
        $verifyQuery = "SELECT name, type_desc, SID, create_date FROM sys.database_principals WHERE type IN ('E','X') AND name NOT LIKE '##%' ORDER BY name"
        $users = Invoke-Sqlcmd `
            -ServerInstance $SqlServerFqdn `
            -Database $DatabaseName `
            -AccessToken $accessToken `
            -Query $verifyQuery `
            -ConnectionTimeout 30 `
            -ErrorAction Stop
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
Write-Host ""
Write-Host "========== STEP 2: Schema Bootstrap =========="

$backendIdentityName = $env:BACKEND_IDENTITY_NAME
$processesIdentityName = $env:PROCESSES_IDENTITY_NAME
$sqlScript = $env:SQL_SCRIPT_CONTENT

Write-Host "    Backend Identity  : $backendIdentityName"
Write-Host "    Processes Identity: $processesIdentityName"

if ([string]::IsNullOrWhiteSpace($sqlScript)) {
    Write-Host "WARNING: SQL_SCRIPT_CONTENT is empty. Skipping schema bootstrap."
} else {
    # Replace SQLCMD-style variables with actual values
    $sqlScript = $sqlScript.Replace('$(BackendIdentityName)', $backendIdentityName)
    $sqlScript = $sqlScript.Replace('$(ProcessesIdentityName)', $processesIdentityName)

    Write-Host "SQL script length: $($sqlScript.Length) characters"

    # Split on GO statements and execute each batch separately
    $batches = $sqlScript -split '(?m)^\s*GO\s*$' | Where-Object { $_.Trim() -ne '' }

    Write-Host "Executing $($batches.Count) SQL batches..."
    $batchNum = 0
    foreach ($batch in $batches) {
        $batchNum++
        try {
            $result = Invoke-Sqlcmd `
                -ServerInstance $SqlServerFqdn `
                -Database $DatabaseName `
                -AccessToken $accessToken `
                -Query $batch `
                -ConnectionTimeout 30 `
                -QueryTimeout 120 `
                -Verbose `
                -ErrorAction Stop 4>&1
            if ($result) { Write-Host "  Batch $batchNum output: $result" }
        } catch {
            Write-Host "ERROR in batch $batchNum : $_"
            Write-Host "Batch content: $($batch.Substring(0, [Math]::Min(200, $batch.Length)))..."
            throw
        }
    }

    # Verify schemas
    Write-Host "Verifying schemas..."
    $schemas = Invoke-Sqlcmd `
        -ServerInstance $SqlServerFqdn `
        -Database $DatabaseName `
        -AccessToken $accessToken `
        -Query "SELECT name FROM sys.schemas WHERE name IN ('RAP','JBPM') ORDER BY name" `
        -ConnectionTimeout 30 `
        -ErrorAction Stop
    foreach ($s in $schemas) { Write-Host "  Schema found: $($s.name)" }

    # Verify base tables
    Write-Host "Verifying base tables..."
    $tables = Invoke-Sqlcmd `
        -ServerInstance $SqlServerFqdn `
        -Database $DatabaseName `
        -AccessToken $accessToken `
        -Query "SELECT s.name AS [schema], t.name AS [table] FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name IN ('RAP','JBPM') ORDER BY s.name, t.name" `
        -ConnectionTimeout 30 `
        -ErrorAction Stop
    foreach ($t in $tables) { Write-Host "  [$($t.schema)].[$($t.table)]" }

    Write-Host "==> Schema bootstrap completed! Schemas: $($schemas.Count), Tables: $($tables.Count)"
}

Write-Host ""
Write-Host "==> SQL Setup completed successfully!"
$DeploymentScriptOutputs = @{ result = 'success' }
