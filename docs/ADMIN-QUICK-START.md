# Quick Start: Grant Key Vault Permissions to Service Principal

**Service Principal**: `e22cd074-2f43-4262-af66-bfa30e67c4d8`  
**Subscription**: `5b489d19-6e0a-45bd-be65-d7d1c40af428` (NexGen Dev/Test)

---

## Choose Your Approach

### ✅ Option 1: Built-in Role (Recommended - Takes 1 minute)

Use Azure's built-in **Key Vault Contributor** role:

```bash
az role assignment create \
  --assignee e22cd074-2f43-4262-af66-bfa30e67c4d8 \
  --role "Key Vault Contributor" \
  --scope "/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428"
```

**Done!** This is the standard approach used across Azure.

---

### 🔒 Option 2: Minimal Custom Role (Takes 5 minutes)

If your security policy requires minimal permissions:

#### Using Azure Portal (Recommended for GUI)

**Step 1: Create Custom Role**

1. Azure Portal → **Subscriptions** → **NexGen Dev/Test**
2. **Access control (IAM)** → **+ Add** → **Add custom role**
3. **Basics:**
   - Name: `Key Vault Lifecycle Manager`
   - Description: `Minimal permissions to view, recover, and purge soft-deleted Key Vaults`
   - Click **Next**
4. **Permissions:**
   - Click **+ Add permissions**
   - Search: `Microsoft.KeyVault`
   - Select these 4 permissions:
     - ☑ locations/deletedVaults → **Read** (Get deleted vault)
     - ☑ locations/deletedVaults → **purge/action** (Purges soft deleted vault)
     - ☑ vaults → **Read** (Get vault)
     - ☑ vaults → **Write** (Create or update vault)
   - Click **Add** → **Next** → **Next** → **Create**

**Step 2: Assign to Service Principal**

1. Still in **Access control (IAM)** → **+ Add** → **Add role assignment**
2. **Role:** Select `Key Vault Lifecycle Manager`
3. **Members:** 
   - Select "User, group, or service principal"
   - Click **+ Select members**
   - Search: `e22cd074-2f43-4262-af66-bfa30e67c4d8`
   - Select the service principal → **Select**
4. **Review + assign** (twice)

✅ Done!

#### Using Azure CLI (Alternative)

```bash
# Step 1: Create the custom role
az role definition create --role-definition @keyvault-lifecycle-role.json

# Step 2: Assign it to the service principal
az role assignment create \
  --assignee e22cd074-2f43-4262-af66-bfa30e67c4d8 \
  --role "Key Vault Lifecycle Manager" \
  --scope "/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428"
```

The custom role grants only these permissions:
- View soft-deleted Key Vaults
- Purge soft-deleted Key Vaults
- Read/write Key Vaults (already has this)

---

## Verify It Works

After granting permissions, test with:

```bash
# Should now succeed (shows deleted vaults)
az keyvault list-deleted -o table

# Should show vault details
az keyvault show-deleted --name kv-dev-rtzig3eodfdtu-v1 --location eastus2

# Should purge the vault
az keyvault purge --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
```

All commands should complete without `AuthorizationFailed` errors.

---

## Why This Matters

**Before**: Every deployment cycle requires manual admin intervention to purge soft-deleted Key Vaults  
**After**: Automated scripts handle Key Vault lifecycle, zero manual intervention needed

**Time saved**: ~20 minutes per deployment cycle  
**Cost saved**: Eliminates unnecessary retention fees for deleted vaults

---

## Full Documentation

See `AZURE-ADMIN-PERMISSION-REQUEST.md` for complete business justification and technical details.
