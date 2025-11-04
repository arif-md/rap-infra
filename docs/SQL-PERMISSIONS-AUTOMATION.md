# SQL Permissions Automation

## Overview

The backend Container App uses **Managed Identity** to connect to Azure SQL Database without passwords. This requires creating a database user for the managed identity and granting appropriate permissions.

Since Azure Resource Manager (ARM/Bicep) cannot execute T-SQL commands to create database users or grant permissions, we use **post-provision hooks** to automate this after infrastructure deployment.

## How It Works

### 1. Infrastructure Deployment (`azd provision`)

Bicep templates create:
- ✅ Azure SQL Server
- ✅ Azure SQL Database
- ✅ Backend Managed Identity
- ✅ Firewall rules (public mode) or Private Endpoint (VNet mode)

### 2. Post-Provision Hook (Automatic)

After Bicep deployment completes, `azd` automatically runs:

**Windows**: `infra/hooks/postprovision.ps1`  
**Linux/macOS**: `infra/scripts/postprovision.sh`

These scripts:
1. Retrieve deployment outputs (server name, database name, identity name)
2. Connect to SQL Database using **Azure CLI with AAD authentication**
3. Execute T-SQL commands to:
   ```sql
   CREATE USER [backend-identity-name] FROM EXTERNAL PROVIDER
   ALTER ROLE db_datareader ADD MEMBER [backend-identity-name]
   ALTER ROLE db_datawriter ADD MEMBER [backend-identity-name]
   ALTER ROLE db_ddladmin ADD MEMBER [backend-identity-name]
   ```

### 3. Backend Connection

The Spring Boot backend automatically:
- Acquires AAD tokens using its managed identity
- Connects to SQL Database using `Authentication=ActiveDirectoryMSI`
- Runs Flyway migrations to initialize schema
- Executes queries with granted permissions

## Deployment Outputs Used

The post-provision scripts retrieve these outputs from `infra/main.bicep`:

| Output | Description | Used For |
|--------|-------------|----------|
| `backendIdentityName` | Managed identity resource name | SQL user creation |
| `sqlServerFqdn` | SQL Server FQDN | Connection string |
| `sqlDatabaseName` | Database name | Target database |

These are automatically available as environment variables:
- `BACKEND_IDENTITY_NAME`
- `SQL_SERVER_NAME` (extracted from FQDN)
- `SQL_DATABASE_NAME`

## Configuration Files

### `infra/azure.yaml`

Defines post-provision hooks:

```yaml
hooks:
  postprovision:
    windows:
      shell: pwsh
      run: |
        ./hooks/postprovision.ps1
    posix:
      shell: sh
      run: |
        ./scripts/postprovision.sh
```

### `infra/hooks/postprovision.ps1` (Windows)

PowerShell script that:
- Retrieves Bicep outputs via `az deployment group show`
- Uses `az sql db query` to execute SQL commands
- Grants permissions with idempotent checks

### `infra/scripts/postprovision.sh` (Linux/macOS)

Bash script that:
- Calls `ensure-sql-permissions.sh`
- Handles firewall rules if needed
- Uses `sqlcmd` or Azure CLI for SQL execution

## SQL Permissions Granted

| Role | Permissions | Why Needed |
|------|------------|------------|
| `db_datareader` | Read all tables | Query application data |
| `db_datawriter` | Insert/Update/Delete | Modify application data |
| `db_ddladmin` | Create/Alter/Drop tables | Flyway migrations |

## Troubleshooting

### Script Fails: "Missing required environment variables"

**Cause**: Bicep outputs not exported as environment variables.

**Solution**: Ensure `infra/main.bicep` includes:
```bicep
output backendIdentityName string = backendIdentityName
output sqlServerFqdn string = sqlDatabase.outputs.sqlServerFqdn
output sqlDatabaseName string = sqlDatabase.outputs.sqlDatabaseName
```

### Script Fails: "Cannot connect to SQL Server"

**Public Access Mode**:
- Check "Allow Azure Services" firewall rule exists
- Your local IP may need a firewall rule for the script to run

**Private Endpoint Mode**:
- Script must run from a machine with VNet access
- Or temporarily enable public access, run script, then disable

### Script Succeeds but Backend Can't Connect

**Check Backend Logs**:
```powershell
az containerapp logs show `
  -n $(azd env get-value BACKEND_APP_NAME) `
  -g $(azd env get-value AZURE_RESOURCE_GROUP) `
  --tail 100
```

**Verify SQL User Exists**:
```sql
SELECT name, type_desc 
FROM sys.database_principals 
WHERE name = '<backend-identity-name>'
```

**Verify Permissions**:
```sql
SELECT 
    dp.name AS username,
    dp.type_desc,
    r.name AS role_name
FROM sys.database_principals dp
LEFT JOIN sys.database_role_members drm ON dp.principal_id = drm.member_principal_id
LEFT JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
WHERE dp.name = '<backend-identity-name>'
```

### Manual Permission Grant

If automation fails, grant permissions manually:

```sql
-- Connect as SQL Admin (AAD or SQL auth)
CREATE USER [<backend-identity-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<backend-identity-name>];
ALTER ROLE db_datawriter ADD MEMBER [<backend-identity-name>];
ALTER ROLE db_ddladmin ADD MEMBER [<backend-identity-name>];
GO
```

Replace `<backend-identity-name>` with the value from:
```powershell
azd env get-value BACKEND_IDENTITY_NAME
```

## Security Considerations

### Why `db_ddladmin`?

The backend needs `db_ddladmin` to run Flyway migrations, which create/alter tables. This is safe because:

1. **Scope**: Only applies to the application database (not entire SQL Server)
2. **Isolation**: Managed identity can only be used by the backend Container App
3. **Alternatives**: You could separate migration deployment (CI/CD) from runtime permissions

### Production Recommendation

For production environments, consider:

1. **Separate Migration Identity**: Use a different managed identity for Flyway migrations
   - CI/CD pipeline uses migration identity (with `db_ddladmin`)
   - Runtime app uses runtime identity (only `db_datareader` + `db_datawriter`)

2. **Schema Permissions**: Instead of `db_ddladmin`, grant specific object permissions
   ```sql
   GRANT CREATE TABLE TO [backend-identity];
   GRANT ALTER ON SCHEMA::dbo TO [backend-identity];
   ```

3. **Monitoring**: Enable SQL Database auditing to track schema changes

## Testing the Automation

### Test Full Deployment

```powershell
# Clean deployment
azd down --force --purge
azd up

# Check script output during provision
# Look for "🔐 Configuring SQL Database permissions..."

# Verify permissions
az sql db query `
  --server $(azd env get-value SQL_SERVER_NAME) `
  --database $(azd env get-value SQL_DATABASE_NAME) `
  --auth-type ActiveDirectoryDefault `
  --query "SELECT name, type_desc FROM sys.database_principals WHERE name = '$(azd env get-value BACKEND_IDENTITY_NAME)'"
```

### Test Script Independently

```powershell
# Windows
cd infra
./hooks/postprovision.ps1

# Linux/macOS
cd infra
./scripts/postprovision.sh
```

## Alternative Approaches

### 1. Bicep Deployment Scripts

Use Bicep `deploymentScripts` resource:
- ✅ Runs in Azure (not local machine)
- ✅ Built-in retry logic
- ❌ More complex setup
- ❌ Requires Storage Account + Managed Identity

### 2. Azure Functions

Deploy a temporary Function App to run SQL commands:
- ✅ Serverless, no local dependencies
- ✅ Can use VNet integration
- ❌ More infrastructure to manage
- ❌ Additional costs

### 3. CI/CD Pipeline

Run SQL commands in GitHub Actions/Azure DevOps:
- ✅ Centralized, auditable
- ✅ Easier to handle private endpoints
- ❌ Requires pipeline configuration
- ❌ Not automatic for local dev

### 4. Manual Setup (Not Recommended)

Require developers to run SQL commands manually:
- ✅ Simple, no automation needed
- ❌ Error-prone
- ❌ Not scalable
- ❌ Poor developer experience

## Related Documentation

- [SQL Connection Guide](./SQL-CONNECTION-GUIDE.md) - Detailed connection string formats and networking
- [VNet Integration Guide](./VNET-INTEGRATION-GUIDE.md) - Switching between public and private modes

## Summary

✅ **Automatic**: Runs after every `azd provision`  
✅ **Idempotent**: Safe to run multiple times  
✅ **Cross-platform**: PowerShell (Windows) and Bash (Linux/macOS)  
✅ **Fallback**: Manual instructions if automation fails  
✅ **Secure**: Uses AAD authentication, no hardcoded credentials  

The post-provision hook ensures your backend Container App can seamlessly connect to SQL Database using Managed Identity without any manual configuration steps.
