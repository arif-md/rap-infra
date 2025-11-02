# Azure SQL Database Setup with Managed Identity

**Version**: 1.1  
**Last Updated**: November 2, 2025  
**Status**: ✅ Complete

## Overview

The RAP (Raptor) infrastructure now includes Azure SQL Database with:
- **Private Endpoint**: Secure, private connectivity from Container Apps
- **Managed Identity Authentication**: Passwordless authentication using Azure AD
- **VNet Integration**: Container Apps and SQL Server connected via private virtual network
- **Automatic Configuration**: Connection strings injected via environment variables
- **Schema Automation**: Flyway migrations for consistent database schema across environments

## SQL Server Options for Containerized Applications

When deploying SQL Server for containerized microservices, you have three main options:

### Option 1: Azure SQL Database (Managed PaaS) ⭐ **CHOSEN**

**What it is**: Fully managed SQL Server database-as-a-service

**Pros**:
- ✅ **Zero Database Operations**: Microsoft manages patching, backups, HA, security updates
- ✅ **Built-in High Availability**: 99.99% SLA with automatic failover
- ✅ **Automatic Backups**: Point-in-time restore (7-35 days retention)
- ✅ **Elastic Scaling**: Scale up/down without downtime; serverless option available
- ✅ **Advanced Security**: Private endpoints, managed identity auth, TDE, threat protection
- ✅ **Best Azure Integration**: Native support in Container Apps, App Service, Functions
- ✅ **Cost Effective for Production**: No VM management overhead
- ✅ **Geo-Replication**: Active geo-replication for DR scenarios
- ✅ **Auditing & Monitoring**: Built-in diagnostics, query performance insights

**Cons**:
- ❌ **Higher Cost than Self-Managed**: ~$5-15/month (Basic/Standard) vs self-hosted
- ❌ **Feature Limitations**: No SQL Agent, limited cross-database queries
- ❌ **Less Control**: Cannot modify server-level configurations

**Best for**: **Production microservices requiring reliability, security, and minimal operations overhead**

**Why we chose this**:
1. **Microservices Architecture**: Container Apps are stateless; database should be managed externally
2. **DevOps Efficiency**: Team focuses on application code, not database administration
3. **Private Endpoint Support**: Seamless integration with VNet-isolated Container Apps
4. **Managed Identity**: Passwordless authentication aligns with zero-trust security
5. **Automatic Scaling**: Serverless tier auto-scales for variable workloads
6. **Disaster Recovery**: Built-in geo-replication and backup/restore capabilities

---

### Option 2: SQL Server in Azure Container Instances (ACI)

**What it is**: SQL Server running in a container on Azure Container Instances

**Pros**:
- ✅ **Lower Cost**: Pay only for container compute (~$30-50/month)
- ✅ **Full SQL Server Features**: Developer/Express edition with all features
- ✅ **Quick Dev/Test Setup**: Spin up/down rapidly for testing
- ✅ **Container Portability**: Same image works locally and in Azure

**Cons**:
- ❌ **No Automatic Backups**: Must implement backup scripts/volumes
- ❌ **No High Availability**: Single container; no automatic failover
- ❌ **Data Persistence Complexity**: Requires Azure Files/Disk mounting
- ❌ **Manual Patching**: You manage SQL Server updates and security patches
- ❌ **Not Production-Ready**: Microsoft doesn't recommend for production workloads
- ❌ **Licensing Considerations**: Developer edition for non-prod only; need licenses for prod

**Best for**: Development and testing environments where cost is primary concern

**Why we didn't choose this**:
- No automatic HA/DR for production workloads
- Operational overhead (backups, patching, monitoring)
- Not recommended by Microsoft for production databases

---

### Option 3: SQL Server on Azure Virtual Machine

**What it is**: SQL Server installed on Windows/Linux VM

**Pros**:
- ✅ **Full Control**: Complete access to SQL Server and OS configurations
- ✅ **All SQL Features**: SQL Agent, cross-database queries, advanced features
- ✅ **BYOL Support**: Bring your own SQL Server licenses (cost savings)
- ✅ **Custom HA/DR**: Configure Always On Availability Groups, clustering
- ✅ **Production-Grade**: Suitable for enterprise workloads

**Cons**:
- ❌ **Highest Operational Overhead**: Manage VM, OS patches, SQL updates, backups
- ❌ **More Expensive**: VM costs + storage + management (~$100-300+/month)
- ❌ **Complexity**: Requires database administrator expertise
- ❌ **Slower Provisioning**: Minutes to provision VM vs seconds for Azure SQL
- ❌ **Manual Scaling**: More complex to scale compared to Azure SQL

**Best for**: Lift-and-shift migrations, applications requiring specific SQL Server features, or when you have existing licenses

**Why we didn't choose this**:
- Microservices architecture benefits from managed services
- Team lacks dedicated DBA resources
- Higher total cost of ownership (TCO)
- Slower iteration speed for development

---

## Comparison Matrix

| Feature | Azure SQL Database | SQL on ACI | SQL on VM |
|---------|-------------------|------------|-----------|
| **Management Overhead** | None | Medium | High |
| **High Availability** | Built-in (99.99%) | None | Manual setup |
| **Backups** | Automatic | Manual | Manual |
| **Scaling** | Automatic | Manual | Manual |
| **Private Endpoints** | ✅ Native | ⚠️ Complex | ✅ Supported |
| **Managed Identity** | ✅ Native | ❌ No | ⚠️ Limited |
| **Cost (Dev)** | ~$5/month | ~$30/month | ~$100/month |
| **Cost (Prod)** | ~$15-465/month | Not recommended | ~$200-500/month |
| **Setup Time** | Seconds | Minutes | 15-30 minutes |
| **Ideal Use Case** | Production microservices | Dev/Test | Enterprise legacy apps |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Virtual Network (10.0.0.0/16)                              │
│                                                              │
│  ┌──────────────────────────┐  ┌─────────────────────────┐  │
│  │ Container Apps Subnet     │  │ Private Endpoints Subnet│  │
│  │ (10.0.0.0/23)             │  │ (10.0.2.0/24)           │  │
│  │                           │  │                         │  │
│  │  ┌──────────────────┐    │  │  ┌──────────────────┐  │  │
│  │  │ Backend Container│◄───┼──┼──┤ SQL Private     │  │  │
│  │  │ App (Spring Boot)│    │  │  │ Endpoint         │  │  │
│  │  └──────────────────┘    │  │  └────────┬─────────┘  │  │
│  │                           │  │           │            │  │
│  └──────────────────────────┘  └───────────┼────────────┘  │
│                                             │               │
└─────────────────────────────────────────────┼───────────────┘
                                              │
                                              ▼
                                   ┌────────────────────┐
                                   │ Azure SQL Database │
                                   │ (privatelink FQDN) │
                                   └────────────────────┘
```

## Infrastructure Components

### 1. Virtual Network (`infra/shared/vnet.bicep`)

Creates a VNet with two subnets:
- **Container Apps Subnet** (`10.0.0.0/23`): Delegated to `Microsoft.App/environments`
- **Private Endpoints Subnet** (`10.0.2.0/24`): For SQL private endpoint

### 2. Private DNS Zone (`infra/shared/privateDnsZone.bicep`)

- **Zone**: `privatelink.database.windows.net`
- **Purpose**: Resolves SQL Server FQDN to private IP address
- **VNet Link**: Automatically links to the VNet

### 3. SQL Database (`infra/modules/sqlDatabase.bicep`)

- **SQL Server**: Logical server with admin authentication
- **SQL Database**: Single database with configurable SKU
- **Private Endpoint**: Secure connection from Container Apps
- **Public Access**: Disabled when private endpoint is enabled
- **TLS**: Minimum version 1.2

## Configuration

### Infrastructure Parameters (`main.parameters.json`)

```json
{
  "enableSqlDatabase": {
    "value": "${ENABLE_SQL_DATABASE=true}"
  },
  "sqlAdminLogin": {
    "value": "${SQL_ADMIN_LOGIN=sqladmin}"
  },
  "sqlAdminPassword": {
    "value": "${SQL_ADMIN_PASSWORD}"
  },
  "sqlDatabaseSku": {
    "value": "${SQL_DATABASE_SKU=Basic}"
  },
  "sqlDatabaseTier": {
    "value": "${SQL_DATABASE_TIER=Basic}"
  }
}
```

### Environment Variables

Set these in `.azure/{env}/.env` (local) or GitHub Environment secrets (CI/CD):

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `ENABLE_SQL_DATABASE` | Enable/disable SQL deployment | `true` | No (default: true) |
| `SQL_ADMIN_LOGIN` | SQL Server admin username | `sqladmin` | No (default: sqladmin) |
| `SQL_ADMIN_PASSWORD` | SQL Server admin password | `P@ssw0rd123!` | **Yes** |
| `SQL_DATABASE_SKU` | Database SKU name | `Basic`, `S0`, `P1` | No (default: Basic) |
| `SQL_DATABASE_TIER` | Database tier | `Basic`, `Standard`, `Premium` | No (default: Basic) |

### Spring Boot Configuration

The backend Container App receives these environment variables automatically:

```properties
# Injected by backend-springboot.bicep
SPRING_DATASOURCE_URL=jdbc:sqlserver://{sql-server-fqdn}:1433;database={database-name};encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;authentication=ActiveDirectoryMSI;
SPRING_DATASOURCE_DRIVER_CLASS_NAME=com.microsoft.sqlserver.jdbc.SQLServerDriver
SQL_SERVER_FQDN={sql-server-fqdn}
SQL_DATABASE_NAME={database-name}
```

**Key JDBC URL Parameters**:
- `authentication=ActiveDirectoryMSI`: Use managed identity (passwordless)
- `encrypt=true`: Enforce encryption
- `trustServerCertificate=false`: Validate server certificate
- `hostNameInCertificate=*.database.windows.net`: Expected certificate CN

## Troubleshooting

### Issue: Backend fails to start with "Login failed for user"

**Symptoms**:
```
com.microsoft.sqlserver.jdbc.SQLServerException: Login failed for user '<token-identified principal>'
```

**Root Cause**: Backend managed identity doesn't have SQL database permissions

**Automated Solution** (postprovision script should handle this):
```bash
# Re-run postprovision hook
cd infra
./scripts/postprovision.sh
```

**Manual Solution** (if script fails):
1. Check if public access is enabled:
   ```bash
   az sql server show -n {sql-server} -g {rg} --query "publicNetworkAccess" -o tsv
   ```

2. If "Disabled", temporarily enable:
   ```bash
   az sql server update -n {sql-server} -g {rg} --enable-public-network true
   ```

3. Run permission grant SQL:
   ```sql
   CREATE USER [id-backend-{resourceToken}] FROM EXTERNAL PROVIDER;
   ALTER ROLE db_datareader ADD MEMBER [id-backend-{resourceToken}];
   ALTER ROLE db_datawriter ADD MEMBER [id-backend-{resourceToken}];
   ALTER ROLE db_ddladmin ADD MEMBER [id-backend-{resourceToken}];
   ```

4. Disable public access:
   ```bash
   az sql server update -n {sql-server} -g {rg} --enable-public-network false
   ```

### Automated Deployment with `azd up`

The entire infrastructure including SQL Database is deployed with a single command:

```bash
# Set SQL admin password (REQUIRED - one time)
azd env set SQL_ADMIN_PASSWORD 'YourSecurePassword123!'

# Deploy everything (VNet, SQL, Container Apps, permissions)
azd up
```

**What happens automatically**:

1. **Preprovision Hook** (`scripts/ensure-acr.sh`):
   - Ensures Azure Container Registry exists
   - Resolves container images
   - Validates ACR bindings

2. **Bicep Deployment** (`main.bicep`):
   - ✅ Creates Virtual Network with subnets
   - ✅ Creates Private DNS Zone
   - ✅ Creates SQL Server with private endpoint
   - ✅ Creates SQL Database
   - ✅ Creates Container Apps Environment (VNet-integrated)
   - ✅ Creates Backend Container App with managed identity
   - ✅ Injects SQL connection string into backend

3. **Postprovision Hook** (`scripts/postprovision.sh`):
   - ✅ Grants backend managed identity SQL permissions
   - ✅ Creates database user from external provider (Azure AD)
   - ✅ Grants `db_datareader`, `db_datawriter`, `db_ddladmin` roles

4. **Application Startup** (Backend Container App):
   - ✅ Flyway runs database migrations automatically
   - ✅ Creates tables, indexes, sample data (V1__Initial_schema.sql)
   - ✅ Spring Boot starts with validated schema

### Industry Best Practices for Microservices

**Why We Chose This Approach**:

1. **Infrastructure as Code (IaC)**: All resources defined in Bicep
   - Repeatable deployments across environments
   - Version controlled infrastructure changes
   - No manual Azure Portal clicks

2. **Pre/Post Provision Hooks**: Azure Developer CLI standard pattern
   - `preprovision`: Setup external dependencies (ACR, network)
   - `postprovision`: Configure runtime permissions and initialization

3. **Database Migrations (Flyway)**: Industry standard for schema management
   - Version-controlled SQL scripts
   - Automatic execution on application startup
   - Same migrations run in local Docker and Azure
   - Rollback capability (via Flyway undo migrations)

4. **Managed Identity**: Passwordless authentication
   - No connection string secrets in code or environment variables
   - Azure AD manages token lifecycle
   - Automatic rotation and renewal

5. **Separation of Concerns**:
   - **Infrastructure** (Bicep): Creates resources and networking
   - **Permissions** (Scripts): Grants access after resources exist
   - **Schema** (Flyway): Manages database structure in application code
   - **Data** (Application): Business logic owns data operations

### Database Initialization Strategy

**Flyway Migration-Based Approach** (Recommended for Microservices):

```
┌─────────────────────────────────────────────────────────────┐
│ Application Starts                                          │
│   ↓                                                          │
│ 1. Flyway checks flyway_schema_history table               │
│   ↓                                                          │
│ 2. Identifies pending migrations (V1, V2, V3...)           │
│   ↓                                                          │
│ 3. Executes migrations in order                            │
│   ↓                                                          │
│ 4. Updates flyway_schema_history with applied migrations   │
│   ↓                                                          │
│ 5. Spring Boot validates schema against JPA entities       │
│   ↓                                                          │
│ 6. Application ready to serve requests                     │
└─────────────────────────────────────────────────────────────┘
```

**Benefits**:
- ✅ **Environment Parity**: Same migrations run in local, dev, test, prod
- ✅ **Declarative**: SQL scripts in `src/main/resources/db/migration/`
- ✅ **Idempotent**: Running twice produces same result
- ✅ **Versioned**: Each migration has a version number (V1, V2, V3...)
- ✅ **Auditable**: `flyway_schema_history` table tracks what ran when
- ✅ **Team Collaboration**: Merge conflicts detected early via version numbers

**Alternative Approaches (Not Recommended for Production)**:
- ❌ **Hibernate DDL Auto (`create-drop`)**: Deletes all data on restart
- ❌ **Hibernate DDL Auto (`update`)**: Cannot reliably handle all schema changes
- ❌ **Manual SQL Scripts**: Requires manual execution, error-prone
- ❌ **Pre-deployment Scripts**: Tightly couples infrastructure and application

### Local Development with Docker Compose

Consistent database experience in local development:

```bash
# Start SQL Server and backend locally
cd backend
docker-compose up -d

# Flyway runs V1__Initial_schema.sql automatically
# Same schema as Azure deployment!

# View logs
docker-compose logs -f backend

# Access backend
curl http://localhost:8080/api/health

# Connect to SQL Server
sqlcmd -S localhost,1433 -U sa -P 'YourStrong@Passw0rd' -d raptordb
```

**Local vs Azure Differences**:

| Aspect | Local (Docker) | Azure (Production) |
|--------|----------------|-------------------|
| **Authentication** | SQL Auth (sa/password) | Managed Identity (passwordless) |
| **Network** | Docker bridge network | VNet + Private Endpoint |
| **Database** | SQL Server 2022 container | Azure SQL Database |
| **Schema** | Flyway migrations | Flyway migrations ✅ **Same** |
| **Connection String** | `jdbc:sqlserver://localhost:1433;database=raptordb` | `jdbc:sqlserver://{fqdn}:1433;database={name};authentication=ActiveDirectoryMSI` |

### Automated Permission Grants

**How `scripts/ensure-sql-permissions.sh` Works**:

```bash
# Called automatically by azd hooks:postprovision

# 1. Check if SQL Server exists
SQL_SERVER=$(az sql server list -g $RG --query "[0].name" -o tsv)

# 2. Get backend managed identity
IDENTITY=$(az identity list -g $RG --query "[?contains(name,'backend')].name | [0]" -o tsv)

# 3. Create SQL user from external provider
sqlcmd -S $SQL_SERVER.database.windows.net -U $SQL_ADMIN -P $SQL_PASSWORD -Q "
  CREATE USER [$IDENTITY] FROM EXTERNAL PROVIDER;
  ALTER ROLE db_datareader ADD MEMBER [$IDENTITY];
  ALTER ROLE db_datawriter ADD MEMBER [$IDENTITY];
  ALTER ROLE db_ddladmin ADD MEMBER [$IDENTITY];  -- Flyway needs DDL
"
```

**Challenges Addressed**:

1. **Chicken-and-Egg Problem**: Identity must exist before granting permissions
   - ✅ **Solution**: Postprovision hook runs after Bicep deployment

2. **Private Endpoint Access**: Script cannot connect to SQL if public access disabled
   - ✅ **Solution**: Script detects private endpoint and provides manual instructions
   - ⚠️ **Workaround**: Temporarily enable public access during initial setup:
     ```bash
     az sql server update -n $SQL_SERVER -g $RG --enable-public-network true
     azd up
     az sql server update -n $SQL_SERVER -g $RG --enable-public-network false
     ```

3. **sqlcmd Availability**: Not all environments have sqlcmd installed
   - ✅ **Solution**: Script checks for sqlcmd and provides install instructions
   - ✅ **Alternative**: Displays SQL commands for manual execution

### Tear Down Infrastructure

```bash
# Remove all infrastructure resources
azd down

# What gets deleted:
# - Container Apps (frontend + backend)
# - Container Apps Environment
# - SQL Database
# - SQL Server
# - Private Endpoint
# - Private DNS Zone
# - Virtual Network
# - Monitoring resources

# What gets kept:
# - Resource Group (azd default behavior)
# - Azure Container Registry (external resource)

# To also delete the resource group:
azd down --purge
```

### Initial Deployment

```bash
# Set SQL admin password (REQUIRED)
azd env set SQL_ADMIN_PASSWORD 'YourSecurePassword123!'

# Optional: Customize SQL configuration
azd env set SQL_DATABASE_SKU 'S0'          # Standard tier
azd env set SQL_DATABASE_TIER 'Standard'

# Deploy infrastructure
azd up
```

### Post-Deployment

1. **Verify Backend Connection**:
   ```bash
   # Check backend logs for SQL connection and Flyway migrations
   az containerapp logs show -n dev-rap-be -g rg-raptor-test --tail 100
   
   # Look for successful Flyway execution:
   # "Flyway Community Edition X.X.X"
   # "Successfully validated X migrations"
   # "Successfully applied X migrations"
   # "HikariPool-1 - Start completed"
   ```

2. **Check Database Schema**:
   ```bash
   # Query Flyway migration history
   sqlcmd -S {sql-server}.database.windows.net -d {database} -U {admin} -P {password} -Q "
   SELECT * FROM flyway_schema_history ORDER BY installed_rank;
   "
   ```

### Disable SQL Database

To deploy without SQL Database:

```bash
azd env set ENABLE_SQL_DATABASE 'false'
azd up
```

## Troubleshooting

### Issue: Backend fails to start with SQL connection error

**Symptoms**:
```
com.microsoft.sqlserver.jdbc.SQLServerException: Login failed for user '<token-identified principal>'
```

**Solution**: Grant managed identity permissions (see "Database Permissions Setup" above)

---

### Issue: Cannot resolve SQL Server hostname

**Symptoms**:
```
java.net.UnknownHostException: {sql-server-name}.database.windows.net
```

**Solution**: 
- Verify Private DNS Zone is linked to VNet
- Check Container Apps Environment is using VNet integration
- Restart backend container app

---

### Issue: SQL deployment fails with "SubnetDelegationFailed"

**Symptoms**:
```
Subnet must be delegated to Microsoft.App/environments
```

**Solution**: Ensure VNet subnet has proper delegation (already configured in `vnet.bicep`)

---

### Issue: Managed identity authentication fails

**Symptoms**:
```
The token provided does not have the necessary permissions
```

**Solution**:
1. Verify backend managed identity exists:
   ```bash
   az identity list -g rg-raptor-test
   ```
2. Confirm SQL permissions granted (run CREATE USER and ALTER ROLE commands)
3. Restart backend app to refresh identity token

## SKU Recommendations

| Environment | SKU | Tier | Cost (approx) | Use Case |
|-------------|-----|------|---------------|----------|
| Dev | `Basic` | `Basic` | ~$5/month | Development, light testing |
| Test | `S0` | `Standard` | ~$15/month | Integration testing |
| Train | `S1` | `Standard` | ~$30/month | Pre-production, training |
| Prod | `P1` | `Premium` | ~$465/month | Production workloads, HA |

**Serverless Option** (for dev/test):
```json
{
  "sqlDatabaseSku": "GP_S_Gen5_1",
  "sqlDatabaseTier": "GeneralPurpose"
}
```
- Auto-pauses after inactivity
- ~$0.50/hour when active
- Good for intermittent workloads

## Security Best Practices

✅ **Implemented**:
- Private endpoint (no public access)
- TLS 1.2 minimum
- Managed identity authentication (passwordless)
- VNet isolation
- Private DNS resolution

⚠️ **Recommended**:
- Store SQL admin password in Azure Key Vault
- Enable Azure AD admin-only authentication (disable SQL auth)
- Configure firewall rules for admin access
- Enable Advanced Threat Protection
- Configure auditing and diagnostic logs

## Related Files

- `infra/main.bicep` - Main infrastructure orchestration
- `infra/modules/sqlDatabase.bicep` - SQL Server + Database module
- `infra/shared/vnet.bicep` - Virtual Network module
- `infra/shared/privateDnsZone.bicep` - Private DNS Zone module
- `infra/app/backend-springboot.bicep` - Backend Container App (SQL injection)
- `backend/pom.xml` - Spring Boot dependencies (JPA, SQL Server driver)
- `backend/src/main/resources/application.properties` - JPA configuration

## Next Steps

1. ✅ Deploy infrastructure with SQL Database
2. ⏳ Grant backend managed identity SQL permissions
3. ⏳ Create database schema (tables, indexes)
4. ⏳ Add Spring Data JPA entities and repositories
5. ⏳ Implement REST API endpoints
6. ⏳ Add database migration tool (Flyway or Liquibase)
7. ⏳ Configure backup retention policies
8. ⏳ Set up monitoring and alerts

## Support

For issues:
1. Check backend container logs: `az containerapp logs show -n dev-rap-be -g rg-raptor-test`
2. Verify SQL Server firewall rules
3. Test SQL connectivity from Container App
4. Review managed identity permissions

For SQL admin access troubleshooting:
1. Temporarily enable public access: `az sql server update -n {server-name} -g {rg} --enable-public-network true`
2. Add your IP: `az sql server firewall-rule create -g {rg} -s {server-name} -n MyIP --start-ip-address {your-ip} --end-ip-address {your-ip}`
3. After admin tasks, disable public access again
