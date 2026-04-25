# Manual Key Vault Creation Guide

## When Is This Needed?

The `ensure-keyvault.sh` / `ensure-keyvault.ps1` pre-provision hook creates the Key Vault automatically on the first `azd up`. You only need this guide if:

- The hook fails due to insufficient permissions (e.g., the deploying principal lacks `Key Vault Contributor`)
- You need to create the vault before anyone has run `azd up` for the first time (e.g., infrastructure hand-off)
- A vault was accidentally purged and needs to be recreated manually

---

## Step 1: Determine the Key Vault Name

The name is computed by `ensure-keyvault.sh` using an md5 hash of `subscriptionId + environmentName`:

```bash
# On Linux/macOS (same formula as the script)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
UNIQUE=$(printf '%s' "${SUBSCRIPTION_ID}<env-name>" | md5sum | cut -c1-13)
echo "kv-<env-name>-${UNIQUE}-v10"
```

```powershell
# On Windows PowerShell (same formula as ensure-keyvault.ps1)
$SubId = az account show --query id -o tsv
$Bytes = [System.Text.Encoding]::UTF8.GetBytes("$SubId<env-name>")
$Hash  = [System.Security.Cryptography.MD5]::Create().ComputeHash($Bytes)
$Uniq  = ($Hash | ForEach-Object { $_.ToString("x2") }) -join ''
"kv-<env-name>-$($Uniq.Substring(0,13))-v10"
```

Replace `<env-name>` with your actual environment name (e.g., `dev`, `test`, `prod`).

Alternatively, after running `azd up` once (even if it fails partway through), the name is exported:
```bash
azd env get-value KEY_VAULT_NAME
```

---

## Step 2: Create the Key Vault

```bash
# Replace <kv-name>, <resource-group>, and <location> with your values
az keyvault create \
  --name <kv-name> \
  --resource-group <resource-group> \
  --location <location> \
  --retention-days 7 \
  --enable-purge-protection true \
  --sku standard
```

Use `--retention-days 90` for production environments.

**Note:** `--enable-purge-protection` is required by Azure subscription policy and cannot be disabled after creation.

---

## Step 3: Seed the Required Secrets

Secrets are normally seeded by `ensure-keyvault.sh` during the pre-provision hook (create-only — never overwrites). If you are creating the vault manually, seed the secrets yourself:

```bash
az keyvault secret set --vault-name <kv-name> --name jwt-secret         --value "<JWT_SECRET value>"
az keyvault secret set --vault-name <kv-name> --name aad-client-secret  --value "<AZURE_AD_CLIENT_SECRET value>"
az keyvault secret set --vault-name <kv-name> --name oidc-client-secret --value "<OIDC_CLIENT_SECRET value>"
```

> **Important:** Once secrets are seeded in KV, they are the source of truth. Subsequent `azd up` runs will skip secrets that already exist. Rotate secrets directly in KV — see [KEYVAULT-LIFECYCLE.md](KEYVAULT-LIFECYCLE.md#secret-rotation).

---

## Step 4: Register the Name in the azd Environment

```bash
azd env set KEY_VAULT_NAME <kv-name>
```

This ensures Bicep and all pre-provision scripts use the vault you just created rather than trying to compute or create a new one.

---

## Step 5: Run azd up

```bash
azd up
```

`ensure-keyvault.sh` will detect the vault already exists and skip creation. `ensure-identities.sh` will create the managed identities and set the KV access policy for the backend identity. Bicep will then reference both the vault and the identities as `existing` resources.

---

## Verification

```bash
# Confirm vault is accessible
az keyvault show --name <kv-name> --resource-group <resource-group> --query "{name:name, state:properties.provisioningState}"

# Confirm secrets exist
az keyvault secret list --vault-name <kv-name> --query "[].name" -o table

# Confirm backend identity has access
az keyvault show --name <kv-name> --query "properties.accessPolicies[].{objectId:objectId, permissions:permissions.secrets}" -o table
```

---

## Troubleshooting

### "Vault already exists in deleted state"

The vault was previously deleted (manually or by an old deployment). Recover it to restore secrets:

```bash
# Option 1: Recover (preserves all secrets)
az keyvault recover --name <kv-name> --location <location>

# Option 2: Purge then recreate (secrets lost — requires Key Vault Contributor on subscription)
az keyvault purge --name <kv-name> --location <location>
# Then repeat Steps 2–5 above
```

### "Insufficient privileges to complete the operation"

The deploying principal needs `Key Vault Contributor` on the resource group (to create the vault) and `Key Vault Secrets Officer` (or an access policy granting `set`) to seed secrets. Ask your Azure admin to:

```bash
# Grant Key Vault Contributor to the deploying principal
az role assignment create \
  --role "Key Vault Contributor" \
  --assignee <principal-id-or-upn> \
  --scope /subscriptions/<sub>/resourceGroups/<rg>
```

---

## Related Documentation

- [KEYVAULT-LIFECYCLE.md](KEYVAULT-LIFECYCLE.md) — How KV is managed, secret rotation, propagation to containers
- [KEYVAULT-RETENTION-FLAG.md](KEYVAULT-RETENTION-FLAG.md) — Why the old `DEPLOY_KEY_VAULT` flag was removed

## Calculate Key Vault Name for Your Environment

Each environment gets a unique Key Vault name. Use this command to calculate the exact name:

```powershell
# Calculate Key Vault name for any environment
az deployment group create `
  --resource-group rg-raptor-test `
  --template-file docs/calculate-keyvault-name.bicep `
  --parameters environmentName=<your-env-name> `
  --query properties.outputs.keyVaultName.value `
  -o tsv
```

**Examples:**

```powershell
# For dev environment
az deployment group create --resource-group rg-raptor-test --template-file docs/calculate-keyvault-name.bicep --parameters environmentName=dev --query properties.outputs.keyVaultName.value -o tsv
# Output: kv-dev-rtzig3eodfdtu-v1

# For train environment
az deployment group create --resource-group rg-raptor-test --template-file docs/calculate-keyvault-name.bicep --parameters environmentName=train --query properties.outputs.keyVaultName.value -o tsv
# Output: kv-train-k64rrtsafeuu6-v1

# For test environment
az deployment group create --resource-group rg-raptor-test --template-file docs/calculate-keyvault-name.bicep --parameters environmentName=test --query properties.outputs.keyVaultName.value -o tsv
# Output: kv-test-5cek3a3bpt72c-v1

# For prod environment
az deployment group create --resource-group rg-raptor-test --template-file docs/calculate-keyvault-name.bicep --parameters environmentName=prod --query properties.outputs.keyVaultName.value -o tsv
# Output: kv-prod-exyrbfy7byjho-v1
```

## Your Environment Details (Example: dev)

- **Environment Name**: dev
- **Subscription ID**: <subscription-id>
- **Location**: eastus2
- **Resource Group**: rg-raptor-test
- **Key Vault Name**: `kv-dev-rtzig3eodfdtu-v1`

## Step-by-Step Manual Creation

### Step 1: Calculate the Key Vault Name

First, determine the exact Key Vault name for your environment:

```powershell
# Replace 'dev' with your environment name (dev, train, test, prod)
$kvName = az deployment group create `
  --resource-group rg-raptor-test `
  --template-file docs/calculate-keyvault-name.bicep `
  --parameters environmentName=dev `
  --query properties.outputs.keyVaultName.value `
  -o tsv

Write-Host "Key Vault Name: $kvName"
```

### Step 2: Create the Key Vault

```powershell
# Use the calculated name from Step 1
az keyvault create `
  --name $kvName `
  --resource-group rg-raptor-test `
  --location eastus2 `
  --retention-days 7 `
  --enable-purge-protection true `
  --sku standard
```

**Note**: 
- Soft-delete is enabled by default (cannot be disabled)
- Use `--retention-days 90` for production environments

**Expected Output**: Key Vault created successfully with properties showing soft-delete and purge protection enabled.

### Step 3: Verify Creation

```powershell
# Check vault status
az keyvault show --name $kvName --resource-group rg-raptor-test
```

### Step 4: Run azd up (Secrets Created Automatically)

**You don't need to manually create secrets!** The Bicep templates will automatically read them from your azd environment variables.

Your azd environment already has:
- `OIDC_CLIENT_SECRET`
- `JWT_SECRET`

When you run `azd up`, the deployment will:
1. Detect the existing Key Vault
2. Read secret values from azd environment variables
3. Create/update the secrets in Key Vault automatically
4. Configure access policies for the backend managed identity

```powershell
cd c:\tmp\source-code\rap-prototype\infra
azd up
```

**What happens**: 
- Bicep will detect the Key Vault already exists and will UPDATE it instead of creating new
- Access policies will be added for backend managed identity
- Other resources will be created normally

## Alternative: If You Get Permission Errors

If you don't have permissions to create Key Vault directly, ask your Azure admin to run:

```bash
# As Azure admin with Key Vault Contributor role
az keyvault create \
  --name kv-dev-rtzig3eodfdtu-v1 \
  --resource-group rg-raptor-test \
  --location eastus2 \
  --retention-days 7 \
  --enable-purge-protection true \
  --sku standard

# Create secrets
az keyvault secret set \
  --vault-name kv-dev-rtzig3eodfdtu-v1 \
  --name oidc-client-secret \
  --value "<get-from-user>"

az keyvault secret set \
  --vault-name kv-dev-rtzig3eodfdtu-v1 \
  --name jwt-secret \
  --value "<get-from-user>"

# Grant user access to manage secrets (optional)
az keyvault set-policy \
  --name kv-dev-rtzig3eodfdtu-v1 \
  --upn <your-email@nexgeninc.com> \
  --secret-permissions get list set delete
```

## Troubleshooting

### Issue: "Vault already exists in deleted state"

**Solution**: Ask admin to recover or purge the vault first:

```powershell
# Option 1: Recover (preserves secrets if they exist)
az keyvault recover --name kv-dev-rtzig3eodfdtu-v1 --location eastus2

# Option 2: Purge (permanent deletion - requires special permissions)
az keyvault purge --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
```

### Issue: "Cannot set purge protection to true"

**Reason**: Azure policy requires it - this is expected and correct.

### Issue: Bicep tries to change purge protection

**Solution**: Once purge protection is enabled, it cannot be disabled. Bicep will fail if it tries to set it to false. Ensure `main.bicep` has:

```bicep
var keyVaultEnablePurgeProtection = true  // Required by Azure policy
```

## After Setup

Once the Key Vault is created manually:

1. ✅ Run `azd up` - will succeed and use existing vault
2. ✅ Secrets are preserved across `azd down` / `azd up` cycles
3. ✅ Access policies managed by Bicep automatically
4. ⚠️ Cannot delete vault permanently (purge protection enabled)
5. ℹ️ On `azd down`, vault moves to soft-deleted state for 7 days

## Future: Automated Recovery (After Getting Permissions)

Once your Azure admin grants you **Key Vault Contributor** role at subscription level:

1. Uncomment the recovery script in `infra/azure.yaml`:
   ```yaml
   # Remove the comment from this line:
   ./scripts/recover-or-create-keyvault.ps1
   ```

2. Future `azd up` will automatically recover soft-deleted vaults

3. No more manual intervention needed!

## Quick Reference Commands

```powershell
# Create vault
az keyvault create --name kv-dev-rtzig3eodfdtu-v1 --resource-group rg-raptor-test --location eastus2 --retention-days 7 --enable-purge-protection true

# Add secrets (replace with actual values)
az keyvault secret set --vault-name kv-dev-rtzig3eodfdtu-v1 --name oidc-client-secret --value "YOUR_SECRET_HERE"
az keyvault secret set --vault-name kv-dev-rtzig3eodfdtu-v1 --name jwt-secret --value "YOUR_JWT_KEY_HERE"

# Verify
az keyvault show --name kv-dev-rtzig3eodfdtu-v1 --resource-group rg-raptor-test

# Run deployment
azd up
```
