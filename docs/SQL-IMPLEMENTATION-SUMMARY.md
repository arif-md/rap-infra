# SQL Database Implementation - Summary

**Version**: 1.0  
**Date**: November 2, 2025

## What Was Implemented

### 1. Three SQL Server Options Documented ✅

Comprehensive comparison of:
- **Option 1: Azure SQL Database** (Managed PaaS) - **CHOSEN**
- **Option 2: SQL Server in ACI** (Container-based)
- **Option 3: SQL Server on VM** (IaaS)

**Documented in**: `infra/docs/SQL-DATABASE-SETUP.md`

**Why Azure SQL Database?**
- Zero database operations overhead
- Built-in HA/DR, backups, security
- Native VNet + Private Endpoint support
- Managed Identity authentication
- Best fit for microservices architecture

---

### 2. Automated Deployment via `azd up` ✅

**Single command deployment**:
```bash
azd env set SQL_ADMIN_PASSWORD 'YourSecurePassword123!'
azd up
```

**What runs automatically**:
1. **Preprovision**: ACR validation, image resolution
2. **Bicep Deployment**: VNet, SQL, Container Apps
3. **Postprovision**: SQL permissions grant
4. **Application Startup**: Flyway migrations

**What runs on `azd down`**:
- Deletes all infrastructure resources
- Keeps resource group (detaches)
- Keeps ACR (external resource)

---

### 3. Database Initialization with Flyway ✅

**Industry Standard Approach**:
- Version-controlled SQL migration scripts
- Automatic execution on app startup
- **Same migrations** run in local Docker and Azure
- Idempotent and auditable

**Migration Location**: `backend/src/main/resources/db/migration/V1__Initial_schema.sql`

**Flyway Tracks**:
- Which migrations ran
- When they ran
- Who ran them (in `flyway_schema_history` table)

---

### 4. Local Development Parity ✅

**Docker Compose** (`backend/docker-compose.yml`):
```bash
docker-compose up -d
```

**Provides**:
- SQL Server 2022 container
- Same Flyway migrations as Azure
- Consistent schema across environments
- SQL Authentication for local dev

**Differences from Azure**:
| Aspect | Local | Azure |
|--------|-------|-------|
| Auth | SQL (sa/password) | Managed Identity |
| Network | Docker bridge | VNet + Private Endpoint |
| Schema | Flyway migrations ✅ | Flyway migrations ✅ |

---

### 5. Automated Permission Grants ✅

**No Manual Steps Required** (in most cases)

**Postprovision Hook** (`scripts/postprovision.sh`):
- Automatically grants backend managed identity permissions
- Runs SQL commands via `sqlcmd`
- Creates database user from Azure AD external provider
- Grants `db_datareader`, `db_datawriter`, `db_ddladmin` roles

**Handles Edge Cases**:
- SQL Server not yet created → Skip
- Managed identity not found → Skip
- Private endpoint enabled → Provides manual instructions
- sqlcmd not installed → Displays SQL commands to run

---

## Files Created/Modified

### New Files
1. `infra/modules/sqlDatabase.bicep` - SQL Server + Database module
2. `infra/shared/vnet.bicep` - Virtual Network with subnets
3. `infra/shared/privateDnsZone.bicep` - Private DNS zone
4. `infra/scripts/ensure-sql-permissions.sh` - Automated permission grants
5. `infra/scripts/postprovision.sh` - Post-deployment hook
6. `backend/src/main/resources/db/migration/V1__Initial_schema.sql` - Initial schema
7. `infra/docs/SQL-DATABASE-SETUP.md` - Comprehensive documentation

### Modified Files
1. `infra/main.bicep` - Added VNet, DNS, SQL modules
2. `infra/main.parameters.json` - Added SQL parameters
3. `infra/app/backend-springboot.bicep` - Added SQL connection injection
4. `infra/azure.yaml` - Added postprovision hook
5. `backend/pom.xml` - Added Flyway dependencies
6. `backend/src/main/resources/application.properties` - Configured Flyway
7. `backend/docker-compose.yml` - Updated to use Flyway

---

## Deployment Workflow

### First Time Setup

```bash
# 1. Set SQL admin password (required once per environment)
azd env set SQL_ADMIN_PASSWORD 'YourSecurePassword123!'

# 2. Optional: Customize SQL SKU
azd env set SQL_DATABASE_SKU 'Basic'      # or S0, P1, GP_S_Gen5_1
azd env set SQL_DATABASE_TIER 'Basic'     # or Standard, Premium, GeneralPurpose

# 3. Deploy everything
azd up
```

### What Happens

```
1. Preprovision Hook
   ├── Ensure ACR exists
   ├── Resolve container images
   └── Validate ACR bindings

2. Bicep Deployment
   ├── Create VNet (10.0.0.0/16)
   │   ├── Container Apps subnet (10.0.0.0/23)
   │   └── Private Endpoints subnet (10.0.2.0/24)
   ├── Create Private DNS Zone (privatelink.database.windows.net)
   ├── Create SQL Server
   ├── Create SQL Database
   ├── Create Private Endpoint
   ├── Create Container Apps Environment (VNet-integrated)
   ├── Create Backend Container App
   └── Inject SQL connection string (with managed identity auth)

3. Postprovision Hook
   ├── Check if SQL Server exists
   ├── Get backend managed identity
   ├── Connect to SQL Server
   ├── CREATE USER [identity] FROM EXTERNAL PROVIDER
   ├── GRANT db_datareader, db_datawriter, db_ddladmin
   └── Success! ✅

4. Backend App Startup
   ├── Flyway connects to database
   ├── Checks flyway_schema_history table
   ├── Runs pending migrations (V1__Initial_schema.sql)
   ├── Creates tables: users, products, orders, order_items
   ├── Inserts sample data
   ├── Spring Boot validates schema
   └── App ready to serve requests ✅
```

### Tear Down

```bash
# Remove all infrastructure
azd down

# What gets deleted:
# - All Container Apps
# - SQL Database
# - SQL Server  
# - VNet, Private Endpoint, DNS Zone
# - Monitoring resources

# What remains:
# - Resource Group
# - ACR (external dependency)
```

---

## Industry Best Practices Followed

### 1. Infrastructure as Code
- ✅ All resources defined in Bicep
- ✅ Version controlled
- ✅ Repeatable deployments

### 2. Database Migrations
- ✅ Flyway (industry standard)
- ✅ Version-controlled SQL scripts
- ✅ Automatic execution
- ✅ Environment parity

### 3. Security
- ✅ Private endpoints (no public access)
- ✅ Managed identity (passwordless)
- ✅ VNet isolation
- ✅ TLS 1.2 minimum
- ✅ Least privilege RBAC

### 4. DevOps
- ✅ Single command deployment (`azd up`)
- ✅ Single command teardown (`azd down`)
- ✅ Automated permission grants
- ✅ Pre/post provision hooks

### 5. Development Experience
- ✅ Local Docker environment matches Azure
- ✅ Same migrations everywhere
- ✅ No manual SQL script execution
- ✅ Fast iteration (Flyway auto-runs)

---

## Addressing Your Questions

### Q1: Why is Option 1 (Azure SQL) beneficial for our case?

**Answer**: See comparison matrix in SQL-DATABASE-SETUP.md

Key reasons:
1. Microservices architecture → Stateless containers need managed database
2. Team efficiency → Focus on code, not DB admin
3. Private endpoints → Seamless VNet integration
4. Managed identity → Zero-trust security
5. Built-in HA/DR → Production-ready out of the box

---

### Q2: Shouldn't DB be set through pre-provisioning scripts?

**Answer**: **Hybrid approach** (optimal for Azure)

**Pre-provision**: External dependencies (ACR, images)
**Bicep**: Resource creation (VNet, SQL, Container Apps)
**Post-provision**: Runtime configuration (permissions, initialization)

**Why not pre-provision for SQL?**
- Bicep handles resource orchestration better
- Dependency tracking automatic (VNet → SQL → Container Apps)
- Post-provision grants permissions after identity created
- Industry standard: IaC for resources, scripts for runtime config

---

### Q3: Can we have DB initialization scripts for consistency?

**Answer**: **YES - Flyway migrations** ✅

- ✅ V1__Initial_schema.sql runs automatically
- ✅ Same script in local Docker and Azure
- ✅ Version controlled
- ✅ Idempotent (safe to re-run)
- ✅ Add V2, V3, V4... as needed

**Location**: `backend/src/main/resources/db/migration/`

---

### Q4: Can I still use `azd up` and `azd down`?

**Answer**: **YES - Fully supported** ✅

```bash
# Everything up
azd up

# Everything down
azd down
```

**No manual steps required** (postprovision handles permissions automatically)

---

### Q5: Can we avoid manual SQL commands?

**Answer**: **YES - Automated via `postprovision.sh`** ✅

**How it works**:
1. `azd up` completes Bicep deployment
2. `postprovision.sh` runs automatically
3. Script connects to SQL Server
4. Grants managed identity permissions
5. Backend starts and Flyway runs migrations
6. Done! ✅

**Edge case**: If SQL has private endpoint and script runs from outside VNet:
- Script detects this and provides instructions
- **Workaround**: Temporarily enable public access during first deployment

---

## Next Steps

1. **Test the deployment**:
   ```bash
   azd env set SQL_ADMIN_PASSWORD 'YourSecurePassword123!'
   azd up
   ```

2. **Verify Flyway migrations**:
   ```bash
   az containerapp logs show -n dev-rap-be -g rg-raptor-test --tail 100 | grep Flyway
   ```

3. **Add more migrations**:
   - Create `V2__Add_customer_table.sql`
   - Flyway runs it automatically on next deployment

4. **Test local development**:
   ```bash
   cd backend
   docker-compose up -d
   curl http://localhost:8080/api/health
   ```

5. **Review documentation**:
   - `infra/docs/SQL-DATABASE-SETUP.md` - Complete guide
   - `backend/src/main/resources/db/migration/` - Migration scripts

---

## Support

**Common Issues**:
1. "Login failed for user" → Re-run `./scripts/postprovision.sh`
2. "Cannot resolve SQL hostname" → Check Private DNS Zone VNet link
3. "Flyway migration failed" → Check migration syntax
4. "sqlcmd not found" → Install mssql-tools or run SQL manually

**Get Help**:
- Check `infra/docs/SQL-DATABASE-SETUP.md` troubleshooting section
- Review backend logs: `az containerapp logs show`
- Verify SQL permissions: Query `sys.database_principals`
