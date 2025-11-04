# SQL Permissions Automation

## Overview

This directory contains workflows to automate SQL database permission grants for managed identities.

## How It Works

### Local Development (`azd up`)
When running `azd up` locally, SQL permissions must be granted **manually one time**:

1. Run `azd up` to provision infrastructure
2. Open Azure Portal → SQL Database → Query Editor
3. Login with Microsoft Entra authentication
4. Execute the SQL commands from the console output or use:

```sql
-- Replace 'id-backend-xxxxx' with your actual backend identity name
CREATE USER [id-backend-xxxxx] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [id-backend-xxxxx];
ALTER ROLE db_datawriter ADD MEMBER [id-backend-xxxxx];
ALTER ROLE db_ddladmin ADD MEMBER [id-backend-xxxxx];
```

5. Backend will now connect successfully

**Note**: This is a one-time step per environment. Once permissions are granted, they persist unless you recreate the managed identity.

### GitHub Actions (Fully Automated)
When deploying via GitHub Actions, SQL permissions are **automatically granted**:

1. `provision-infrastructure.yaml` runs `azd provision`
2. After successful provisioning, it calls `grant-sql-permissions.yml`
3. The SQL permissions workflow:
   - Discovers SQL Server and backend managed identity automatically
   - Installs sqlcmd on the GitHub runner
   - Creates a temporary firewall rule
   - Connects using Azure AD authentication
   - Executes SQL commands to grant permissions
   - Cleans up the firewall rule

**No manual intervention required!**

## Workflows

### `grant-sql-permissions.yml`
Reusable workflow that grants SQL permissions to the backend managed identity.

**Inputs:**
- `environment`: Environment name (dev, staging, prod)

**Secrets Required:**
- `AZURE_CLIENT_ID`: Service principal client ID
- `AZURE_TENANT_ID`: Azure AD tenant ID
- `AZURE_SUBSCRIPTION_ID`: Azure subscription ID

**Usage:**
Can be triggered manually or called from other workflows.

### Manual Trigger
```bash
# Via GitHub UI: Actions → Grant SQL Permissions → Run workflow
# Or via GitHub CLI:
gh workflow run grant-sql-permissions.yml -f environment=dev
```

## Why This Approach?

### Industry Standard
Microsoft's recommended approach separates **control plane** (Azure resources) from **data plane** (database permissions):

- ✅ Bicep/ARM templates manage Azure resources
- ✅ T-SQL manages database permissions
- ✅ One-time manual setup for local development
- ✅ Fully automated for CI/CD pipelines

### Alternatives Considered

1. **Bicep Deployment Scripts** ❌
   - Creates temporary Azure Container Instances
   - More complex and slower
   - Additional Azure costs
   - Requires Directory Reader permissions

2. **Post-provision hooks (azd)** ❌
   - Requires sqlcmd installed locally
   - Requires firewall access
   - Requires Directory Reader role for service principals
   - Inconsistent across environments

3. **Current approach** ✅
   - Simple one-time manual step for local dev
   - Fully automated for CI/CD
   - Uses standard tools (sqlcmd, Azure CLI)
   - No special Azure AD permissions required
   - Industry standard practice

## Troubleshooting

### Local Development

**Error: "Login failed for user '<token-identified principal>'"**
- Run the SQL commands in Azure Portal Query Editor to grant permissions

**Error: "Cannot open server requested by the login"**
- Add your IP to SQL Server firewall rules in Azure Portal

### GitHub Actions

**Workflow fails with "Resource group not found"**
- Verify the naming convention matches your environment (e.g., `rg-raptor-dev`)

**Workflow fails with authentication error**
- Verify GitHub secrets are correctly configured
- Verify service principal is set as Azure AD admin on SQL Server

**Workflow succeeds but backend still can't connect**
- Check Container App logs for the actual error
- Verify the managed identity name matches what was created
- Verify the JDBC connection string includes `msiClientId` parameter
