# SQL Database Connection Guide

## Overview

This guide explains how the backend connects to Azure SQL Database in different network configurations and how to set up managed identity authentication.

---

## Network Modes Comparison

### Public Access Mode vs Private Endpoint Mode

| Feature | **Public Access (Current)** | **Private Endpoint (Future)** |
|---------|----------------------------|-------------------------------|
| **VNet Integration** | Disabled (`ENABLE_VNET_INTEGRATION=false`) | Enabled (`ENABLE_VNET_INTEGRATION=true`) |
| **SQL Endpoint** | `<server>.database.windows.net` | `<server>.database.windows.net` (resolves to private IP) |
| **DNS Resolution** | Public DNS → Public Azure IP | Private DNS → Private IP (10.0.2.x) |
| **Container Apps** | Public subnet (Azure-managed) | VNet-integrated subnet (10.0.0.0/23) |
| **Network Path** | Azure backbone (public endpoint) | Private VNet (fully isolated) |
| **Firewall** | "Allow Azure Services" rule (0.0.0.0-0.0.0.0) | No firewall needed (network-level isolation) |
| **Access Control** | Authentication-based (any Azure service can attempt) | Network-based + Authentication |
| **Traffic** | Never leaves Azure network but uses public IPs | Fully private within VNet |
| **Internet Exposure** | SQL endpoint has public DNS (but requires auth) | No public DNS resolution |
| **Cost** | Free | Private Endpoint: ~$7.20/month + ~$0.01/GB egress |
| **Requires** | Nothing special | `Microsoft.ContainerService` provider registration |
| **Use Case** | Development, Testing, Non-sensitive workloads | Production, Compliance, High-security workloads |

---

## Architecture Diagrams

### Public Access Mode (Current)

```
┌──────────────────────────────────────────────────────────┐
│  Azure Container Apps Environment                        │
│  ├─ Subnet: Azure-managed (public)                       │
│  ├─ Backend Container App                                │
│  │  ├─ FQDN: dev-rap-be.<region>.azurecontainerapps.io  │
│  │  ├─ Managed Identity: ✓ Enabled                      │
│  │  └─ Outbound: Dynamic Azure IP range                 │
│  └─ Frontend Container App                               │
└────────────────┬─────────────────────────────────────────┘
                 │
                 │ Connection over Azure backbone
                 │ (secure but uses public endpoint)
                 ▼
┌──────────────────────────────────────────────────────────┐
│  Azure SQL Database                                       │
│  ├─ Endpoint: sql-xxx.database.windows.net               │
│  ├─ DNS: Public DNS → Public Azure IP                    │
│  ├─ Firewall: "AllowAllWindowsAzureIps" (0.0.0.0)        │
│  ├─ Public Network Access: ✓ Enabled                     │
│  └─ Authentication: Managed Identity (passwordless)       │
└──────────────────────────────────────────────────────────┘

Traffic Flow:
1. Backend resolves sql-xxx.database.windows.net → Public IP
2. Establishes TCP connection on port 1433
3. SQL firewall checks: "Is source from Azure service?" → Yes
4. Connection allowed through firewall
5. Managed Identity authenticates via AAD token
6. TLS 1.2 encryption protects data in transit
```

### Private Endpoint Mode (Future)

```
┌────────────────────────────────────────────────────────────┐
│  Virtual Network (10.0.0.0/16)                             │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Container Apps Subnet (10.0.0.0/23)                  │  │
│  │ Delegation: Microsoft.App/environments               │  │
│  │                                                       │  │
│  │ ┌─────────────────────────────────────────────────┐  │  │
│  │ │ Azure Container Apps Environment                │  │  │
│  │ │ ├─ Internal Mode: ✓ Enabled                     │  │  │
│  │ │ ├─ Backend: Private IP 10.0.0.x                 │  │  │
│  │ │ └─ Frontend: Private IP 10.0.0.y                │  │  │
│  │ └─────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                           │                                 │
│                           │ Private connection              │
│                           │ (no internet traversal)         │
│                           ▼                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Private Endpoints Subnet (10.0.2.0/24)               │  │
│  │                                                       │  │
│  │ ┌─────────────────────────────────────────────────┐  │  │
│  │ │ SQL Private Endpoint                             │  │  │
│  │ │ ├─ Private IP: 10.0.2.4                          │  │  │
│  │ │ ├─ NIC: sql-xxx-pe-nic                           │  │  │
│  │ │ └─ Connects to: Azure SQL Database               │  │  │
│  │ └─────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Private DNS Zone: privatelink.database.windows.net   │  │
│  │ ├─ sql-xxx.database.windows.net → 10.0.2.4           │  │
│  │ └─ Auto-registration from Private Endpoint           │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
                           │
                           │ Private Link connection
                           ▼
┌──────────────────────────────────────────────────────────┐
│  Azure SQL Database (PaaS)                                │
│  ├─ Endpoint: sql-xxx.database.windows.net                │
│  ├─ Public Network Access: ✗ Disabled                     │
│  ├─ Private Endpoint: ✓ Enabled                           │
│  └─ Authentication: Managed Identity (passwordless)        │
└──────────────────────────────────────────────────────────┘

Traffic Flow:
1. Backend resolves sql-xxx.database.windows.net via Private DNS
2. Private DNS returns 10.0.2.4 (private IP)
3. Connection routed through Private Endpoint (stays in VNet)
4. Managed Identity authenticates via AAD token
5. No firewall checks needed (network isolation)
```

---

## Connection String Formats

### JDBC Connection Strings

Both modes use the **same JDBC URL format** - DNS resolution changes based on VNet configuration:

```properties
# MANAGED IDENTITY AUTHENTICATION (Recommended for both modes)
spring.datasource.url=jdbc:sqlserver://<server>.database.windows.net:1433;database=<dbname>;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;authentication=ActiveDirectoryMSI;

# SQL AUTHENTICATION (Not recommended - uses password)
spring.datasource.url=jdbc:sqlserver://<server>.database.windows.net:1433;database=<dbname>;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;
spring.datasource.username=<admin-login>
spring.datasource.password=<admin-password>
```

### Environment Variables (Set by Infrastructure)

The backend Container App receives these environment variables automatically:

```bash
# Public Access Mode
SPRING_DATASOURCE_URL=jdbc:sqlserver://sql-rvcmyaz2n4zde.database.windows.net:1433;database=db-raptor-dev;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;authentication=ActiveDirectoryMSI;
SPRING_DATASOURCE_DRIVER_CLASS_NAME=com.microsoft.sqlserver.jdbc.SQLServerDriver
SQL_SERVER_FQDN=sql-rvcmyaz2n4zde.database.windows.net
SQL_DATABASE_NAME=db-raptor-dev

# Private Endpoint Mode (same variables, DNS resolution changes)
# Same URLs - the Private DNS Zone in VNet resolves to private IP instead
```

---

## How Public Access Works

### Azure Firewall Rule: "Allow Azure Services"

In `sqlDatabase.bicep`:

```bicep
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-05-01-preview' = if (allowAzureServices) {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}
```

**What `0.0.0.0 - 0.0.0.0` means:**
- This is a **special Azure magic IP range**
- **NOT** the same as allowing all internet traffic (`0.0.0.0/0`)
- Specifically allows connections from **Azure service IP ranges**
- Includes:
  - Azure Container Apps
  - Azure App Service
  - Azure Functions
  - Azure Data Factory
  - Azure Logic Apps
  - Any other Azure PaaS service

**Security Implications:**
- ✅ Blocks internet traffic (your laptop, on-premises networks)
- ✅ Requires authentication (SQL password or Managed Identity)
- ✅ TLS 1.2 encryption in transit
- ✅ Traffic stays on Azure backbone (never touches internet)
- ⚠️ Any Azure service in **any subscription** can attempt connection
  - Example: Someone else's Azure Function could try connecting
  - Still requires valid credentials to succeed
- ⚠️ No network-level isolation between services

### DNS Resolution

**Public Access Mode:**
```bash
$ nslookup sql-rvcmyaz2n4zde.database.windows.net
Server:  AzureDNS
Address:  168.63.129.16

Non-authoritative answer:
Name:    sql-rvcmyaz2n4zde.database.windows.net
Address:  40.112.X.X  # Public Azure IP
```

**Private Endpoint Mode:**
```bash
$ nslookup sql-rvcmyaz2n4zde.database.windows.net
Server:  AzureDNS
Address:  168.63.129.16

Non-authoritative answer:
Name:    sql-rvcmyaz2n4zde.database.windows.net
Address:  10.0.2.4  # Private IP in VNet
```

---

## Setting Up Managed Identity Authentication

### Prerequisites

1. ✅ Backend Container App deployed with managed identity enabled
2. ✅ SQL Database deployed
3. ✅ `azure-identity` and `mssql-jdbc` dependencies in `pom.xml`

### How Managed Identity Authentication Works

When the backend connects to SQL Database using managed identity, the authentication flow involves:

1. **User-Assigned Managed Identity**: Created in Bicep (`infra/app/backend-springboot.bicep`)
2. **AZURE_CLIENT_ID Environment Variable**: Points the Azure SDK to the correct identity
3. **MSSQL JDBC Driver**: Uses `authentication=ActiveDirectoryMSI` mode
4. **Azure Identity SDK**: Retrieves access token from Azure Instance Metadata Service (IMDS)
5. **SQL Database**: Validates the token and grants access based on database roles

#### Why AZURE_CLIENT_ID is Required

Azure Container Apps can have multiple managed identities attached:
- **System-assigned identity** (one per container app)
- **User-assigned identities** (multiple can be attached)

The `AZURE_CLIENT_ID` environment variable tells the Azure Identity SDK **which specific managed identity to use** for authentication.

**Configuration in Bicep:**
```bicep
// Backend Container App environment variables
var baseEnvArray = [
  {
    name: 'AZURE_CLIENT_ID'
    value: uai.properties.clientId  // Points to user-assigned identity's client ID
  }
  // ... other variables
]
```

**How it's used:**
```
┌─────────────────────────────────────────────────────────────────┐
│ Spring Boot App                                                  │
│ ├─ Connection String: authentication=ActiveDirectoryMSI         │
│ └─ MSSQL JDBC Driver                                             │
│    └─ Azure Identity SDK (DefaultAzureCredential)                │
│       └─ Checks AZURE_CLIENT_ID environment variable            │
│          └─ Uses ManagedIdentityCredential with that client ID   │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ Azure Instance Metadata Service (IMDS)                          │
│ ├─ Endpoint: http://169.254.169.254/metadata/identity/oauth2    │
│ ├─ Receives request with client_id parameter                    │
│ └─ Returns access token for SQL Database resource               │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ Azure SQL Database                                               │
│ ├─ Validates access token                                       │
│ ├─ Maps token to database user (created via SQL commands)       │
│ └─ Grants permissions based on database roles                   │
└─────────────────────────────────────────────────────────────────┘
```

**Without AZURE_CLIENT_ID:**
```
❌ Error: [Managed Identity] Error Message: Unable to load the proper Managed Identity
❌ The Azure SDK doesn't know which identity to use
❌ Authentication fails
```

**With AZURE_CLIENT_ID:**
```
✅ Azure SDK uses the specified user-assigned managed identity
✅ Gets access token from IMDS
✅ Successfully authenticates to SQL Database
```

### Step 1: Get Backend Managed Identity Name

```bash
# Option 1: From Azure Portal
# Navigate to: Container App → Identity → User assigned
# Copy the identity name (e.g., "uaibackend-rvcmyaz2n4zde")

# Option 2: Using Azure CLI
az identity list --resource-group rg-raptor-test --query "[?contains(name, 'backend')].{Name:name, ClientId:clientId, PrincipalId:principalId}" -o table
```

### Step 2: Grant SQL Database Access

You need to create a database user for the managed identity and grant permissions. This requires:
- Azure AD admin configured on SQL Server (already done via Bicep)
- Connection to SQL Database with admin privileges

#### Method 1: Using Azure Data Studio or SSMS (Recommended)

1. **Connect to SQL Database:**
   - Server: `sql-rvcmyaz2n4zde.database.windows.net`
   - Authentication: Azure Active Directory
   - Database: `db-raptor-dev`

2. **Run these SQL commands:**

```sql
-- Create user for the backend's managed identity
-- Replace 'uaibackend-rvcmyaz2n4zde' with your actual identity name
CREATE USER [uaibackend-rvcmyaz2n4zde] FROM EXTERNAL PROVIDER;

-- Grant read access
ALTER ROLE db_datareader ADD MEMBER [uaibackend-rvcmyaz2n4zde];

-- Grant write access
ALTER ROLE db_datawriter ADD MEMBER [uaibackend-rvcmyaz2n4zde];

-- Grant DDL permissions (for Flyway migrations)
ALTER ROLE db_ddladmin ADD MEMBER [uaibackend-rvcmyaz2n4zde];

-- Verify the user was created
SELECT name, type_desc, authentication_type_desc
FROM sys.database_principals
WHERE name = 'uaibackend-rvcmyaz2n4zde';
```

#### Method 2: Using Azure CLI with SQL Query

```bash
# Set variables
RESOURCE_GROUP="rg-raptor-test"
SQL_SERVER="sql-rvcmyaz2n4zde"
DATABASE="db-raptor-dev"
IDENTITY_NAME="uaibackend-rvcmyaz2n4zde"  # Replace with actual name

# Run SQL commands via Azure CLI
az sql db query \
  --resource-group $RESOURCE_GROUP \
  --server $SQL_SERVER \
  --name $DATABASE \
  --auth-type SqlPassword \  # Initial setup with admin
  --username sqladmin \
  --password '<your-admin-password>' \
  --query "
    CREATE USER [$IDENTITY_NAME] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [$IDENTITY_NAME];
    ALTER ROLE db_datawriter ADD MEMBER [$IDENTITY_NAME];
    ALTER ROLE db_ddladmin ADD MEMBER [$IDENTITY_NAME];
  "
```

### Step 3: Verify Connection

After granting access, restart the backend container app to test:

```bash
# Restart backend to pick up managed identity permissions
az containerapp revision restart \
  --resource-group rg-raptor-test \
  --name dev-rap-be \
  --revision-name <latest-revision>

# Check logs for successful connection
az containerapp logs show \
  --resource-group rg-raptor-test \
  --name dev-rap-be \
  --tail 50
```

Expected log output:
```
HikariPool-1 - Starting...
HikariPool-1 - Added connection com.microsoft.sqlserver.jdbc.SQLServerConnection@...
HikariPool-1 - Start completed.
Flyway Community Edition by Redgate
Database: jdbc:sqlserver://sql-rvcmyaz2n4zde.database.windows.net:1433;database=db-raptor-dev
Successfully validated 2 migrations
```

---

## Switching Between Modes

### Enable Private Endpoint Mode

**Prerequisites:**
1. ✅ `Microsoft.ContainerService` resource provider registered
2. ✅ Azure administrator approval (requires elevated permissions)

**Steps:**

1. **Update environment variable:**

```bash
# Edit .azure/dev/.env
ENABLE_VNET_INTEGRATION=true
```

2. **Provision infrastructure:**

```bash
azd provision
```

3. **What happens:**
   - VNet created with two subnets
   - Private DNS Zone created and linked to VNet
   - Container Apps Environment deployed in VNet-integrated mode
   - SQL Private Endpoint created with private IP
   - Container Apps can only communicate via private network

4. **Verify private connectivity:**

```bash
# From backend container, test DNS resolution
az containerapp exec \
  --resource-group rg-raptor-test \
  --name dev-rap-be \
  --command "nslookup sql-rvcmyaz2n4zde.database.windows.net"

# Should return private IP: 10.0.2.x
```

### Revert to Public Access Mode

```bash
# Edit .azure/dev/.env
ENABLE_VNET_INTEGRATION=false

# Provision infrastructure
azd provision
```

**Note:** Managed identity permissions persist - no need to reconfigure SQL access.

---

## Troubleshooting

### Connection Refused

**Public Access Mode:**
```
Error: The TCP/IP connection to the host ... failed
```

**Possible causes:**
1. Firewall rule not created → Check Azure Portal: SQL Server → Networking
2. Managed identity not granted access → Run SQL commands in Step 2

**Private Endpoint Mode:**
```
Error: The driver could not establish a secure connection to SQL Server
```

**Possible causes:**
1. Private DNS Zone not linked to VNet
2. Private Endpoint not created
3. Container Apps not in VNet-integrated subnet

### Authentication Failed

```
Error: Login failed for user '<token-identified principal>'
```

**Possible causes:**
1. Managed identity user not created in database
2. Incorrect database roles assigned
3. Azure AD admin not configured on SQL Server

**Solution:**
Re-run SQL commands from Step 2 above.

### Managed Identity Token Issues

```
Error: Could not acquire access token
```

**Possible causes:**
1. Managed identity not enabled on Container App
2. Wrong authentication method in connection string
3. Missing `spring-cloud-azure-starter-jdbc-mssql` dependency

**Solution:**
Verify in `pom.xml`:
```xml
<dependency>
    <groupId>com.azure.spring</groupId>
    <artifactId>spring-cloud-azure-starter-jdbc-mssql</artifactId>
</dependency>
```

---

## Cost Comparison

| Component | Public Access | Private Endpoint |
|-----------|---------------|------------------|
| **Container Apps Environment** | $0 (consumption-based) | $0 (same) |
| **VNet** | Not created | $0 (VNet is free) |
| **Private Endpoint** | Not created | ~$7.20/month |
| **Private DNS Zone** | Not created | $0.50/month |
| **Inbound Data Transfer** | $0 (within Azure) | $0 (within VNet) |
| **Outbound Data Transfer** | $0 (within Azure) | ~$0.01/GB |
| **Total Additional Cost** | **$0/month** | **~$7.70/month** |

---

## Security Recommendations

### Development/Test Environments
- ✅ Public Access Mode is acceptable
- ✅ Use Managed Identity (never SQL passwords)
- ✅ Enable Azure Defender for SQL
- ✅ Regular security audits

### Production Environments
- ✅ Use Private Endpoint Mode
- ✅ Use Managed Identity exclusively
- ✅ Enable diagnostic logging
- ✅ Implement network security groups (NSGs)
- ✅ Enable Azure Defender for SQL
- ✅ Regular vulnerability assessments
- ✅ Implement Azure Policy for compliance

---

## References

- [Azure SQL Database Private Endpoint](https://learn.microsoft.com/azure/azure-sql/database/private-endpoint-overview)
- [Container Apps VNet Integration](https://learn.microsoft.com/azure/container-apps/vnet-custom)
- [Managed Identity for Azure SQL](https://learn.microsoft.com/azure/azure-sql/database/authentication-aad-configure)
- [Spring Cloud Azure JDBC](https://learn.microsoft.com/azure/developer/java/spring-framework/configure-spring-boot-starter-java-app-with-azure-sql-database)
