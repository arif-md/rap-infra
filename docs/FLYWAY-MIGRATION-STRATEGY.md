# Flyway Migration Strategy Guide

Comprehensive guide for database schema management using Flyway in the RAP microservices project.

---

## Table of Contents
1. [Flyway Basics](#1-flyway-basics)
2. [Development Workflow (Iterative Changes)](#2-development-workflow-iterative-changes)
3. [Rollback Strategies](#3-rollback-strategies)
4. [Environment Promotion](#4-environment-promotion)
5. [Best Practices](#5-best-practices)
6. [Common Scenarios](#6-common-scenarios)

---

## 1. Flyway Basics

### What is Flyway?

**Flyway** is a database migration tool that applies **versioned SQL scripts** to your database in a controlled, repeatable manner.

### Core Concepts

```
┌────────────────────────────────────────────────────────────────┐
│  Flyway Migration Lifecycle                                     │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Flyway scans db/migration/ for SQL files                   │
│     ├─ V1__Initial_schema.sql                                  │
│     ├─ V2__Add_user_roles.sql                                  │
│     └─ V3__Add_orders_table.sql                                │
│                                                                 │
│  2. Checks flyway_schema_history table                         │
│     ├─ Which migrations already ran?                           │
│     ├─ V1: ✅ Applied on 2025-01-15 10:30:00                   │
│     ├─ V2: ✅ Applied on 2025-01-20 14:22:00                   │
│     └─ V3: ❌ Not applied yet                                  │
│                                                                 │
│  3. Applies pending migrations in order                        │
│     └─ Runs V3__Add_orders_table.sql                           │
│                                                                 │
│  4. Records in flyway_schema_history                           │
│     └─ V3: ✅ Applied on 2025-01-25 09:15:00                   │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

### Migration File Naming Convention

```
V{VERSION}__{DESCRIPTION}.sql
│    │          │
│    │          └─ Human-readable description (underscores = spaces)
│    └─ Version number (determines order)
└─ Prefix: V = Versioned, R = Repeatable, U = Undo (paid version)
```

**Examples:**
```
V1__Initial_schema.sql              # Version 1
V2__Add_user_roles.sql              # Version 2
V2.1__Add_role_indexes.sql          # Version 2.1 (runs after V2)
V3__Add_orders_table.sql            # Version 3
V10__Add_payment_gateway.sql        # Version 10 (numeric comparison)
```

**CRITICAL RULES:**
- ✅ **Once applied, NEVER modify a migration file** (Flyway checksums will fail)
- ✅ **Version numbers must be unique** (can't have two V2 migrations)
- ✅ **Migrations run in version order** (V1 → V2 → V3)
- ✅ **Migrations are idempotent** (safe to run multiple times)

---

## 2. Development Workflow (Iterative Changes)

### Scenario: You're Developing a New Feature

**Problem:** During development, you might:
1. Create a table
2. Realize you need an extra column
3. Change the column type
4. Add an index
5. Rename the table

**❌ WRONG Approach:** Keep modifying V5__New_feature.sql
```sql
-- DON'T DO THIS - Editing existing migration
-- V5__New_feature.sql (attempt 1)
CREATE TABLE products (id INT);

-- V5__New_feature.sql (attempt 2 - EDITED!)
CREATE TABLE products (id INT, name VARCHAR(100));  -- Flyway checksum fails! ❌
```

**✅ CORRECT Approach:** Add new migrations for each iteration

```
Development Branch: feature/add-products
├─ V5__Add_products_table.sql          (Initial attempt)
├─ V6__Add_product_name_column.sql     (Iteration 1)
├─ V7__Change_price_to_decimal.sql     (Iteration 2)
├─ V8__Add_product_indexes.sql         (Iteration 3)
└─ V9__Rename_products_to_catalog.sql  (Final iteration)
```

### Local Development Cycle

```bash
# Day 1: Create initial migration
# backend/src/main/resources/db/migration/V5__Add_products_table.sql
CREATE TABLE products (
    id INT IDENTITY(1,1) PRIMARY KEY,
    name NVARCHAR(50)
);

# Test locally
docker-compose restart backend
# Flyway runs V5__Add_products_table.sql

# Day 2: Realized name is too short
# backend/src/main/resources/db/migration/V6__Increase_product_name_length.sql
ALTER TABLE products ALTER COLUMN name NVARCHAR(200);

# Test locally
docker-compose restart backend
# Flyway runs V6__Increase_product_name_length.sql

# Day 3: Need to add price
# backend/src/main/resources/db/migration/V7__Add_product_price.sql
ALTER TABLE products ADD price DECIMAL(10,2) NOT NULL DEFAULT 0.00;

# Test locally
docker-compose restart backend
# Flyway runs V7__Add_product_price.sql
```

**Result after all iterations:**
```
flyway_schema_history:
installed_rank | version | description                     | script
---------------|---------|--------------------------------|--------------------------------
5              | 5       | Add products table             | V5__Add_products_table.sql
6              | 6       | Increase product name length   | V6__Increase_product_name_length.sql
7              | 7       | Add product price              | V7__Add_product_price.sql
```

---

### Consolidating Migrations Before Production

**Problem:** Multiple incremental migrations clutter the history.

**Solution 1: Squashing Migrations (Development Only)**

Before merging to `main`, consolidate into a single clean migration:

```bash
# In feature branch, you have:
# V5, V6, V7 (incremental changes)

# Step 1: Reset local database
docker-compose down -v  # Delete volume
docker-compose up -d

# Step 2: Create consolidated migration
# backend/src/main/resources/db/migration/V5__Add_products_feature.sql
CREATE TABLE products (
    id INT IDENTITY(1,1) PRIMARY KEY,
    name NVARCHAR(200) NOT NULL,
    price DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    created_at DATETIME2 DEFAULT GETDATE()
);

CREATE INDEX idx_products_name ON products(name);

# Step 3: Delete old migrations
rm V6__Increase_product_name_length.sql
rm V7__Add_product_price.sql

# Step 4: Test consolidated migration
docker-compose restart backend
# Flyway applies single V5 migration

# Step 5: Commit to feature branch
git add db/migration/V5__Add_products_feature.sql
git rm db/migration/V6__Increase_product_name_length.sql
git rm db/migration/V7__Add_product_price.sql
git commit -m "Consolidated products feature migration"
```

**⚠️ CRITICAL:** Only squash migrations that **haven't been deployed to shared environments** (dev, test, prod).

---

**Solution 2: Keep All Migrations (Audit Trail)**

If migrations already deployed to `dev` environment:

```bash
# Keep all migrations for audit trail
# V5, V6, V7 all remain

# When merging to main:
git merge feature/add-products
# All three migrations go to production

# Production deployment:
# Flyway applies: V5 → V6 → V7 in sequence
```

**Pros:**
- ✅ Complete audit trail of changes
- ✅ No risk of checksum mismatches
- ✅ Matches exactly what ran in dev

**Cons:**
- ❌ Migration history can get cluttered
- ❌ Slower initial deployment (many small migrations)

---

## 3. Rollback Strategies

### The Hard Truth: Flyway Community Edition Doesn't Support Automatic Rollbacks

**Flyway Community (Free):**
- ❌ No automatic rollback
- ❌ No `U` (Undo) migrations
- ✅ Only forward migrations

**Flyway Teams/Enterprise (Paid):**
- ✅ Automatic rollback via `U` migrations
- ✅ Dry-run previews
- ✅ Cherry-pick migrations

### Rollback Strategies for Community Edition

---

#### **Strategy 1: Forward-Only Rollback (Recommended)**

**Principle:** Never go backward, always go forward with compensating migrations.

**Example:**

```sql
-- V10__Add_user_status_column.sql (Original - DEPLOYED)
ALTER TABLE users ADD status NVARCHAR(20) NOT NULL DEFAULT 'active';

-- Later: Realized status column causes issues
-- ❌ DON'T: Delete V10 migration (already ran in production!)
-- ❌ DON'T: Modify V10 migration (checksum will fail!)

-- ✅ DO: Create new migration to remove it
-- V11__Remove_user_status_column.sql (Rollback via new migration)
ALTER TABLE users DROP COLUMN status;
```

**Workflow:**
```bash
# Production has V10 (adds status column)
# Issue discovered: status column breaks legacy systems

# Create compensating migration
cat > db/migration/V11__Remove_user_status_column.sql <<EOF
-- Rollback V10 changes
ALTER TABLE users DROP COLUMN status;
EOF

# Deploy V11 to production
azd up
# Flyway applies V11, removes the problematic column
```

**Result:**
```
flyway_schema_history:
version | description                  | state
--------|------------------------------|--------
10      | Add user status column       | Success ✅
11      | Remove user status column    | Success ✅
```

Schema is back to original state, but history shows the journey.

---

#### **Strategy 2: Data Preservation Rollback**

**Problem:** Rolling back a column that has data.

**Solution:** Preserve data before dropping.

```sql
-- V10__Add_user_preferences.sql (Original)
ALTER TABLE users ADD preferences NVARCHAR(MAX);

-- Users start adding data to preferences column
-- Later: Need to rollback, but preserve data

-- V11__Rollback_user_preferences.sql (Safe rollback)
-- Step 1: Backup data
CREATE TABLE users_preferences_backup (
    user_id INT PRIMARY KEY,
    preferences NVARCHAR(MAX),
    backed_up_at DATETIME2 DEFAULT GETDATE()
);

INSERT INTO users_preferences_backup (user_id, preferences)
SELECT id, preferences FROM users WHERE preferences IS NOT NULL;

-- Step 2: Drop column
ALTER TABLE users DROP COLUMN preferences;

-- Note: Data is safe in users_preferences_backup for recovery if needed
```

---

#### **Strategy 3: Feature Flag Rollback (No Schema Change)**

**Best approach:** Use feature flags instead of dropping columns.

```sql
-- V10__Add_experimental_feature.sql
CREATE TABLE user_experiments (
    user_id INT PRIMARY KEY,
    feature_enabled BIT DEFAULT 0,  -- Feature flag
    experiment_data NVARCHAR(MAX)
);

-- Application code checks feature_enabled flag
-- If feature causes issues, disable via configuration (no migration needed)
UPDATE user_experiments SET feature_enabled = 0;  -- Turn off feature

-- Later, when feature is stable:
UPDATE user_experiments SET feature_enabled = 1;  -- Turn on feature
```

---

#### **Strategy 4: Versioned Schema Pattern**

**For complex rollbacks:** Use versioned tables.

```sql
-- V10__Create_products_v2.sql
-- Don't modify products table, create new version
CREATE TABLE products_v2 (
    id INT IDENTITY(1,1) PRIMARY KEY,
    name NVARCHAR(200),
    price DECIMAL(10,2),
    new_field NVARCHAR(100)  -- New field in v2
);

-- Migrate data
INSERT INTO products_v2 (name, price, new_field)
SELECT name, price, NULL FROM products;

-- Application uses products_v2
-- If issues found, switch back to products table (no migration needed)

-- Later: V11__Drop_products_v1.sql (when v2 is stable)
DROP TABLE products;
```

---

## 4. Environment Promotion

### Typical Environment Flow

```
Developer Laptop (Docker) → Dev → Test → Train → Production
```

### How Flyway Migrations are Promoted

```
┌─────────────────────────────────────────────────────────────────┐
│  Environment Promotion Flow                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. DEVELOPER LAPTOP (Docker Compose)                           │
│     ├─ Create V5, V6, V7 migrations                             │
│     ├─ Test locally with Flyway                                 │
│     ├─ Squash to V5 (optional)                                  │
│     └─ Commit to feature branch                                 │
│                                                                  │
│  2. DEV ENVIRONMENT (Azure SQL Database)                        │
│     ├─ Merge feature → main                                     │
│     ├─ GitHub Actions: Build backend image                      │
│     ├─ Push image: raptor/backend-dev@sha256:abc123            │
│     ├─ Deploy to dev-rap-be Container App                       │
│     ├─ Container starts → Flyway runs V5                        │
│     └─ Dev database: V1, V2, V3, V4, V5 ✅                      │
│                                                                  │
│  3. TEST ENVIRONMENT (Promote Image)                            │
│     ├─ Promote image: raptor/backend-dev → raptor/backend-test │
│     ├─ GitHub Actions: Tag & promote image                      │
│     ├─ Deploy to test-rap-be Container App                      │
│     ├─ Container starts → Flyway runs V5 (new)                  │
│     ├─ Test database: V1, V2, V3, V4, V5 ✅                     │
│     │                                                            │
│     ├─ BUG FOUND: V5 breaks order processing                    │
│     │                                                            │
│     └─ Hotfix: Create V6__Fix_order_issue.sql                   │
│         ├─ Build new image with V6                              │
│         ├─ Deploy to test                                       │
│         ├─ Flyway runs V6                                       │
│         └─ Test database: V1, V2, V3, V4, V5, V6 ✅             │
│                                                                  │
│  4. TRAIN ENVIRONMENT (Promote Fixed Image)                     │
│     ├─ Promote image with V6 fix                                │
│     ├─ Deploy to train-rap-be Container App                     │
│     ├─ Flyway runs V5, V6                                       │
│     └─ Train database: V1, V2, V3, V4, V5, V6 ✅                │
│                                                                  │
│  5. PRODUCTION (Final Promotion)                                │
│     ├─ Promote tested image                                     │
│     ├─ Deploy to prod-rap-be Container App                      │
│     ├─ Flyway runs V5, V6                                       │
│     └─ Prod database: V1, V2, V3, V4, V5, V6 ✅                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Key Points

**1. Migrations Are Embedded in Docker Images**
```dockerfile
# Backend Dockerfile
FROM maven:3.9-eclipse-temurin-17 AS build
COPY src/main/resources/db/migration /app/src/main/resources/db/migration  # ← Migrations packaged in image
RUN mvn package

FROM eclipse-temurin:17-jre
COPY --from=build /target/backend.jar /app.jar
# Migrations are inside backend.jar
```

**2. Same Image, Different Databases**
```bash
# Same Docker image deployed to all environments
raptor/backend:v1.2.3@sha256:abc123

# Different database connections:
# Dev:   sql-dev-abc.database.windows.net     (has V1-V4)
# Test:  sql-test-xyz.database.windows.net    (has V1-V3, needs V4)
# Prod:  sql-prod-def.database.windows.net    (has V1-V2, needs V3, V4)

# Flyway automatically applies missing migrations in each environment
```

---

### Handling Defects Found in Test/Train

#### **Scenario 1: Schema Bug Found in Test**

```bash
# Test environment has V5 deployed
# Bug found: V5 created column with wrong data type

# Option A: Create compensating migration (forward-only)
cat > db/migration/V6__Fix_column_type.sql <<EOF
ALTER TABLE orders ALTER COLUMN amount DECIMAL(18,2);  -- Was INT, should be DECIMAL
EOF

git add db/migration/V6__Fix_column_type.sql
git commit -m "Fix: Correct order amount column type"
git push

# GitHub Actions:
# - Builds new image with V6
# - Deploys to test
# - Flyway runs V6
# - Bug fixed ✅

# Later, promote to train/prod:
# - Same image (includes V5 + V6)
# - Flyway runs both migrations
# - Prod gets correct schema without ever having the bug ✅
```

---

#### **Scenario 2: Need to Revert Entire Feature**

```bash
# Test environment has V5 (new feature)
# Feature causes major issues, need to revert

# Create V6 to undo V5 changes
cat > db/migration/V6__Revert_new_feature.sql <<EOF
-- Undo all changes from V5
DROP TABLE IF EXISTS new_feature_table;
ALTER TABLE users DROP COLUMN IF EXISTS new_feature_flag;
-- Restore any modified columns to original state
EOF

git add db/migration/V6__Revert_new_feature.sql
git commit -m "Revert: Remove problematic feature"
git push

# Deploy to test
# Flyway runs V6, reverts changes
# Test environment: V1, V2, V3, V4, V5, V6 (V5 negated by V6)

# Promote to train/prod:
# These environments never had V5, but will get V5 + V6
# Net effect: No feature changes (V5 immediately undone by V6)
# History preserved for audit ✅
```

---

#### **Scenario 3: Hotfix Needed in Production (Skipping Test)**

**⚠️ Emergency only!**

```bash
# Production has critical bug, can't wait for test cycle

# Create hotfix branch
git checkout -b hotfix/critical-sql-bug

# Create emergency migration
cat > db/migration/V10.1__Emergency_index_fix.sql <<EOF
-- Add missing index causing production slowdown
CREATE INDEX idx_orders_created_at ON orders(created_at);
EOF

git add db/migration/V10.1__Emergency_index_fix.sql
git commit -m "Hotfix: Add critical index for performance"
git push origin hotfix/critical-sql-bug

# Deploy to production (bypass test/train)
# Manually trigger production deployment workflow

# After production fix:
# Merge hotfix to main
git checkout main
git merge hotfix/critical-sql-bug

# Deploy to test/train to sync them
# Test/train now have V10.1 as well
```

---

### Migration Ordering Across Environments

**Common Issue:** Environments have different migration histories.

```
Dev:    V1, V2, V3, V4, V5, V6, V7  (latest development)
Test:   V1, V2, V3, V4              (older, stable)
Train:  V1, V2, V3, V4, V5          (promoted from test last week)
Prod:   V1, V2, V3                  (production, most stable)
```

**What happens when promoting?**

```bash
# Promote dev → test (includes V5, V6, V7)
# Test deployment:
# - Flyway sees: Database has V1-V4
# - Flyway runs: V5, V6, V7 in order
# - Result: V1, V2, V3, V4, V5, V6, V7 ✅

# Promote test → train (includes V5, V6, V7)
# Train deployment:
# - Flyway sees: Database has V1-V5
# - Flyway runs: V6, V7 (skips V1-V5, already applied)
# - Result: V1, V2, V3, V4, V5, V6, V7 ✅

# Promote train → prod (includes V5, V6, V7)
# Prod deployment:
# - Flyway sees: Database has V1-V3
# - Flyway runs: V4, V5, V6, V7
# - Result: V1, V2, V3, V4, V5, V6, V7 ✅
```

**Flyway is idempotent:** Safe to deploy same image to all environments.

---

## 5. Best Practices

### 1. **One Logical Change Per Migration**

**❌ Bad:**
```sql
-- V5__Multiple_changes.sql
CREATE TABLE products (...);
CREATE TABLE orders (...);
ALTER TABLE users ADD status NVARCHAR(20);
CREATE INDEX idx_users_email ON users(email);
```

**✅ Good:**
```sql
-- V5__Add_products_table.sql
CREATE TABLE products (...);

-- V6__Add_orders_table.sql
CREATE TABLE orders (...);

-- V7__Add_user_status.sql
ALTER TABLE users ADD status NVARCHAR(20);

-- V8__Add_user_email_index.sql
CREATE INDEX idx_users_email ON users(email);
```

**Why?** Easier to rollback individual changes.

---

### 2. **Include Rollback Instructions in Comments**

```sql
-- V10__Add_payment_gateway_integration.sql
-- Adds payment_transactions table for new payment gateway
-- ROLLBACK: See V11__Rollback_payment_gateway.sql (if needed)

CREATE TABLE payment_transactions (
    id INT IDENTITY(1,1) PRIMARY KEY,
    order_id INT NOT NULL,
    gateway_transaction_id NVARCHAR(100),
    amount DECIMAL(18,2),
    status NVARCHAR(20),
    created_at DATETIME2 DEFAULT GETDATE(),
    FOREIGN KEY (order_id) REFERENCES orders(id)
);
```

---

### 3. **Use Idempotent Scripts**

**❌ Not idempotent:**
```sql
-- V5__Add_index.sql
CREATE INDEX idx_users_email ON users(email);  -- Fails if index exists
```

**✅ Idempotent:**
```sql
-- V5__Add_index.sql
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'idx_users_email')
BEGIN
    CREATE INDEX idx_users_email ON users(email);
END
```

---

### 4. **Version Number Strategy**

**Use semantic-style versioning:**
```
V1.0__Initial_schema.sql
V1.1__Add_user_roles.sql
V1.2__Add_user_indexes.sql
V2.0__Add_products_module.sql       -- Major: New module
V2.1__Add_product_categories.sql
V2.2__Add_product_reviews.sql
V3.0__Add_orders_module.sql         -- Major: New module
```

**Or date-based versioning:**
```
V20250115__Initial_schema.sql       -- YYYYMMDD format
V20250120__Add_user_roles.sql
V20250125__Add_products.sql
```

---

### 5. **Test Migrations in Isolation**

```bash
# Test each migration individually in Docker
docker-compose down -v  # Fresh start
docker-compose up -d
# Flyway runs V1
# Verify schema

# Add V2
docker-compose restart backend
# Flyway runs V2
# Verify changes

# Repeat for each migration
```

---

### 6. **Pre-Production Validation**

```sql
-- V10__Major_schema_change.sql
-- VALIDATION CHECKLIST:
-- [ ] Tested in local Docker
-- [ ] Deployed to dev environment
-- [ ] Ran integration tests
-- [ ] Verified performance impact
-- [ ] Tested rollback script (V11)
-- [ ] Documented in CHANGELOG.md

ALTER TABLE users ADD complex_new_feature NVARCHAR(MAX);
-- ...complex changes...
```

---

### 7. **Baseline Migration for Existing Databases**

If adding Flyway to an **existing database** with schema:

```bash
# Generate baseline
azd env set FLYWAY_BASELINE_VERSION 0
azd env set FLYWAY_BASELINE_DESCRIPTION "Existing schema before Flyway"

# On first deployment:
# Flyway creates flyway_schema_history with version 0
# All migrations with version > 0 will run
```

---

## 6. Common Scenarios

### Scenario A: Adding a New Feature (Happy Path)

```bash
# Feature branch: feature/add-shopping-cart
git checkout -b feature/add-shopping-cart

# Day 1: Create migrations
cat > db/migration/V10__Add_cart_table.sql <<EOF
CREATE TABLE shopping_carts (
    id INT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL,
    created_at DATETIME2 DEFAULT GETDATE(),
    FOREIGN KEY (user_id) REFERENCES users(id)
);
EOF

cat > db/migration/V11__Add_cart_items_table.sql <<EOF
CREATE TABLE cart_items (
    id INT IDENTITY(1,1) PRIMARY KEY,
    cart_id INT NOT NULL,
    product_id INT NOT NULL,
    quantity INT NOT NULL DEFAULT 1,
    FOREIGN KEY (cart_id) REFERENCES shopping_carts(id),
    FOREIGN KEY (product_id) REFERENCES products(id)
);
EOF

# Test locally
docker-compose restart backend

# Commit
git add db/migration/V10*.sql db/migration/V11*.sql
git commit -m "Add shopping cart feature"
git push origin feature/add-shopping-cart

# Merge to main
git checkout main
git merge feature/add-shopping-cart
git push origin main

# GitHub Actions deploys to dev
# Flyway applies V10, V11

# Promote to test, train, prod
# Same migrations apply in each environment
```

---

### Scenario B: Bug Found in Test, Need Hotfix

```bash
# Test has V10, V11 (shopping cart)
# Bug: cart_items missing price snapshot

# Create hotfix migration
git checkout -b hotfix/cart-item-price
cat > db/migration/V12__Add_cart_item_price.sql <<EOF
-- Add price snapshot to cart items (for price history)
ALTER TABLE cart_items ADD price_at_add DECIMAL(18,2) NOT NULL DEFAULT 0.00;
EOF

git add db/migration/V12__Add_cart_item_price.sql
git commit -m "Fix: Add price snapshot to cart items"
git push origin hotfix/cart-item-price

# Merge to main
git checkout main
git merge hotfix/cart-item-price
git push origin main

# Deploy to test
# Flyway applies V12

# Promote to train, prod
# Flyway applies V10, V11, V12 in order
```

---

### Scenario C: Reverting a Feature

```bash
# Production has V10, V11 (shopping cart)
# Business decision: Remove shopping cart feature

# Create revert migration
cat > db/migration/V12__Remove_shopping_cart.sql <<EOF
-- Remove shopping cart feature
-- CAUTION: This drops tables with data!

-- Backup first (optional)
SELECT * INTO cart_items_backup FROM cart_items;
SELECT * INTO shopping_carts_backup FROM shopping_carts;

-- Drop tables
DROP TABLE cart_items;
DROP TABLE shopping_carts;
EOF

git add db/migration/V12__Remove_shopping_cart.sql
git commit -m "Revert: Remove shopping cart feature"
git push origin main

# Deploy to production
# Flyway applies V12
# Shopping cart removed
```

---

### Scenario D: Conflicting Migrations (Multiple Developers)

```bash
# Developer A creates: V10__Add_user_avatar.sql
# Developer B creates: V10__Add_user_bio.sql (same version!)

# Merge conflict! ❌

# Solution: Renumber one migration
git checkout feature/user-bio
mv db/migration/V10__Add_user_bio.sql db/migration/V11__Add_user_bio.sql

git add db/migration/V11__Add_user_bio.sql
git commit --amend -m "Add user bio (V11)"
git push origin feature/user-bio --force

# Now: V10 (avatar), V11 (bio) ✅
```

---

### Scenario E: Data Migration with Schema Change

```sql
-- V15__Normalize_user_address.sql
-- Move address from users table to separate addresses table

-- Step 1: Create new table
CREATE TABLE user_addresses (
    id INT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL,
    street NVARCHAR(200),
    city NVARCHAR(100),
    state NVARCHAR(50),
    zip NVARCHAR(20),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- Step 2: Migrate data
INSERT INTO user_addresses (user_id, street, city, state, zip)
SELECT id, street, city, state, zip 
FROM users 
WHERE street IS NOT NULL;

-- Step 3: Drop old columns (after verifying migration)
-- CAUTION: Uncomment only after data verified in user_addresses
-- ALTER TABLE users DROP COLUMN street;
-- ALTER TABLE users DROP COLUMN city;
-- ALTER TABLE users DROP COLUMN state;
-- ALTER TABLE users DROP COLUMN zip;
```

**Safe approach:** Drop columns in a separate migration (V16) after validation.

---

## 7. Production Deployment Strategies (Multiple vs. Consolidated Migrations)

### The Question: Should Production Execute Multiple Migrations?

**Scenario:**
```
Production:  V1, V2, V3           (stable, older)
Train:       V1, V2, V3, V4       (defect found in V4)
Test:        V1, V2, V3, V4, V5   (latest changes)
Fix:         V6 created           (fixes train defect)
```

**When promoting to Production, Flyway will execute V4, V5, V6 sequentially.**

**Question:** Is it better to have 3 separate migrations or 1 consolidated migration?

---

### Approach 1: Multiple Migrations (Flyway Standard) ✅ RECOMMENDED

**What happens:**
```
Production deployment:
- Deploy image with V1, V2, V3, V4, V5, V6
- Flyway sees: Database has V1, V2, V3
- Flyway executes: V4, V5, V6 in sequence
- Result: V1, V2, V3, V4, V5, V6
```

**Pros:**
- ✅ **Same migrations across all environments** (dev, test, train, prod)
- ✅ **Complete audit trail** - can see when V4 added, when V6 fixed it
- ✅ **Proven safe** - migrations already tested in test/train
- ✅ **Simple** - no special build processes
- ✅ **Image promotion works** - same image deployed everywhere
- ✅ **Flyway best practice** - designed to work this way

**Cons:**
- ❌ **Slightly longer deployment** - 3 migrations instead of 1
- ❌ **Could be slow** if V4, V5 have large data migrations

**When to use:**
- ✅ Migrations are lightweight (< 10 seconds each)
- ✅ V4, V5 already tested and stable
- ✅ No tight deployment time windows
- ✅ Want consistent migration history across environments

**Example:**
```sql
-- Production deployment log:
10:00:00 - Starting deployment
10:00:02 - Flyway: Running V4__Add_preferences.sql (2 seconds)
10:00:04 - Flyway: Running V5__Add_reviews.sql (5 seconds)
10:00:09 - Flyway: Running V6__Fix_preferences.sql (1 second)
10:00:10 - Deployment complete ✅
```

---

### Approach 2: Consolidated Migration (Blue-Green Strategy) ⚠️

**What happens:**
```
Test/Train: V1, V2, V3, V4, V5, V6 (incremental, for testing)
Production: V1, V2, V3, V4_consolidated (single migration with final state)
```

**Implementation:**
```bash
# Create production branch
git checkout -b prod-release-2024-11-02

# Create consolidated migration
cat > db/migration/V4__Production_release_features_and_fixes.sql <<EOF
-- Consolidated production migration
-- Replaces dev/test migrations V4, V5, V6
-- Tested individually in test environments
-- Deployed as single unit to production

-- From V4: Add user preferences
ALTER TABLE users ADD preferences NVARCHAR(MAX);

-- From V5: Add product reviews
CREATE TABLE product_reviews (
    id INT IDENTITY(1,1) PRIMARY KEY,
    product_id INT NOT NULL,
    user_id INT NOT NULL,
    rating INT NOT NULL,
    created_at DATETIME2 DEFAULT GETDATE(),
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- From V6: Fix (already incorporated in consolidated version)
-- No additional fix needed

-- Result: Single migration with final state ✅
EOF

# Build production-specific Docker image
docker build -t raptor/backend:prod-v1.5.0 .

# Deploy to production (blue-green)
# 1. Create "green" environment
# 2. Deploy with consolidated migration
# 3. Test green environment
# 4. Cutover to green
```

**Pros:**
- ✅ **Faster production deployment** - single migration instead of 3
- ✅ **Cleaner production history** - no intermediate states
- ✅ **Good for large data migrations** - consolidate heavy operations

**Cons:**
- ❌ **Environments have different migration files** - V4,V5,V6 in test vs. V4_consolidated in prod
- ❌ **Complex build process** - need prod-specific branch/image
- ❌ **Can't promote images** - test image ≠ prod image
- ❌ **Risk of drift** - prod migration not exactly what was tested
- ❌ **Checksum mismatches** if same version number used

**When to use:**
- ⚠️ V4, V5, V6 have large data migrations (30+ minutes each)
- ⚠️ Very short deployment window (< 5 minutes)
- ⚠️ Blue-green infrastructure already exists
- ⚠️ Team can manage environment-specific migration files

**⚠️ WARNING:** This breaks the "test what you deploy" principle. Use with caution.

---

### Approach 3: Hybrid - Squash in Dev, Promote to Prod ✅ ACCEPTABLE

**What happens:**
```
Feature branch: V10, V11, V12 (development iterations)
Main branch: V10_squashed (consolidated before merge)
All environments: V10_squashed (same migration everywhere)
```

**Implementation:**
```bash
# Feature branch development
git checkout -b feature/shopping-cart

# Create iterations
cat > db/migration/V10__Add_cart_table.sql
cat > db/migration/V11__Add_cart_items.sql
cat > db/migration/V12__Fix_cart_foreign_keys.sql

# Test locally with all 3 migrations
docker-compose restart backend

# Before merging to main, consolidate
docker-compose down -v  # Reset database

# Create consolidated migration
cat > db/migration/V10__Add_shopping_cart_feature.sql <<EOF
-- Consolidated shopping cart feature
-- Replaces V10, V11, V12 from development

CREATE TABLE shopping_carts (
    id INT IDENTITY(1,1) PRIMARY KEY,
    user_id INT NOT NULL,
    created_at DATETIME2 DEFAULT GETDATE(),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE cart_items (
    id INT IDENTITY(1,1) PRIMARY KEY,
    cart_id INT NOT NULL,
    product_id INT NOT NULL,
    quantity INT DEFAULT 1,
    FOREIGN KEY (cart_id) REFERENCES shopping_carts(id),
    FOREIGN KEY (product_id) REFERENCES products(id)
);
EOF

# Remove old iterations
rm db/migration/V11__Add_cart_items.sql
rm db/migration/V12__Fix_cart_foreign_keys.sql

# Test consolidated version
docker-compose restart backend

# Merge to main
git add db/migration/V10__Add_shopping_cart_feature.sql
git commit -m "Add shopping cart feature"
git push origin feature/shopping-cart

# Deploy to all environments with same V10 migration
```

**Pros:**
- ✅ **Clean migration history** everywhere
- ✅ **Same migrations in all environments**
- ✅ **Image promotion works**
- ✅ **Fast deployment** - single migration

**Cons:**
- ❌ **Loses development iteration history**
- ❌ **Only works for new features** (not already deployed to shared environments)
- ❌ **Requires discipline** - must squash before deploying to dev

**When to use:**
- ✅ Feature still in development (not deployed to shared dev/test)
- ✅ Many small iterations during development
- ✅ Want clean history in all environments
- ✅ Feature complete and ready to ship

---

### Decision Matrix

| Scenario | Recommended Approach |
|----------|---------------------|
| V4, V5, V6 are small, fast migrations (< 30 seconds total) | **Multiple Migrations** ✅ |
| V4, V5, V6 already deployed to test/train | **Multiple Migrations** ✅ |
| Want same migrations across all environments | **Multiple Migrations** ✅ |
| V4, V5, V6 have large data migrations (30+ minutes) | **Consolidated Migration** ⚠️ |
| Tight production deployment window | **Consolidated Migration** ⚠️ |
| Feature still in development (not deployed anywhere) | **Squash Before Deploy** ✅ |
| Blue-green infrastructure already exists | **Consolidated Migration** ⚠️ |

---

### Best Practice Recommendation

**For 90% of cases:** Use **Approach 1 (Multiple Migrations)**

**Reasons:**
1. Simplicity - same migrations everywhere
2. Consistency - test what you deploy
3. Audit trail - complete history
4. Flyway design - works as intended
5. Low risk - proven in test/train

**Optimize by:**
- Keeping migrations lightweight (schema only, no large data migrations)
- Running data migrations separately (scheduled jobs)
- Using deployment slots for zero-downtime
- Monitoring migration execution time

**Only use consolidated migrations when:**
- Performance is critical (deployment window < 5 minutes)
- Data migrations are unavoidable and slow
- Blue-green infrastructure justifies the complexity

---

## Summary

### Key Takeaways

| Topic | Best Practice |
|-------|--------------|
| **Development** | Create incremental migrations (V5, V6, V7), optionally squash before merging |
| **Rollbacks** | Use forward-only compensating migrations (V11 reverts V10) |
| **Environment Promotion** | Same Docker image → Different databases → Flyway applies missing migrations |
| **Production Deployment** | Accept multiple migrations (V4, V5, V6) for consistency; consolidate only for performance |
| **Bug Fixes** | Create new migration (V12) to fix issues introduced by previous migrations |
| **Version Numbers** | Use semantic (V1.0, V1.1) or date-based (V20250115) versioning |
| **Testing** | Test each migration in isolation in Docker before deploying |
| **Naming** | `V{VERSION}__{DESCRIPTION}.sql` - Never change after deployment |
| **Idempotency** | Use `IF NOT EXISTS` checks for safe re-execution |

### Flyway Commands Reference

```bash
# In Spring Boot application.properties
spring.flyway.enabled=true                          # Enable Flyway
spring.flyway.locations=classpath:db/migration      # Migration scripts location
spring.flyway.baseline-on-migrate=true              # Baseline existing DB
spring.flyway.validate-on-migrate=true              # Validate checksums
spring.flyway.clean-disabled=true                   # Disable clean (safety)

# Docker Compose (local dev)
docker-compose restart backend                      # Run pending migrations
docker-compose logs backend | grep Flyway           # Check migration logs

# Check migration status (manual)
sqlcmd -S localhost -U sa -P password -d raptordb -Q \
  "SELECT * FROM flyway_schema_history ORDER BY installed_rank"
```

---

## Additional Resources

- **Flyway Documentation:** https://flywaydb.org/documentation/
- **Migration Best Practices:** https://flywaydb.org/documentation/concepts/migrations
- **Community vs Teams:** https://flywaydb.org/download/
- **SQL Server Compatibility:** https://flywaydb.org/documentation/database/sqlserver

---

Happy Migrating! 🚀
