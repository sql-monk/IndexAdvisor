BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Rules.TestHelpers.ps1')
	Initialize-IaRuleTestScriptDom
	function Test-TestRecommendation {
		param($Recommendation, $Snapshot, $Config)
		return InModuleScope IndexAdvisor -Parameters @{ Recommendation = $Recommendation; Snapshot = $Snapshot; Config = $Config } {
			Test-IaRecommendation -Recommendation $Recommendation -Snapshot $Snapshot -Config $Config
		}
	}
	function Get-TestCheck {
		param($Validation, [string]$Id)
		return $Validation.checks | Where-Object { $_.id -eq $Id }
	}
	function Test-Create {
		param([string]$Execute, [string]$Index = 'IX_New', [string]$Rollback, [string[]]$Replaces = @(), $Snapshot, $Config)
		if (-not $PSBoundParameters.ContainsKey('Rollback')) { $Rollback = "DROP INDEX [$Index] ON [dbo].[Orders];" }
		$recommendation = New-IaRuleTestRecommendation -Action 'CreateIndex' -Index $Index -ExecuteScript $Execute -RollbackScript $Rollback -ReplacesIndexes $Replaces
		return Test-TestRecommendation $recommendation $Snapshot $Config
	}
	function Test-Drop {
		param([string]$Index = 'IX_Status', [string]$Execute, [string]$Rollback, [string]$Table = 'Orders', $Snapshot, $Config)
		if (-not $Execute) { $Execute = "DROP INDEX [$Index] ON [dbo].[$Table];" }
		$recommendation = New-IaRuleTestRecommendation -Action 'DropIndex' -Table $Table -Index $Index -ExecuteScript $Execute -RollbackScript $Rollback
		return Test-TestRecommendation $recommendation $Snapshot $Config
	}
	$script:statusRollback = 'CREATE NONCLUSTERED INDEX [IX_Status] ON [dbo].[Orders] ([Status]) WITH (ONLINE = ON);'
}

Describe 'Test-IaRecommendation' {
	BeforeAll {
		Mock -ModuleName IndexAdvisor ConvertTo-IaSqlFragment { Invoke-IaRuleTestParse -Sql $Sql }
	}
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$config = Get-IaTestConfig
	}

	Context 'рекомендації з tests/Fixtures/llm-response.sample.json' {
		It '<action> проходить усі перевірки й відповідає recommendation.schema.json' -ForEach @(
			@{ action = 'CreateIndex'; position = 0 }
			@{ action = 'DropIndex'; position = 1 }
		) {
			$draft = (Get-IaTestFixture -Name 'llm-response.sample.json').recommendations[$position]
			$recommendation = & (Get-Module IndexAdvisor) { param($Draft) New-IaRecommendation -Draft $Draft -RunId 'run-1' -Module 'Indexes' } $draft
			$validation = Test-TestRecommendation $recommendation $snapshot $config
			$validation.status | Should -Be 'Passed' -Because (($validation.checks | ForEach-Object { "$($_.id)=$($_.status): $($_.message)" }) -join ' | ')
			$validation.checks.Count | Should -Be 9
			$recommendation.validation = $validation
			Test-IaJsonAgainstSchema -Json ($recommendation | ConvertTo-Json -Depth 50) -Schema recommendation | Should -BeTrue
		}
	}

	Context 'ObjectsExist' {
		It 'неіснуюча колонка, таблиця чи індекс — Failed' {
			$validation = Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Foo]) INCLUDE ([Amount]) WHERE [Bar] = 1 WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config
			$check = Get-TestCheck $validation 'ObjectsExist'
			$check.status | Should -Be 'Failed'
			$check.message | Should -Match 'Foo, Bar'
			$validation.status | Should -Be 'Failed'
			(Get-TestCheck (Test-Drop -Index 'IX_Missing' -Rollback $script:statusRollback -Snapshot $snapshot -Config $config) 'ObjectsExist').status | Should -Be 'Failed'
			$recommendation = New-IaRuleTestRecommendation -Action 'CreateIndex' -Table 'Nope' -Index 'IX_New' -ExecuteScript 'CREATE INDEX [IX_New] ON [dbo].[Nope] ([A]);' -RollbackScript 'DROP INDEX [IX_New] ON [dbo].[Nope];'
			(Get-TestCheck (Test-TestRecommendation $recommendation $snapshot $config) 'ObjectsExist').message | Should -Match 'не знайдена'
		}
	}

	Context 'NotDuplicate' {
		It 'дублікат ключів, перекриття наявним і зайняте ім''я — Failed' {
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([CustomerId], [OrderDate]) INCLUDE ([Status]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'NotDuplicate').status | Should -Be 'Failed'
			$prefix = Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([OrderId] DESC) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'NotDuplicate'
			$prefix.status | Should -Be 'Passed'
			$covered = Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Comment]) INCLUDE ([Status]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'NotDuplicate'
			$covered.status | Should -Be 'Failed'
			$covered.message | Should -Match 'IX_Comment'
			$name = Get-TestCheck (Test-Create -Index 'IX_Status' -Execute 'CREATE NONCLUSTERED INDEX [IX_Status] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'NotDuplicate'
			$name.message | Should -Match 'уже існує'
		}

		It 'новий індекс перекриває наявний — Warning, з replacesIndexes — Passed' {
			$execute = 'CREATE NONCLUSTERED INDEX [IX_Status_Amount] ON [dbo].[Orders] ([Status], [Amount]) WITH (ONLINE = ON);'
			$validation = Test-Create -Index 'IX_Status_Amount' -Execute $execute -Snapshot $snapshot -Config $config
			(Get-TestCheck $validation 'NotDuplicate').status | Should -Be 'Warning'
			$validation.status | Should -Be 'Warning'
			(Get-TestCheck (Test-Create -Index 'IX_Status_Amount' -Execute $execute -Replaces 'IX_Status' -Snapshot $snapshot -Config $config) 'NotDuplicate').status | Should -Be 'Passed'
		}

		It 'другий columnstore-індекс — Failed' {
			$orders = $snapshot.instances[0].databases[0].tables[1]
			$columnstore = Copy-IaTestObject $orders.indexes[3]
			$columnstore.name = 'CS_Status'
			$columnstore.typeDesc = 'NONCLUSTERED COLUMNSTORE'
			$orders.indexes = @($orders.indexes) + @($columnstore)
			$validation = Test-Create -Index 'CS_Amount' -Execute 'CREATE NONCLUSTERED COLUMNSTORE INDEX [CS_Amount] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config
			(Get-TestCheck $validation 'NotDuplicate').message | Should -Match 'CS_Status'
		}
	}

	Context 'DropAllowed' {
		It '<index> — Failed (<reason>)' -ForEach @(
			@{ index = 'IX_CustomerId'; table = 'Orders'; reason = 'хінтах' }
			@{ index = 'PK_Orders'; table = 'Orders'; reason = 'первинним ключем' }
			@{ index = 'UQ_Customers_Email'; table = 'Customers'; reason = 'UNIQUE' }
		) {
			$check = Get-TestCheck (Test-Drop -Index $index -Table $table -Rollback "CREATE INDEX [$index] ON [dbo].[$table] ([X]);" -Snapshot $snapshot -Config $config) 'DropAllowed'
			$check.status | Should -Be 'Failed'
			$check.message | Should -Match $reason
		}

		It 'невідомі дані — Warning' {
			(Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Status').usedByReplication = $null
			$check = Get-TestCheck (Test-Drop -Rollback $script:statusRollback -Snapshot $snapshot -Config $config) 'DropAllowed'
			$check.status | Should -Be 'Warning'
			$check.message | Should -Match 'Невідомо'
		}
	}

	Context 'SyntaxValid' {
		It 'синтаксична помилка, порожній скрипт і недоступний ScriptDom — Failed' {
			$broken = Test-Create -Execute 'CREATE NONCLUSTERED INDEX ON [dbo].[Orders] ([Amount]' -Snapshot $snapshot -Config $config
			$check = Get-TestCheck $broken 'SyntaxValid'
			$check.status | Should -Be 'Failed'
			$check.message | Should -Match 'рядок 1'
			(Get-TestCheck $broken 'SafeScript').status | Should -Be 'Skipped'
			(Get-TestCheck (Test-Create -Execute '' -Snapshot $snapshot -Config $config) 'SyntaxValid').message | Should -Match 'порожній'
			Mock -ModuleName IndexAdvisor ConvertTo-IaSqlFragment { throw 'ScriptDom не знайдено' }
			(Get-TestCheck (Test-Drop -Rollback $script:statusRollback -Snapshot $snapshot -Config $config) 'SyntaxValid').message | Should -Match 'ScriptDom недоступний'
		}
	}

	Context 'RollbackMatches' {
		It 'CREATE ↔ DROP того самого індексу на тій самій таблиці' {
			$validation = Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);' -Rollback 'DROP INDEX [IX_Other] ON [dbo].[Orders];' -Snapshot $snapshot -Config $config
			$check = Get-TestCheck $validation 'RollbackMatches'
			$check.status | Should -Be 'Failed'
			$check.message | Should -Match 'не видаляє створений індекс \[IX_New\]'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);' -Rollback '' -Snapshot $snapshot -Config $config) 'RollbackMatches').status | Should -Be 'Failed'
		}

		It 'DROP: відкат має відтворити ключі, INCLUDE і фільтр' {
			$index = 'IX_CustomerId_OrderDate_INC'
			$good = "CREATE NONCLUSTERED INDEX [$index] ON [dbo].[Orders] ([CustomerId], [OrderDate]) INCLUDE ([Amount]) WITH (ONLINE = ON);"
			(Get-TestCheck (Test-Drop -Index $index -Rollback $good -Snapshot $snapshot -Config $config) 'RollbackMatches').status | Should -Be 'Passed'
			$noInclude = Get-TestCheck (Test-Drop -Index $index -Rollback "CREATE NONCLUSTERED INDEX [$index] ON [dbo].[Orders] ([CustomerId], [OrderDate]) WITH (ONLINE = ON);" -Snapshot $snapshot -Config $config) 'RollbackMatches'
			$noInclude.status | Should -Be 'Failed'
			$noInclude.message | Should -Match 'INCLUDE'
			$order = Get-TestCheck (Test-Drop -Index $index -Rollback "CREATE NONCLUSTERED INDEX [$index] ON [dbo].[Orders] ([OrderDate], [CustomerId]) INCLUDE ([Amount]) WITH (ONLINE = ON);" -Snapshot $snapshot -Config $config) 'RollbackMatches'
			$order.message | Should -Match 'ключ'
			$filter = Get-TestCheck (Test-Drop -Index $index -Rollback "CREATE NONCLUSTERED INDEX [$index] ON [dbo].[Orders] ([CustomerId], [OrderDate]) INCLUDE ([Amount]) WHERE [Status] = 1 WITH (ONLINE = ON);" -Snapshot $snapshot -Config $config) 'RollbackMatches'
			$filter.message | Should -Match 'фільтр'
			$filtered = Find-IaRuleTestIndex -Snapshot $snapshot -Index $index
			$filtered.hasFilter = $true
			$filtered.filterDefinition = '([Status]=(1))'
			(Get-TestCheck (Test-Drop -Index $index -Rollback "CREATE NONCLUSTERED INDEX [$index] ON [dbo].[Orders] ([CustomerId], [OrderDate]) INCLUDE ([Amount]) WHERE [Status] = 1 WITH (ONLINE = ON);" -Snapshot $snapshot -Config $config) 'RollbackMatches').status | Should -Be 'Passed'
		}

		It 'інша компресія у відкаті — Warning' {
			$check = Get-TestCheck (Test-Drop -Rollback 'CREATE NONCLUSTERED INDEX [IX_Status] ON [dbo].[Orders] ([Status]) WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);' -Snapshot $snapshot -Config $config) 'RollbackMatches'
			$check.status | Should -Be 'Warning'
			$check.message | Should -Match 'компресія PAGE'
		}

		It 'REBUILD з порожнім відкатом — Warning' {
			$recommendation = New-IaRuleTestRecommendation -Action 'AlterIndex' -Index 'IX_Comment' -ExecuteScript 'ALTER INDEX [IX_Comment] ON [dbo].[Orders] REBUILD WITH (ONLINE = ON);' -RollbackScript ''
			$validation = Test-TestRecommendation $recommendation $snapshot $config
			(Get-TestCheck $validation 'RollbackMatches').status | Should -Be 'Warning'
			$validation.status | Should -Be 'Warning'
		}
	}

	Context 'PlatformLimits' {
		It 'ключ понад 1700 байт: фіксована довжина — Failed, змінна — Warning; MAX — Failed' {
			$orders = $snapshot.instances[0].databases[0].tables[1]
			$orders.columns = @($orders.columns) + @(
				[ordered]@{ columnId = 7; name = 'Code1'; typeName = 'char'; maxLength = 900; precision = 0; scale = 0; isNullable = $false }
				[ordered]@{ columnId = 8; name = 'Code2'; typeName = 'char'; maxLength = 900; precision = 0; scale = 0; isNullable = $false }
				[ordered]@{ columnId = 9; name = 'Notes'; typeName = 'nvarchar'; maxLength = -1; precision = 0; scale = 0; isNullable = $true }
			)
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Code1], [Code2]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'PlatformLimits').status | Should -Be 'Failed'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Code1], [Comment], [Status]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'PlatformLimits').status | Should -Be 'Warning'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Notes]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'PlatformLimits').message | Should -Match 'MAX'
		}

		It 'понад 32 ключові колонки і другий кластерний індекс — Failed' {
			$orders = $snapshot.instances[0].databases[0].tables[1]
			$orders.columns = @($orders.columns) + @(1..33 | ForEach-Object { [ordered]@{ columnId = 10 + $_; name = "C$_"; typeName = 'int'; maxLength = 4; precision = 10; scale = 0; isNullable = $false } })
			$keys = (1..33 | ForEach-Object { "[C$_]" }) -join ', '
			(Get-TestCheck (Test-Create -Execute "CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ($keys) WITH (ONLINE = ON);" -Snapshot $snapshot -Config $config) 'PlatformLimits').message | Should -Match '33 ключових колонок'
			$clustered = Get-TestCheck (Test-Create -Index 'CI_OrderDate' -Execute 'CREATE CLUSTERED INDEX [CI_OrderDate] ON [dbo].[Orders] ([OrderDate]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'PlatformLimits'
			$clustered.status | Should -Be 'Failed'
			$clustered.message | Should -Match 'PK_Orders'
		}
	}

	Context 'EditionFeatures' {
		It 'ONLINE без підтримки редакції чи RESUMABLE без ONLINE — Failed; Enterprise без ONLINE — Warning' {
			$execute = 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON, RESUMABLE = ON);'
			(Get-TestCheck (Test-Create -Execute $execute -Snapshot $snapshot -Config $config) 'EditionFeatures').status | Should -Be 'Passed'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (RESUMABLE = ON);' -Snapshot $snapshot -Config $config) 'EditionFeatures').message | Should -Match 'потребує ONLINE'
			$warning = Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]);' -Snapshot $snapshot -Config $config) 'EditionFeatures'
			$warning.status | Should -Be 'Warning'
			$warning.message | Should -Match 'без ONLINE = ON'
			$snapshot.instances[0].supportsOnlineIndexOps = $false
			$snapshot.instances[0].edition = 'Standard Edition (64-bit)'
			$standard = Get-TestCheck (Test-Create -Execute $execute -Snapshot $snapshot -Config $config) 'EditionFeatures'
			$standard.status | Should -Be 'Failed'
			$standard.message | Should -Match 'Standard Edition'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]);' -Snapshot $snapshot -Config $config) 'EditionFeatures').status | Should -Be 'Passed'
		}
	}

	Context 'PartitionAlignment' {
		BeforeEach {
			$orders = $snapshot.instances[0].databases[0].tables[1]
			$orders.isPartitioned = $true
			$orders.partitionScheme = 'ps_dbo_datetime27'
			$orders.partitionFunction = 'pf_dbo_datetime27'
			$orders.partitionColumn = 'OrderDate'
		}

		It 'для несекціонованої таблиці — Skipped' {
			$snapshot = Get-IaTestSnapshot
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'PartitionAlignment').status | Should -Be 'Skipped'
		}

		It 'вирівняний за замовчуванням чи на схемі — Passed; на файловій групі — Warning; інший стовпець чи унікальний без ключа — Failed' {
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'PartitionAlignment').status | Should -Be 'Passed'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON) ON [ps_dbo_datetime27] ([OrderDate]);' -Snapshot $snapshot -Config $config) 'PartitionAlignment').status | Should -Be 'Passed'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON) ON [PRIMARY];' -Snapshot $snapshot -Config $config) 'PartitionAlignment').status | Should -Be 'Warning'
			(Get-TestCheck (Test-Create -Execute 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON) ON [ps_dbo_datetime27] ([CustomerId]);' -Snapshot $snapshot -Config $config) 'PartitionAlignment').status | Should -Be 'Failed'
			$unique = Get-TestCheck (Test-Create -Execute 'CREATE UNIQUE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);' -Snapshot $snapshot -Config $config) 'PartitionAlignment'
			$unique.status | Should -Be 'Failed'
			$unique.message | Should -Match 'OrderDate'
		}
	}

	Context 'SafeScript' {
		It '<name> — Failed' -ForEach @(
			@{ name = 'DML у скрипті створення'; action = 'CreateIndex'; index = 'IX_New'; execute = 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON); DELETE FROM [dbo].[Orders];'; rollback = 'DROP INDEX [IX_New] ON [dbo].[Orders];'; pattern = 'DeleteStatement' }
			@{ name = 'EXEC у відкаті'; action = 'DropIndex'; index = 'IX_Status'; execute = 'DROP INDEX [IX_Status] ON [dbo].[Orders];'; rollback = 'CREATE NONCLUSTERED INDEX [IX_Status] ON [dbo].[Orders] ([Status]) WITH (ONLINE = ON); EXEC sp_who;'; pattern = 'ExecuteStatement' }
			@{ name = 'видалення іншого індексу'; action = 'DropIndex'; index = 'IX_Status'; execute = 'DROP INDEX [IX_Status] ON [dbo].[Orders]; DROP INDEX [IX_Comment] ON [dbo].[Orders];'; rollback = 'CREATE NONCLUSTERED INDEX [IX_Status] ON [dbo].[Orders] ([Status]) WITH (ONLINE = ON);'; pattern = 'IX_Comment' }
			@{ name = 'DISABLE'; action = 'AlterIndex'; index = 'IX_Status'; execute = 'ALTER INDEX [IX_Status] ON [dbo].[Orders] DISABLE;'; rollback = 'ALTER INDEX [IX_Status] ON [dbo].[Orders] REBUILD WITH (ONLINE = ON);'; pattern = 'DISABLE' }
			@{ name = 'DROP_EXISTING у CreateIndex'; action = 'CreateIndex'; index = 'IX_New'; execute = 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (DROP_EXISTING = ON, ONLINE = ON);'; rollback = 'DROP INDEX [IX_New] ON [dbo].[Orders];'; pattern = 'DROP_EXISTING' }
			@{ name = 'інша таблиця'; action = 'CreateIndex'; index = 'IX_New'; execute = 'CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Customers] ([Name]) WITH (ONLINE = ON);'; rollback = 'DROP INDEX [IX_New] ON [dbo].[Customers];'; pattern = 'Customers' }
			@{ name = 'зміна колонок таблиці'; action = 'CreateIndex'; index = 'IX_New'; execute = 'ALTER TABLE [dbo].[Orders] ADD [X] INT NULL;'; rollback = 'DROP INDEX [IX_New] ON [dbo].[Orders];'; pattern = 'AlterTableAdd' }
		) {
			$recommendation = New-IaRuleTestRecommendation -Action $action -Index $index -ExecuteScript $execute -RollbackScript $rollback
			$validation = Test-TestRecommendation $recommendation $snapshot $config
			$check = Get-TestCheck $validation 'SafeScript'
			$check.status | Should -Be 'Failed'
			$check.message | Should -Match $pattern
			$validation.status | Should -Be 'Failed'
		}

		It 'ідемпотентна обгортка IF [NOT] EXISTS із системних каталогів розгортається: усі перевірки проходять' {
			$execute = "IF NOT EXISTS (SELECT 1 FROM [sys].[indexes] WHERE [object_id] = OBJECT_ID(N'[dbo].[Orders]') AND [name] = N'IX_New')`n" +
				"BEGIN`n`tCREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);`nEND;"
			$rollback = "IF INDEXPROPERTY(OBJECT_ID(N'[dbo].[Orders]'), N'IX_New', 'IndexID') IS NOT NULL`n`tDROP INDEX [IX_New] ON [dbo].[Orders];"
			$validation = Test-Create -Execute $execute -Rollback $rollback -Snapshot $snapshot -Config $config
			$validation.status | Should -Be 'Passed' -Because (($validation.checks | ForEach-Object { "$($_.id)=$($_.status): $($_.message)" }) -join ' | ')
			(Get-TestCheck $validation 'NotDuplicate').status | Should -Be 'Passed'
			(Get-TestCheck $validation 'SafeScript').status | Should -Be 'Passed'
		}

		It 'допоміжні інструкції: USE цільової бази, SET, PRINT і SELECT із системних каталогів — Passed' {
			$execute = "USE [Sales];`nSET XACT_ABORT ON;`nSET LOCK_TIMEOUT 60000;`nPRINT N'Створення індексу';`n" +
				"CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);`n" +
				"SELECT [i].[name] FROM [sys].[indexes] AS [i] WHERE [i].[object_id] = OBJECT_ID(N'[dbo].[Orders]');"
			$validation = Test-Create -Execute $execute -Rollback "USE [Sales];`nDROP INDEX [IX_New] ON [dbo].[Orders];" -Snapshot $snapshot -Config $config
			$validation.status | Should -Be 'Passed' -Because (($validation.checks | ForEach-Object { "$($_.id)=$($_.status): $($_.message)" }) -join ' | ')
		}

		It 'допоміжна інструкція <name> — Failed' -ForEach @(
			@{ name = 'USE іншої бази'; execute = "USE [master];`nCREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);"; pattern = 'USE \[master\]' }
			@{ name = 'SELECT з таблиці користувача'; execute = "CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);`nSELECT TOP (10) * FROM [dbo].[Orders];"; pattern = 'системних каталогів' }
			@{ name = 'SELECT INTO'; execute = "CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]) WITH (ONLINE = ON);`nSELECT [name] INTO [dbo].[x] FROM [sys].[indexes];"; pattern = 'без INTO' }
		) {
			$validation = Test-Create -Execute $execute -Snapshot $snapshot -Config $config
			$check = Get-TestCheck $validation 'SafeScript'
			$check.status | Should -Be 'Failed'
			$check.message | Should -Match $pattern
		}

		It 'обгортка IF <name> не розгортається — Failed' -ForEach @(
			@{ name = 'з умовою по користувацькій таблиці'; execute = "IF NOT EXISTS (SELECT 1 FROM [dbo].[Orders] WHERE [Amount] > 0) CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]);" }
			@{ name = 'з ELSE'; execute = "IF OBJECT_ID(N'[dbo].[Orders]') IS NULL CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]); ELSE DROP INDEX [IX_Status] ON [dbo].[Orders];" }
			@{ name = 'з EXEC в умові'; execute = "IF NOT EXISTS (SELECT 1 FROM OPENQUERY([lnk], 'SELECT 1')) CREATE NONCLUSTERED INDEX [IX_New] ON [dbo].[Orders] ([Amount]);" }
		) {
			$validation = Test-Create -Execute $execute -Snapshot $snapshot -Config $config
			$check = Get-TestCheck $validation 'SafeScript'
			$check.status | Should -Be 'Failed'
			$check.message | Should -Match 'IfStatement'
		}
	}
}
