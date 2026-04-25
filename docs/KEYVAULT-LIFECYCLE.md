# Key Vault Lifecycle Management

## Overview

Key Vault is managed **outside** the `azd` deployment stack. It is created and maintained by the `ensure-keyvault.sh` / `ensure-keyvault.ps1` pre-provision hook, which runs automatically before every `azd up`. Bicep references the vault as an `existing` resource — this means the deployment stack never tracks it, and `azd down` never deletes or soft-deletes it.

---

## Lifecycle at a Glance

```
azd up
  └─ Pre-provision hooks (in order)
       ├─ ensure-keyvault.sh   → creates KV if missing; seeds secrets (create-only)
       ├─ ensure-identities.sh → creates managed identities; grants backend identity KV access
       │                         (ARM-polled until confirmed; +15s data-plane buffer)
       └─ … other hooks …
  └─ Bicep deployment
       ├─ references KV as 'existing' (not in stack)
       ├─ references identities as 'existing' (not in stack)
       └─ deploys Container Apps, SQL, App Config, CAE, …

azd down
  └─ deletes only stack-managed resources
  └─ Key Vault untouched (not in stack)
  └─ Managed identities untouched (not in stack)
```

---

## Key Vault Naming

The vault name is derived by `ensure-keyvault.sh` using an md5 hash of `subscriptionId + environmentName`, then stored in the azd environment and passed to Bicep as the `KEY_VAULT_NAME` parameter override.

```
kv-{environmentName}-{13-char-hash}-v10
```

Example: `kv-dev-aa00584401909-v10`

The version suffix (`-v10`) is incremented in `ensure-keyvault.sh` whenever a naming change is needed to avoid soft-delete conflicts with old vaults.

---

## Secret Management

### How Secrets Are Seeded (Initial Creation Only)

Secrets are seeded by `ensure-keyvault.sh` during the pre-provision hook. The function is **create-only**: if a secret already exists in Key Vault, it is skipped regardless of the value in the azd environment variable. Key Vault is the source of truth after initial seeding.

```
ensure-keyvault.sh runs:
  secret 'jwt-secret' exists? → skip
  secret 'jwt-secret' missing? → create from $JWT_SECRET env var
```

Secrets managed:
- `jwt-secret` — JWT signing key (from `JWT_SECRET` azd env var on first run)
- `aad-client-secret` — Azure AD client secret (from `AZURE_AD_CLIENT_SECRET`)
- `oidc-client-secret` — OIDC provider client secret (from `OIDC_CLIENT_SECRET`)

### What Bicep Does With Secrets

Bicep does **not** create or update secrets. It only:
1. References the existing Key Vault as `existing`
2. Wires KV URL secret references into the Container App (`keyVaultUrl: '${kv.properties.vaultUri}secrets/jwt-secret'`)

### How Secrets Reach the Running Container

Container Apps fetches each KV-referenced secret **once per revision**, at revision activation time, and caches the value as an OS environment variable. The Spring Boot process reads `${JWT_SECRET}` from the environment at startup.

```
KV secret value
  └─ fetched at revision activation → cached in Container App revision
       └─ injected as OS env var when container process starts
            └─ Spring Boot reads it at startup (static for life of the process)
```

**Consequence:** Rotating a secret in KV alone does not affect the currently running revision. A new revision must be created to pick up the rotated value.

---

## Secret Rotation

Key Vault is the authoritative source. The GitHub environment variable for a secret is used only for the initial seed. Rotation does **not** require updating GitHub secrets.

### Rotation Procedure

```bash
# Step 1 — Update the secret directly in Key Vault
az keyvault secret set \
  --vault-name kv-dev-aa00584401909-v10 \
  --name jwt-secret \
  --value "<new-value>"

# Step 2 — Create a new Container App revision to pick up the new value
# Option A: run azd provision (creates a new revision as part of deployment)
azd provision

# Option B: copy the current revision (faster, no full deployment needed)
az containerapp revision copy \
  --name dev-rap-be \
  --resource-group rg-raptor-dev
```

The new revision fetches the updated KV secret value at activation. The old revision continues running with the cached old value until traffic is shifted to the new revision (or replicas are cycled).

> **Do NOT run `azd provision` expecting it to push the new secret value from the GitHub env var into KV** — `ensure-keyvault.sh` is create-only and will skip the secret if it already exists.

---

## Managed Identity Access to Key Vault

Access policies (backend identity gets `get` + `list` on KV secrets) are set by `ensure-identities.sh`, not by Bicep. This happens in the same pre-provision hook run as KV creation.

The script polls the ARM control plane until the policy write is confirmed (up to 120s), then waits a 15-second fixed buffer for KV data-plane propagation. This eliminates the race condition where Container Apps validates KV URL secret references before the access policy has replicated.

```
ensure-identities.sh:
  1. Create identity (if missing)
  2. az keyvault set-policy (get, list)
  3. Poll ARM until policy appears in accessPolicies[]
  4. Wait 15s (KV data-plane sync buffer)
  → Bicep deploys Container App → KV validation succeeds
```

---

## Environment-Specific Configuration

```bicep
softDeleteRetentionInDays: isProduction ? 90 : 7
enablePurgeProtection: true   // Required by Azure policy — cannot be disabled
```

| Environment | Soft-delete retention | Purge protection |
|-------------|----------------------|------------------|
| dev / test  | 7 days               | enabled          |
| prod        | 90 days              | enabled          |

Because KV is never deleted by `azd down`, the soft-delete retention is only relevant if the vault is manually deleted.

---

## Troubleshooting

### "unable to fetch secret using Managed identity" (Container App deployment failure)

This is the KV data-plane propagation race condition. `ensure-identities.sh` was designed to prevent it. If it still occurs:

1. Check that `ensure-identities.sh` ran in the pre-provision hook and completed successfully
2. Check that the backend identity name in Azure matches `BACKEND_IDENTITY_NAME` in the azd env
3. Verify the KV access policy exists: `az keyvault show --name <kv> --query "properties.accessPolicies"`

### "Vault with same name exists in deleted state"

This happens if the vault was manually deleted (not via `azd down`):

```bash
# Recover (preserves secrets)
az keyvault recover --name kv-dev-aa00584401909-v10 --location eastus2

# Or purge (permanent — requires Key Vault Contributor on subscription)
az keyvault purge --name kv-dev-aa00584401909-v10 --location eastus2
```

### Secret value not updating after rotation

The running revision still has the old cached value. Create a new revision:
```bash
az containerapp revision copy --name dev-rap-be --resource-group rg-raptor-dev
```

---

## Related Documentation

- [KEYVAULT-RETENTION-FLAG.md](KEYVAULT-RETENTION-FLAG.md) — Why the old retention flag was removed
- [MANUAL-KEYVAULT-SETUP.md](MANUAL-KEYVAULT-SETUP.md) — First-time Key Vault creation (if pre-provision hook cannot create it)

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
