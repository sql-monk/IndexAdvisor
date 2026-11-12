/*
	Setup-IndexAdvisorLogin.sql — штатний обліковий запис IndexAdvisor (CONTRACTS.md, розділ 10). Ідемпотентний.
	Окремий інструмент DBA: запускається явно в базі master; сама програма IndexAdvisor цей скрипт не виконує.

	Права лише через ролі:
		- серверна роль [srv_index_advisor]: VIEW SERVER STATE, VIEW ANY DEFINITION; логін — член ролі;
		- у кожній базі: користувач з іменем логіна і роль [db_index_advisor]: VIEW DATABASE STATE, VIEW DEFINITION.
	Жодних прав безпосередньо логіну чи користувачу, жодного членства в db_datareader, db_owner, sysadmin тощо,
	без SELECT на користувацькі таблиці. SQL-логін створюється з CHECK_POLICY = ON.

	sqlcmd-змінні (усі обов'язкові; для невикористаних передайте порожній рядок):
		Mode          Install | AddDatabase | Remove | Verify
		LoginName     ім'я логіна (за замовчуванням у програмі index-advisor; Windows — DOMAIN\user)
		LoginType     Sql | Windows
		LoginPassword пароль SQL-логіна (лише Install); обгортка Install-IaServiceLogin генерує його, зберігає в SecretManagement
		              і передає параметром запиту, тому пароль не потрапляє в текст скрипта
		Databases     бази через кому або ALL (усі користувацькі бази ONLINE); порожньо — ALL

	Приклади:
		sqlcmd -S SQL01 -d master -E -b -i Setup-IndexAdvisorLogin.sql `
			-v Mode="Verify" LoginName="index-advisor" LoginType="Sql" LoginPassword="" Databases="ALL"
		Install-IaServiceLogin -SqlInstance SQL01, SQL02 -Mode Install
	Для SQLCMD-режиму SSMS додайте на початку рядки на кшталт:  :setvar Mode "Verify"
	sqlcmd підставляє значення змінних як текст, тому апостроф у значенні подвоюйте (Databases="Owner''s DB");
	обгортка Install-IaServiceLogin робить це сама.

	Verify виконує лише SELECT: показує фактичні членства й права логіна та попереджає про зайві
	(sysadmin, db_owner, db_datareader, db_datawriter, права на зміну даних, права безпосередньо логіну чи користувачу).
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @mode NVARCHAR(20) = N'$(Mode)';
DECLARE @loginName NVARCHAR(128) = N'$(LoginName)';
DECLARE @loginType NVARCHAR(20) = N'$(LoginType)';
DECLARE @loginPassword NVARCHAR(128) = N'$(LoginPassword)';
DECLARE @databases NVARCHAR(MAX) = N'$(Databases)';
DECLARE @sql NVARCHAR(MAX);
DECLARE @dbSql NVARCHAR(MAX);
DECLARE @dbTemplate NVARCHAR(MAX);
DECLARE @serverPart NVARCHAR(MAX);
DECLARE @procedureName NVARCHAR(400);
DECLARE @databaseName SYSNAME;
DECLARE @message NVARCHAR(2048);
DECLARE @failedCount INT = 0;
-- Роздільник STRING_AGG може бути лише літералом або змінною (Msg 8733), тому винесено в змінну.
DECLARE @unionSeparator NVARCHAR(20) = CONCAT(NCHAR(13), NCHAR(10), N'UNION ALL', NCHAR(13), NCHAR(10));

SET @mode = TRIM(@mode);
SET @loginName = TRIM(@loginName);
SET @loginType = TRIM(@loginType);
SET @databases = TRIM(ISNULL(@databases, N''));
IF @databases = N''
	SET @databases = N'ALL';

-- Перевірка параметрів до будь-яких змін.
IF DB_NAME() <> N'master'
	THROW 50001, N'Скрипт виконується в базі master (sqlcmd -d master).', 1;
IF @mode NOT IN (N'Install', N'AddDatabase', N'Remove', N'Verify')
	THROW 50002, N'Mode має бути Install, AddDatabase, Remove або Verify.', 1;
IF @loginType NOT IN (N'Sql', N'Windows')
	THROW 50003, N'LoginType має бути Sql або Windows.', 1;
IF @loginName = N''
	THROW 50004, N'Не задано LoginName.', 1;
IF @loginType = N'Windows' AND CHARINDEX(N'\', @loginName) = 0
	THROW 50005, N'Для Windows-логіна LoginName має бути у форматі DOMAIN\user.', 1;
IF @mode = N'Install' AND @loginType = N'Sql' AND LEN(ISNULL(@loginPassword, N'')) = 0
	THROW 50006, N'Для SQL-логіна в режимі Install потрібен LoginPassword (рекомендовано запуск через Install-IaServiceLogin).', 1;
IF @mode = N'AddDatabase' AND SUSER_ID(@loginName) IS NULL
	THROW 50007, N'Логін не існує: спершу виконайте Mode = Install.', 1;

-- Явно перелічені бази, яких немає, які не ONLINE або недоступні.
IF UPPER(@databases) <> N'ALL'
BEGIN
	SELECT @message = STRING_AGG(CONVERT(NVARCHAR(MAX), TRIM(s.value)), N', ')
	FROM STRING_SPLIT(@databases, N',') AS s
	WHERE TRIM(s.value) <> N''
		AND NOT EXISTS (
			SELECT 1
			FROM sys.databases AS d
			WHERE d.name = TRIM(s.value)
				AND d.database_id > 4
				AND d.state = 0
				AND HAS_DBACCESS(d.name) = 1
		);
	IF @message IS NOT NULL
		RAISERROR(N'Пропущено бази (не знайдено, системні, не ONLINE або недоступні): %s', 10, 1, @message) WITH NOWAIT;
	SET @message = NULL;
END;

IF @mode = N'Install'
BEGIN
	-- Серверна роль із правами лише на читання стану й метаданих.
	IF SUSER_ID(N'srv_index_advisor') IS NULL
		CREATE SERVER ROLE [srv_index_advisor];
	GRANT VIEW SERVER STATE TO [srv_index_advisor];
	GRANT VIEW ANY DEFINITION TO [srv_index_advisor];

	IF SUSER_ID(@loginName) IS NULL
	BEGIN
		IF @loginType = N'Sql'
			SET @sql = CONCAT(N'CREATE LOGIN ', QUOTENAME(@loginName), N' WITH PASSWORD = N''', REPLACE(@loginPassword, N'''', N''''''),
				N''', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = [master];');
		ELSE
			SET @sql = CONCAT(N'CREATE LOGIN ', QUOTENAME(@loginName), N' FROM WINDOWS WITH DEFAULT_DATABASE = [master];');
		EXEC sys.sp_executesql @sql;
		RAISERROR(N'Створено логін %s.', 0, 1, @loginName) WITH NOWAIT;
	END
	ELSE IF @loginType = N'Sql'
	BEGIN
		-- Логін уже існує: пароль синхронізується зі сховищем секретів, політика складності залишається ввімкненою.
		SET @sql = CONCAT(N'ALTER LOGIN ', QUOTENAME(@loginName), N' WITH PASSWORD = N''', REPLACE(@loginPassword, N'''', N''''''), N''', CHECK_POLICY = ON;');
		EXEC sys.sp_executesql @sql;
		RAISERROR(N'Логін %s існує: пароль синхронізовано, CHECK_POLICY = ON.', 0, 1, @loginName) WITH NOWAIT;
	END;
	SET @sql = NULL;

	IF NOT EXISTS (
		SELECT 1
		FROM sys.server_role_members AS rm
		WHERE rm.role_principal_id = SUSER_ID(N'srv_index_advisor')
			AND rm.member_principal_id = SUSER_ID(@loginName)
	)
	BEGIN
		SET @sql = CONCAT(N'ALTER SERVER ROLE [srv_index_advisor] ADD MEMBER ', QUOTENAME(@loginName), N';');
		EXEC sys.sp_executesql @sql;
	END;
END;

IF @mode IN (N'Install', N'AddDatabase', N'Remove')
BEGIN
	IF @mode = N'Remove'
		SET @dbTemplate = CONCAT(
			N'IF USER_ID(@loginName) IS NOT NULL AND USER_ID(N''db_index_advisor'') IS NOT NULL', NCHAR(13), NCHAR(10),
			N'	AND EXISTS (SELECT 1 FROM sys.database_role_members AS rm WHERE rm.role_principal_id = USER_ID(N''db_index_advisor'')',
			N' AND rm.member_principal_id = USER_ID(@loginName))', NCHAR(13), NCHAR(10),
			N'	ALTER ROLE [db_index_advisor] DROP MEMBER ', QUOTENAME(@loginName), N';', NCHAR(13), NCHAR(10),
			N'IF USER_ID(@loginName) IS NOT NULL', NCHAR(13), NCHAR(10),
			N'	DROP USER ', QUOTENAME(@loginName), N';', NCHAR(13), NCHAR(10),
			N'IF USER_ID(N''db_index_advisor'') IS NOT NULL', NCHAR(13), NCHAR(10),
			N'	AND NOT EXISTS (SELECT 1 FROM sys.database_role_members AS rm',
			N' WHERE rm.role_principal_id = USER_ID(N''db_index_advisor''))', NCHAR(13), NCHAR(10),
			N'	DROP ROLE [db_index_advisor];');
	ELSE
		SET @dbTemplate = CONCAT(
			N'IF USER_ID(@loginName) IS NULL', NCHAR(13), NCHAR(10),
			N'	CREATE USER ', QUOTENAME(@loginName), N' FOR LOGIN ', QUOTENAME(@loginName), N';', NCHAR(13), NCHAR(10),
			N'IF USER_ID(''db_index_advisor'') IS NULL CREATE ROLE [db_index_advisor];', NCHAR(13), NCHAR(10),
			N'GRANT VIEW DATABASE STATE TO [db_index_advisor];', NCHAR(13), NCHAR(10),
			N'GRANT VIEW DEFINITION TO [db_index_advisor];', NCHAR(13), NCHAR(10),
			N'IF NOT EXISTS (SELECT 1 FROM sys.database_role_members AS rm WHERE rm.role_principal_id = USER_ID(N''db_index_advisor'')',
			N' AND rm.member_principal_id = USER_ID(@loginName))', NCHAR(13), NCHAR(10),
			N'	ALTER ROLE [db_index_advisor] ADD MEMBER ', QUOTENAME(@loginName), N';');

	DECLARE databaseCursor CURSOR LOCAL FAST_FORWARD FOR
		SELECT d.name
		FROM sys.databases AS d
		WHERE d.database_id > 4
			AND d.state = 0
			AND d.is_distributor = 0
			AND HAS_DBACCESS(d.name) = 1
			AND (
				UPPER(@databases) = N'ALL'
				OR d.name IN (SELECT TRIM(s.value) FROM STRING_SPLIT(@databases, N',') AS s)
			)
		ORDER BY d.name;
	OPEN databaseCursor;
	FETCH NEXT FROM databaseCursor INTO @databaseName;
	WHILE @@FETCH_STATUS = 0
	BEGIN
		IF CONVERT(NVARCHAR(128), DATABASEPROPERTYEX(@databaseName, 'Updateability')) <> N'READ_WRITE'
		BEGIN
			RAISERROR(N'База %s лише для читання (наприклад, вторинна репліка AG): пропущено; користувачі реплікуються з primary.',
				10, 1, @databaseName) WITH NOWAIT;
		END
		ELSE
		BEGIN
			BEGIN TRY
				SET @procedureName = CONCAT(QUOTENAME(@databaseName), N'.sys.sp_executesql');
				EXEC @procedureName @dbTemplate, N'@loginName NVARCHAR(128)', @loginName = @loginName;
				RAISERROR(N'База %s: виконано (%s).', 0, 1, @databaseName, @mode) WITH NOWAIT;
			END TRY
			BEGIN CATCH
				SET @failedCount += 1;
				SET @message = CONCAT(N'Помилка ', ERROR_NUMBER(), N': ', ERROR_MESSAGE());
				RAISERROR(N'База %s: %s', 10, 1, @databaseName, @message) WITH NOWAIT;
			END CATCH;
		END;
		FETCH NEXT FROM databaseCursor INTO @databaseName;
	END;
	CLOSE databaseCursor;
	DEALLOCATE databaseCursor;
END;

IF @mode = N'Remove'
BEGIN
	BEGIN TRY
		IF SUSER_ID(@loginName) IS NOT NULL
		BEGIN
			IF EXISTS (
				SELECT 1
				FROM sys.server_role_members AS rm
				WHERE rm.role_principal_id = SUSER_ID(N'srv_index_advisor')
					AND rm.member_principal_id = SUSER_ID(@loginName)
			)
			BEGIN
				SET @sql = CONCAT(N'ALTER SERVER ROLE [srv_index_advisor] DROP MEMBER ', QUOTENAME(@loginName), N';');
				EXEC sys.sp_executesql @sql;
			END;
			SET @sql = CONCAT(N'DROP LOGIN ', QUOTENAME(@loginName), N';');
			EXEC sys.sp_executesql @sql;
			RAISERROR(N'Видалено логін %s.', 0, 1, @loginName) WITH NOWAIT;
		END;
		IF SUSER_ID(N'srv_index_advisor') IS NOT NULL
			AND NOT EXISTS (SELECT 1 FROM sys.server_role_members AS rm WHERE rm.role_principal_id = SUSER_ID(N'srv_index_advisor'))
			DROP SERVER ROLE [srv_index_advisor];
	END TRY
	BEGIN CATCH
		SET @failedCount += 1;
		SET @message = CONCAT(N'Помилка ', ERROR_NUMBER(), N': ', ERROR_MESSAGE());
		RAISERROR(N'Сервер: %s', 10, 1, @message) WITH NOWAIT;
	END CATCH;
END;

IF @mode = N'Verify'
BEGIN
	-- [Verify:begin] Лише SELECT: фактичні членства й права логіна; IsExcessive = 1 і Warning — зайві або відсутні права.
	SET @serverPart = CONVERT(NVARCHAR(MAX), N'
SELECT CONVERT(NVARCHAR(256), @@SERVERNAME) AS ServerName, CONVERT(NVARCHAR(128), NULL) AS DatabaseName, CONVERT(NVARCHAR(128), @loginName) AS PrincipalName,
	CONVERT(NVARCHAR(60), N''Login'') AS Kind, CONVERT(NVARCHAR(400), ISNULL(sp.type_desc, N''не існує'')) AS Name,
	CONVERT(NVARCHAR(60), CASE WHEN sp.principal_id IS NULL THEN NULL WHEN sp.is_disabled = 1 THEN N''DISABLED'' ELSE N''ENABLED'' END) AS State,
	CONVERT(BIT, 0) AS IsExcessive,
	CONVERT(NVARCHAR(400), CASE
		WHEN sp.principal_id IS NULL THEN N''Логін не існує: виконайте Mode = Install.''
		WHEN sl.principal_id IS NOT NULL AND sl.is_policy_checked = 0 THEN N''Для SQL-логіна вимкнено CHECK_POLICY.''
	END) AS Warning
FROM (SELECT 1 AS one) AS o
LEFT JOIN sys.server_principals AS sp ON sp.principal_id = SUSER_ID(@loginName)
LEFT JOIN sys.sql_logins AS sl ON sl.principal_id = sp.principal_id
UNION ALL
SELECT @@SERVERNAME, NULL, @loginName, N''Expected'', N''srv_index_advisor'',
	CASE WHEN rm.member_principal_id IS NULL THEN N''MISSING'' ELSE N''OK'' END, 0,
	CASE WHEN rm.member_principal_id IS NULL THEN N''Логін не є членом серверної ролі srv_index_advisor.'' END
FROM (SELECT 1 AS one) AS o
LEFT JOIN sys.server_role_members AS rm ON rm.role_principal_id = SUSER_ID(N''srv_index_advisor'') AND rm.member_principal_id = SUSER_ID(@loginName)
UNION ALL
SELECT @@SERVERNAME, NULL, @loginName, N''ServerRole'', r.name, N''MEMBER'',
	CASE WHEN r.name = N''srv_index_advisor'' THEN 0 ELSE 1 END,
	CASE
		WHEN r.name = N''srv_index_advisor'' THEN NULL
		WHEN r.name = N''sysadmin'' THEN N''Зайве: членство в sysadmin дає повний доступ до даних і змін.''
		ELSE CONCAT(N''Зайве членство в серверній ролі '', r.name, N''.'')
	END
FROM sys.server_role_members AS rm
INNER JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
WHERE rm.member_principal_id = SUSER_ID(@loginName)
UNION ALL
SELECT @@SERVERNAME, NULL, @loginName,
	CASE WHEN g.principal_id = SUSER_ID(@loginName) THEN N''ServerPermission'' ELSE CONCAT(N''ServerPermission via '', g.name) END,
	CONCAT(p.permission_name, CASE WHEN p.class <> 100 THEN CONCAT(N'' ('', p.class_desc, N'' id '', p.major_id, N'')'') ELSE N'''' END), p.state_desc,
	CASE
		WHEN p.state = ''D'' THEN 0
		WHEN g.principal_id = SUSER_ID(@loginName) AND p.class = 100 AND p.permission_name = N''CONNECT SQL'' THEN 0
		WHEN g.name = N''srv_index_advisor'' AND p.class = 100 AND p.permission_name IN (N''VIEW SERVER STATE'', N''VIEW ANY DEFINITION'') THEN 0
		ELSE 1
	END,
	CASE
		WHEN p.state = ''D'' THEN NULL
		WHEN g.principal_id = SUSER_ID(@loginName) AND p.class = 100 AND p.permission_name = N''CONNECT SQL'' THEN NULL
		WHEN g.name = N''srv_index_advisor'' AND p.class = 100 AND p.permission_name IN (N''VIEW SERVER STATE'', N''VIEW ANY DEFINITION'') THEN NULL
		WHEN g.principal_id = SUSER_ID(@loginName) THEN CONCAT(N''Зайве: право '', p.permission_name, N'' надано безпосередньо логіну (лише через роль).'')
		ELSE CONCAT(N''Зайве серверне право '', p.permission_name, N'' через роль '', g.name, N''.'')
	END
FROM sys.server_permissions AS p
INNER JOIN sys.server_principals AS g ON g.principal_id = p.grantee_principal_id
WHERE g.principal_id = SUSER_ID(@loginName)
	OR g.principal_id IN (SELECT rm.role_principal_id FROM sys.server_role_members AS rm WHERE rm.member_principal_id = SUSER_ID(@loginName))');

	SET @dbTemplate = CONVERT(NVARCHAR(MAX), N'
SELECT @@SERVERNAME, N''{dbLiteral}'', COALESCE(u.name COLLATE DATABASE_DEFAULT, @loginName), N''DatabaseUser'',
	COALESCE(u.type_desc COLLATE DATABASE_DEFAULT, N''не існує''), NULL, 0,
	CASE WHEN u.principal_id IS NULL THEN N''Користувача немає: виконайте Mode = AddDatabase.'' END
FROM (SELECT 1 AS one) AS o
LEFT JOIN {db}.sys.database_principals AS u ON u.sid = SUSER_SID(@loginName)
UNION ALL
SELECT @@SERVERNAME, N''{dbLiteral}'', m.name COLLATE DATABASE_DEFAULT, N''DatabaseRole'', r.name COLLATE DATABASE_DEFAULT, N''MEMBER'',
	CASE WHEN r.name = N''db_index_advisor'' THEN 0 ELSE 1 END,
	CASE
		WHEN r.name = N''db_index_advisor'' THEN NULL
		WHEN r.name IN (N''db_owner'', N''db_datareader'', N''db_datawriter'', N''db_ddladmin'', N''db_securityadmin'',
			N''db_accessadmin'', N''db_backupoperator'')
			THEN CONCAT(N''Зайве: членство в '', r.name COLLATE DATABASE_DEFAULT, N'' дає доступ до даних або змін.'')
		ELSE CONCAT(N''Зайве членство в ролі '', r.name COLLATE DATABASE_DEFAULT, N''.'')
	END
FROM {db}.sys.database_role_members AS rm
INNER JOIN {db}.sys.database_principals AS r ON r.principal_id = rm.role_principal_id
INNER JOIN {db}.sys.database_principals AS m ON m.principal_id = rm.member_principal_id
WHERE m.sid = SUSER_SID(@loginName)
UNION ALL
SELECT @@SERVERNAME, N''{dbLiteral}'', @loginName,
	CASE WHEN g.sid = SUSER_SID(@loginName) THEN N''DatabasePermission'' ELSE CONCAT(N''DatabasePermission via '', g.name COLLATE DATABASE_DEFAULT) END,
	CONCAT(p.permission_name COLLATE DATABASE_DEFAULT,
		CASE WHEN p.class <> 0 THEN CONCAT(N'' ('', p.class_desc COLLATE DATABASE_DEFAULT, N'' id '', p.major_id, N'')'') ELSE N'''' END),
	p.state_desc COLLATE DATABASE_DEFAULT,
	CASE
		WHEN p.state = ''D'' THEN 0
		WHEN g.sid = SUSER_SID(@loginName) AND p.class = 0 AND p.permission_name = N''CONNECT'' THEN 0
		WHEN g.name = N''db_index_advisor'' AND p.class = 0 AND p.permission_name IN (N''VIEW DATABASE STATE'', N''VIEW DEFINITION'') THEN 0
		ELSE 1
	END,
	CASE
		WHEN p.state = ''D'' THEN NULL
		WHEN g.sid = SUSER_SID(@loginName) AND p.class = 0 AND p.permission_name = N''CONNECT'' THEN NULL
		WHEN g.name = N''db_index_advisor'' AND p.class = 0 AND p.permission_name IN (N''VIEW DATABASE STATE'', N''VIEW DEFINITION'') THEN NULL
		WHEN p.permission_name IN (N''SELECT'', N''INSERT'', N''UPDATE'', N''DELETE'', N''EXECUTE'', N''ALTER'', N''CONTROL'',
			N''TAKE OWNERSHIP'', N''IMPERSONATE'',
			N''ALTER ANY SCHEMA'', N''REFERENCES'', N''UNMASK'')
			THEN CONCAT(N''Зайве: право '', p.permission_name COLLATE DATABASE_DEFAULT, N'' дає доступ до даних або змін.'')
		WHEN g.sid = SUSER_SID(@loginName)
			THEN CONCAT(N''Зайве: право '', p.permission_name COLLATE DATABASE_DEFAULT, N'' надано безпосередньо користувачу (лише через роль).'')
		ELSE CONCAT(N''Зайве право '', p.permission_name COLLATE DATABASE_DEFAULT, N'' через роль '', g.name COLLATE DATABASE_DEFAULT, N''.'')
	END
FROM {db}.sys.database_permissions AS p
INNER JOIN {db}.sys.database_principals AS g ON g.principal_id = p.grantee_principal_id
WHERE g.sid = SUSER_SID(@loginName)
	OR g.principal_id IN (
		SELECT rm.role_principal_id
		FROM {db}.sys.database_role_members AS rm
		INNER JOIN {db}.sys.database_principals AS m ON m.principal_id = rm.member_principal_id
		WHERE m.sid = SUSER_SID(@loginName)
	)');

	SELECT @dbSql = STRING_AGG(
			CONVERT(NVARCHAR(MAX), REPLACE(REPLACE(@dbTemplate, N'{db}', QUOTENAME(d.name)), N'{dbLiteral}', REPLACE(d.name, N'''', N''''''))),
			@unionSeparator
		) WITHIN GROUP (ORDER BY d.name)
	FROM sys.databases AS d
	WHERE d.database_id > 4
		AND d.state = 0
		AND HAS_DBACCESS(d.name) = 1
		AND (
			UPPER(@databases) = N'ALL'
			OR d.name IN (SELECT TRIM(s.value) FROM STRING_SPLIT(@databases, N',') AS s)
		);

	SET @sql = CONCAT(
		CONVERT(NVARCHAR(MAX), N'SELECT v.ServerName, v.DatabaseName, v.PrincipalName, v.Kind, v.Name, v.State, v.IsExcessive, v.Warning FROM ('),
		@serverPart,
		CASE WHEN @dbSql IS NULL THEN CONVERT(NVARCHAR(MAX), N'') ELSE CONCAT(CONVERT(NVARCHAR(MAX), N' UNION ALL '), @dbSql) END,
		N') AS v ORDER BY CASE WHEN v.DatabaseName IS NULL THEN 0 ELSE 1 END, v.DatabaseName, v.Kind, v.Name;');
	EXEC sys.sp_executesql @sql, N'@loginName NVARCHAR(128)', @loginName = @loginName;
	-- [Verify:end]
END;

IF @failedCount > 0
BEGIN
	SET @message = CONCAT(N'Виконано з помилками: ', @failedCount, N'. Подробиці — у повідомленнях вище.');
	THROW 50010, @message, 1;
END;
