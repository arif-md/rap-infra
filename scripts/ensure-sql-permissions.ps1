#!/usr/bin/env pwsh

# =============================================================================
# Ensure SQL Database Exists and Grant Managed Identity Permissions
# =============================================================================
# This script is called by postprovision hook to ensure SQL resources
# exist and backend managed identity has appropriate database permissions.
#
# This runs AFTER main.bicep deployment, granting permissions to the
# newly created managed identity.
#
# Note: This uses Azure CLI with AAD authentication (no SQL admin password needed)
# =============================================================================

$ErrorActionPreference = "Stop"

Write-Host "==> Ensuring SQL Database setup and permissions..." -ForegroundColor Cyan

# Check if SQL Database is enabled
$enableSql = azd env get-value ENABLE_SQL_DATABASE 2>$null
if (-not $enableSql) { $enableSql = "true" }

if ($enableSql -ne "true") {
    Write-Host "SQL Database is disabled. Skipping SQL setup." -ForegroundColor Yellow
    exit 0
}

# Get required environment variables
try {
    $azureEnvName = azd env get-value AZURE_ENV_NAME
    $resourceGroup = azd env get-value AZURE_RESOURCE_GROUP
} catch {
    Write-Host "ERROR: Failed to get azd environment values" -ForegroundColor Red
    Write-Host "Make sure you're running this from an azd environment" -ForegroundColor Yellow
    exit 1
}

Write-Host "Environment: $azureEnvName" -ForegroundColor White
Write-Host "Resource Group: $resourceGroup" -ForegroundColor White
Write-Host ""

# Check if SQL Server exists
Write-Host "Looking for SQL Server in resource group..." -ForegroundColor Yellow
$sqlServerName = az sql server list -g $resourceGroup --query "[0].name" -o tsv 2>$null

if (-not $sqlServerName) {
    Write-Host "SQL Server not found in resource group. Should have been created by main.bicep deployment." -ForegroundColor Yellow
    Write-Host "Skipping permission grants." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found SQL Server: $sqlServerName" -ForegroundColor Green

# Get database name
$sqlDatabaseName = az sql db list -g $resourceGroup -s $sqlServerName --query "[?name != 'master'].name | [0]" -o tsv 2>$null

if (-not $sqlDatabaseName) {
    Write-Host "SQL Database not found. Should have been created by main.bicep deployment." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found SQL Database: $sqlDatabaseName" -ForegroundColor Green

# Get backend managed identity name - try multiple methods
Write-Host "Looking for backend managed identity..." -ForegroundColor Yellow

# Method 1: Try from Bicep outputs
try {
    $backendIdentityName = az deployment group show `
        --resource-group $resourceGroup `
        --name main `
        --query "properties.outputs.backendIdentityName.value" `
        --output tsv 2>$null
} catch {
    $backendIdentityName = $null
}

# Method 2: Search identities in resource group
if (-not $backendIdentityName) {
    $backendIdentityName = az identity list -g $resourceGroup --query "[?contains(name, 'backend')].name | [0]" -o tsv 2>$null
}

if (-not $backendIdentityName) {
    Write-Host "Backend managed identity not found yet. Should have been created by main.bicep deployment." -ForegroundColor Yellow
    Write-Host "Skipping SQL permission grants." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found backend identity: $backendIdentityName" -ForegroundColor Green
Write-Host ""

# Get SQL Server FQDN
$sqlServerFqdn = az sql server show -n $sqlServerName -g $resourceGroup --query "fullyQualifiedDomainName" -o tsv

Write-Host "SQL Server FQDN: $sqlServerFqdn" -ForegroundColor White

# Check if public access is enabled (required for this script)
$publicAccess = az sql server show -n $sqlServerName -g $resourceGroup --query "publicNetworkAccess" -o tsv

if ($publicAccess -eq "Disabled") {
    Write-Host ""
    Write-Host "WARNING: SQL Server has public access disabled (using private endpoint)." -ForegroundColor Yellow
    Write-Host "Cannot grant permissions from this script. You have two options:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Option 1: Temporarily enable public access, run this script, then disable:" -ForegroundColor Cyan
    Write-Host "  az sql server update -n $sqlServerName -g $resourceGroup --enable-public-network true" -ForegroundColor White
    Write-Host "  azd hooks run postprovision" -ForegroundColor White
    Write-Host "  az sql server update -n $sqlServerName -g $resourceGroup --enable-public-network false" -ForegroundColor White
    Write-Host ""
    Write-Host "Option 2: Run SQL commands from a machine with VNet access" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Skipping permission grants." -ForegroundColor Yellow
    exit 0
}

# Get current IP for firewall rule (if needed)
try {
    $myIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing -TimeoutSec 5).Content.Trim()
    Write-Host "Current IP: $myIp" -ForegroundColor White
} catch {
    Write-Host "WARNING: Could not determine public IP address" -ForegroundColor Yellow
    $myIp = $null
}

$cleanupFirewallRule = $false

if ($myIp) {
    # Check if firewall rule exists
    $ruleExists = az sql server firewall-rule list -g $resourceGroup -s $sqlServerName --query "[?name=='AllowDeploymentScript'].name | [0]" -o tsv 2>$null
    
    if (-not $ruleExists) {
        Write-Host "Creating temporary firewall rule for deployment script..." -ForegroundColor Yellow
        az sql server firewall-rule create `
            -g $resourceGroup `
            -s $sqlServerName `
            -n "AllowDeploymentScript" `
            --start-ip-address $myIp `
            --end-ip-address $myIp `
            -o none
        $cleanupFirewallRule = $true
    }
}

# Grant managed identity permissions using Azure CLI
Write-Host ""
Write-Host "Granting database permissions to managed identity..." -ForegroundColor Cyan

# Create SQL script
$sqlScript = @"
-- Check if user already exists
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$backendIdentityName')
BEGIN
    PRINT 'Creating user from external provider...'
    CREATE USER [$backendIdentityName] FROM EXTERNAL PROVIDER
END
ELSE
BEGIN
    PRINT 'User already exists.'
END
GO

-- Grant permissions
IF IS_ROLEMEMBER('db_datareader', '$backendIdentityName') = 0
BEGIN
    PRINT 'Granting db_datareader role...'
    ALTER ROLE db_datareader ADD MEMBER [$backendIdentityName]
END

IF IS_ROLEMEMBER('db_datawriter', '$backendIdentityName') = 0
BEGIN
    PRINT 'Granting db_datawriter role...'
    ALTER ROLE db_datawriter ADD MEMBER [$backendIdentityName]
END

IF IS_ROLEMEMBER('db_ddladmin', '$backendIdentityName') = 0
BEGIN
    PRINT 'Granting db_ddladmin role (for Flyway migrations)...'
    ALTER ROLE db_ddladmin ADD MEMBER [$backendIdentityName]
END
GO

PRINT 'Permissions granted successfully.'
GO
"@

# Try using Azure CLI with AAD authentication
Write-Host "Using Azure CLI with AAD authentication..." -ForegroundColor Yellow

try {
    $result = az sql db query `
        --resource-group $resourceGroup `
        --server $sqlServerName `
        --name $sqlDatabaseName `
        --auth-type ActiveDirectoryDefault `
        --query-text $sqlScript `
        2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ SQL permissions granted successfully!" -ForegroundColor Green
    } else {
        Write-Host "WARNING: SQL command execution failed" -ForegroundColor Yellow
        Write-Host $result -ForegroundColor Red
        Write-Host ""
        Write-Host "This usually means your Azure account is not configured as an AAD admin on the SQL Server." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To fix this:" -ForegroundColor Cyan
        Write-Host "1. Go to Azure Portal → SQL Server → Azure Active Directory" -ForegroundColor White
        Write-Host "2. Set yourself as the AAD admin" -ForegroundColor White
        Write-Host "3. Run: azd hooks run postprovision" -ForegroundColor White
        Write-Host ""
        Write-Host "Or run these SQL commands manually using SQL Server Management Studio:" -ForegroundColor Cyan
        Write-Host $sqlScript -ForegroundColor White
    }
} catch {
    Write-Host "ERROR: Failed to execute SQL commands: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please run these SQL commands manually:" -ForegroundColor Yellow
    Write-Host $sqlScript -ForegroundColor White
}

# Cleanup temporary firewall rule if created
if ($cleanupFirewallRule) {
    Write-Host ""
    Write-Host "Removing temporary firewall rule..." -ForegroundColor Yellow
    az sql server firewall-rule delete `
        -g $resourceGroup `
        -s $sqlServerName `
        -n "AllowDeploymentScript" `
        -o none 2>$null
}

Write-Host ""
Write-Host "==> SQL setup complete!" -ForegroundColor Green
