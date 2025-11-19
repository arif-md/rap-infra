# Key Vault Retention Flag

## Overview

The `DEPLOY_KEY_VAULT` environment variable controls whether the Key Vault is managed by `azd` deployment stacks. This is useful when dealing with Key Vault soft-delete conflicts during development.

## How It Works

**Deployment Stack Behavior:**
- Azure deployment stacks track which resources were deployed and manage their lifecycle
- When `azd down` runs, it deletes all resources **that were in the deployment stack**
- Simply setting `DEPLOY_KEY_VAULT=false` and running `azd down` will NOT work - the Key Vault will still be deleted because it was in the original stack

**The Correct Solution:**
To preserve Key Vault, you must **remove it from the stack BEFORE running azd down** by deploying without it first:

1. Deploy with `DEPLOY_KEY_VAULT=false` (updates stack to exclude Key Vault)
2. Then run `azd down` (only deletes resources currently in stack)

**Detailed Flow:**

- **`DEPLOY_KEY_VAULT=true` (default)**: Key Vault is deployed and managed by deployment stack
  - On `azd up`: Creates or updates Key Vault (added to deployment stack)
  - On `azd down`: Deletes Key Vault (enters soft-delete state for 7 days in dev)
  
- **`DEPLOY_KEY_VAULT=false`**: Key Vault is excluded from deployment stack
  - On `azd up`: Skips Key Vault deployment, uses existing vault, **removes it from stack**
  - On `azd down` (after running `azd up` with flag=false): Preserves Key Vault
  - Backend container app will reference existing Key Vault by name

## Usage

### ⚠️ IMPORTANT: Correct Workflow to Preserve Key Vault

To preserve the Key Vault when running `azd down`, you MUST follow this sequence:

```powershell
# Step 1: Deploy normally (Key Vault created and added to stack)
azd env set DEPLOY_KEY_VAULT true
azd up

# Step 2: Update deployment to exclude Key Vault from stack
azd env set DEPLOY_KEY_VAULT false
azd up  # This removes Key Vault from deployment stack

# Step 3: Now azd down will preserve the Key Vault
azd down --force  # Deletes other resources, KEEPS Key Vault
```

**Why this workflow is necessary:**
- Deployment stacks track what was deployed, not just what's in the current template
- Simply setting the flag to `false` and running `azd down` immediately **will still delete the Key Vault**
- You must run `azd up` with `DEPLOY_KEY_VAULT=false` first to update the stack

### Option 1: Set Environment Variable for Current Session

```powershell
# Retain Key Vault when running azd down
azd env set DEPLOY_KEY_VAULT false

# Re-enable Key Vault management
azd env set DEPLOY_KEY_VAULT true
```

### Option 2: Use with azd down Command

```powershell
# Normal deployment (Key Vault managed)
azd up

# To preserve Key Vault:
azd env set DEPLOY_KEY_VAULT false
azd up                # CRITICAL: Update stack to exclude Key Vault
azd down --force     # Now Key Vault is preserved

# Re-enable for next deployment
azd env set DEPLOY_KEY_VAULT true
azd up
```

## Common Scenarios

### Scenario 1: Avoid Soft-Delete Conflicts During Development

When you're frequently running `azd down` / `azd up` cycles and hitting the 7-day soft-delete retention:

```powershell
# Initial deployment (creates Key Vault v5)
azd env set DEPLOY_KEY_VAULT true
azd up

# Remove Key Vault from deployment stack
azd env set DEPLOY_KEY_VAULT false
azd up  # IMPORTANT: This step removes Key Vault from stack

# Now you can run azd down/up repeatedly without Key Vault conflicts
azd down --force  # Deletes other resources, keeps Key Vault v5
azd up            # Redeploys using existing Key Vault v5

# The Key Vault persists across cycles
```

**Note**: When `DEPLOY_KEY_VAULT=false`, ensure:
1. The Key Vault already exists before running `azd up`
2. The Key Vault name matches the expected pattern in `main.bicep` line 354-355
3. Required secrets exist in the vault: `oidc-client-secret`, `jwt-secret`

### Scenario 2: Temporary Key Vault Retention

If you want to keep Key Vault for a specific deployment but normally manage it:

```powershell
# Deploy normally
azd up

# Temporarily disable Key Vault management
azd env set DEPLOY_KEY_VAULT false

# Clean up other resources (keeps Key Vault)
azd down --force

# Do some work...

# Re-deploy without recreating Key Vault
azd up

# Re-enable Key Vault management
azd env set DEPLOY_KEY_VAULT true
```

### Scenario 3: Production Environment (Always Retain)

For production, you may want to permanently disable Key Vault deletion:

```powershell
# Set environment to prod
azd env new prod
azd env set DEPLOY_KEY_VAULT false

# Key Vault will never be deleted by azd down
azd up
azd down --force  # Deletes other resources, keeps Key Vault
```

## Important Notes

1. **Existing Key Vault Required**: When `DEPLOY_KEY_VAULT=false`, the Key Vault must already exist. The backend container app expects:
   - Key Vault name: `kv-{environmentName}-{uniqueString}-v4`
   - Required secrets: `oidc-client-secret`, `jwt-secret`

2. **Backend Configuration**: When Key Vault is not deployed, ensure the backend can still access it via managed identity with proper access policies.

3. **Manual Cleanup**: If `DEPLOY_KEY_VAULT=false`, you'll need to manually delete the Key Vault when it's no longer needed:
   ```powershell
   az keyvault delete --name kv-dev-rtzig3eodfdtu-v4
   az keyvault purge --name kv-dev-rtzig3eodfdtu-v4  # Requires permissions
   ```

4. **Version Management**: The `-v4` suffix remains in the Key Vault name. If you need to increment versions, update `main.bicep` line 177.

## Verification

Check current setting:
```powershell
azd env get-value DEPLOY_KEY_VAULT
```

Check deployed resources:
```powershell
az keyvault list --resource-group rg-raptor-{env} --query "[].name" -o table
```

## Related Documentation

- [KEYVAULT-LIFECYCLE.md](KEYVAULT-LIFECYCLE.md) - Complete Key Vault lifecycle management
- [AZURE-ADMIN-PERMISSION-REQUEST.md](AZURE-ADMIN-PERMISSION-REQUEST.md) - Permission requirements for purging soft-deleted vaults
- [MANUAL-KEYVAULT-SETUP.md](MANUAL-KEYVAULT-SETUP.md) - Manual Key Vault creation steps
