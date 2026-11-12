BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'LlmTestHelpers.ps1')
	Register-IaLlmScriptDomMock

	function Get-TestMaskConfig {
		param([bool]$MaskNames)
		$config = Get-IaTestConfig
		$config.llm.maskNames = $MaskNames
		return $config
	}

	function Test-WholeWord {
		param([string]$Text, [string]$Word)
		return $Text -match ('(?<![\w@#$])' + [regex]::Escape($Word) + '(?![\w@#$])')
	}
}

Describe 'Remove-IaSqlLiterals' {
	It 'замінює рядкові, числові, двійкові та дата-літерали плейсхолдерами' {
		$sql = "SELECT o.Id, N'Іван' AS n FROM dbo.Orders AS o WHERE o.CustomerId = 42 AND o.Note = 'it''s' AND o.Created >= '2026-01-01T10:00:00' AND o.Flag = 0x1F AND o.Amount > -12.5 AND o.R = 1e3 AND o.M = `$5 AND o.X = @p"
		$result = InModuleScope IndexAdvisor -Parameters @{ Sql = $sql } { param($Sql) Remove-IaSqlLiterals -Sql $Sql }
		$result | Should -Be "SELECT o.Id, {str} AS n FROM dbo.Orders AS o WHERE o.CustomerId = {num} AND o.Note = {str} AND o.Created >= {date} AND o.Flag = {bin} AND o.Amount > -{num} AND o.R = {num} AND o.M = {num} AND o.X = @p"
	}

	It 'прибирає коментарі, які можуть містити значення' {
		$result = InModuleScope IndexAdvisor { Remove-IaSqlLiterals -Sql "SELECT a FROM t -- клієнт 'Петренко'`nWHERE b = 1 /* рахунок 4411 */;" }
		$result | Should -Not -Match 'Петренко|4411|клієнт|рахунок'
		$result | Should -Match '^SELECT a FROM t\s+WHERE b = \{num\}\s+;$'
	}

	It 'повертає порожні значення без змін' {
		InModuleScope IndexAdvisor { Remove-IaSqlLiterals -Sql '' } | Should -Be ''
		InModuleScope IndexAdvisor { Remove-IaSqlLiterals -Sql $null } | Should -BeNullOrEmpty
	}

	It 'без ScriptDom очищує резервним способом, зокрема незакритий рядок' {
		Mock -ModuleName IndexAdvisor Get-IaScriptDomParser { throw [System.NotImplementedException]::new('stub') }
		$result = InModuleScope IndexAdvisor { Remove-IaSqlLiterals -Sql "SELECT [Col1], x FROM t WHERE a = 'secret value' AND b = 0xFF AND c = 77 AND d = N'незакри" }
		$result | Should -Be 'SELECT [Col1], x FROM t WHERE a = {str} AND b = {bin} AND c = {num} AND d = {str}'
	}

	It 'текст, який лексер не розбирає, очищується резервним способом' {
		$result = InModuleScope IndexAdvisor { Remove-IaSqlLiterals -Sql "SELECT a FROM t WHERE b = ? AND c = 'value-1' AND d = 15" }
		$result | Should -Not -Match 'value-1|15'
	}
}

Describe 'ConvertTo-IaMaskedObject без маскування імен' {
	It 'очищує лише літерали в текстах запитів, позначає masking і не змінює оригінал' {
		$snapshot = Get-IaTestSnapshot
		$map = InModuleScope IndexAdvisor { New-IaMaskingMap }
		$masked = InModuleScope IndexAdvisor -Parameters @{ Snapshot = $snapshot; Map = $map; Config = (Get-TestMaskConfig -MaskNames $false) } {
			param($Snapshot, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Snapshot -Map $Map -Config $Config
		}
		$query = $masked.instances[0].databases[0].queryStoreQueries[0]
		$query.queryText | Should -Be 'SELECT o.OrderId, o.Amount FROM dbo.Orders AS o WHERE o.CustomerId = @customerId AND o.OrderDate >= {date}'
		$masked.instances[0].databases[0].tables[1].name | Should -Be 'Orders'
		$masked.masking.namesMasked | Should -BeFalse
		$masked.masking.literalsMasked | Should -BeTrue
		$map.names.Count | Should -Be 0
		$snapshot.instances[0].databases[0].queryStoreQueries[0].queryText | Should -Match "'2026-10-01'"
		$snapshot.masking.literalsMasked | Should -BeFalse
	}
}

Describe 'ConvertTo-IaMaskedObject: XML плану виконання' {
	It 'очищує літерали в StatementText, ScalarString і значеннях параметрів навіть без маскування імен' {
		$xml = '<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><Statements><StmtSimple StatementText="SELECT * FROM dbo.Orders WHERE Status = 5 AND Comment = N&apos;VIP клієнт&apos;" StatementSubTreeCost="0.5"><QueryPlan><RelOp EstimateRows="1000"><Predicate><ScalarOperator ScalarString="[Sales].[dbo].[Orders].[Status]=(5)"><Const ConstValue="(5)" /></ScalarOperator></Predicate></RelOp><ParameterList><ColumnReference Column="@p1" ParameterCompiledValue="N''Петренко''" ParameterRuntimeValue="(4411)" /></ParameterList></QueryPlan></StmtSimple></Statements></ShowPlanXML>'
		$row = [ordered]@{ planId = 1; queryPlanXml = $xml }
		$plain = InModuleScope IndexAdvisor -Parameters @{ Row = $row; Map = (& (Get-Module IndexAdvisor) { New-IaMaskingMap }); Config = (Get-TestMaskConfig -MaskNames $false) } {
			param($Row, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Row -Map $Map -Config $Config
		}
		$plain.queryPlanXml | Should -Not -Match 'VIP|Петренко|4411|=\(5\)|ConstValue="\(5\)"'
		$plain.queryPlanXml | Should -Match 'ParameterRuntimeValue="\(\{num\}\)"'
		$plain.queryPlanXml | Should -Match 'EstimateRows="1000"'
		$plain.queryPlanXml | Should -Match '\[Orders\]'
		([xml]$plain.queryPlanXml).ShowPlanXML | Should -Not -BeNullOrEmpty

		$map = InModuleScope IndexAdvisor { New-IaMaskingMap }
		$map.names['Orders'] = 'tbl1'; $map.reverse['tbl1'] = 'Orders'
		$masked = InModuleScope IndexAdvisor -Parameters @{ Row = $row; Map = $map; Config = (Get-TestMaskConfig -MaskNames $true) } {
			param($Row, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Row -Map $Map -Config $Config
		}
		$masked.queryPlanXml | Should -Not -Match 'Orders'
		$masked.queryPlanXml | Should -Match '\[tbl1\]'
	}
}

Describe 'ConvertTo-IaMaskedObject з маскуванням імен (llm.maskNames)' {
	BeforeAll {
		$script:Snapshot = Get-IaTestSnapshot
		$script:Map = InModuleScope IndexAdvisor { New-IaMaskingMap }
		$script:Masked = InModuleScope IndexAdvisor -Parameters @{ Snapshot = $script:Snapshot; Map = $script:Map; Config = (Get-TestMaskConfig -MaskNames $true) } {
			param($Snapshot, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Snapshot -Map $Map -Config $Config
		}
		$script:Json = ConvertTo-Json -InputObject $script:Masked -Depth 50
	}

	It 'видає послідовні псевдоніми за категоріями' {
		foreach ($alias in @('srv1', 'db1', 'sch1', 'tbl1', 'col1', 'ix1', 'fk1', 'mod1')) {
			$script:Map.reverse.Contains($alias) | Should -BeTrue -Because "очікується псевдонім $alias"
		}
		$script:Map.names['Sales'] | Should -Be 'db1'
		$script:Map.names['dbo'] | Should -Be 'sch1'
		$script:Map.names['Orders'] | Should -Match '^tbl\d+$'
		$script:Map.names['OrderDate'] | Should -Match '^col\d+$'
		$script:Map.names['IX_Status'] | Should -Match '^ix\d+$'
		$script:Map.names['FK_Orders_Customers'] | Should -Match '^fk\d+$'
		$script:Map.names['usp_GetOrdersByCustomer'] | Should -Match '^mod\d+$'
		$script:Map.names['AG1'] | Should -Match '^srv\d+$'
		$script:Map.names['SQL02'] | Should -Match '^srv\d+$'
		$script:Map.counters['db'] | Should -Be 1
	}

	It 'маскує імена в структурі й у текстах запитів (за токенами ScriptDom)' {
		$database = $script:Masked.instances[0].databases[0]
		$orders = $script:Map.names['Orders']
		$database.name | Should -Be 'db1'
		$database.availabilityGroup | Should -Be $script:Map.names['AG1']
		$database.tables[1].name | Should -Be $orders
		$database.tables[1].columns[0].name | Should -Be $script:Map.names['OrderId']
		$database.tables[1].indexes[3].keyColumns[0].name | Should -Be $script:Map.names[$script:Snapshot.instances[0].databases[0].tables[1].indexes[3].keyColumns[0].name]
		$database.moduleHints[0].moduleName | Should -Be ('sch1.' + $script:Map.names['usp_GetOrdersByCustomer'])
		$database.moduleHints[0].hintText | Should -Be ('WITH (INDEX(' + $script:Map.names['IX_CustomerId'] + '))')
		$database.queryStoreQueries[1].queryText | Should -Be ("SELECT CAST(o.{0} AS date) AS d, SUM(o.{1}) FROM sch1.{2} AS o WHERE o.{0} >= @from GROUP BY CAST(o.{0} AS date)" -f $script:Map.names['OrderDate'], $script:Map.names['Amount'], $orders)
		$script:Masked.masking.namesMasked | Should -BeTrue
		$script:Masked.masking.literalsMasked | Should -BeTrue
	}

	It 'у результаті немає справжніх імен і літералів' {
		foreach ($word in @('Orders', 'Customers', 'Sales', 'dbo', 'IX_Status', 'IX_CustomerId', 'PK_Orders', 'OrderDate', 'CustomerId', 'Amount', 'SQL01', 'SQL02', 'AG1',
				'AGL-SALES', 'usp_GetOrdersByCustomer', 'usp_DailyRevenue', 'FK_Orders_Customers', '2026-10-01')) {
			Test-WholeWord -Text $script:Json -Word $word | Should -BeFalse -Because "'$word' не повинно потрапити в модель"
		}
	}

	It 'маскований snapshot відповідає схемі snapshot' {
		Test-IaJsonAgainstSchema -Json $script:Json -Schema 'snapshot' | Should -BeTrue
	}

	It 'повторне маскування з тією самою мапою дає ті самі псевдоніми' {
		$count = $script:Map.names.Count
		$finding = [ordered]@{
			target = [ordered]@{ server = 'AG1'; database = 'Sales'; schema = 'dbo'; table = 'Orders'; index = 'IX_Status'; objectKey = 'ag1|sales|dbo.orders|ix_status' }
			relatedIndexes = @('IX_Comment')
			message = 'Індекс IX_Status на dbo.Orders не використовується'
			severity = 'Medium'
		}
		$masked = InModuleScope IndexAdvisor -Parameters @{ Finding = $finding; Map = $script:Map; Config = (Get-TestMaskConfig -MaskNames $true) } {
			param($Finding, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Finding -Map $Map -Config $Config
		}
		$masked.target.table | Should -Be $script:Map.names['Orders']
		$masked.target.objectKey | Should -Be ('{0}|db1|sch1.{1}|{2}' -f $script:Map.names['AG1'], $script:Map.names['Orders'], $script:Map.names['IX_Status'])
		$masked.relatedIndexes[0] | Should -Be $script:Map.names['IX_Comment']
		$masked.message | Should -Be ('Індекс {0} на sch1.{1} не використовується' -f $script:Map.names['IX_Status'], $script:Map.names['Orders'])
		$masked.severity | Should -Be 'Medium'
		$script:Map.names.Count | Should -Be $count
	}

	It 'результат дозапиту: назви колонок результату не маскуються, значення — так, SQL-тексти очищуються' {
		$envelope = [ordered]@{
			success = $true
			columns = @([ordered]@{ name = 'index_name'; type = 'nvarchar' }, [ordered]@{ name = 'query_sql_text'; type = 'nvarchar' })
			rows = @([ordered]@{ index_name = 'IX_Status'; query_sql_text = "SELECT * FROM dbo.Orders WHERE Status = 5 AND Comment = N'VIP'" })
		}
		$masked = InModuleScope IndexAdvisor -Parameters @{ Envelope = $envelope; Map = $script:Map; Config = (Get-TestMaskConfig -MaskNames $true) } {
			param($Envelope, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Envelope -Map $Map -Config $Config
		}
		$masked.columns[0].name | Should -Be 'index_name'
		$masked.rows[0].index_name | Should -Be $script:Map.names['IX_Status']
		$masked.rows[0].query_sql_text | Should -Be ('SELECT * FROM sch1.{0} WHERE {1} = {{num}} AND {2} = {{str}}' -f $script:Map.names['Orders'], $script:Map.names['Status'], $script:Map.names['Comment'])
	}

	It 'рядки результату декларативного інструмента: імена, списки колонок через кому, queryText; зворотне розмаскування' {
		$envelope = [ordered]@{
			success = $true
			server = 'AG1'
			database = 'Sales'
			columns = @(
				[ordered]@{ name = 'schemaName'; type = 'sysname' }, [ordered]@{ name = 'tableName'; type = 'sysname' }, [ordered]@{ name = 'indexName'; type = 'sysname' },
				[ordered]@{ name = 'moduleName'; type = 'nvarchar' }, [ordered]@{ name = 'keyColumns'; type = 'nvarchar' }, [ordered]@{ name = 'includedColumns'; type = 'nvarchar' },
				[ordered]@{ name = 'seekColumns'; type = 'nvarchar' }, [ordered]@{ name = 'queryText'; type = 'nvarchar' }
			)
			rows = @(
				[ordered]@{
					schemaName = 'dbo'; tableName = 'Orders'; indexName = 'IX_CustomerId_OrderDate_INC'; moduleName = 'dbo.usp_DailyRevenue'
					keyColumns = 'CustomerId, OrderDate DESC'; includedColumns = '[Amount],[Status]'; seekColumns = 'CustomerId'
					queryText = "SELECT o.Amount FROM dbo.Orders AS o WHERE o.CustomerId = 42 AND o.Status = N'Нове'"
				}
				[ordered]@{
					schemaName = 'billing'; tableName = 'Invoices'; indexName = 'IX_InvoiceDate'; moduleName = $null
					keyColumns = '[InvoiceDate] ASC'; includedColumns = 'Total, Customer Ref'; seekColumns = ''
					queryText = "SELECT Total FROM billing.Invoices WHERE InvoiceDate >= '2026-01-01'"
				}
			)
		}
		$masked = InModuleScope IndexAdvisor -Parameters @{ Envelope = $envelope; Map = $script:Map; Config = (Get-TestMaskConfig -MaskNames $true) } {
			param($Envelope, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Envelope -Map $Map -Config $Config
		}
		$alias = $script:Map.names
		$first = $masked.rows[0]
		$first.schemaName | Should -Be 'sch1'
		$first.tableName | Should -Be $alias['Orders']
		$first.indexName | Should -Be $alias['IX_CustomerId_OrderDate_INC']
		$first.moduleName | Should -Be ('sch1.' + $alias['usp_DailyRevenue'])
		$first.keyColumns | Should -Be ('{0}, {1} DESC' -f $alias['CustomerId'], $alias['OrderDate'])
		$first.includedColumns | Should -Be ('[{0}],[{1}]' -f $alias['Amount'], $alias['Status'])
		$first.seekColumns | Should -Be $alias['CustomerId']
		$first.queryText | Should -Be ('SELECT o.{0} FROM sch1.{1} AS o WHERE o.{2} = {{num}} AND o.{3} = {{str}}' -f $alias['Amount'], $alias['Orders'], $alias['CustomerId'], $alias['Status'])
		$masked.columns[4].name | Should -Be 'keyColumns'
		$masked.server | Should -Be $alias['AG1']
		# Нові імена, яких немає в snapshot, реєструються з рядків результату.
		$second = $masked.rows[1]
		$second.schemaName | Should -Match '^sch\d+$'
		$second.tableName | Should -Match '^tbl\d+$'
		$second.indexName | Should -Match '^ix\d+$'
		$second.keyColumns | Should -Match '^\[col\d+\] ASC$'
		$second.includedColumns | Should -Match '^col\d+, col\d+$'
		$json = ConvertTo-Json -InputObject $masked -Depth 10
		foreach ($word in @('dbo', 'Orders', 'billing', 'Invoices', 'InvoiceDate', 'Total', 'Customer Ref', 'IX_InvoiceDate', 'usp_DailyRevenue', 'Нове', '42', '2026-01-01')) {
			Test-WholeWord -Text $json -Word $word | Should -BeFalse -Because "'$word' не повинно потрапити в модель"
		}
		$restored = InModuleScope IndexAdvisor -Parameters @{ Masked = $masked; Map = $script:Map } { param($Masked, $Map) ConvertFrom-IaMaskedObject -InputObject $Masked -Map $Map }
		$restored.rows[0].tableName | Should -Be 'Orders'
		$restored.rows[0].moduleName | Should -Be 'dbo.usp_DailyRevenue'
		$restored.rows[0].keyColumns | Should -Be 'CustomerId, OrderDate DESC'
		$restored.rows[0].includedColumns | Should -Be '[Amount],[Status]'
		$restored.rows[1].schemaName | Should -Be 'billing'
		$restored.rows[1].keyColumns | Should -Be '[InvoiceDate] ASC'
		$restored.rows[1].includedColumns | Should -Be 'Total, Customer Ref'
		$restored.rows[1].queryText | Should -Be 'SELECT Total FROM billing.Invoices WHERE InvoiceDate >= {date}'
	}
}

Describe 'ConvertFrom-IaMaskedObject' {
	BeforeAll {
		$script:Snapshot = Get-IaTestSnapshot
		$script:Map = InModuleScope IndexAdvisor { New-IaMaskingMap }
		$script:Masked = InModuleScope IndexAdvisor -Parameters @{ Snapshot = $script:Snapshot; Map = $script:Map; Config = (Get-TestMaskConfig -MaskNames $true) } {
			param($Snapshot, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Snapshot -Map $Map -Config $Config
		}
		$script:Alias = $script:Map.names
	}

	It 'повертає справжні імена в об''єктах і T-SQL рекомендації' {
		$draft = [ordered]@{
			action = 'CreateIndex'
			target = [ordered]@{ server = $script:Alias['AG1']; database = 'db1'; schema = 'sch1'; table = $script:Alias['Orders']; index = ('IX_{0}_INC' -f $script:Alias['OrderDate']) }
			title = ('Індекс за {0}' -f $script:Alias['OrderDate'])
			rationale = ('Запит сканує {0}; замінює {1}.' -f $script:Alias['PK_Orders'], $script:Alias['IX_CustomerId'])
			executeScript = ("CREATE NONCLUSTERED INDEX [IX_{0}_INC] ON [sch1].{1} ({0} DESC) INCLUDE ([{2}]) WITH (ONLINE = ON, RESUMABLE = ON);" -f $script:Alias['OrderDate'], $script:Alias['Orders'], $script:Alias['Amount'])
			rollbackScript = ("IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_{0}_INC' AND object_id = OBJECT_ID(N'sch1.{1}')) DROP INDEX [IX_{0}_INC] ON [sch1].[{1}];" -f $script:Alias['OrderDate'], $script:Alias['Orders'])
			replacesIndexes = @($script:Alias['IX_CustomerId'])
		}
		$real = InModuleScope IndexAdvisor -Parameters @{ Draft = $draft; Map = $script:Map } { param($Draft, $Map) ConvertFrom-IaMaskedObject -InputObject $Draft -Map $Map }
		$real.target.server | Should -Be 'AG1'
		$real.target.database | Should -Be 'Sales'
		$real.target.schema | Should -Be 'dbo'
		$real.target.table | Should -Be 'Orders'
		$real.target.index | Should -Be 'IX_OrderDate_INC'
		$real.title | Should -Be 'Індекс за OrderDate'
		$real.rationale | Should -Be 'Запит сканує PK_Orders; замінює IX_CustomerId.'
		$real.executeScript | Should -Be 'CREATE NONCLUSTERED INDEX [IX_OrderDate_INC] ON [dbo].Orders (OrderDate DESC) INCLUDE ([Amount]) WITH (ONLINE = ON, RESUMABLE = ON);'
		$real.rollbackScript | Should -Be "IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OrderDate_INC' AND object_id = OBJECT_ID(N'dbo.Orders')) DROP INDEX [IX_OrderDate_INC] ON [dbo].[Orders];"
		$real.replacesIndexes | Should -Be @('IX_CustomerId')
	}

	It 'бере ім''я в дужки, якщо воно не є звичайним ідентифікатором, і подвоює лапки в рядках' {
		$map = InModuleScope IndexAdvisor { New-IaMaskingMap }
		$map.names['Order Details'] = 'tbl1'; $map.reverse['tbl1'] = 'Order Details'
		$map.names['Key'] = 'col1'; $map.reverse['col1'] = 'Key'
		$map.names["O'Brien"] = 'sch1'; $map.reverse['sch1'] = "O'Brien"
		$item = [ordered]@{ executeScript = "CREATE INDEX IX_col1 ON sch1.tbl1 (col1); SELECT OBJECT_ID(N'sch1.tbl1');" }
		$real = InModuleScope IndexAdvisor -Parameters @{ Item = $item; Map = $map } { param($Item, $Map) ConvertFrom-IaMaskedObject -InputObject $Item -Map $Map }
		$real.executeScript | Should -Be "CREATE INDEX IX_Key ON [O'Brien].[Order Details] ([Key]); SELECT OBJECT_ID(N'O''Brien.Order Details');"
	}

	It 'повне повернення snapshot: імена такі самі, як в оригіналі' {
		$restored = InModuleScope IndexAdvisor -Parameters @{ Masked = $script:Masked; Map = $script:Map } { param($Masked, $Map) ConvertFrom-IaMaskedObject -InputObject $Masked -Map $Map }
		$original = $script:Snapshot.instances[0].databases[0]
		$back = $restored.instances[0].databases[0]
		$back.name | Should -Be $original.name
		$restored.requestedServer | Should -Be $script:Snapshot.requestedServer
		@($back.tables | ForEach-Object { $_.name }) | Should -Be @($original.tables | ForEach-Object { $_.name })
		@($back.tables[1].indexes | ForEach-Object { $_.name }) | Should -Be @($original.tables[1].indexes | ForEach-Object { $_.name })
		@($back.tables[1].columns | ForEach-Object { $_.name }) | Should -Be @($original.tables[1].columns | ForEach-Object { $_.name })
		$back.moduleHints[0].moduleName | Should -Be $original.moduleHints[0].moduleName
		$back.queryStoreQueries[2].queryText | Should -Be 'SELECT o.OrderId, o.Status FROM dbo.Orders AS o WITH (INDEX(IX_CustomerId)) WHERE o.CustomerId = @CustomerId'
	}

	It 'без псевдонімів у мапі повертає глибоку копію' {
		$item = [ordered]@{ a = @('x', 'tbl1'); b = [ordered]@{ c = 'srv1' } }
		$copy = InModuleScope IndexAdvisor -Parameters @{ Item = $item } { param($Item) ConvertFrom-IaMaskedObject -InputObject $Item -Map (New-IaMaskingMap) }
		$copy.a | Should -Be @('x', 'tbl1')
		$copy.b.c | Should -Be 'srv1'
		[object]::ReferenceEquals($copy.b, $item.b) | Should -BeFalse
	}
}
