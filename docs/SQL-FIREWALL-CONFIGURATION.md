# SQL Database Firewall Configuration

## Problem

When trying to access Azure SQL Database via Azure Portal Query Editor, you may encounter this error:

```
Cannot open server 'sql-xxxxx' requested by the login.
Client with IP address 'x.x.x.x' is not allowed to access the server.
```

This occurs because the SQL Server firewall blocks external IP addresses by default when VNet integration is disabled.

## Why This Happens

The infrastructure is configured with:
- **VNet Integration**: Disabled (`ENABLE_VNET_INTEGRATION=false`)
- **Public Network Access**: Enabled (for non-VNet deployments)
- **Default Firewall**: Only allows Azure services (0.0.0.0-0.0.0.0)
- **No external IP rules**: Client IPs are blocked

## Solutions

### Solution 1: Quick Fix - Allow Your IP via Portal (Recommended for One-Time Access)

1. When you see the firewall error in Query Editor, click the **"Allowlist IP"** link
2. Azure will automatically add your current IP to the firewall rules
3. Wait ~5 minutes for the change to propagate
4. Refresh the Query Editor page

**Note**: This IP rule will persist until manually removed.

### Solution 2: Enable "Allow All IPs" (Development Only)

⚠️ **WARNING: NOT recommended for production! This opens your database to the internet.**

For development environments where you need consistent access:

```powershell
# Set the parameter
azd env set SQL_ALLOW_ALL_IPS true

# Re-provision infrastructure
azd provision
```

This creates a firewall rule allowing IPs from `0.0.0.0` to `255.255.255.255`.

To disable:
```powershell
azd env set SQL_ALLOW_ALL_IPS false
azd provision
```

### Solution 3: Add Specific IP Ranges (Production)

For controlled access to specific IP ranges (e.g., office networks):

Currently, this requires manual Azure CLI commands:

```powershell
# Add a firewall rule for your office network
az sql server firewall-rule create \
  --resource-group $AZURE_RESOURCE_GROUP \
  --server <sql-server-name> \
  --name "OfficeNetwork" \
  --start-ip-address "203.0.113.0" \
  --end-ip-address "203.0.113.255"
```

**Future Enhancement**: We can extend `main.bicep` to accept an array of IP ranges via parameters.

### Solution 4: Use Private Endpoints (Production - Most Secure)

For production deployments, enable VNet integration with private endpoints:

```powershell
azd env set ENABLE_VNET_INTEGRATION true
azd provision
```

This will:
- Disable public network access to SQL Server
- Create a private endpoint in the VNet
- Configure private DNS resolution
- Only allow access from within the Azure VNet

## Current Configuration

### Default Firewall Rules

When `ENABLE_VNET_INTEGRATION=false` (default):

1. **AllowAllWindowsAzureIps** (0.0.0.0-0.0.0.0)
   - Allows Azure services (Container Apps, Functions, etc.)
   - Does NOT allow external clients

2. **AllowAllIps** (0.0.0.0-255.255.255.255) - **Only if `SQL_ALLOW_ALL_IPS=true`**
   - Allows all internet IPs
   - For development only

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SQL_ALLOW_ALL_IPS` | `false` | Allow all IPs (dev only) |
| `ENABLE_VNET_INTEGRATION` | `false` | Use private endpoints instead of public access |

## Checking Current Firewall Rules

```powershell
# List all firewall rules
az sql server firewall-rule list \
  --resource-group $AZURE_RESOURCE_GROUP \
  --server <sql-server-name> \
  --output table
```

## Troubleshooting

### "My AAD admin was working before, why isn't it now?"

The AAD admin configuration hasn't changed, but firewall rules are independent of authentication. Even with AAD admin configured, you still need firewall access.

**Previous access might have worked because**:
1. A firewall rule was manually added for your IP
2. The SQL Server was temporarily configured differently
3. You were accessing from an Azure service (within Azure network)

### "I added my IP but still can't connect"

1. **Wait 5 minutes** - Firewall changes can take time to propagate
2. **Verify the rule was created**:
   ```powershell
   az sql server firewall-rule list -g $AZURE_RESOURCE_GROUP --server <sql-server-name>
   ```
3. **Check your current IP** - Your IP may have changed (common with home/mobile networks)
4. **Clear browser cache** - Query Editor may cache connection failures

### "I want to remove all public access"

Enable VNet integration:
```powershell
azd env set ENABLE_VNET_INTEGRATION true
azd provision
```

This will set `publicNetworkAccess: 'Disabled'` on the SQL Server.

## Security Best Practices

### Development
- ✅ Use `SQL_ALLOW_ALL_IPS=true` for local development environments
- ✅ Use one-time IP allowlist via Portal for occasional access
- ❌ Don't expose dev databases with production data

### Production
- ✅ Enable VNet integration with private endpoints
- ✅ Use specific IP ranges for known networks only
- ✅ Regularly audit firewall rules
- ❌ Never use `SQL_ALLOW_ALL_IPS=true` in production
- ❌ Don't allow 0.0.0.0-255.255.255.255 ranges

## Related Files

- **Bicep Module**: `infra/modules/sqlDatabase.bicep` - Firewall rule definitions
- **Main Template**: `infra/main.bicep` - SQL_ALLOW_ALL_IPS parameter
- **Parameters**: `infra/main.parameters.json` - Parameter mapping
- **Workflow**: `infra/.github/workflows/provision-infrastructure.yaml` - Deployment pipeline
