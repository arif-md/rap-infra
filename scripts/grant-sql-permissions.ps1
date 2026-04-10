param(
    [Parameter(Mandatory)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory)]
    [string]$DatabaseName
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Granting SQL database permissions via deployment script"
Write-Host "    Server : $SqlServerFqdn"
Write-Host "    Database: $DatabaseName"

# Obtain an Azure AD access token for Azure SQL using the managed identity
Write-Host "Acquiring access token for Azure SQL..."
$tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F'
$tokenResponse = Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = 'true' } -ErrorAction Stop
$accessToken = $tokenResponse.access_token
Write-Host "Access token acquired."

# Read identity grants from JSON environment variable (set by Bicep)
$identityGrantsJson = $env:IDENTITY_GRANTS_JSON
$adAdminGroupJson = $env:AD_ADMIN_GROUP_JSON

if ([string]::IsNullOrWhiteSpace($identityGrantsJson) -or $identityGrantsJson -eq '[]') {
    Write-Host "No identity grants provided. Nothing to do."
    $DeploymentScriptOutputs = @{ result = 'skipped - no identity grants' }
    exit 0
}

# Parse JSON inputs
$identityGrants = $identityGrantsJson | ConvertFrom-Json
$adAdminGroup = if (![string]::IsNullOrWhiteSpace($adAdminGroupJson) -and $adAdminGroupJson -ne '{}') {
    $adAdminGroupJson | ConvertFrom-Json
} else {
    $null
}

# Build SQL statements dynamically
# SID + TYPE = E (for managed identities) bypasses the need for Directory Readers
# SID + TYPE = X (for AD groups) also bypasses Directory Readers
# SID must be VARBINARY(16) (hex format), not a GUID string.
# We convert the GUID to hex bytes in PowerShell and embed as a 0x... literal.

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
    # Drop and recreate if SID changed (e.g., after azd down + azd up)
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

$sqlScript = $sqlParts -join "`n`n"

Write-Host "SQL script to execute:"
Write-Host $sqlScript
Write-Host ""

# Install SqlServer module for Invoke-Sqlcmd
Write-Host "Installing SqlServer PowerShell module..."
Install-Module -Name SqlServer -Force -Scope CurrentUser -AllowClobber | Out-Null
Import-Module SqlServer
Write-Host "SqlServer module ready."

# Execute the SQL script
Write-Host "Executing SQL statements..."
try {
    $result = Invoke-Sqlcmd `
        -ServerInstance $SqlServerFqdn `
        -Database $DatabaseName `
        -AccessToken $accessToken `
        -Query $sqlScript `
        -ConnectionTimeout 30 `
        -QueryTimeout 60 `
        -Verbose `
        -ErrorAction Stop 4>&1
    Write-Host "Invoke-Sqlcmd output: $result"

    # Verify users were actually created
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
        Write-Host "WARNING: No external users found in database! CREATE USER may have silently failed."
    }

    Write-Host "==> SQL permissions granted successfully!"
    $DeploymentScriptOutputs = @{ result = 'success' }
} catch {
    Write-Host "ERROR: Failed to execute SQL script: $_"
    Write-Host "Full exception: $($_.Exception)"
    throw
}
