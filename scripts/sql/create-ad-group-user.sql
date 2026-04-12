PRINT 'Granting db_owner to AD group: $(GroupName)';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(GroupName)')
    CREATE USER [$(GroupName)] WITH SID = $(GroupSid), TYPE = X;

IF IS_ROLEMEMBER('db_owner', '$(GroupName)') = 0
    ALTER ROLE db_owner ADD MEMBER [$(GroupName)];

PRINT 'Done: $(GroupName)';
