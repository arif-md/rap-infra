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

## Alternative: Azure AD Group for Full Automation (Recommended)

### Why an Azure AD Group?

**Current limitation:** Service principals cannot be SQL Server Azure AD administrators according to Microsoft documentation. However, service principals CAN be members of Azure AD groups, and groups CAN be SQL Server administrators.

**With an Azure AD group:**
- ✅ GitHub Actions can grant SQL permissions **fully automatically** (no manual steps)
- ✅ Multiple team members can manage SQL permissions without sharing credentials
- ✅ Service principal authentication works for CI/CD automation
- ✅ Follows Azure security best practices for team-based access control
- ✅ Easier to manage as team grows (add/remove members from group)

### Business Justification for Azure Admin

**Request:** Create an Azure AD security group for SQL Server administration

**Purpose:** Enable fully automated CI/CD pipeline for database permission management

**Technical Requirement:**
- Microsoft Azure SQL Database does not allow service principals as direct administrators
- Service principals are required for GitHub Actions automation
- Azure AD groups solve this by allowing service principals as members while satisfying Azure SQL's requirement for User/Group administrators

**Benefits:**
1. **Eliminates manual intervention** - Reduces deployment time and human error
2. **Consistent permissions** - Automated grants ensure identical configuration across environments
3. **Audit trail** - All permission grants logged in CI/CD pipeline
4. **Team scalability** - New team members added to group, inherit SQL admin rights automatically
5. **Security** - No shared passwords or manual SQL authentication required

**Cost:** None - Azure AD groups are free

**Risk:** Low - Group only grants SQL Server administrative access, which is already required for the application

### Setup Steps for Azure Admin

The Azure administrator needs to perform these one-time steps:

#### Step 1: Create Azure AD Security Group

```bash
# Create the group
az ad group create \
  --display-name "RAP-SQL-Admins" \
  --mail-nickname "rap-sql-admins" \
  --description "SQL Server administrators for RAP application - enables automated database permission management via CI/CD"

# Get the group's Object ID (needed for configuration)
az ad group show --group "RAP-SQL-Admins" --query id -o tsv
```

**Note:** Save the Object ID returned - you'll need it for GitHub configuration.

#### Step 2: Add Members to Group

```bash
# Add the service principal (for GitHub Actions automation)
az ad group member add \
  --group "RAP-SQL-Admins" \
  --member-id 6ed5ad18-23d5-4098-ac8e-b8b1de016d06

# Add your user account (for manual access and troubleshooting)
az ad group member add \
  --group "RAP-SQL-Admins" \
  --member-id 0cf6158a-b48d-4638-beeb-715c8811101a

# Verify membership
az ad group member list --group "RAP-SQL-Admins" --query "[].{Name:displayName, Type:objectType, ID:objectId}" -o table
```

**Service Principal Details:**
- Name: `sp-raptordev`
- Object ID: `6ed5ad18-23d5-4098-ac8e-b8b1de016d06`
- Purpose: Authenticate GitHub Actions workflows

**User Account Details:**
- Name: `Arif Mohammed`
- Object ID: `0cf6158a-b48d-4638-beeb-715c8811101a`
- Purpose: Manual troubleshooting and Azure Portal access

#### Step 3: Update GitHub Repository Variables

After the group is created, update these variables in the GitHub repository:

**Settings** → **Secrets and variables** → **Actions** → **Variables** tab

| Variable Name | Old Value | New Value | Change |
|---------------|-----------|-----------|--------|
| `SQL_AZURE_AD_ADMIN_OBJECT_ID` | `0cf6158a-b48d-4638-beeb-715c8811101a` | `<Object ID from Step 1>` | Group Object ID |
| `SQL_AZURE_AD_ADMIN_LOGIN` | `Arif Mohammed` | `RAP-SQL-Admins` | Group display name |
| `SQL_AZURE_AD_ADMIN_PRINCIPAL_TYPE` | `User` | `Group` | Change to Group |

#### Step 4: Re-enable Automated Workflow

After GitHub variables are updated, uncomment the automated SQL permission workflow:

In `infra/.github/workflows/provision-infrastructure.yaml`:

```yaml
# Change from:
  # grant-sql-permissions:
  #   needs: provision
  #   uses: ./.github/workflows/grant-sql-permissions.yml

# To:
  grant-sql-permissions:
    needs: provision
    uses: ./.github/workflows/grant-sql-permissions.yml
    with:
      environment: ${{ inputs.targetEnv || 'dev' }}
      resource_group: ${{ needs.provision.outputs.resource_group }}
    secrets: inherit
```

#### Step 5: Test Automation

Trigger the `provision-infrastructure` workflow. It should now:
1. ✅ Provision all Azure infrastructure
2. ✅ Set the Azure AD group as SQL Server admin
3. ✅ **Automatically grant SQL permissions** via GitHub Actions (no manual steps)
4. ✅ Restart backend container app
5. ✅ Backend connects to database successfully

### Verification Commands

```bash
# Verify group exists and has members
az ad group show --group "RAP-SQL-Admins"
az ad group member list --group "RAP-SQL-Admins"

# Verify group is set as SQL Server admin
az sql server ad-admin list \
  --resource-group rg-raptor-test \
  --server sql-rvcmyaz2n4zde

# Test service principal can authenticate to SQL Server (using group membership)
# This happens automatically in GitHub Actions workflow
```

### Rollback Plan

If issues occur, you can quickly revert to the current manual approach:
1. Change GitHub variables back to user account values
2. Re-comment the `grant-sql-permissions` workflow
3. Continue using manual SQL script execution from job summary

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
