# Network Configuration Guide

This guide explains how to configure your infrastructure with or without VNet integration and SQL Private Endpoints.

## Configuration Modes

### Mode 1: Public Access (Default - No VNet Integration)
**Current Configuration** - Works without `Microsoft.ContainerService` provider

- ✅ Container Apps use public endpoints
- ✅ SQL Database allows Azure services via firewall rules
- ✅ No VNet required
- ✅ Simpler setup, lower cost
- ⚠️ Less secure (uses public internet with firewall rules)

**Configuration:**
```bash
# In .azure/<env-name>/.env or as environment variable
ENABLE_VNET_INTEGRATION=false
```

### Mode 2: Private Access with VNet Integration
**Requires:** `Microsoft.ContainerService` resource provider registration

- ✅ Container Apps deployed in private VNet
- ✅ SQL Database uses Private Endpoint (no public access)
- ✅ All traffic stays within Azure backbone
- ✅ Production-grade security
- ⚠️ Requires `Microsoft.ContainerService` provider registration
- ⚠️ Slightly higher cost (Private Endpoint charges)

**Configuration:**
```bash
# In .azure/<env-name>/.env or as environment variable
ENABLE_VNET_INTEGRATION=true
```

## How to Switch Between Modes

### Option A: Using azd environment variables (Recommended)

```powershell
# Switch to your environment
azd env select <environment-name>

# For Public Access (Default)
azd env set ENABLE_VNET_INTEGRATION false

# For Private Access with VNet (After provider registration)
azd env set ENABLE_VNET_INTEGRATION true

# Apply the changes
azd provision
```

### Option B: Edit main.parameters.json

Change line 27 in `main.parameters.json`:

```json
// For Public Access (Default)
"enableVnetIntegration": {
  "value": "${ENABLE_VNET_INTEGRATION=false}"
}

// For Private Access with VNet
"enableVnetIntegration": {
  "value": "${ENABLE_VNET_INTEGRATION=true}"
}
```

### Option C: Edit main.bicep directly

Change line 53 in `main.bicep`:

```bicep
// For Public Access (Default)
param enableVnetIntegration bool = false

// For Private Access with VNet
param enableVnetIntegration bool = true
```

## Registering Microsoft.ContainerService Provider

**Required for Mode 2 (Private Access)**

Contact your Azure administrator to run:

```bash
az provider register --namespace Microsoft.ContainerService --wait
```

Or register via Azure Portal:
1. Go to your Subscription
2. Navigate to "Resource providers"
3. Search for "Microsoft.ContainerService"
4. Click "Register"

Verify registration status:
```bash
az provider show --namespace Microsoft.ContainerService --query "registrationState"
```

Wait until status shows: `"Registered"`

## Network Architecture

### Mode 1: Public Access
```
Internet
   ↓
Container Apps (Public) → SQL Database (Public with Firewall)
```

### Mode 2: Private Access
```
Container Apps Environment
   ↓ (VNet: 10.0.0.0/16)
   ├─ Container Apps Subnet (10.0.0.0/23)
   │    ↓
   │  Container Apps (Internal)
   │
   └─ Private Endpoints Subnet (10.0.2.0/24)
        ↓
      SQL Private Endpoint → SQL Database (Private)
        ↓
      Private DNS Zone (privatelink.database.windows.net)
```

## What Gets Deployed

| Resource | Mode 1 (Public) | Mode 2 (Private) |
|----------|-----------------|------------------|
| VNet | ❌ Not deployed | ✅ Deployed |
| Private DNS Zone | ❌ Not deployed | ✅ Deployed |
| Container Apps Environment | ✅ Public | ✅ VNet-integrated |
| SQL Server | ✅ Public firewall | ✅ Private endpoint only |
| Container Apps | ✅ Public | ✅ Internal |

## Connection Strings

### Mode 1 (Public Access)
Backend connects to SQL using:
```
Server=tcp:sql-xxxxx.database.windows.net,1433;Database=db-raptor-dev;Authentication=Active Directory Default;
```

SQL Server firewall allows Azure services.

### Mode 2 (Private Access)
Backend connects to SQL using:
```
Server=tcp:sql-xxxxx.database.windows.net,1433;Database=db-raptor-dev;Authentication=Active Directory Default;
```

DNS resolves to private IP (10.0.2.x) via Private DNS Zone.

## Testing

### Verify Public Mode (Mode 1)
```bash
azd provision
# Should succeed without Microsoft.ContainerService provider
```

### Verify Private Mode (Mode 2)
```bash
# After provider registration
azd env set ENABLE_VNET_INTEGRATION true
azd provision
# Should deploy VNet, Private Endpoint, etc.
```

## Troubleshooting

### Error: "SubscriptionIsNotRegistered: ... Microsoft.ContainerService"

**Cause:** Trying to use Mode 2 (VNet integration) without provider registration

**Solution:** 
1. Switch to Mode 1 (set `ENABLE_VNET_INTEGRATION=false`)
2. OR ask admin to register `Microsoft.ContainerService` provider

### Container Apps can't connect to SQL Database

**Mode 1:** Check SQL Server firewall rules allow Azure services
```bash
az sql server firewall-rule list --resource-group <rg-name> --server <sql-server-name>
```

**Mode 2:** Check Private Endpoint and DNS Zone are deployed
```bash
az network private-endpoint list --resource-group <rg-name>
```

## Cost Implications

**Mode 1 (Public):** ~$0/month additional networking costs

**Mode 2 (Private):** 
- Private Endpoint: ~$7.30/month per endpoint
- VNet: Free
- Private DNS Zone: ~$0.50/month

## Recommendations

- **Development/Testing:** Use Mode 1 (Public Access)
- **Production:** Use Mode 2 (Private Access) after getting provider registered
- **Migration:** Start with Mode 1, switch to Mode 2 when ready
