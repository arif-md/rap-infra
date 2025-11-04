# SQL Server Azure AD Admin Configuration

## Problem Summary

**Service principals CANNOT be set as Azure AD admin for Azure SQL Database** according to Microsoft documentation:

> "The Microsoft Entra administrator must be a Microsoft Entra user or Microsoft Entra group, but it can't be a service principal."

Source: [Microsoft Documentation](https://learn.microsoft.com/en-us/fabric/data-factory/connector-azure-sql-database#authentication)

## Solution: Manual SQL Permission Setup

Instead of using automated GitHub Actions to grant SQL permissions, we use a **hybrid approach**:

1. **Your user account** is set as the SQL Server Azure AD admin during infrastructure provisioning
2. After deployment, the workflow generates a **ready-to-use SQL script**
3. You **copy and paste** the script in Azure Portal Query Editor
4. The script creates the managed identity user and grants all necessary permissions

## GitHub Variables to Configure

Add these variables in your GitHub repository:

**Settings** → **Secrets and variables** → **Actions** → **Variables** tab

| Variable Name | Value | Description |
|---------------|-------|-------------|
| `SQL_AZURE_AD_ADMIN_OBJECT_ID` | `0cf6158a-b48d-4638-beeb-715c8811101a` | Your Azure AD user Object ID |
| `SQL_AZURE_AD_ADMIN_LOGIN` | `Arif Mohammed` | Your display name |
| `SQL_AZURE_AD_ADMIN_PRINCIPAL_TYPE` | `User` | Principal type (User, not Application) |

### How to Get Your Object ID

```bash
az ad signed-in-user show --query id -o tsv
```

## Workflow Process

After you configure the GitHub variables:

1. **GitHub Actions provisions infrastructure** with your user as SQL Server Azure AD admin
2. **Workflow completes** and displays a SQL script in the job summary
3. **You execute the script manually** via Azure Portal Query Editor
4. **Backend container app connects** to the database with managed identity

## Manual Execution Steps

After the workflow completes:

1. Go to [Azure Portal](https://portal.azure.com)
2. Navigate to your resource group
3. Click on the SQL Database
4. Click **Query editor** in the left menu
5. Sign in with **Azure AD** (your account)
6. Copy the SQL script from the GitHub Actions job summary
7. Paste and run it
8. Restart the backend container app:
   ```bash
   az containerapp revision restart --name dev-rap-be --resource-group rg-raptor-test
   ```

## Benefits of This Approach

✅ **Compliant with Microsoft requirements** - User account as Azure AD admin  
✅ **Automated infrastructure** - GitHub Actions handles everything except SQL permissions  
✅ **Ready-to-use script** - No manual editing required  
✅ **One-time setup** - Only needed once per environment  
✅ **Clear documentation** - Script includes comments and verification queries  

## Alternative: Azure AD Group (Requires Permissions)

If you have permissions to create Azure AD groups:

1. Create group: `az ad group create --display-name "SQL-Admins" --mail-nickname "sql-admins"`
2. Add service principal: `az ad group member add --group "SQL-Admins" --member-id <sp-object-id>`
3. Add your user: `az ad group member add --group "SQL-Admins" --member-id <your-object-id>`
4. Set group as SQL Server Azure AD admin

This would allow the GitHub Actions workflow to grant permissions automatically.

## Troubleshooting

### "Login failed for user '<token-identified principal>'"

- Service principal cannot be SQL Server Azure AD admin
- Solution: Use your user account or an Azure AD group

### "Cannot create Azure AD users"

- Only Azure AD authenticated users can create Azure AD users
- SQL admin account cannot create Azure AD users
- Solution: Use Azure AD authentication (not SQL authentication)

### Backend still can't connect after granting permissions

- Container app needs restart to pick up new authentication state
- Solution: Restart the container app revision

```bash
az containerapp revision restart --name <app-name> --resource-group <rg-name>
```
