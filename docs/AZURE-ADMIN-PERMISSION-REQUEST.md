# Azure Permission Request: Key Vault Management

## Executive Summary

Our deployment automation requires permissions to manage soft-deleted Key Vaults to enable efficient development workflows and minimize unnecessary Azure costs.

---

## Current Issue

Our service principal lacks permissions to view, recover, or purge soft-deleted Key Vaults, which creates operational bottlenecks and unnecessary costs during development cycles.

### Service Principal Details
- **Client ID**: `e22cd074-2f43-4262-af66-bfa30e67c4d8`
- **Object ID**: `6ed5ad18-23d5-4098-ac8e-b8b1de016d06`
- **Subscription**: NexGen Dev/Test (`5b489d19-6e0a-45bd-be65-d7d1c40af428`)

---

## Missing Permissions

The service principal requires these permissions at the **subscription level**:

1. **`Microsoft.KeyVault/locations/deletedVaults/read`**
   - View soft-deleted Key Vaults
   - Check if a vault name is available before creation

2. **`Microsoft.KeyVault/locations/deletedVaults/purge/action`**
   - Permanently delete soft-deleted Key Vaults
   - Free up vault names for reuse

3. **`Microsoft.KeyVault/vaults/write`** (already has this)
   - Create and update Key Vaults

### Recommended Role Assignment Options

#### Option 1: Built-in Role (Recommended - Easiest)

**Role**: `Key Vault Contributor` (built-in role)  
**Scope**: Subscription level (`/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428`)  
**Permissions**: `Microsoft.KeyVault/*` (all Key Vault operations)

**Azure CLI Command:**
```bash
az role assignment create \
  --assignee e22cd074-2f43-4262-af66-bfa30e67c4d8 \
  --role "Key Vault Contributor" \
  --scope "/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428"
```

**Azure Portal Steps:**
1. Navigate to: Subscriptions → NexGen Dev/Test → Access Control (IAM)
2. Click: Add → Add role assignment
3. Select role: **Key Vault Contributor**
4. Select members: Service Principal (Object ID: `6ed5ad18-23d5-4098-ac8e-b8b1de016d06`)
5. Review + assign

#### Option 2: Minimal Custom Role (Most Secure)

If you prefer to grant only the exact permissions needed (principle of least privilege), create a custom role:

**Custom Role Definition** (provided in `infra/docs/keyvault-lifecycle-role.json`):
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

##### Azure Portal Steps (Recommended for GUI users)

**Step 1: Create the Custom Role**

1. Open Azure Portal → Search for **"Subscriptions"**
2. Click on **"NexGen Dev/Test"** subscription
3. In left menu, click **"Access control (IAM)"**
4. Click **"+ Add"** → Select **"Add custom role"**
5. **Basics tab:**
   - Role name: `Key Vault Lifecycle Manager`
   - Description: `Minimal permissions to view, recover, and purge soft-deleted Key Vaults`
   - Baseline permissions: Start from scratch
   - Click **"Next"**

6. **Permissions tab:**
   - Click **"+ Add permissions"**
   - Search for: `Microsoft.KeyVault`
   - Expand **Microsoft.KeyVault**
   - Expand **locations/deletedVaults**
   - Check: ☑ **Read : Get deleted vault** (`read`)
   - Check: ☑ **Other : Purges soft deleted vault** (`purge/action`)
   - Expand **vaults** (scroll down)
   - Check: ☑ **Read : Get vault** (`read`)
   - Check: ☑ **Write : Create or update vault** (`write`)
   - Click **"Add"**
   - Click **"Next"**

7. **Assignable scopes tab:**
   - Should show: Subscription - NexGen Dev/Test
   - Click **"Next"**

8. **JSON tab:**
   - Review the generated JSON (should match above)
   - Click **"Next"**

9. **Review + create:**
   - Click **"Create"**

**Step 2: Assign the Custom Role to Service Principal**

1. Still in **Subscriptions → NexGen Dev/Test → Access control (IAM)**
2. Click **"+ Add"** → Select **"Add role assignment"**
3. **Role tab:**
   - In the search box, type: `Key Vault Lifecycle Manager`
   - Select the custom role you just created
   - Click **"Next"**

4. **Members tab:**
   - Select: **"User, group, or service principal"**
   - Click **"+ Select members"**
   - In search box, paste: `e22cd074-2f43-4262-af66-bfa30e67c4d8` OR `6ed5ad18-23d5-4098-ac8e-b8b1de016d06`
   - Select the service principal from results
   - Click **"Select"**
   - Click **"Next"**

5. **Review + assign:**
   - Click **"Review + assign"**
   - Click **"Review + assign"** again (confirmation)

✅ Done! The service principal now has minimal permissions to manage deleted Key Vaults.

##### Azure CLI Commands (Alternative)

If you prefer command-line:

```bash
# Create the custom role
az role definition create --role-definition @keyvault-lifecycle-role.json

# Assign the custom role to the service principal
az role assignment create \
  --assignee e22cd074-2f43-4262-af66-bfa30e67c4d8 \
  --role "Key Vault Lifecycle Manager" \
  --scope "/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428"
```

**Comparison:**

| Aspect | Built-in Role | Custom Role |
|--------|--------------|-------------|
| Permissions | All Key Vault operations | Only deleted vault management |
| Setup Time | 1 minute | 5 minutes |
| Maintenance | Zero (Microsoft-managed) | Update if Azure changes APIs |
| Security | Broader permissions | Minimal permissions |
| Recommendation | ✅ Standard practice | ⚠️ Only if security policy requires |

---

## Business Impact

### Without These Permissions (Current State)

**Development Workflow:**
1. Developer runs `azd down` to clean up resources
2. Key Vault enters soft-deleted state (7-day retention for dev environments)
3. Developer attempts `azd up` to redeploy
4. ❌ **Deployment fails**: "A vault with the same name already exists in deleted state"
5. Developer must:
   - Wait 7 days for automatic purge, OR
   - Manually create vault with new name (creates naming inconsistencies), OR
   - Request admin intervention to purge vault

**Cost Impact:**
- Each soft-deleted Key Vault costs ~**$0.03/month** in retention fees
- Multiple dev/test cycles accumulate these costs unnecessarily
- Example: 10 failed deployments over 7 days = **$0.30 extra cost** (small but avoidable)

**Time Impact:**
- Manual intervention required for each deployment cycle
- Estimated **15-30 minutes delay per incident**
- Blocks developer productivity and testing

### With These Permissions (Proposed Solution)

**Automated Development Workflow:**
1. Developer runs `azd down` → Key Vault soft-deleted
2. Developer runs `azd up` → Automation script detects soft-deleted vault
3. **Script automatically recovers the vault** (if needed) or **purges it** (if changing configuration)
4. ✅ **Deployment succeeds immediately**

**Benefits:**
- Zero manual intervention required
- Eliminates unnecessary retention costs
- Enables rapid dev/test iterations
- Consistent naming across deployments
- Developer self-service capability

---

## Cost Analysis

### Key Vault Costs (Azure Pricing as of 2025)

| Component | Cost | Notes |
|-----------|------|-------|
| Active Key Vault | ~$0.03/month | Standard tier |
| Soft-deleted vault retention | ~$0.03/month | Same as active vault |
| Secret operations | $0.03 per 10,000 operations | Minimal in dev |

### Scenario: Development Cycle Without Purge Permissions

**Conservative estimate:**
- 4 developers × 2 deployments/week = 8 deployment cycles/month
- Average 3 failed attempts per cycle due to soft-delete conflicts = 24 extra vaults
- Retention period: 7 days average before auto-purge
- Monthly accumulated retention cost: **24 vaults × $0.03 × (7/30) = $0.17/month**

**Annualized unnecessary cost**: ~**$2/year** (minimal but completely avoidable)

### More Important: Developer Productivity

- **Manual intervention time**: 20 minutes average per incident
- **24 incidents/month** × 20 minutes = **8 hours/month of blocked productivity**
- Developer hourly cost: $75/hour (estimated)
- **Monthly productivity loss**: 8 hours × $75 = **$600/month** = **$7,200/year**

**ROI: The permission grant eliminates $7,200/year in productivity loss for a one-time 5-minute configuration change.**

---

## Security Considerations

### Why Subscription-Level Scope?

- Soft-deleted vaults exist at the **subscription/location level**, not within resource groups
- Permissions must be granted at subscription scope to view/manage deleted vaults
- This is standard practice for Key Vault lifecycle management

### Risk Mitigation

1. **Purge protection is enabled** by subscription policy (cannot be disabled)
   - Prevents accidental permanent deletion of production secrets
   
2. **Service principal scope is limited**:
   - Already has write access to create vaults (no new create permissions needed)
   - Only adds ability to view and clean up soft-deleted vaults
   - Cannot bypass purge protection in production

3. **Audit trail maintained**:
   - All purge operations are logged in Azure Activity Log
   - Can be monitored via Azure Monitor alerts if needed

---

## Technical Details

### Current Error Examples

**Attempting to list deleted vaults:**
```
ERROR: (AuthorizationFailed) The client 'e22cd074-2f43-4262-af66-bfa30e67c4d8' 
with object id '6ed5ad18-23d5-4098-ac8e-b8b1de016d06' does not have authorization 
to perform action 'Microsoft.KeyVault/locations/deletedVaults/read' over scope 
'/subscriptions/5b489d19-6e0a-45bd-be65-d7d1c40af428/providers/Microsoft.KeyVault/...'
```

**Attempting to purge deleted vault:**
```
ERROR: (AuthorizationFailed) ... does not have authorization to perform action 
'Microsoft.KeyVault/locations/deletedVaults/purge/action'
```

### Automation Script (Ready to Deploy)

We have already implemented the automation script that will:
1. Check for soft-deleted vaults matching the environment naming pattern
2. Recover vaults if needed (preserving existing secrets)
3. Purge vaults when configuration changes require a fresh start
4. Handle all scenarios automatically without manual intervention

**Script location**: `infra/scripts/recover-or-create-keyvault.ps1` (currently commented out)

The script is ready to uncomment and use immediately after permissions are granted.

---

## Testing Commands

After granting permissions, verify with these commands:

```powershell
# Test 1: List deleted vaults (should succeed)
az keyvault list-deleted --query "[].{Name:name, Location:location}" -o table

# Test 2: View specific deleted vault (should succeed)
az keyvault show-deleted --name kv-dev-rtzig3eodfdtu-v1 --location eastus2

# Test 3: Purge deleted vault (should succeed)
az keyvault purge --name kv-dev-rtzig3eodfdtu-v1 --location eastus2
```

Expected result: All commands complete successfully without AuthorizationFailed errors.

---

## Implementation Timeline

| Step | Duration | Owner |
|------|----------|-------|
| Review & approve request | 1 business day | Azure Admin |
| Grant role assignment | 5 minutes | Azure Admin |
| Verify permissions | 5 minutes | DevOps Team |
| Uncomment automation script | 2 minutes | DevOps Team |
| Test full deployment cycle | 10 minutes | DevOps Team |
| **Total** | **~1 day** | |

---

## Questions?

**Contact**: DevOps Team  
**Priority**: Medium (blocks efficient development workflows)  
**Documentation**: See `infra/docs/KEYVAULT-LIFECYCLE.md` for full technical details

---

## Appendix: Key Vault Soft-Delete Behavior

- **Enabled by default**: Cannot be disabled (Azure enforces this)
- **Retention period**: 7-90 days (we use 7 for dev, 90 for prod)
- **Purge protection**: Enabled by subscription policy (cannot be disabled)
- **Auto-purge**: Vaults automatically purge after retention period expires
- **Manual purge**: Requires explicit permissions (this request)
- **Recovery**: Allows restoring accidentally deleted vaults with all secrets intact

**Why we need purge capability**: During development, we need to test infrastructure changes that require fresh Key Vault creation. Waiting 7 days for auto-purge between tests is not practical.
