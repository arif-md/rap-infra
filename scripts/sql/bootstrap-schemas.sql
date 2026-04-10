-- =============================================================================
-- Bootstrap SQL: Schemas, Base Tables, Views & Seed Data
-- =============================================================================
-- Runs via Bicep deployment script BEFORE any container starts.
-- Must be fully idempotent (safe to re-run on every deployment).
--
-- This script creates the foundational database objects that both the
-- backend (RAP schema) and processes (JBPM schema) containers depend on.
-- Flyway migrations in each service handle incremental, service-specific
-- schema evolution on top of this baseline.
--
-- Table definitions here MUST match the Flyway migrations exactly:
--   - RAP tables  match  backend V4__Create_auth_tables.sql
--   - JBPM tables match  processes V12__Create_JBPM_User_tables.sql
--
-- Execution order (guaranteed by Bicep dependsOn):
--   1. SQL Server + Database created
--   2. SQL role assignments (managed identity users + roles)
--   3. THIS SCRIPT (schema bootstrap)
--   4. Container Apps start (Flyway runs incremental migrations)
-- =============================================================================

-- ============================================================================
-- 1. Create Schemas
-- ============================================================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'RAP')
BEGIN
    EXEC('CREATE SCHEMA RAP');
    PRINT 'Created schema: RAP';
END
ELSE
    PRINT 'Schema RAP already exists';
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'JBPM')
BEGIN
    EXEC('CREATE SCHEMA JBPM');
    PRINT 'Created schema: JBPM';
END
ELSE
    PRINT 'Schema JBPM already exists';
GO

-- ============================================================================
-- 2. Base Tables — RAP Schema
--    (definitions match backend V4__Create_auth_tables.sql exactly)
-- ============================================================================

-- RAP.USER_INFO — Authenticated users from OIDC provider
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'RAP' AND t.name = 'USER_INFO')
BEGIN
    CREATE TABLE RAP.USER_INFO (
        id BIGINT IDENTITY PRIMARY KEY,
        oidc_subject NVARCHAR(255) NOT NULL UNIQUE,
        email NVARCHAR(255) NOT NULL UNIQUE,
        first_name NVARCHAR(255) NULL,
        last_name NVARCHAR(255) NULL,
        full_name NVARCHAR(255),
        lang NVARCHAR(255) NULL,
        pwd NVARCHAR(255) NULL,
        is_active BIT NOT NULL DEFAULT 1,
        created_at DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        updated_at DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        last_login_at DATETIME2,
        INDEX IX_user_info_email (email),
        INDEX IX_user_info_oidc_subject (oidc_subject),
        INDEX IX_user_info_is_active (is_active)
    );
    PRINT 'Created table: RAP.USER_INFO';
END
ELSE
    PRINT 'Table RAP.USER_INFO already exists';
GO

-- RAP.ROLE_REF — Application roles for authorization
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'RAP' AND t.name = 'ROLE_REF')
BEGIN
    CREATE TABLE RAP.ROLE_REF (
        id BIGINT IDENTITY PRIMARY KEY,
        role_name NVARCHAR(50) NOT NULL UNIQUE,
        description NVARCHAR(255),
        created_at DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        INDEX IX_roles_role_name (role_name)
    );
    PRINT 'Created table: RAP.ROLE_REF';
END
ELSE
    PRINT 'Table RAP.ROLE_REF already exists';
GO

-- RAP.USER_ROLE — Many-to-many user-role mapping
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'RAP' AND t.name = 'USER_ROLE')
BEGIN
    CREATE TABLE RAP.USER_ROLE (
        id BIGINT IDENTITY(1,1) PRIMARY KEY,
        user_id BIGINT NOT NULL,
        role_id BIGINT NOT NULL,
        granted_at DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        granted_by NVARCHAR(255),
        CONSTRAINT FK_user_roles_user FOREIGN KEY (user_id)
            REFERENCES RAP.USER_INFO(id) ON DELETE CASCADE,
        CONSTRAINT FK_user_roles_role FOREIGN KEY (role_id)
            REFERENCES RAP.ROLE_REF(id) ON DELETE CASCADE,
        CONSTRAINT UQ_user_role UNIQUE (user_id, role_id),
        INDEX IX_user_roles_user_id (user_id),
        INDEX IX_user_roles_role_id (role_id)
    );
    PRINT 'Created table: RAP.USER_ROLE';
END
ELSE
    PRINT 'Table RAP.USER_ROLE already exists';
GO

-- RAP.refresh_tokens — JWT refresh token storage
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'RAP' AND t.name = 'refresh_tokens')
BEGIN
    CREATE TABLE RAP.refresh_tokens (
        id BIGINT IDENTITY(1,1) PRIMARY KEY,
        token_hash NVARCHAR(255) NOT NULL UNIQUE,
        user_id BIGINT NOT NULL,
        issued_at DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        expires_at DATETIME2 NOT NULL,
        last_used_at DATETIME2,
        ip_address NVARCHAR(45),
        user_agent NVARCHAR(500),
        is_revoked BIT NOT NULL DEFAULT 0,
        revoked_at DATETIME2,
        revoked_reason NVARCHAR(255),
        CONSTRAINT FK_refresh_tokens_user FOREIGN KEY (user_id)
            REFERENCES RAP.USER_INFO(id) ON DELETE CASCADE,
        INDEX IX_refresh_tokens_token_hash (token_hash),
        INDEX IX_refresh_tokens_user_id (user_id),
        INDEX IX_refresh_tokens_expires_at (expires_at)
    );
    PRINT 'Created table: RAP.refresh_tokens';
END
ELSE
    PRINT 'Table RAP.refresh_tokens already exists';
GO

-- RAP.revoked_tokens — Revoked JWT tracking for immediate invalidation
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'RAP' AND t.name = 'revoked_tokens')
BEGIN
    CREATE TABLE RAP.revoked_tokens (
        id BIGINT IDENTITY(1,1) PRIMARY KEY,
        jti NVARCHAR(255) NOT NULL UNIQUE,
        user_id BIGINT NOT NULL,
        revoked_at DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        expires_at DATETIME2 NOT NULL,
        reason NVARCHAR(255),
        revoked_by NVARCHAR(255),
        CONSTRAINT FK_revoked_tokens_user FOREIGN KEY (user_id)
            REFERENCES RAP.USER_INFO(id) ON DELETE CASCADE,
        INDEX IX_revoked_tokens_jti (jti),
        INDEX IX_revoked_tokens_user_id (user_id),
        INDEX IX_revoked_tokens_expires_at (expires_at)
    );
    PRINT 'Created table: RAP.revoked_tokens';
END
ELSE
    PRINT 'Table RAP.revoked_tokens already exists';
GO

-- ============================================================================
-- 3. Base Tables — JBPM Schema
--    (definitions match processes V12__Create_JBPM_User_tables.sql exactly)
-- ============================================================================

-- JBPM.ROLE_REF — Roles for jBPM user/group resolution
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'JBPM' AND t.name = 'ROLE_REF')
BEGIN
    CREATE TABLE JBPM.ROLE_REF (
        id int identity not null,
        role_code varchar(255) null,
        primary key (id)
    );
    PRINT 'Created table: JBPM.ROLE_REF';
END
ELSE
    PRINT 'Table JBPM.ROLE_REF already exists';
GO

-- JBPM.USER_INFO — jBPM user identities
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'JBPM' AND t.name = 'USER_INFO')
BEGIN
    CREATE TABLE JBPM.USER_INFO (
        id int identity not null,
        first_name varchar(255) null,
        last_name varchar(255) null,
        email varchar(255) not null,
        lang varchar(255) null,
        pwd varchar(255) null,
        primary key (id)
    );
    PRINT 'Created table: JBPM.USER_INFO';
END
ELSE
    PRINT 'Table JBPM.USER_INFO already exists';
GO

-- JBPM.USER_GROUP — jBPM user-to-group mapping
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'JBPM' AND t.name = 'USER_GROUP')
BEGIN
    CREATE TABLE JBPM.USER_GROUP (
        user_id int not null,
        group_id varchar(255) null,
        role_id int not null
    );

    ALTER TABLE JBPM.USER_GROUP WITH CHECK ADD CONSTRAINT FK_USER_GROUP_USER_ID
        FOREIGN KEY (user_id) REFERENCES JBPM.USER_INFO (id);

    ALTER TABLE JBPM.USER_GROUP WITH CHECK ADD CONSTRAINT FK_USER_GROUP_ROLE_ID
        FOREIGN KEY (role_id) REFERENCES JBPM.ROLE_REF (id);

    PRINT 'Created table: JBPM.USER_GROUP';
END
ELSE
    PRINT 'Table JBPM.USER_GROUP already exists';
GO

-- JBPM.USER_ROLE — jBPM user-to-role mapping
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = 'JBPM' AND t.name = 'USER_ROLE')
BEGIN
    CREATE TABLE JBPM.USER_ROLE (
        user_id int not null,
        role_id int not null
    );

    ALTER TABLE JBPM.USER_ROLE WITH CHECK ADD CONSTRAINT FK_USER_ROLE_USER_ID
        FOREIGN KEY (user_id) REFERENCES JBPM.USER_INFO (id);

    ALTER TABLE JBPM.USER_ROLE WITH CHECK ADD CONSTRAINT FK_USER_ROLE_ROLE_ID
        FOREIGN KEY (role_id) REFERENCES JBPM.ROLE_REF (id);

    PRINT 'Created table: JBPM.USER_ROLE';
END
ELSE
    PRINT 'Table JBPM.USER_ROLE already exists';
GO

-- ============================================================================
-- 4. Base Views
-- ============================================================================

-- RAP.vw_user_roles — Flattened user-role view for quick lookups
IF OBJECT_ID('RAP.vw_user_roles', 'V') IS NOT NULL
    DROP VIEW RAP.vw_user_roles;
GO
CREATE VIEW RAP.vw_user_roles AS
SELECT u.id AS user_id, u.email, u.first_name, u.last_name, u.oidc_subject,
       r.id AS role_id, r.role_name
FROM RAP.USER_INFO u
    JOIN RAP.USER_ROLE ur ON u.id = ur.user_id
    JOIN RAP.ROLE_REF r ON ur.role_id = r.id;
GO
PRINT 'Created/replaced view: RAP.vw_user_roles';
GO

-- JBPM.vw_user_roles — Flattened jBPM user-role view
IF OBJECT_ID('JBPM.vw_user_roles', 'V') IS NOT NULL
    DROP VIEW JBPM.vw_user_roles;
GO
CREATE VIEW JBPM.vw_user_roles AS
SELECT u.id AS user_id, u.email, u.first_name, u.last_name,
       r.id AS role_id, r.role_code
FROM JBPM.USER_INFO u
    JOIN JBPM.USER_ROLE ur ON u.id = ur.user_id
    JOIN JBPM.ROLE_REF r ON ur.role_id = r.id;
GO
PRINT 'Created/replaced view: JBPM.vw_user_roles';
GO

-- ============================================================================
-- 5. Seed Data — Reference/Lookup Data
-- ============================================================================

-- RAP roles (matches V4 + V8 seed data)
IF NOT EXISTS (SELECT 1 FROM RAP.ROLE_REF WHERE role_name = 'USER')
    INSERT INTO RAP.ROLE_REF (role_name, description) VALUES ('USER', 'Internal user with read access');
IF NOT EXISTS (SELECT 1 FROM RAP.ROLE_REF WHERE role_name = 'EXTERNAL_USER')
    INSERT INTO RAP.ROLE_REF (role_name, description) VALUES ('EXTERNAL_USER', 'External user with read access');
IF NOT EXISTS (SELECT 1 FROM RAP.ROLE_REF WHERE role_name = 'MANAGER')
    INSERT INTO RAP.ROLE_REF (role_name, description) VALUES ('MANAGER', 'Manager with read/write access to managed entities');
IF NOT EXISTS (SELECT 1 FROM RAP.ROLE_REF WHERE role_name = 'ADMIN')
    INSERT INTO RAP.ROLE_REF (role_name, description) VALUES ('ADMIN', 'System administrator with full access');
IF NOT EXISTS (SELECT 1 FROM RAP.ROLE_REF WHERE role_name = 'INTERNAL_USER')
    INSERT INTO RAP.ROLE_REF (role_name, description) VALUES ('INTERNAL_USER', 'Internal user with access to internal dashboard and university-scoped data');
PRINT 'Seeded RAP.ROLE_REF';
GO

-- JBPM roles (matches V12 seed data)
IF NOT EXISTS (SELECT 1 FROM JBPM.ROLE_REF WHERE role_code = 'kie-server')
    INSERT INTO JBPM.ROLE_REF (role_code) VALUES ('kie-server');
IF NOT EXISTS (SELECT 1 FROM JBPM.ROLE_REF WHERE role_code = 'admin')
    INSERT INTO JBPM.ROLE_REF (role_code) VALUES ('admin');
IF NOT EXISTS (SELECT 1 FROM JBPM.ROLE_REF WHERE role_code = 'user')
    INSERT INTO JBPM.ROLE_REF (role_code) VALUES ('user');
PRINT 'Seeded JBPM.ROLE_REF';
GO

-- Default JBPM service user (kieserver) — matches V12 seed data
IF NOT EXISTS (SELECT 1 FROM JBPM.USER_INFO WHERE email = 'kieserver')
BEGIN
    INSERT INTO JBPM.USER_INFO (email, pwd, lang) VALUES ('kieserver', 'kieserver123', 'en-UK');

    DECLARE @kieUserId INT = SCOPE_IDENTITY();

    INSERT INTO JBPM.USER_ROLE (user_id, role_id)
    SELECT @kieUserId, r.id FROM JBPM.ROLE_REF r WHERE r.role_code = 'kie-server';

    INSERT INTO JBPM.USER_ROLE (user_id, role_id)
    SELECT @kieUserId, r.id FROM JBPM.ROLE_REF r WHERE r.role_code = 'admin';

    INSERT INTO JBPM.USER_ROLE (user_id, role_id)
    SELECT @kieUserId, r.id FROM JBPM.ROLE_REF r WHERE r.role_code = 'user';

    INSERT INTO JBPM.USER_GROUP (user_id, group_id, role_id)
    SELECT @kieUserId, 'Administrators', r.id FROM JBPM.ROLE_REF r WHERE r.role_code = 'admin';

    PRINT 'Seeded JBPM kieserver user with roles and groups';
END
ELSE
    PRINT 'JBPM kieserver user already exists';
GO

-- ===================================================================
-- 7. SEED DATA - Test User (for local development only)
-- ===================================================================
IF NOT EXISTS (SELECT 1 FROM RAP.USER_INFO WHERE oidc_subject = 'system|system-user')
BEGIN
    DECLARE @testUserId BIGINT;
    DECLARE @userRoleId BIGINT;

    INSERT INTO RAP.USER_INFO (oidc_subject, email, full_name, is_active)
    VALUES ('system|system-user', 'system@nexgeninc.com', 'System User', 1);
    SET @testUserId = SCOPE_IDENTITY();

    SELECT @userRoleId = id FROM RAP.ROLE_REF WHERE role_name = 'ADMIN';
    INSERT INTO RAP.USER_ROLE (user_id, role_id, granted_by)
    VALUES (@testUserId, @userRoleId, 'SYSTEM_SEED');
    PRINT 'Seeded test user: system@nexgeninc.com';
END
ELSE
    PRINT 'Test user already exists';

-- ============================================================================
-- 6. Set Default Schemas for Managed Identities
-- ============================================================================
-- Set default schemas so unqualified table references resolve correctly.
-- Backend identity -> RAP schema; Processes identity -> JBPM schema.
-- Identity names are injected as SQL variables by the PowerShell wrapper.
-- ============================================================================

IF '$(BackendIdentityName)' <> '' AND EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(BackendIdentityName)')
BEGIN
    EXEC('ALTER USER [$(BackendIdentityName)] WITH DEFAULT_SCHEMA = RAP');
    PRINT 'Set default schema RAP for $(BackendIdentityName)';
END
GO

IF '$(ProcessesIdentityName)' <> '' AND EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(ProcessesIdentityName)')
BEGIN
    EXEC('ALTER USER [$(ProcessesIdentityName)] WITH DEFAULT_SCHEMA = JBPM');
    PRINT 'Set default schema JBPM for $(ProcessesIdentityName)';
END
GO

PRINT '=== Schema bootstrap completed successfully ===';
GO
