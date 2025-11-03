# VNet Integration Configuration Guide

This guide explains how to switch between public access and private endpoint modes for Azure Container Apps and SQL Database.

## Quick Reference

📖 **For detailed information, see:**
- **[SQL Connection Guide](./SQL-CONNECTION-GUIDE.md)** - Complete architecture diagrams, connection strings, and troubleshooting

---

## Current Configuration

- **Mode:** Public Access (VNet integration disabled)
- **Container Apps:** Public subnet (Azure-managed)
- **SQL Database:** Public endpoint with "Allow Azure Services" firewall rule
- **Cost:** $0/month additional (beyond standard resource costs)

---

## Prerequisites for Private Endpoint Mode

Before enabling VNet integration, ensure:

1. ✅ **`Microsoft.ContainerService` resource provider registered**
   
   Your Azure administrator must register this provider:
   ```bash
   az provider register --namespace Microsoft.ContainerService --wait
   ```

2. ✅ **Permissions:** Contributor role on the resource group

3. ✅ **Cost awareness:** ~$7.70/month additional cost for Private Endpoint and DNS Zone

---

## Switching to Private Endpoint Mode

### Step 1: Enable VNet Integration

Edit `.azure/dev/.env` or `.azure/<environment-name>/.env`:

```bash
# Add or update this line
ENABLE_VNET_INTEGRATION=true
```

### Step 2: Provision Infrastructure

```bash
azd provision
```

**What happens:**
- ✅ VNet created (10.0.0.0/16)
- ✅ Container Apps subnet created (10.0.0.0/23)
- ✅ Private endpoints subnet created (10.0.2.0/24)
- ✅ Private DNS Zone created (privatelink.database.windows.net)
- ✅ Container Apps Environment deployed in VNet-integrated mode (internal)
- ✅ SQL Private Endpoint created with private IP
- ✅ SQL Public Network Access disabled

### Step 3: Verify

```bash
# Check Container Apps subnet assignment
az containerapp env show \
  --resource-group rg-raptor-test \
  --name cae-rvcmyaz2n4zde \
  --query "properties.vnetConfiguration.infrastructureSubnetId"

# Verify SQL private endpoint
az network private-endpoint show \
  --resource-group rg-raptor-test \
  --name sql-rvcmyaz2n4zde-pe \
  --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState.status"
```

---

## Reverting to Public Access Mode

### Step 1: Disable VNet Integration

Edit `.azure/dev/.env`:

```bash
# Update this line
ENABLE_VNET_INTEGRATION=false
```

### Step 2: Provision Infrastructure

```bash
azd provision
```

**What happens:**
- ✅ VNet, Private Endpoint, and DNS Zone removed
- ✅ Container Apps Environment switched to public mode
- ✅ SQL Database public access enabled
- ✅ "Allow Azure Services" firewall rule created

---

## Configuration Parameters

### In `main.parameters.json`:

```json
{
  "enableVnetIntegration": {
    "value": "${ENABLE_VNET_INTEGRATION=false}"
  }
}
```

### In `.azure/<env>/.env`:

```bash
# Default: false (public access)
ENABLE_VNET_INTEGRATION=false

# For private endpoint mode
ENABLE_VNET_INTEGRATION=true
```

---

## Troubleshooting

### Error: Microsoft.ContainerService provider not registered

**Symptom:**
```
SubscriptionIsNotRegistered: Subscription is not registered with the required resource providers, 
please register with the resource providers Microsoft.App and Microsoft.ContainerService.
```

**Solution:**
Ask your Azure administrator to register the provider:
```bash
az provider register --namespace Microsoft.ContainerService --wait
```

**Why needed?**
VNet-integrated Container Apps Environments require this provider for network configuration.

### Error: Container Apps Environment deployment failed

**Symptom:**
```
Failed: Container Apps Environment: cae-xxx
```

**Possible causes:**
1. Subnet delegation not set correctly → Check VNet subnet delegation
2. Subnet too small → Requires /23 or larger
3. Conflicting network security rules

**Solution:**
Verify subnet configuration in `shared/vnet.bicep`:
```bicep
{
  name: 'container-apps-subnet'
  addressPrefix: '10.0.0.0/23'  // Must be /23 or larger
  delegation: 'Microsoft.App/environments'
}
```

---

## Architecture Changes

### Public Access Mode (Current)

```
┌─────────────────────────┐
│ Container Apps          │ ──┐
│ (Azure-managed subnet)  │   │ Azure backbone
└─────────────────────────┘   │ (public endpoints)
                              │
┌─────────────────────────┐   │
│ SQL Database            │ ←─┘
│ (Public endpoint)       │
│ Firewall: Allow Azure   │
└─────────────────────────┘
```

### Private Endpoint Mode

```
┌───────────────────────────────────────┐
│ VNet (10.0.0.0/16)                    │
│                                        │
│ ┌────────────────────────────────┐    │
│ │ Container Apps Subnet          │    │
│ │ (10.0.0.0/23)                  │    │
│ │ ├─ Backend (10.0.0.x)          │    │
│ │ └─ Frontend (10.0.0.y)         │    │
│ └────────────┬───────────────────┘    │
│              │ Private connection     │
│              ▼                         │
│ ┌────────────────────────────────┐    │
│ │ Private Endpoints Subnet       │    │
│ │ (10.0.2.0/24)                  │    │
│ │ └─ SQL PE (10.0.2.4)           │    │
│ └────────────┬───────────────────┘    │
└──────────────┼────────────────────────┘
               │ Private Link
               ▼
   ┌───────────────────────┐
   │ SQL Database (PaaS)   │
   │ Public Access: OFF    │
   └───────────────────────┘
```

---

## See Also

- [SQL Connection Guide](./SQL-CONNECTION-GUIDE.md) - Detailed networking and connection information
- [Managed Identity Setup](./SQL-CONNECTION-GUIDE.md#setting-up-managed-identity-authentication)
- [Azure Container Apps VNet Integration](https://learn.microsoft.com/azure/container-apps/vnet-custom)
- [Azure Private Endpoint Overview](https://learn.microsoft.com/azure/private-link/private-endpoint-overview)
