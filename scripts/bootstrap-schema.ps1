param(
    [Parameter(Mandatory)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory)]
    [string]$DatabaseName
)

$ErrorActionPreference = 'Stop'

Write-Host "==> SQL Schema Bootstrap — creating schemas, base tables, views & seed data"
Write-Host "    Server  : $SqlServerFqdn"
Write-Host "    Database: $DatabaseName"

# Identity names passed via environment variables from Bicep
$backendIdentityName = $env:BACKEND_IDENTITY_NAME
$processesIdentityName = $env:PROCESSES_IDENTITY_NAME

Write-Host "    Backend Identity : $backendIdentityName"
Write-Host "    Processes Identity: $processesIdentityName"

# --------------------------------------------------------------------------
# Acquire Azure AD access token for SQL (via managed identity)
# --------------------------------------------------------------------------
Write-Host "Acquiring access token for Azure SQL..."
$tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F'
$tokenResponse = Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = 'true' } -ErrorAction Stop
$accessToken = $tokenResponse.access_token
Write-Host "Access token acquired."

# --------------------------------------------------------------------------
# Load the SQL script and perform variable substitution
# --------------------------------------------------------------------------
# The SQL file uses $(VariableName) placeholders — we replace them here
# so the SQL executes with concrete identity names.
$sqlScript = $env:SQL_SCRIPT_CONTENT

if ([string]::IsNullOrWhiteSpace($sqlScript)) {
    Write-Host "ERROR: SQL_SCRIPT_CONTENT environment variable is empty!"
    throw "SQL script content not provided"
}

# Replace SQLCMD-style variables with actual values
$sqlScript = $sqlScript.Replace('$(BackendIdentityName)', $backendIdentityName)
$sqlScript = $sqlScript.Replace('$(ProcessesIdentityName)', $processesIdentityName)

Write-Host "SQL script length: $($sqlScript.Length) characters"

# --------------------------------------------------------------------------
# Install SqlServer module & execute
# --------------------------------------------------------------------------
Write-Host "Installing SqlServer PowerShell module..."
Install-Module -Name SqlServer -Force -Scope CurrentUser -AllowClobber | Out-Null
Import-Module SqlServer
Write-Host "SqlServer module ready."

# Split on GO statements and execute each batch separately
# (SQL Server requires GO as a batch separator — it's not valid T-SQL)
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

# --------------------------------------------------------------------------
# Verify schemas exist
# --------------------------------------------------------------------------
Write-Host "Verifying schemas..."
$schemas = Invoke-Sqlcmd `
    -ServerInstance $SqlServerFqdn `
    -Database $DatabaseName `
    -AccessToken $accessToken `
    -Query "SELECT name FROM sys.schemas WHERE name IN ('RAP','JBPM') ORDER BY name" `
    -ConnectionTimeout 30 `
    -ErrorAction Stop

foreach ($s in $schemas) {
    Write-Host "  Schema found: $($s.name)"
}

# Verify base tables
Write-Host "Verifying base tables..."
$tables = Invoke-Sqlcmd `
    -ServerInstance $SqlServerFqdn `
    -Database $DatabaseName `
    -AccessToken $accessToken `
    -Query "SELECT s.name AS [schema], t.name AS [table] FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name IN ('RAP','JBPM') ORDER BY s.name, t.name" `
    -ConnectionTimeout 30 `
    -ErrorAction Stop

foreach ($t in $tables) {
    Write-Host "  [$($t.schema)].[$($t.table)]"
}

Write-Host "==> Schema bootstrap completed successfully!"
$DeploymentScriptOutputs = @{
    result = "success - schemas: $($schemas.Count), tables: $($tables.Count)"
}
