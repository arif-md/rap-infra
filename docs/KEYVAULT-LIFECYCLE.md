# Key Vault Lifecycle Management

## Overview

The infrastructure uses environment-aware Key Vault configuration to balance security, cost, and operational flexibility across different deployment environments.

## Environment-Specific Configuration

**Important**: Azure subscription policy requires purge protection to be enabled on all Key Vaults. To support frequent `azd up/down` cycles, the infrastructure includes an **automatic recovery mechanism** that recovers soft-deleted vaults before attempting to create new ones.

### Lower Environments (dev, test, train)

```bicep
softDeleteRetentionInDays: 7      // Minimum retention period
enablePurgeProtection: true       // Required by Azure policy
```

**Benefits:**
- Automatic vault recovery on `azd up` (no manual intervention needed)
- 7-day soft-delete window for accident recovery
- Auto-purge after 7 days (no permanent orphaned vaults)
- Supports frequent dev/test cycles

**Workflow:**
1. `azd down` - Deletes vault (goes to soft-deleted state)
2. `azd up` - Automatically recovers the soft-deleted vault
3. Secrets and configuration preserved across cycles

**Cost:** ~$0.03/month (active) + up to 7 days retention after `azd down`

### Production Environment

```bicep
softDeleteRetentionInDays: 90     // Maximum retention period
enablePurgeProtection: true        // Prevents permanent deletion
```

**Benefits:**
- Protection against accidental or malicious deletion
- 90-day recovery window
- Compliance with audit requirements
- Cannot be permanently deleted (even by admins)

**Cost:** ~$0.03/month (active) + 90 days retention after deletion

## How It Works

### Secret Management

**Q: If there are no secrets in Key Vault, will it get configured secrets from environment variables?**

**A:** Yes! The Bicep template **always updates secrets** on every `azd up` deployment:

1. Set environment variables:
   ```powershell
   azd env set OIDC_CLIENT_SECRET "your-secret"
   azd env set JWT_SECRET "your-jwt-key-min-32-chars"
   ```

2. Run deployment:
   ```powershell
   azd up
   ```

3. Bicep creates/updates secrets in Key Vault:
   - If secret doesn't exist → creates it
   - If secret exists with different value → updates it
   - If secret exists with same value → no change (idempotent)

### Naming Strategy

**Predictable, environment-based naming:**
```bicep
var resourceToken = toLower('${environmentName}-${uniqueString(subscription().id, environmentName)}')
// Example: kv-dev-abc123xyz
```

**Benefits:**
- Same Key Vault reused across deployments
- No soft-delete conflicts on re-deployment
- Easy to identify which environment a vault belongs to

### Lifecycle Operations

#### Create/Update Infrastructure
```powershell
azd up
```
- Creates Key Vault if it doesn't exist
- Updates Key Vault configuration if it exists
- Creates/updates secrets from environment variables

#### Delete Infrastructure (Lower Environments)
```powershell
azd down          # Deletes resources, Key Vault goes to soft-deleted state
azd down --purge  # Permanently deletes Key Vault immediately (requires permissions)
```

#### Delete Infrastructure (Production)
```powershell
azd down          # Deletes resources, Key Vault CANNOT be purged (protection enabled)
```

To recover a production Key Vault:
```powershell
az keyvault recover --name kv-prod-xyz --location eastus2
```

## Environment Detection

The infrastructure automatically detects the environment:

```bicep
var isProduction = environmentName == 'prod' || environmentName == 'production'
```

**Set environment name:**
```powershell
azd env new dev      # For development
azd env new test     # For testing
azd env new prod     # For production
```

## GitHub Secrets Configuration

For GitHub Actions workflows, set these repository secrets:
- `OIDC_CLIENT_SECRET` - Your Keycloak/OIDC provider client secret
- `JWT_SECRET` - Your JWT signing key (min 32 characters)

The workflow will pass these to the Bicep deployment.

## Cost Optimization

### Development Workflow
1. Use `azd down --purge` to permanently delete resources immediately
2. No cost after purge completes
3. Re-run `azd up` when needed

### Long-Running Lower Environments
1. Use `azd down` (soft-delete for 7 days)
2. Pay for 7 days retention (~$0.07 total)
3. Automatic purge after 7 days

### Production
1. Soft-delete retention: 90 days
2. Purge protection prevents deletion
3. Cost continues until vault is recovered or retention expires

## Troubleshooting

### "Vault with same name exists in deleted state"

**Lower environments:**
```powershell
# Option 1: Purge the deleted vault (requires permissions)
az keyvault purge --name kv-dev-xyz --location eastus2

# Option 2: Recover the deleted vault
az keyvault recover --name kv-dev-xyz

# Option 3: Change environment name
azd env new dev2
azd up
```

**Production:**
```powershell
# Purge protection enabled - can only recover
az keyvault recover --name kv-prod-xyz --location eastus2
```

### Permission Issues

If you don't have permissions to view/purge deleted vaults:
- Contact subscription admin to grant: `Key Vault Contributor` role
- Or use Option 3 above (change environment name)

### Secrets Not Updating

Check environment variables are set:
```powershell
azd env get-values | Select-String "SECRET"
```

If missing, set them:
```powershell
azd env set OIDC_CLIENT_SECRET "value"
azd env set JWT_SECRET "value"
azd up
```

## Best Practices

1. **Never commit secrets** to git - use `azd env set` or GitHub Secrets
2. **Use different environment names** for isolation (dev, test, prod)
3. **Enable purge protection in production** (already configured)
4. **Rotate secrets regularly** - just update env vars and run `azd up`
5. **Clean up lower environments** - use `azd down --purge` when not needed
6. **Monitor costs** - check Azure Cost Management for Key Vault charges

## References

- [Azure Key Vault Soft-Delete](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview)
- [Azure Key Vault Purge Protection](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview#purge-protection)
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/)
