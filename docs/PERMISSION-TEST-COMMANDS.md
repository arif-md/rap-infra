# Commands to Demonstrate Service Principal Permission Issue

## Service Principal Details
- **Client ID**: `e22cd074-2f43-4262-af66-bfa30e67c4d8`
- **Object ID**: `6ed5ad18-23d5-4098-ac8e-b8b1de016d06`
- **Subscription**: `5b489d19-6e0a-45bd-be65-d7d1c40af428`

---

## Test Commands (Run These to Prove Permission Issues)

### 1. List All Deleted Key Vaults
```powershell
az keyvault list-deleted --query "[].{Name:name, Location:location, DeletionDate:properties.deletionDate}" -o table
```

**Expected Error:**
- Returns empty (no error, but cannot see deleted vaults)
- OR: `AuthorizationFailed` if attempting to view details

**Missing Permission**: `Microsoft.KeyVault/locations/deletedVaults/read`

---

### 2. View Specific Deleted Key Vault
```powershell
az keyvault show-deleted --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
```

**Expected Error:**
```
ERROR: (AuthorizationFailed) The client 'e22cd074-2f43-4262-af66-bfa30e67c4d8' 
with object id '6ed5ad18-23d5-4098-ac8e-b8b1de016d06' does not have authorization 
to perform action 'Microsoft.KeyVault/locations/deletedVaults/read' over scope 
'/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428/providers/Microsoft.KeyVault/
locations/eastus2/deletedVaults/kv-dev-rtzig3eodfdtu-v1'
```

**Missing Permission**: `Microsoft.KeyVault/locations/deletedVaults/read`

---

### 3. Attempt to Recover Deleted Key Vault
```powershell
az keyvault recover --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
```

**Expected Error:**
```
ERROR: (AuthorizationFailed) The client 'e22cd074-2f43-4262-af66-bfa30e67c4d8' 
does not have authorization to perform action 
'Microsoft.KeyVault/vaults/write' [or similar error]
```

**Missing Permission**: Combination of read + write permissions

---

### 4. Attempt to Purge Deleted Key Vault
```powershell
az keyvault purge --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
```

**Expected Error:**
```
ERROR: (AuthorizationFailed) The client 'e22cd074-2f43-4262-af66-bfa30e67c4d8' 
with object id '6ed5ad18-23d5-4098-ac8e-b8b1de016d06' does not have authorization 
to perform action 'Microsoft.KeyVault/locations/deletedVaults/purge/action'
```

**Missing Permission**: `Microsoft.KeyVault/locations/deletedVaults/purge/action`

---

## All-In-One Test Script

Run this PowerShell script to demonstrate all permission issues at once:

```powershell
Write-Host "`n=== Testing Service Principal Key Vault Permissions ===" -ForegroundColor Cyan
Write-Host "Service Principal: e22cd074-2f43-4262-af66-bfa30e67c4d8`n" -ForegroundColor Yellow

Write-Host "1. Attempting to list deleted Key Vaults:" -ForegroundColor White
az keyvault list-deleted --query "[].{Name:name, Location:location}" -o table
Write-Host ""

Write-Host "2. Attempting to view deleted vault 'kv-dev-rtzig3eodfdtu-v1':" -ForegroundColor White
az keyvault show-deleted --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
Write-Host ""

Write-Host "3. Attempting to purge deleted vault:" -ForegroundColor White
az keyvault purge --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
Write-Host ""

Write-Host "=== Test Complete ===" -ForegroundColor Cyan
Write-Host "All commands should fail with AuthorizationFailed errors." -ForegroundColor Yellow
Write-Host "See AZURE-ADMIN-PERMISSION-REQUEST.md for solution.`n" -ForegroundColor Yellow
```

---

## Solution Options

### Option 1: Built-in Role (Recommended)

**Fastest and easiest** - Use Azure's built-in Key Vault Contributor role:

```bash
az role assignment create \
  --assignee e22cd074-2f43-4262-af66-bfa30e67c4d8 \
  --role "Key Vault Contributor" \
  --scope "/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428"
```

**Pros:**
- ✅ One command, immediate effect
- ✅ Microsoft-managed, no maintenance
- ✅ Standard practice across Azure

**Cons:**
- ⚠️ Grants all Key Vault operations (broader than strictly needed)

---

### Option 2: Minimal Custom Role (Most Secure)

**For security-conscious environments** - Grant only the exact permissions needed.

#### Method A: Using Azure Portal (Recommended for GUI users)

**Step 1: Create the Custom Role**

1. Open **Azure Portal** (portal.azure.com)
2. Search for **"Subscriptions"** → Click **"NexGen Dev/Test"**
3. In left menu, click **"Access control (IAM)"**
4. Click **"+ Add"** → Select **"Add custom role"**

5. **Basics tab:**
   - **Role name**: `Key Vault Lifecycle Manager`
   - **Description**: `Minimal permissions to view, recover, and purge soft-deleted Key Vaults`
   - **Baseline permissions**: Select **"Start from scratch"**
   - Click **"Next"**

6. **Permissions tab:**
   - Click **"+ Add permissions"**
   - In the search box, type: `Microsoft.KeyVault`
   - Click on **"Microsoft.KeyVault"** in the results
   
   - **Select these 4 permissions** (expand sections to find them):
     
     a) Expand **"locations/deletedVaults"**:
        - ☑ Check **"Read : Get deleted vault"** (`read`)
        - ☑ Check **"Other : Purges soft deleted vault"** (`purge/action`)
     
     b) Scroll down, expand **"vaults"**:
        - ☑ Check **"Read : Get vault"** (`read`)
        - ☑ Check **"Write : Create or update vault"** (`write`)
   
   - Click **"Add"** button at the bottom
   - Click **"Next"**

7. **Assignable scopes tab:**
   - Should automatically show: **Subscription - NexGen Dev/Test**
   - Click **"Next"**

8. **JSON tab:**
   - Review the generated JSON (should have 4 actions)
   - Click **"Next"**

9. **Review + create tab:**
   - Verify settings
   - Click **"Create"**

**Step 2: Assign the Custom Role to Service Principal**

1. Still in **Subscriptions → NexGen Dev/Test → Access control (IAM)**
2. Click **"+ Add"** → Select **"Add role assignment"**

3. **Role tab:**
   - In the search box, type: `Key Vault Lifecycle Manager`
   - Select the custom role you just created
   - Click **"Next"**

4. **Members tab:**
   - **Assign access to**: Select **"User, group, or service principal"**
   - Click **"+ Select members"**
   - In the search box, paste: `e22cd074-2f43-4262-af66-bfa30e67c4d8`
     - (Alternative: paste Object ID `6ed5ad18-23d5-4098-ac8e-b8b1de016d06`)
   - Click on the service principal in the results
   - Click **"Select"** button at the bottom
   - Click **"Next"**

5. **Conditions tab** (optional):
   - Leave as default (no conditions)
   - Click **"Next"**

6. **Review + assign tab:**
   - Review the assignment
   - Click **"Review + assign"**
   - Confirm by clicking **"Review + assign"** again

✅ **Done!** The service principal now has minimal permissions to manage deleted Key Vaults.

---

#### Method B: Using Azure CLI

**Step 1: Create the custom role definition file**

The file `keyvault-lifecycle-role.json` is already provided in the repository:

```json
{
  "Name": "Key Vault Lifecycle Manager",
  "Description": "Minimal permissions to view, recover, and purge soft-deleted Key Vaults",
  "Actions": [
    "Microsoft.KeyVault/locations/deletedVaults/read",
    "Microsoft.KeyVault/locations/deletedVaults/purge/action",
    "Microsoft.KeyVault/vaults/write",
    "Microsoft.KeyVault/vaults/read"
  ],
  "NotActions": [],
  "AssignableScopes": [
    "/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428"
  ]
}
```

**Step 2: Create and assign the custom role**

```bash
# Create the custom role
az role definition create --role-definition @keyvault-lifecycle-role.json

# Assign it to the service principal
az role assignment create \
  --assignee e22cd074-2f43-4262-af66-bfa30e67c4d8 \
  --role "Key Vault Lifecycle Manager" \
  --scope "/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428"
```

---

**Pros:**
- ✅ Minimal permissions (principle of least privilege)
- ✅ Only grants deleted vault management capabilities
- ✅ More granular control

**Cons:**
- ⚠️ Requires custom role creation (extra step)
- ⚠️ Custom role needs to be maintained if Azure API changes

---

### Quick Comparison

| Aspect | Option 1: Built-in | Option 2: Custom |
|--------|-------------------|------------------|
| **Setup Time** | 1 minute | 5-10 minutes (Portal) / 2 minutes (CLI) |
| **Permissions** | All Key Vault ops | Only deleted vault management |
| **Maintenance** | None (MS-managed) | Manual if APIs change |
| **Security** | Broader scope | Minimal scope |
| **Recommendation** | ✅ Use this unless security policy requires minimal | ⚠️ Only if required by policy |

---

## After Permissions Are Granted

### Verification Commands

Run these to confirm permissions work:

```powershell
# Should now succeed
az keyvault list-deleted -o table

# Should show vault details
az keyvault show-deleted --name kv-dev-rtzig3eodfdtu-v1 --location eastus2

# Should successfully purge the vault
az keyvault purge --name kv-dev-rtzig3eodfdtu-v1 --location eastus2

# Verify vault is gone
az keyvault show-deleted --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
# Expected: "Vault not found" (vault successfully purged)
```

### Enable Automation Script

After permissions are granted, uncomment the recovery script in `azure.yaml`:

```yaml
preprovision:
  windows:
    run: |
      ./scripts/recover-or-create-keyvault.ps1  # UNCOMMENT THIS LINE
      ./scripts/resolve-images.ps1
      ...
```

This will enable automatic Key Vault recovery/cleanup during `azd up` deployments.

---

## Reference

- **Full justification**: See `AZURE-ADMIN-PERMISSION-REQUEST.md`
- **Technical docs**: See `KEYVAULT-LIFECYCLE.md`
- **Automation script**: `scripts/recover-or-create-keyvault.ps1`
