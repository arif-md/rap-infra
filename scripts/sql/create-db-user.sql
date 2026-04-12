PRINT 'Granting permissions to: $(UserName)';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(UserName)')
    CREATE USER [$(UserName)] WITH SID = $(UserSid), TYPE = E;

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(UserName)' AND SID <> $(UserSid))
BEGIN
    PRINT 'SID mismatch - recreating user with correct SID';
    DROP USER [$(UserName)];
    CREATE USER [$(UserName)] WITH SID = $(UserSid), TYPE = E;
END

-- ROLE_GRANTS_PLACEHOLDER

PRINT 'Done: $(UserName)';
