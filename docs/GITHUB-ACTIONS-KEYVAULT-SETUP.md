# GitHub Actions Key Vault Configuration

## Overview

The infrastructure deployment workflows require the `KEY_VAULT_NAME` environment variable to ensure consistent Key Vault references across local development and CI/CD pipelines. This document explains why this is needed and how to configure it.

## Background

### The Challenge

Azure Key Vault names are generated using a combination of environment identifiers and hashing:

```bicep
var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, location))
var keyVaultName = 'kv-${resourceToken}-v10'
```

The `uniqueString()` function in Bicep uses a proprietary algorithm that cannot be replicated exactly in PowerShell or Bash. While the preprovision scripts use MD5 hashing as an approximation, there's no guarantee of exact match.

### Why It Matters

Without an explicit `KEY_VAULT_NAME`, the preprovision script calculates a name that might:
- Not match the existing Key Vault from local deployment
- Find soft-deleted Key Vaults with conflicting names
- Cause deployment failures with errors like:
  ```
  ConflictError: A vault with the same name already exists in deleted state
  ```

### The Solution

By explicitly setting `KEY_VAULT_NAME` as a GitHub environment variable, we ensure:
1. **Consistency**: Same vault name used across all deployments
2. **Idempotency**: Script finds and reuses existing vault instead of creating new ones
3. **Reliability**: No conflicts with soft-deleted vaults

## Configuration Steps

### Step 1: Get Your Key Vault Name

#### Option A: From Local Deployment
After a successful local deployment, retrieve the Key Vault name:

```powershell
# PowerShell
azd env get-value KEY_VAULT_NAME
```

```bash
# Bash
azd env get-value KEY_VAULT_NAME
```

Example output: `kv-dev-aa00584401909-v10`

#### Option B: From Azure Portal
1. Navigate to your resource group (e.g., `rg-raptor-dev`)
2. Look for the Key Vault resource
3. Copy the name (format: `kv-{resourceToken}-v10`)

#### Option C: From Azure CLI
```bash
# List all Key Vaults in the resource group
az keyvault list --resource-group rg-raptor-dev --query "[].name" -o table
```

### Step 2: Set GitHub Environment Variable

#### Per-Environment Configuration (Recommended)

For each GitHub Environment (dev, test, train, prod):

1. Go to **Settings** → **Environments** in your GitHub repository
2. Select the environment (e.g., `dev`)
3. Under **Environment variables**, click **Add variable**
4. Set:
   - **Name**: `KEY_VAULT_NAME`
   - **Value**: Your Key Vault name (e.g., `kv-dev-aa00584401909-v10`)
5. Click **Add variable**

Repeat for each environment using its corresponding Key Vault name.

#### Repository-Level Configuration (Alternative)

If all environments share the same Key Vault (not recommended for production):

1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Select the **Variables** tab
3. Click **New repository variable**
4. Set:
   - **Name**: `KEY_VAULT_NAME`
   - **Value**: Your Key Vault name
5. Click **Add variable**

### Step 3: Verify Configuration

After configuring, trigger a deployment workflow and check the logs:

**Expected output** (when KEY_VAULT_NAME is set):
```
Using provided KEY_VAULT_NAME: kv-dev-aa00584401909-v10
```

**Warning output** (when KEY_VAULT_NAME is not set):
```
KEY_VAULT_NAME not set - preprovision script will calculate it
```

## Workflows Updated

The following workflows now support `KEY_VAULT_NAME`:

### Deployment Workflows
- ✅ `deploy-backend.yaml` - Backend service deployments
- ✅ `deploy-frontend.yaml` - Frontend service deployments
- ✅ `provision-infrastructure.yaml` - Full infrastructure provisioning

### Promotion Workflows
- ✅ `promote-backend.yaml` - Backend image promotions (dev→test→train→prod)
- ✅ `promote-frontend.yaml` - Frontend image promotions (dev→test→train→prod)

## Implementation Details

### Workflow Environment Variable

All workflows now include:

```yaml
env:
  KEY_VAULT_NAME: ${{ vars.KEY_VAULT_NAME || '' }}
```

This makes the variable available to all steps in the workflow.

### Preprovision Script Integration

Each workflow's "Prepare azd environment" step includes:

```yaml
- name: Prepare azd environment
  run: |
    # ... other azd env set commands ...
    
    # Set Key Vault name if provided (optional - preprovision script will calculate if not set)
    if [ -n "$KEY_VAULT_NAME" ]; then
      azd env set KEY_VAULT_NAME "$KEY_VAULT_NAME"
      echo "Using provided KEY_VAULT_NAME: $KEY_VAULT_NAME"
    else
      echo "KEY_VAULT_NAME not set - preprovision script will calculate it"
    fi
```

This ensures the preprovision script (`ensure-keyvault.ps1`/`.sh`) receives the configured value.

## Troubleshooting

### Error: "A vault with the same name already exists in deleted state"

**Cause**: Preprovision script calculated a name that matches a soft-deleted Key Vault.

**Solution**:
1. Find the correct Key Vault name from Azure Portal or CLI
2. Set `KEY_VAULT_NAME` in GitHub environment variables
3. Re-run the workflow

**Alternative**: Purge the soft-deleted vault (requires Key Vault Contributor role):
```bash
az keyvault purge --name <vault-name>
```

### Error: "Key Vault not found"

**Cause**: Configured `KEY_VAULT_NAME` doesn't exist.

**Solution**:
1. Verify the vault name is correct
2. Check you're deploying to the correct resource group
3. Ensure the vault wasn't accidentally deleted
4. Run a full `azd up` to recreate infrastructure

### Warning: "KEY_VAULT_NAME not set - preprovision script will calculate it"

**Not an Error**: This is normal for initial deployments. The script will calculate a name using MD5 hashing.

**Best Practice**: After initial deployment succeeds, retrieve the Key Vault name and configure it in GitHub for consistency.

## Multi-Environment Setup

For a typical multi-environment setup:

| Environment | Resource Group | Key Vault Name | GitHub Environment |
|------------|---------------|----------------|-------------------|
| dev | `rg-raptor-dev` | `kv-dev-{hash}-v10` | `dev` |
| test | `rg-raptor-test` | `kv-test-{hash}-v10` | `test` |
| train | `rg-raptor-train` | `kv-train-{hash}-v10` | `train` |
| prod | `rg-raptor-prod` | `kv-prod-{hash}-v10` | `prod` |

Each GitHub Environment should have its own `KEY_VAULT_NAME` variable configured.

## Related Documentation

- [ACR Deletion Resilience](./ACR-DELETION-RESILIENCE.md) - Similar pattern for ACR
- [Image Resolution](./IMAGE-RESOLUTION.md) - How container images are resolved
- [Dev Environment Setup](./DEV-ENVIRONMENT-SETUP.md) - Local development setup

## Key Takeaways

1. **Set KEY_VAULT_NAME** in GitHub environment variables for all environments
2. **Get the value** from a successful local deployment or Azure Portal
3. **Per-environment** configuration recommended for production setups
4. **Optional but recommended** - workflows will calculate if not provided
5. **Prevents conflicts** with soft-deleted Key Vaults during CI/CD
