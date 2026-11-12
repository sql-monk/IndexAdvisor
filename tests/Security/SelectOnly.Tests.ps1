# Обов'язковий тест безпеки (розділ 4.7 ТЗ): будь-яка спроба DDL, DML, EXEC, SELECT INTO чи другої інструкції
# блокується Invoke-IaSqlQuery ДО виклику драйвера Invoke-IaDbCommand — зокрема в небезпечних режимах.

BeforeDiscovery {
	$script:ForbiddenQueries = @(
		@{ Name = 'CREATE TABLE'; Sql = 'CREATE TABLE dbo.Evil (id INT);' }
		@{ Name = 'ALTER TABLE'; Sql = 'ALTER TABLE dbo.Orders ADD Evil INT NULL;' }
		@{ Name = 'DROP TABLE'; Sql = 'DROP TABLE dbo.Orders;' }
		@{ Name = 'TRUNCATE TABLE'; Sql = 'TRUNCATE TABLE dbo.Orders;' }
		@{ Name = 'CREATE INDEX'; Sql = 'CREATE INDEX IX_Evil ON dbo.Orders (Id);' }
		@{ Name = 'ALTER INDEX'; Sql = 'ALTER INDEX ALL ON dbo.Orders REBUILD;' }
		@{ Name = 'DROP INDEX'; Sql = 'DROP INDEX IX_Status ON dbo.Orders;' }
		@{ Name = 'CREATE PROCEDURE'; Sql = 'CREATE PROCEDURE dbo.Evil AS SELECT 1;' }
		@{ Name = 'UPDATE STATISTICS'; Sql = 'UPDATE STATISTICS dbo.Orders;' }
		@{ Name = 'INSERT'; Sql = 'INSERT INTO dbo.Orders (Id) VALUES (1);' }
		@{ Name = 'UPDATE'; Sql = 'UPDATE dbo.Orders SET Status = 0;' }
		@{ Name = 'DELETE'; Sql = 'DELETE FROM dbo.Orders;' }
		@{ Name = 'MERGE'; Sql = 'MERGE dbo.Orders AS t USING (SELECT 1 AS Id) AS s ON t.Id = s.Id WHEN MATCHED THEN DELETE;' }
		@{ Name = 'EXEC процедури'; Sql = 'EXEC sp_who;' }
		@{ Name = 'EXECUTE рядка'; Sql = "EXECUTE ('SELECT name FROM sys.objects');" }
		@{ Name = 'sp_executesql'; Sql = "EXEC sys.sp_executesql N'SELECT name FROM sys.objects';" }
		@{ Name = 'xp_cmdshell'; Sql = "EXEC master..xp_cmdshell 'dir';" }
		@{ Name = 'SELECT INTO таблиці'; Sql = 'SELECT name INTO dbo.Copy FROM sys.objects;' }
		@{ Name = 'SELECT INTO #t'; Sql = 'SELECT name INTO #t FROM sys.objects;' }
		@{ Name = 'друга інструкція через ;'; Sql = 'SELECT name FROM sys.objects; DROP TABLE dbo.Orders;' }
		@{ Name = 'дві інструкції SELECT'; Sql = 'SELECT name FROM sys.objects; SELECT name FROM sys.columns;' }
		@{ Name = 'друга інструкція без ;'; Sql = "SELECT name FROM sys.objects`nDELETE FROM dbo.Orders" }
		@{ Name = 'розділювач GO'; Sql = "SELECT name FROM sys.objects`nGO`nDROP TABLE dbo.Orders" }
		@{ Name = 'GO між двома SELECT'; Sql = "SELECT name FROM sys.objects`nGO`nSELECT name FROM sys.columns" }
		@{ Name = 'коментар перед DDL'; Sql = "-- SELECT name FROM sys.objects`nDROP TABLE dbo.Orders" }
		@{ Name = 'блоковий коментар перед DDL'; Sql = '/* SELECT */ DROP TABLE dbo.Orders' }
		@{ Name = 'коментарі навколо ;'; Sql = 'SELECT name FROM sys.objects /* x */ ; /* y */ DELETE FROM dbo.Orders -- z' }
		@{ Name = 'CTE + DELETE'; Sql = 'WITH c AS (SELECT name FROM sys.objects) DELETE FROM c;' }
		@{ Name = 'CTE + UPDATE'; Sql = 'WITH c AS (SELECT Id FROM dbo.Orders) UPDATE c SET Id = 0;' }
		@{ Name = 'INSERT…EXEC'; Sql = 'INSERT INTO #t EXEC sp_who;' }
		@{ Name = 'OPENROWSET'; Sql = "SELECT * FROM OPENROWSET('SQLNCLI', 'Server=other;Trusted_Connection=yes;', 'SELECT 1') AS r;" }
		@{ Name = 'OPENROWSET BULK'; Sql = "SELECT * FROM OPENROWSET(BULK 'C:\secret.txt', SINGLE_CLOB) AS r;" }
		@{ Name = 'OPENQUERY'; Sql = "SELECT * FROM OPENQUERY(LinkedSrv, 'SELECT 1') AS r;" }
		@{ Name = 'OPENDATASOURCE'; Sql = "SELECT * FROM OPENDATASOURCE('SQLNCLI', 'Data Source=other;Integrated Security=SSPI').master.sys.objects;" }
		@{ Name = 'NEXT VALUE FOR'; Sql = 'SELECT NEXT VALUE FOR dbo.Seq AS v;' }
		@{ Name = 'користувацька таблиця'; Sql = 'SELECT * FROM dbo.Orders;' }
		@{ Name = 'таблиця без схеми'; Sql = 'SELECT * FROM Orders;' }
		@{ Name = 'користувацька функція'; Sql = 'SELECT dbo.fnSecret(1) AS v FROM sys.objects;' }
		@{ Name = 'табличне значення користувацької функції'; Sql = 'SELECT * FROM dbo.tvfSecret(1) AS t;' }
		@{ Name = 'зв''язаний сервер'; Sql = 'SELECT * FROM LinkedSrv.master.sys.objects;' }
		@{ Name = 'GRANT'; Sql = 'GRANT SELECT ON dbo.Orders TO public;' }
		@{ Name = 'REVOKE'; Sql = 'REVOKE SELECT ON dbo.Orders FROM public;' }
		@{ Name = 'DENY'; Sql = 'DENY SELECT ON dbo.Orders TO public;' }
		@{ Name = 'SHUTDOWN'; Sql = 'SHUTDOWN WITH NOWAIT;' }
		@{ Name = 'WAITFOR'; Sql = "WAITFOR DELAY '00:00:10';" }
		@{ Name = 'BEGIN TRAN'; Sql = 'BEGIN TRAN;' }
		@{ Name = 'BEGIN TRAN + SELECT'; Sql = 'BEGIN TRANSACTION; SELECT name FROM sys.objects;' }
		@{ Name = 'DECLARE'; Sql = 'DECLARE @x INT = 1;' }
		@{ Name = 'SET'; Sql = 'SET NOCOUNT ON;' }
		@{ Name = 'USE'; Sql = 'USE master;' }
		@{ Name = 'DBCC'; Sql = 'DBCC FREEPROCCACHE;' }
		@{ Name = 'BACKUP'; Sql = "BACKUP DATABASE master TO DISK = 'C:\x.bak';" }
		@{ Name = 'KILL'; Sql = 'KILL 55;' }
		@{ Name = 'ALTER DATABASE'; Sql = 'ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;' }
		@{ Name = 'CREATE LOGIN'; Sql = "CREATE LOGIN evil WITH PASSWORD = 'P@ssw0rd!123';" }
		@{ Name = 'текст, що не розбирається'; Sql = 'SELECT FROM WHERE' }
	)
	$script:UnsafeModes = @(
		@{ Mode = 'стандартний режим, Purpose Collector'; Purpose = 'Collector'; AllowFreeQuery = $false; DisableSelectCheck = $false }
		@{ Mode = 'стандартний режим, Purpose Tool'; Purpose = 'Tool'; AllowFreeQuery = $false; DisableSelectCheck = $false }
		@{ Mode = 'unsafe.allowFreeQuery, Purpose Tool'; Purpose = 'Tool'; AllowFreeQuery = $true; DisableSelectCheck = $false }
		@{ Mode = 'unsafe.allowFreeQuery, Purpose FreeQuery'; Purpose = 'FreeQuery'; AllowFreeQuery = $true; DisableSelectCheck = $false }
		@{ Mode = 'усі unsafe-прапорці, Purpose FreeQuery'; Purpose = 'FreeQuery'; AllowFreeQuery = $true; DisableSelectCheck = $true }
	)
	# DECLARE і SET змінної як окремі інструкції дозволені лише при unsafe.disableSelectCheck (лише читання), тож у режимі
	# з вимкненою перевіркою SELECT перевіряються всі інші випадки.
	$script:ReadOnlyWhenUnsafe = @('DECLARE', 'дві інструкції SELECT')
}

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:IaModule = Get-Module IndexAdvisor

	function Invoke-IaTestQuery {
		param(
			[string]$Query,
			[System.Collections.IDictionary]$Config,
			[string]$Purpose = 'Collector',
			[System.Collections.IDictionary]$Parameters = @{}
		)
		& $script:IaModule {
			param($q, $c, $p, $par)
			Invoke-IaSqlQuery -Server 'srv1' -Database 'db1' -Query $q -Config $c -Purpose $p -Parameters $par
		} $Query $Config $Purpose $Parameters
	}
}

Describe 'Invoke-IaSqlQuery: заборонені інструкції блокуються до виклику драйвера' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Invoke-IaDbCommand {
			@{ columns = @(@{ name = 'name'; type = 'nvarchar' }); rows = @(, [object[]]@('x')); messages = @(); hasMoreRows = $false }
		}
		Mock -ModuleName IndexAdvisor Get-IaSecret { 'TestPassword1!' }
	}

	Context '<Mode>' -ForEach $script:UnsafeModes {
		It 'блокує: <Name>' -ForEach ($script:ForbiddenQueries | Where-Object { -not ($DisableSelectCheck -and $_.Name -in $script:ReadOnlyWhenUnsafe) }) {
			$config = Get-IaTestConfig
			$config.unsafe.allowFreeQuery = $AllowFreeQuery
			$config.unsafe.disableSelectCheck = $DisableSelectCheck
			$config.unsafe.disableMaxdop = $DisableSelectCheck
			$config.unsafe.disableTimeouts = $DisableSelectCheck
			$config.unsafe.allowNonStandardLogin = $DisableSelectCheck

			$response = Invoke-IaTestQuery -Query $Sql -Config $config -Purpose $Purpose

			$response.success | Should -BeFalse
			$response.error.code | Should -BeIn @('NotSingleSelect', 'ForbiddenSource')
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}
	}

	It 'DECLARE без SELECT при unsafe.disableSelectCheck не потрапляє до драйвера з DDL' {
		$config = Get-IaTestConfig
		$config.unsafe.disableSelectCheck = $true
		$response = Invoke-IaTestQuery -Query 'DECLARE @x INT = 1; DROP TABLE dbo.Orders;' -Config $config
		$response.success | Should -BeFalse
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
	}

	It 'Purpose FreeQuery без unsafe.allowFreeQuery блокується навіть для валідного SELECT' {
		$response = Invoke-IaTestQuery -Query 'SELECT name FROM sys.objects;' -Config (Get-IaTestConfig) -Purpose FreeQuery
		$response.success | Should -BeFalse
		$response.error.code | Should -Be 'ArgumentInvalid'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
	}

	It 'склеювання значення параметра в текст неможливе: значення йде окремим параметром драйвера' {
		$evil = "x'; DROP TABLE dbo.Orders; --"
		$response = Invoke-IaTestQuery -Query 'SELECT name FROM sys.objects WHERE name = @Name;' -Config (Get-IaTestConfig) -Parameters @{ Name = $evil }
		$response.success | Should -BeTrue
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
			$CommandText -notmatch 'DROP' -and $Parameters[0].value -eq "x'; DROP TABLE dbo.Orders; --" -and $Parameters[0].name -eq '@Name'
		}
	}
}

Describe 'Invoke-IaSqlQuery: валідні SELECT із системних каталогів проходять' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Invoke-IaDbCommand {
			@{ columns = @(@{ name = 'name'; type = 'nvarchar' }); rows = @(, [object[]]@('x')); messages = @(); hasMoreRows = $false }
		}
		Mock -ModuleName IndexAdvisor Get-IaSecret { 'TestPassword1!' }
	}

	It 'виконує: <Name>' -ForEach @(
		@{ Name = 'sys.objects'; Sql = 'SELECT o.name FROM sys.objects AS o;'; Parameters = @{} }
		@{ Name = 'INFORMATION_SCHEMA'; Sql = 'SELECT t.TABLE_NAME FROM INFORMATION_SCHEMA.TABLES AS t;'; Parameters = @{} }
		@{ Name = 'префікс бази'; Sql = 'SELECT d.name FROM master.sys.databases AS d;'; Parameters = @{} }
		@{ Name = 'CTE і агрегат'; Sql = 'WITH c AS (SELECT i.object_id FROM sys.indexes AS i) SELECT COUNT(*) AS cnt FROM c;'; Parameters = @{} }
		@{ Name = 'DMV і системна таблична функція'; Sql = "SELECT u.index_id, p.avg_fragmentation_in_percent FROM sys.dm_db_index_usage_stats AS u CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), u.object_id, u.index_id, NULL, 'LIMITED') AS p;"; Parameters = @{} }
		@{ Name = 'вбудовані функції'; Sql = "SELECT SERVERPROPERTY('IsHadrEnabled') AS isHadr, @@SERVERNAME AS serverName, SYSUTCDATETIME() AS nowUtc;"; Parameters = @{} }
		@{ Name = 'іменований параметр'; Sql = 'SELECT o.name FROM sys.objects AS o WHERE o.name = @Name;'; Parameters = @{ Name = 'Orders' } }
		@{ Name = 'sys.fn_my_permissions'; Sql = "SELECT p.permission_name FROM sys.fn_my_permissions(NULL, 'SERVER') AS p;"; Parameters = @{} }
		@{ Name = 'Query Store і XML-метод'; Sql = "SELECT q.query_id, TRY_CAST(p.query_plan AS XML).value('count(//*)', 'int') AS nodes FROM sys.query_store_query AS q INNER JOIN sys.query_store_plan AS p ON p.query_id = q.query_id;"; Parameters = @{} }
		@{ Name = 'коментар зі «шкідливим» текстом'; Sql = "SELECT o.name FROM sys.objects AS o -- ; DROP TABLE dbo.Orders`n/* DELETE FROM dbo.Orders */"; Parameters = @{} }
		@{ Name = 'рядок із «шкідливим» текстом'; Sql = "SELECT o.name FROM sys.objects AS o WHERE o.name = N'; DROP TABLE dbo.Orders';"; Parameters = @{} }
	) {
		$response = Invoke-IaTestQuery -Query $Sql -Config (Get-IaTestConfig) -Parameters $Parameters
		$response.error | Should -BeNullOrEmpty
		$response.success | Should -BeTrue
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly
	}

	It 'коментарі не потрапляють у виконуваний текст' {
		$response = Invoke-IaTestQuery -Query "SELECT o.name FROM sys.objects AS o -- ; DROP TABLE dbo.Orders`n/* DELETE FROM dbo.Orders */" -Config (Get-IaTestConfig)
		$response.success | Should -BeTrue
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -notmatch 'DROP|DELETE' }
	}
}

Describe 'Test-IaSelectOnly і Test-IaSystemSourcesOnly напряму' {
	It 'Test-IaSelectOnly відхиляє: <Name>' -ForEach ($script:ForbiddenQueries | Where-Object { $_.Name -notmatch 'таблиця|функці|сервер|OPEN|NEXT VALUE' }) {
		$result = & $script:IaModule { param($s) Test-IaSelectOnly -Sql $s } $Sql
		$result.isValid | Should -BeFalse
		@($result.errors).Count | Should -BeGreaterThan 0
		@($result.errors)[0].code | Should -Be 'NotSingleSelect'
	}

	It 'Test-IaSystemSourcesOnly відхиляє: <Name>' -ForEach ($script:ForbiddenQueries | Where-Object { $_.Name -match 'таблиця|функці|сервер|OPEN|NEXT VALUE|EXEC|xp_|sp_' }) {
		$result = & $script:IaModule { param($s) Test-IaSystemSourcesOnly -Sql $s } $Sql
		$result.isValid | Should -BeFalse
		@($result.errors)[0].code | Should -Be 'ForbiddenSource'
	}
}
