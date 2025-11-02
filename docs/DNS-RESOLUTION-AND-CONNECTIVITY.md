# DNS Resolution and Connectivity Guide

This document explains how DNS resolution, private endpoints, and managed identity authentication work in the RAP microservices architecture.

---

## Table of Contents
1. [DNS Resolution Flow for Private Endpoints](#1-dns-resolution-flow-for-private-endpoints)
2. [Manual SQL Server Access (Without Compromising Security)](#2-manual-sql-server-access-without-compromising-security)
3. [Managed Identity Authentication (Passwordless)](#3-managed-identity-authentication-passwordless)
4. [Local Docker Environment](#4-local-docker-environment)

---

## 1. DNS Resolution Flow for Private Endpoints

### Overview
When using **Azure SQL Database with Private Endpoints**, DNS resolution is critical for directing traffic through the private network instead of the public internet.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Azure Virtual Network                        │
│                          (10.0.0.0/16)                              │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Container Apps Subnet (10.0.0.0/23)                         │  │
│  │                                                               │  │
│  │  ┌─────────────────────┐                                     │  │
│  │  │ Backend Container   │                                     │  │
│  │  │ App (Spring Boot)   │                                     │  │
│  │  │                     │                                     │  │
│  │  │ Managed Identity:   │                                     │  │
│  │  │ id-backend-abc123   │                                     │  │
│  │  └─────────┬───────────┘                                     │  │
│  │            │                                                  │  │
│  │            │ (1) DNS Query:                                  │  │
│  │            │ sql-abc123.database.windows.net                 │  │
│  │            │                                                  │  │
│  └────────────┼──────────────────────────────────────────────────┘  │
│               │                                                      │
│               ↓                                                      │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │         Azure Private DNS Zone                              │    │
│  │         privatelink.database.windows.net                    │    │
│  │                                                              │    │
│  │  DNS Records:                                                │    │
│  │  sql-abc123.privatelink.database.windows.net → 10.0.2.4     │    │
│  │                                                              │    │
│  │  (2) Returns: 10.0.2.4 (Private IP)                         │    │
│  └────────────────────────────────────────────────────────────┘    │
│               │                                                      │
│               ↓                                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Private Endpoints Subnet (10.0.2.0/24)                      │  │
│  │                                                               │  │
│  │  ┌─────────────────────┐                                     │  │
│  │  │  Private Endpoint   │                                     │  │
│  │  │  (NIC: 10.0.2.4)    │                                     │  │
│  │  │                     │                                     │  │
│  │  │  ┌───────────────┐  │                                     │  │
│  │  │  │ Private Link  │  │  (3) TCP Connection                │  │
│  │  │  │   to SQL      │──┼──────────────────┐                 │  │
│  │  │  └───────────────┘  │                  │                 │  │
│  │  └─────────────────────┘                  │                 │  │
│  └───────────────────────────────────────────┼─────────────────┘  │
└────────────────────────────────────────────────┼────────────────────┘
                                                │
                                                │ Azure Backbone Network
                                                │ (Private, Encrypted)
                                                ↓
                                    ┌───────────────────────┐
                                    │  Azure SQL Database   │
                                    │  sql-abc123           │
                                    │                       │
                                    │  Public Access: OFF   │
                                    │  Private IP: 10.0.2.4 │
                                    │                       │
                                    │  (4) Validates MI     │
                                    │  (5) Grants Access    │
                                    └───────────────────────┘
```

### Step-by-Step DNS Resolution Process

#### **Step 1: Application Initiates Connection**
```java
// Backend Spring Boot application code
String jdbcUrl = "jdbc:sqlserver://sql-abc123.database.windows.net:1433;" +
                 "database=raptordb;" +
                 "authentication=ActiveDirectoryMSI;";
```

The application uses the **public FQDN** (`sql-abc123.database.windows.net`), but DNS will resolve it to the **private IP**.

---

#### **Step 2: DNS Query to Azure DNS**
```
Container App → Azure DNS Resolver
Query: "What is the IP address of sql-abc123.database.windows.net?"
```

**Azure DNS Resolver checks:**
1. Is there a **Private DNS Zone** linked to this VNet?
   - ✅ Yes: `privatelink.database.windows.net` is linked
2. Is there a DNS record for `sql-abc123` in that zone?
   - ✅ Yes: `sql-abc123.privatelink.database.windows.net` → `10.0.2.4`

---

#### **Step 3: DNS Response (Private IP)**
```
Azure DNS → Container App
Response: "sql-abc123.database.windows.net resolves to 10.0.2.4"
```

**Key Point**: The FQDN automatically maps to the Private DNS Zone record because of Azure's DNS resolution rules:
- `*.database.windows.net` queries check `privatelink.database.windows.net` zone first
- If a match is found, returns the private IP
- If no match, falls back to public DNS

---

#### **Step 4: TCP Connection via Private Endpoint**
```
Container App (10.0.0.x) → Private Endpoint (10.0.2.4) → SQL Server
```

**Traffic flow:**
- Container App initiates TCP connection to `10.0.2.4:1433`
- Traffic routes through **VNet internal routing** (no internet hop)
- Private Endpoint's Network Interface Card (NIC) receives the connection
- Private Link service forwards traffic to SQL Server's backend

---

#### **Step 5: SQL Server Validates Managed Identity**
```sql
-- SQL Server checks:
-- 1. Is the connection from a recognized Managed Identity?
-- 2. Does this identity have database permissions?

-- User: id-backend-abc123@External
-- Permissions: db_datareader, db_datawriter, db_ddladmin
```

---

#### **Step 6: Connection Established**
```
✅ Connection successful
✅ All traffic encrypted via TLS 1.2
✅ Traffic never leaves Azure's private network
✅ No public IP exposure
```

---

### DNS Resolution Comparison

| Scenario | DNS Query | DNS Response | Connection Path | Security |
|----------|-----------|--------------|-----------------|----------|
| **With Private DNS Zone** | `sql-abc123.database.windows.net` | `10.0.2.4` (private IP) | VNet internal → Private Endpoint → SQL Server | ✅ Secure, private |
| **Without Private DNS Zone** | `sql-abc123.database.windows.net` | `104.45.123.45` (public IP) | Internet → Public endpoint | ❌ Connection fails (public access disabled) |
| **Public Access Enabled** | `sql-abc123.database.windows.net` | `104.45.123.45` (public IP) | Internet → SQL Server | ⚠️ Works but exposed to internet |

---

### How Private DNS Zone is Created

```bicep
// In main.bicep
module sqlPrivateDnsZone 'shared/privateDnsZone.bicep' = {
  name: 'sql-private-dns-zone'
  params: {
    // Azure's standard private link zone for SQL Server
    zoneName: 'privatelink.database.windows.net'
    
    // Link to VNet so DNS queries from VNet use this zone
    vnetId: vnet.outputs.vnetId
    
    tags: tags
  }
}
```

---

### How DNS Record is Created

```bicep
// In modules/sqlDatabase.bicep
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${sqlServerName}-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId  // 10.0.2.0/24
    }
    privateLinkServiceConnections: [
      {
        name: '${sqlServerName}-plink'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: ['sqlServer']  // Azure SQL service type
        }
      }
    ]
  }
}

// Automatically creates DNS record when privateDnsZoneGroup is configured
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
          // This creates: sql-abc123.privatelink.database.windows.net → 10.0.2.4
        }
      }
    ]
  }
}
```

---

### Verification Commands

#### **Check DNS Resolution from Container App**
```bash
# Exec into backend container
az containerapp exec -n dev-rap-be -g rg-raptor-dev

# Inside container, check DNS resolution
nslookup sql-abc123.database.windows.net
# Should return: 10.0.2.4 (private IP)

# Test connectivity
nc -zv sql-abc123.database.windows.net 1433
# Should show: Connection succeeded
```

#### **Check Private DNS Zone Records**
```bash
# List DNS records
az network private-dns record-set a list \
  -g rg-raptor-dev \
  -z privatelink.database.windows.net \
  --query "[].{Name:name, IP:aRecords[0].ipv4Address}" -o table

# Expected output:
# Name         IP
# -----------  ----------
# sql-abc123   10.0.2.4
```

#### **Check Private Endpoint**
```bash
# Get private endpoint details
az network private-endpoint show \
  -n sql-abc123-pe \
  -g rg-raptor-dev \
  --query "{Name:name, PrivateIP:customDnsConfigs[0].ipAddresses[0], FQDN:customDnsConfigs[0].fqdn}" -o table

# Expected output:
# Name           PrivateIP   FQDN
# -------------  ----------  -------------------------------------
# sql-abc123-pe  10.0.2.4    sql-abc123.privatelink.database.windows.net
```

---

## 2. Manual SQL Server Access (Without Compromising Security)

When SQL Server has **public access disabled** and only accepts connections via **private endpoint**, you have several secure options for manual access:

---

### **Option 1: Azure Bastion + Jump Box (Recommended for Production)**

**Architecture:**
```
Your Laptop → Azure Bastion → Jump Box VM (in VNet) → SQL Server (Private Endpoint)
```

**Steps:**

1. **Deploy Azure Bastion** (one-time setup):
```bash
# Create Bastion subnet (must be named exactly "AzureBastionSubnet")
az network vnet subnet create \
  -g rg-raptor-prod \
  --vnet-name vnet-abc123 \
  -n AzureBastionSubnet \
  --address-prefix 10.0.3.0/27

# Create Bastion host
az network bastion create \
  -n bastion-raptor \
  -g rg-raptor-prod \
  --vnet-name vnet-abc123 \
  --public-ip-address bastion-pip \
  --sku Standard
```

2. **Deploy Jump Box VM** (lightweight Windows or Linux VM):
```bash
# Create VM in the VNet
az vm create \
  -n jumpbox-vm \
  -g rg-raptor-prod \
  --image Win2022Datacenter \
  --size Standard_B2s \
  --admin-username azureuser \
  --vnet-name vnet-abc123 \
  --subnet container-apps-subnet \
  --public-ip-address "" \
  --nsg ""
```

3. **Connect via Bastion**:
   - Go to Azure Portal → VM → Connect → Bastion
   - Enter credentials
   - Bastion provides browser-based RDP/SSH (no public IP needed)

4. **Install SQL tools on Jump Box**:
   - SQL Server Management Studio (SSMS)
   - Azure Data Studio
   - Or sqlcmd CLI

5. **Connect to SQL Server**:
```bash
# From Jump Box, DNS resolves to private IP
sqlcmd -S sql-abc123.database.windows.net -d raptordb -G
# -G uses Azure AD authentication (your user account)
```

**Pros:**
- ✅ No public access needed
- ✅ Audit trail via Bastion logs
- ✅ Jump Box can be turned off when not in use
- ✅ Industry best practice for production

**Cons:**
- ❌ Costs ~$140/month (Bastion) + VM costs
- ❌ Extra setup complexity

---

### **Option 2: Azure VPN Gateway or ExpressRoute (For On-Premises)**

**Architecture:**
```
Your Laptop (On-Premises) → VPN/ExpressRoute → VNet → SQL Server (Private Endpoint)
```

**Steps:**

1. **Set up VPN Gateway** (if not already configured):
```bash
# Create Gateway subnet
az network vnet subnet create \
  -g rg-raptor-prod \
  --vnet-name vnet-abc123 \
  -n GatewaySubnet \
  --address-prefix 10.0.255.0/27

# Create VPN Gateway (takes ~30 minutes)
az network vnet-gateway create \
  -n vpn-gateway-raptor \
  -g rg-raptor-prod \
  --gateway-type Vpn \
  --sku VpnGw1 \
  --vnet vnet-abc123 \
  --public-ip-address vpn-pip
```

2. **Configure Point-to-Site VPN** (client access):
   - Download VPN client configuration
   - Install on your laptop
   - Connect to Azure VNet

3. **Connect to SQL Server**:
```bash
# Once VPN connected, your laptop is "inside" the VNet
sqlcmd -S sql-abc123.database.windows.net -d raptordb -G
```

**Pros:**
- ✅ Access from your laptop without Jump Box
- ✅ Secure encrypted tunnel
- ✅ Can access all VNet resources

**Cons:**
- ❌ Expensive (~$140/month for VPN Gateway)
- ❌ VPN connection overhead

---

### **Option 3: Temporary Public Access (Dev/Test Only)**

**⚠️ Use only for development/testing, not production!**

**Steps:**

1. **Temporarily enable public access**:
```bash
# Enable public network access
az sql server update \
  -n sql-abc123 \
  -g rg-raptor-dev \
  --set publicNetworkAccess=Enabled

# Add your IP to firewall
MY_IP=$(curl -s https://api.ipify.org)
az sql server firewall-rule create \
  -n AllowMyIP \
  -g rg-raptor-dev \
  -s sql-abc123 \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP
```

2. **Connect from your laptop**:
```bash
sqlcmd -S sql-abc123.database.windows.net -d raptordb -U sqladmin -P <password>
# Or use Azure Data Studio with SQL auth
```

3. **Disable public access when done**:
```bash
# Remove firewall rule
az sql server firewall-rule delete \
  -n AllowMyIP \
  -g rg-raptor-dev \
  -s sql-abc123

# Disable public access
az sql server update \
  -n sql-abc123 \
  -g rg-raptor-dev \
  --set publicNetworkAccess=Disabled
```

**Pros:**
- ✅ Quick and easy
- ✅ No additional infrastructure

**Cons:**
- ❌ Exposes SQL Server to internet (security risk)
- ❌ Must remember to disable after use
- ❌ Not acceptable for production

---

### **Option 4: Azure Container Instance with Azure CLI (Quick Debug)**

**Architecture:**
```
Azure Container Instance (in VNet) → SQL Server (Private Endpoint)
```

**Steps:**

1. **Run temporary container with SQL tools**:
```bash
az container create \
  -n sql-debug-container \
  -g rg-raptor-dev \
  --image mcr.microsoft.com/mssql-tools \
  --vnet vnet-abc123 \
  --subnet container-apps-subnet \
  --command-line "/bin/bash -c 'sleep 3600'" \
  --restart-policy Never

# Exec into container
az container exec \
  -n sql-debug-container \
  -g rg-raptor-dev \
  --exec-command "/bin/bash"

# Inside container, run sqlcmd
sqlcmd -S sql-abc123.database.windows.net -d raptordb -U sqladmin -P <password>
```

2. **Clean up when done**:
```bash
az container delete -n sql-debug-container -g rg-raptor-dev -y
```

**Pros:**
- ✅ No permanent infrastructure
- ✅ Quick one-off queries
- ✅ Secure (stays in VNet)

**Cons:**
- ❌ Not ideal for interactive sessions
- ❌ Requires Azure CLI knowledge

---

### **Recommended Approach by Environment**

| Environment | Recommended Method | Reason |
|-------------|-------------------|--------|
| **Local Dev** | Docker Compose (local SQL Server) | No Azure access needed |
| **Dev/Test** | Temporary Public Access | Quick debugging, low risk |
| **Train** | Azure Bastion + Jump Box | Production-like security |
| **Prod** | Azure Bastion + Jump Box | Maximum security, audit trail |

---

## 3. Managed Identity Authentication (Passwordless)

### How Container Apps Connect to SQL Server Without Passwords

Azure Managed Identity provides **passwordless authentication** using Azure Active Directory (Azure AD). Here's how it works:

---

### **Architecture Overview**

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Active Directory                        │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Managed Identity: id-backend-abc123                     │  │
│  │  - Object ID: 12345678-1234-1234-1234-123456789abc       │  │
│  │  - Principal ID: 87654321-4321-4321-4321-cba987654321    │  │
│  │  - Assigned to: Container App "dev-rap-be"               │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           │                                      │
│                           │ (1) Request Token                    │
│                           ↓                                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Azure AD Token Endpoint                                 │  │
│  │  Issues JWT token for SQL Server access                  │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────┬────────────────────────────────────┘
                              │ (2) Return JWT Token
                              ↓
                  ┌───────────────────────┐
                  │  Backend Container    │
                  │  App (Spring Boot)    │
                  │                       │
                  │  JDBC Connection:     │
                  │  authentication=      │
                  │  ActiveDirectoryMSI   │
                  └───────────┬───────────┘
                              │ (3) Connect with Token
                              ↓
                  ┌───────────────────────┐
                  │  Azure SQL Database   │
                  │                       │
                  │  (4) Validate Token   │
                  │  (5) Check Permissions│
                  │  (6) Grant Access     │
                  └───────────────────────┘
```

---

### **Step-by-Step Authentication Flow**

#### **Step 1: Container App is Assigned Managed Identity**

When Container App is created:
```bicep
// In app/backend-springboot.bicep
resource backendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName  // e.g., id-backend-abc123
  location: location
}

resource backendApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: name
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${backendIdentity.id}': {}  // Assign the identity
    }
  }
  // ...
}
```

**What happens:**
- Azure creates a **service principal** in Azure AD
- Container App is **bound** to this identity
- Identity has **Object ID** and **Principal ID** (used for permissions)

---

#### **Step 2: Managed Identity is Granted SQL Permissions**

After infrastructure deployment, `postprovision.sh` runs:
```bash
# infra/scripts/ensure-sql-permissions.sh
sqlcmd -S sql-abc123.database.windows.net -d raptordb -U sqladmin -P <password> -Q "
-- Create external user from Managed Identity
CREATE USER [id-backend-abc123] FROM EXTERNAL PROVIDER;

-- Grant database permissions
ALTER ROLE db_datareader ADD MEMBER [id-backend-abc123];
ALTER ROLE db_datawriter ADD MEMBER [id-backend-abc123];
ALTER ROLE db_ddladmin ADD MEMBER [id-backend-abc123];  -- For Flyway migrations
"
```

**What this does:**
- Creates a **database user** linked to the Managed Identity
- Grants **read/write/schema** permissions
- Identity name must match **exactly** (e.g., `id-backend-abc123`)

---

#### **Step 3: Application Requests Access Token**

When Spring Boot app starts, JDBC driver requests a token:
```java
// JDBC URL in application.properties
spring.datasource.url=jdbc:sqlserver://sql-abc123.database.windows.net:1433;
  database=raptordb;
  authentication=ActiveDirectoryMSI;  // ← Triggers token request
```

**Behind the scenes (MSSQL JDBC Driver):**
```
1. Driver detects authentication=ActiveDirectoryMSI
2. Connects to Azure Instance Metadata Service (IMDS)
   Endpoint: http://169.254.169.254/metadata/identity/oauth2/token
3. Requests token for resource: https://database.windows.net/
4. IMDS validates Container App's assigned identity
5. Returns JWT access token
```

**IMDS Request:**
```bash
curl -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://database.windows.net/"
```

**Response:**
```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6Ik...",
  "expires_in": "3600",
  "resource": "https://database.windows.net/",
  "token_type": "Bearer"
}
```

---

#### **Step 4: JDBC Driver Connects to SQL Server with Token**

```
JDBC Driver sends:
- TDS packet with Token-based authentication
- JWT token in the authentication header
- Database name: raptordb
```

---

#### **Step 5: SQL Server Validates Token**

SQL Server:
1. **Extracts token** from authentication header
2. **Validates signature** using Azure AD public keys
3. **Checks claims**:
   ```json
   {
     "oid": "12345678-1234-1234-1234-123456789abc",  // Managed Identity Object ID
     "sub": "id-backend-abc123",                     // Subject (identity name)
     "aud": "https://database.windows.net/",         // Audience (SQL Server)
     "iss": "https://sts.windows.net/<tenant-id>/",  // Issuer (Azure AD)
     "exp": 1730000000                               // Expiration timestamp
   }
   ```
4. **Maps identity** to database user:
   - Finds user `id-backend-abc123` (created in Step 2)
   - Checks permissions: `db_datareader`, `db_datawriter`, `db_ddladmin`

---

#### **Step 6: Connection Established**

```
✅ Token validated
✅ User mapped: id-backend-abc123
✅ Permissions granted: read, write, DDL
✅ Connection established to database: raptordb
```

Application can now execute queries:
```java
jdbcTemplate.query("SELECT * FROM users", ...);
```

---

### **Code Implementation Details**

#### **Spring Boot Configuration**
```properties
# backend/src/main/resources/application.properties

# JDBC URL with Managed Identity authentication
spring.datasource.url=jdbc:sqlserver://${SQL_SERVER_FQDN}:1433;\
  database=${SQL_DATABASE_NAME};\
  encrypt=true;\
  trustServerCertificate=false;\
  hostNameInCertificate=*.database.windows.net;\
  loginTimeout=30;\
  authentication=ActiveDirectoryMSI

# No username/password needed!
# spring.datasource.username=  ← NOT SET
# spring.datasource.password=  ← NOT SET

# Driver automatically uses Managed Identity
spring.datasource.driver-class-name=com.microsoft.sqlserver.jdbc.SQLServerDriver
```

#### **Environment Variables (Injected by Bicep)**
```bicep
// In app/backend-springboot.bicep
{
  name: 'SQL_SERVER_FQDN'
  value: sqlServerFqdn  // e.g., sql-abc123.database.windows.net
}
{
  name: 'SQL_DATABASE_NAME'
  value: sqlDatabaseName  // e.g., raptordb
}
```

#### **Maven Dependencies**
```xml
<!-- backend/pom.xml -->
<dependency>
  <groupId>com.microsoft.sqlserver</groupId>
  <artifactId>mssql-jdbc</artifactId>
  <version>12.4.0.jre11</version>  <!-- Must be 9.2.0+ for Managed Identity support -->
</dependency>
```

---

### **Token Lifecycle**

```
┌─────────────────────────────────────────────────────────────┐
│  Token Lifecycle                                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Application starts                                       │
│     → JDBC driver requests token from IMDS                   │
│     → Token issued (valid for 1 hour)                        │
│                                                              │
│  2. Application makes DB queries                             │
│     → Uses cached token                                      │
│     → Token sent with each SQL connection                    │
│                                                              │
│  3. Token expires (after 1 hour)                            │
│     → JDBC driver detects expiration                         │
│     → Automatically requests new token from IMDS             │
│     → New connection established with fresh token            │
│                                                              │
│  4. Token refresh is transparent                             │
│     → Application code unchanged                             │
│     → No connection interruption                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

### **Security Benefits**

| Traditional SQL Auth | Managed Identity Auth |
|----------------------|----------------------|
| ❌ Password stored in environment variables | ✅ No password needed |
| ❌ Password rotation required | ✅ Token auto-rotated every hour |
| ❌ Password can be leaked | ✅ Token scoped to identity + resource |
| ❌ Shared credentials | ✅ Unique identity per service |
| ❌ No audit trail | ✅ Azure AD logs all token requests |

---

### **Debugging Managed Identity Authentication**

#### **Check if Managed Identity is Assigned**
```bash
az containerapp show -n dev-rap-be -g rg-raptor-dev \
  --query "identity.userAssignedIdentities" -o json
```

Expected output:
```json
{
  "/subscriptions/.../resourcegroups/rg-raptor-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-backend-abc123": {
    "principalId": "87654321-4321-4321-4321-cba987654321",
    "clientId": "12345678-1234-1234-1234-123456789abc"
  }
}
```

#### **Check SQL Database User Permissions**
```bash
# Connect to SQL Server (using sqladmin)
sqlcmd -S sql-abc123.database.windows.net -d raptordb -U sqladmin -P <password>

-- List users
SELECT name, type_desc FROM sys.database_principals WHERE type = 'E';
-- Should show: id-backend-abc123, EXTERNAL_USER

-- Check permissions
SELECT dp.name, dp.type_desc, p.permission_name
FROM sys.database_principals dp
JOIN sys.database_permissions p ON dp.principal_id = p.grantee_principal_id
WHERE dp.name = 'id-backend-abc123';
```

#### **Test Token Acquisition from Container**
```bash
# Exec into backend container
az containerapp exec -n dev-rap-be -g rg-raptor-dev

# Inside container, request token manually
curl -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://database.windows.net/"

# Should return JSON with access_token
```

#### **Check Application Logs**
```bash
# View backend logs for JDBC connection attempts
az containerapp logs show -n dev-rap-be -g rg-raptor-dev --tail 100 --follow

# Look for:
# ✅ "HikariPool-1 - Start completed"
# ❌ "Login failed for user 'id-backend-abc123'"
# ❌ "The token provided is invalid"
```

---

## 4. Local Docker Environment

### Does Local Docker Use the Same Init Scripts?

**Yes!** The local Docker Compose environment uses **the same Flyway migration scripts** as Azure, ensuring **dev/prod parity**.

---

### **Local Docker Compose Setup**

#### **Architecture**
```
┌────────────────────────────────────────────────────────────┐
│  Docker Compose (Local Development)                        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  SQL Server 2022 Container                           │  │
│  │  - Port: 1433                                         │  │
│  │  - Database: raptordb                                 │  │
│  │  - Authentication: SQL Auth (SA + password)          │  │
│  │  - No Managed Identity (not supported locally)       │  │
│  └──────────────────────────────────────────────────────┘  │
│                          ↑                                  │
│                          │ JDBC Connection                  │
│                          │                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Backend Spring Boot Container                       │  │
│  │  - Runs Flyway migrations on startup                 │  │
│  │  - Same scripts: src/main/resources/db/migration/    │  │
│  │  - Authentication: SQL Auth (for local dev)          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

---

### **Docker Compose Configuration**

```yaml
# backend/docker-compose.yml
version: '3.8'

services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: raptor-sqlserver-local
    environment:
      ACCEPT_EULA: "Y"
      SA_PASSWORD: "YourStrong@Passw0rd"  # Local dev password
      MSSQL_PID: "Developer"              # Free developer edition
    ports:
      - "1433:1433"
    volumes:
      - sqlserver-data:/var/opt/mssql
    networks:
      - raptor-network
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P YourStrong@Passw0rd -Q 'SELECT 1'"]
      interval: 10s
      timeout: 5s
      retries: 5

  backend:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: raptor-backend-local
    depends_on:
      sqlserver:
        condition: service_healthy  # Wait for SQL Server to be ready
    environment:
      # Spring Boot datasource configuration
      SPRING_DATASOURCE_URL: "jdbc:sqlserver://sqlserver:1433;databaseName=raptordb;encrypt=true;trustServerCertificate=true"
      SPRING_DATASOURCE_USERNAME: "sa"
      SPRING_DATASOURCE_PASSWORD: "YourStrong@Passw0rd"
      SPRING_DATASOURCE_DRIVER_CLASS_NAME: "com.microsoft.sqlserver.jdbc.SQLServerDriver"
      
      # Flyway configuration (automatic migrations)
      SPRING_FLYWAY_ENABLED: "true"
      SPRING_FLYWAY_LOCATIONS: "classpath:db/migration"
      SPRING_FLYWAY_BASELINE_ON_MIGRATE: "true"
      SPRING_FLYWAY_VALIDATE_ON_MIGRATE: "true"
      
      # JPA configuration (validate schema, don't auto-create)
      SPRING_JPA_HIBERNATE_DDL_AUTO: "validate"
    ports:
      - "8080:8080"
    networks:
      - raptor-network

volumes:
  sqlserver-data:

networks:
  raptor-network:
    driver: bridge
```

---

### **Flyway Migration Scripts (Shared with Azure)**

```
backend/src/main/resources/db/migration/
├── V1__Initial_schema.sql       ← Same script used in Azure!
├── V2__Add_user_indexes.sql     ← Future migrations
└── V3__Add_orders_table.sql     ← Future migrations
```

**V1__Initial_schema.sql:**
```sql
-- This exact same script runs in:
-- 1. Local Docker (via Flyway on Spring Boot startup)
-- 2. Azure SQL Database (via Flyway on Spring Boot startup)

CREATE TABLE users (
    id INT IDENTITY(1,1) PRIMARY KEY,
    username NVARCHAR(50) NOT NULL UNIQUE,
    email NVARCHAR(100) NOT NULL UNIQUE,
    created_at DATETIME2 DEFAULT GETDATE(),
    updated_at DATETIME2 DEFAULT GETDATE()
);

CREATE TABLE products (
    id INT IDENTITY(1,1) PRIMARY KEY,
    name NVARCHAR(100) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    stock INT DEFAULT 0,
    created_at DATETIME2 DEFAULT GETDATE()
);

-- ... more tables
```

---

### **Local Development Workflow**

#### **1. Start Local Environment**
```bash
cd backend

# Start SQL Server + Backend
docker-compose up -d

# View logs
docker-compose logs -f backend
```

**What happens:**
1. SQL Server container starts
2. Healthcheck waits for SQL Server to be ready
3. Backend container starts
4. **Flyway automatically runs migrations** on startup:
   ```
   Flyway: Detected database schema is empty
   Flyway: Running migration V1__Initial_schema.sql
   Flyway: Schema version: 1
   ```
5. Backend app starts and connects to database

---

#### **2. Verify Schema**
```bash
# Connect to local SQL Server
docker exec -it raptor-sqlserver-local /opt/mssql-tools/bin/sqlcmd \
  -S localhost -U sa -P 'YourStrong@Passw0rd' -d raptordb

# Check tables
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES;
GO

# Check Flyway history
SELECT * FROM flyway_schema_history;
GO
```

**Expected output:**
```
TABLE_NAME
-----------
users
products
orders
order_items
flyway_schema_history

installed_rank  version  description          script
--------------  -------  -------------------  ----------------------
1               1        Initial schema       V1__Initial_schema.sql
```

---

#### **3. Test API Endpoints**
```bash
# Create a user
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"username": "john", "email": "john@example.com"}'

# Get users
curl http://localhost:8080/api/users
```

---

#### **4. Stop Environment**
```bash
docker-compose down

# Keep data volume for next run
docker-compose down -v  # Remove volume (fresh start)
```

---

### **Key Differences: Local vs. Azure**

| Aspect | Local Docker | Azure Container Apps |
|--------|--------------|---------------------|
| **SQL Server** | SQL Server 2022 container | Azure SQL Database (PaaS) |
| **Authentication** | SQL Auth (username/password) | Managed Identity (passwordless) |
| **Connection String** | `jdbc:sqlserver://sqlserver:1433` | `jdbc:sqlserver://sql-abc123.database.windows.net:1433;authentication=ActiveDirectoryMSI` |
| **Network** | Docker bridge network | Azure VNet + Private Endpoint |
| **DNS** | Container name (`sqlserver`) | Private DNS Zone (`privatelink.database.windows.net`) |
| **Flyway Scripts** | ✅ **Same scripts** | ✅ **Same scripts** |
| **Schema Management** | Flyway migrations | Flyway migrations |
| **TLS/Encryption** | `trustServerCertificate=true` (local dev) | `trustServerCertificate=false` (validates Azure cert) |

---

### **Why This Setup is Valuable**

#### **✅ Dev/Prod Parity**
- Same database schema (Flyway migrations)
- Same application code
- Same JPA entities
- Same queries

#### **✅ Fast Feedback Loop**
```bash
# Make code changes
# Restart backend only (SQL Server keeps running)
docker-compose restart backend

# Or rebuild after schema changes
docker-compose up --build backend
```

#### **✅ Offline Development**
- No Azure connection required
- No VPN needed
- Work on airplane/train

#### **✅ Cost Savings**
- No Azure SQL Database charges during local dev
- Free SQL Server Developer Edition

---

### **Troubleshooting Local Docker**

#### **SQL Server won't start**
```bash
# Check logs
docker logs raptor-sqlserver-local

# Common issues:
# 1. Password too weak → Use complex password
# 2. Port 1433 already in use → Kill local SQL Server instance
# 3. Memory limits → Increase Docker memory to 4GB+
```

#### **Backend can't connect to SQL**
```bash
# Check if SQL Server is healthy
docker ps  # Should show "healthy" status

# Test connection manually
docker exec -it raptor-backend-local bash
curl telnet://sqlserver:1433  # Should connect
```

#### **Flyway migrations fail**
```bash
# Check Flyway logs
docker-compose logs backend | grep Flyway

# Reset database (WARNING: deletes all data)
docker-compose down -v
docker-compose up -d
```

#### **Database persists old data**
```bash
# Remove volume to start fresh
docker volume rm backend_sqlserver-data
docker-compose up -d
```

---

### **Adding New Migrations (Local → Azure)**

**Workflow:**
1. **Create new migration locally:**
   ```bash
   # backend/src/main/resources/db/migration/V2__Add_user_roles.sql
   CREATE TABLE user_roles (
       id INT IDENTITY(1,1) PRIMARY KEY,
       user_id INT NOT NULL,
       role NVARCHAR(50) NOT NULL,
       FOREIGN KEY (user_id) REFERENCES users(id)
   );
   ```

2. **Test locally:**
   ```bash
   # Restart backend to run new migration
   docker-compose restart backend
   
   # Verify
   docker exec -it raptor-sqlserver-local /opt/mssql-tools/bin/sqlcmd \
     -S localhost -U sa -P 'YourStrong@Passw0rd' -d raptordb -Q \
     "SELECT version FROM flyway_schema_history ORDER BY installed_rank"
   ```

3. **Commit and push:**
   ```bash
   git add backend/src/main/resources/db/migration/V2__Add_user_roles.sql
   git commit -m "Add user roles table"
   git push
   ```

4. **Deploy to Azure:**
   ```bash
   azd up
   # Or trigger GitHub Actions workflow
   ```

5. **Flyway runs migration in Azure:**
   - Backend container starts
   - Flyway detects new migration (V2)
   - Runs migration against Azure SQL Database
   - Application starts with new schema

**Result:** Same schema in local Docker and Azure! ✅

---

## Summary

### **1. DNS Resolution Flow**
- Private DNS Zone resolves SQL Server FQDN to private IP
- Traffic stays within Azure VNet (secure, fast)
- No public internet exposure

### **2. Manual SQL Access**
- **Production:** Azure Bastion + Jump Box (most secure)
- **Dev/Test:** Temporary public access (quick debugging)
- **Alternative:** VPN Gateway, Azure Container Instance

### **3. Managed Identity Authentication**
- Passwordless authentication via Azure AD tokens
- Tokens auto-rotated every hour
- Unique identity per service
- Audit trail in Azure AD logs

### **4. Local Docker Environment**
- Uses **same Flyway migration scripts** as Azure
- SQL Server 2022 container (free developer edition)
- SQL authentication (local dev only)
- Dev/prod parity for schema and code

---

## Next Steps

1. **Review DNS documentation** and verify your Private DNS Zone setup
2. **Choose manual access method** for your production environment
3. **Test managed identity** authentication in dev environment
4. **Set up local Docker Compose** for offline development
5. **Create additional Flyway migrations** as your schema evolves

All scripts and configurations are ready to use! 🚀
