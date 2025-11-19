# Manual Key Vault Creation Guide

## Current Situation

Due to Azure subscription policies requiring purge protection on Key Vaults, and limited permissions to recover soft-deleted vaults, you need to manually create the Key Vault before running `azd up`.

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
