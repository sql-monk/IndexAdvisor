# Юніт-тести розбору XML showplan і евристик Query Store (потік Collector).
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:Module = Get-Module IndexAdvisor
	$script:FixturesPath = Join-Path $PSScriptRoot 'Fixtures'
	function ConvertFrom-ColTestPlan {
		param([string]$Xml, [string]$Database = 'Sales')
		& $script:Module { param($x, $d) ConvertFrom-IaColShowplan -PlanXml $x -DefaultDatabase $d } $Xml $Database
	}
	function Get-ColTestPlanFixture {
		param([string]$Name)
		Get-Content -LiteralPath (Join-Path $script:FixturesPath $Name) -Raw -Encoding utf8
	}
}

Describe 'ConvertFrom-IaColShowplan' {
	Context 'OLTP-план: seek з хінтом, key lookup, missing index, неявна конверсія' {
		BeforeAll {
			$script:Plan = ConvertFrom-ColTestPlan -Xml (Get-ColTestPlanFixture 'plan_oltp_lookup.xml')
		}

		It 'визначає операції з індексами (seek, lookup, scan) без тимчасових таблиць' {
			$script:Plan.parseError | Should -BeNullOrEmpty
			$operations = @($script:Plan.indexOperations | ForEach-Object { '{0}.{1}.{2}:{3}' -f $_.schema, $_.table, $_.index, $_.operation })
			$operations | Should -Be @('dbo.Customers.PK_Customers:Scan', 'dbo.Orders.IX_CustomerId:Seek', 'dbo.Orders.PK_Orders:Lookup')
			@($script:Plan.indexOperations.database | Sort-Object -Unique) | Should -Be @('Sales')
		}

		It 'позначає індексний хінт (ForcedIndex) і режим виконання' {
			$seek = $script:Plan.indexOperations | Where-Object operation -EQ 'Seek'
			$seek.isHinted | Should -BeTrue
			$seek.executionMode | Should -Be 'Row'
			($script:Plan.indexOperations | Where-Object operation -EQ 'Lookup').isHinted | Should -BeFalse
		}

		It 'key lookup, неявна конверсія, повне сканування таблиці' {
			$script:Plan.hasKeyLookup | Should -BeTrue
			$script:Plan.hasImplicitConversion | Should -BeTrue
			$script:Plan.usesBatchMode | Should -BeFalse
			$script:Plan.scansWholeTable | Should -BeTrue
			$script:Plan.partitionElimination | Should -Be 'NotApplicable'
			$script:Plan.columnstoreSegmentElimination | Should -Be 'NotApplicable'
		}

		It 'missing index у плані з колонками за типом використання і впливом' {
			@($script:Plan.missingIndexes).Count | Should -Be 1
			$missing = $script:Plan.missingIndexes[0]
			$missing.table | Should -Be 'Orders'
			@($missing.equalityColumns) | Should -Be @('CustomerId')
			@($missing.inequalityColumns) | Should -Be @('OrderDate')
			@($missing.includedColumns) | Should -Be @('Status', 'Comment')
			$missing.impact | Should -Be 85.5
		}

		It 'предикати фільтрації: Eq із seek, Like і Eq із залишкового предиката; ключі з''єднання не потрапляють' {
			$predicates = @($script:Plan.predicates | ForEach-Object { '{0}:{1}' -f $_.column, $_.operator } | Sort-Object)
			$predicates | Should -Be @('Comment:Eq', 'Comment:Like', 'CustomerId:Eq')
			@($script:Plan.predicates.column) | Should -Not -Contain 'OrderId'
		}
	}

	Context 'DWH-план: columnstore, batch mode, partition elimination' {
		BeforeAll {
			$script:Dwh = ConvertFrom-ColTestPlan -Xml (Get-ColTestPlanFixture 'plan_dwh_columnstore.xml') -Database 'DWH'
		}

		It 'batch mode і операція Scan по columnstore' {
			$script:Dwh.usesBatchMode | Should -BeTrue
			$operation = $script:Dwh.indexOperations[0]
			$operation.index | Should -Be 'CCSI'
			$operation.operation | Should -Be 'Scan'
			$operation.executionMode | Should -Be 'Batch'
			$operation.schema | Should -Be 'dw'
		}

		It 'partition elimination за seek по PtnId, сегменти — невідомо з оцінкового плану' {
			$script:Dwh.partitionElimination | Should -Be 'Yes'
			$script:Dwh.columnstoreSegmentElimination | Should -Be 'Unknown'
			$script:Dwh.scansWholeTable | Should -BeFalse
		}

		It 'діапазонний предикат за датою, без службової колонки PtnId' {
			@($script:Dwh.predicates | ForEach-Object { '{0}.{1}:{2}' -f $_.table, $_.column, $_.operator }) | Should -Be @('FactSales.SaleDate:Range')
		}
	}

	Context 'DML-план і невалідний XML' {
		It 'оператори вставки дають операції Update для кожного індексу' {
			$plan = ConvertFrom-ColTestPlan -Xml (Get-ColTestPlanFixture 'plan_insert.xml')
			@($plan.indexOperations | ForEach-Object { '{0}:{1}' -f $_.index, $_.operation }) | Should -Be @('PK_Orders:Update', 'IX_CustomerId:Update')
			$plan.scansWholeTable | Should -BeFalse
		}

		It 'невалідний XML: parseError і запасний розбір посилань на індекси без типу операції' {
			$broken = (Get-ColTestPlanFixture 'plan_oltp_lookup.xml').Substring(0, 5000)
			$plan = ConvertFrom-ColTestPlan -Xml $broken
			$plan.parseError | Should -Not -BeNullOrEmpty
			@($plan.indexOperations.index) | Should -Contain 'PK_Customers'
			@($plan.indexOperations | Where-Object { $null -ne $_.operation }).Count | Should -Be 0
			$plan.partitionElimination | Should -Be 'Unknown'
		}

		It 'не обробляє DTD (захист від XXE)' {
			$xml = '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///c:/windows/win.ini">]><ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan">&e;</ShowPlanXML>'
			$plan = ConvertFrom-ColTestPlan -Xml $xml
			$plan.parseError | Should -Not -BeNullOrEmpty
		}
	}
}

Describe 'Евристики Query Store' {
	It 'категорія навантаження: <Expected>' -ForEach @(
		@{ Text = 'INSERT BULK dbo.Stage (a int)'; Object = $null; Executions = 5; Reads = 10; Param = $false; Expected = 'Etl' }
		@{ Text = 'MERGE dbo.Target AS t USING dbo.Source AS s ON t.Id = s.Id WHEN MATCHED THEN UPDATE SET t.A = s.A;'; Object = $null; Executions = 30; Reads = 50; Param = $false; Expected = 'Etl' }
		@{ Text = 'SELECT * INTO #t FROM dbo.Orders'; Object = $null; Executions = 30; Reads = 500; Param = $false; Expected = 'Etl' }
		@{ Text = 'SELECT a FROM dbo.Src'; Object = 'etl.usp_LoadOrders'; Executions = 30; Reads = 500; Param = $false; Expected = 'Etl' }
		@{ Text = 'SELECT StoreId, SUM(Amount) FROM dbo.Sales GROUP BY StoreId'; Object = $null; Executions = 50; Reads = 250000; Param = $false; Expected = 'Report' }
		@{ Text = 'SELECT a FROM dbo.T'; Object = 'rpt.usp_Daily'; Executions = 50; Reads = 10; Param = $false; Expected = 'Report' }
		@{ Text = 'SELECT a FROM dbo.T WHERE b = 5'; Object = $null; Executions = 2; Reads = 300; Param = $false; Expected = 'AdHoc' }
		@{ Text = '(@id int)SELECT a FROM dbo.T WHERE id = @id'; Object = $null; Executions = 100000; Reads = 4; Param = $true; Expected = 'Oltp' }
		@{ Text = 'SELECT a FROM dbo.T WHERE b = 5'; Object = $null; Executions = 50; Reads = 50000; Param = $false; Expected = 'Unknown' }
	) {
		$category = & $script:Module {
			param($t, $o, $e, $r, $p)
			Get-IaColWorkloadCategory -QueryText $t -ObjectName $o -ExecutionCount $e -AvgLogicalReads $r -IsParameterized $p
		} $Text $Object $Executions $Reads $Param
		$category | Should -Be $Expected
	}

	It 'регресія плану: останній план удвічі повільніший за найкращий' {
		$result = & $script:Module {
			Test-IaColPlanRegression -Plans @(
				[ordered]@{ planId = 1; executionCount = 10; avgDurationMs = 5.0; lastExecutionUtc = '2026-10-01T00:00:00.000Z' }
				[ordered]@{ planId = 2; executionCount = 10; avgDurationMs = 11.0; lastExecutionUtc = '2026-11-01T00:00:00.000Z' }
			)
		}
		$result | Should -BeTrue
		$single = & $script:Module { Test-IaColPlanRegression -Plans @([ordered]@{ planId = 1; executionCount = 10; avgDurationMs = 5.0; lastExecutionUtc = '2026-10-01T00:00:00.000Z' }) }
		$single | Should -BeFalse
	}

	It 'хінти індексів у тексті: INDEX(a, b), INDEX = c, FORCESEEK(d(...)), без CHARINDEX і числових id' {
		$text = 'SELECT CHARINDEX(''x'', a) FROM t WITH (INDEX([IX_A], IX_B)) JOIN u WITH (INDEX = IX_C) ON 1 = 1 JOIN v WITH (FORCESEEK(IX_D (Col))) ON 1 = 1 JOIN w WITH (INDEX(1)) ON 1 = 1'
		$names = & $script:Module { param($t) Get-IaColHintMatches -Text $t } $text | ForEach-Object { $_.name }
		@($names | Sort-Object) | Should -Be @('IX_A', 'IX_B', 'IX_C', 'IX_D')
	}
}

Describe 'Get-IaDatasetSelection' {
	It 'за замовчуванням усі набори ввімкнені без попереджень' {
		$selection = & $script:Module { Get-IaDatasetSelection -Config (Get-IaDefaultConfig) }
		@($selection.enabled).Count | Should -Be 8
		@($selection.disabled).Count | Should -Be 0
		@($selection.warnings).Count | Should -Be 0
	}

	It 'вимкнений набір — у disabled з попередженням про зниження достовірності' -ForEach @(
		@{ Name = 'usageStats'; Pattern = 'usage_stats' }
		@{ Name = 'operationalStats'; Pattern = 'пом''якшені правила' }
		@{ Name = 'sizeAndFragmentation'; Pattern = 'фрагментац' }
		@{ Name = 'missingIndexes'; Pattern = 'Query Store' }
		@{ Name = 'queryStore'; Pattern = 'не використовувався за період' }
		@{ Name = 'constraintsAndReplication'; Pattern = '4\.4' }
	) {
		$config = & $script:Module { Get-IaDefaultConfig }
		$config.collector.datasets[$Name] = $false
		$selection = & $script:Module { param($c) Get-IaDatasetSelection -Config $c } $config
		@($selection.disabled) | Should -Be @($Name)
		@($selection.enabled) | Should -Not -Contain $Name
		$warning = @($selection.warnings)[0]
		$warning.dataset | Should -Be $Name
		$warning.code | Should -Be 'DatasetDisabled'
		$warning.message | Should -Match $Pattern
	}

	It 'обов''язкові набори не вимикаються, але дають попередження' {
		$config = & $script:Module { Get-IaDefaultConfig }
		$config.collector.datasets.indexStructure = $false
		$config.collector.datasets.instanceStartTime = $false
		$selection = & $script:Module { param($c) Get-IaDatasetSelection -Config $c } $config
		@($selection.enabled) | Should -Contain 'indexStructure'
		@($selection.enabled) | Should -Contain 'instanceStartTime'
		@($selection.warnings.code) | Should -Be @('MandatoryDatasetForced', 'MandatoryDatasetForced')
	}
}

Describe 'Scope' {
	It 'шаблон <Pattern> для <Value>: <Expected>' -ForEach @(
		@{ Value = 'Sales'; Pattern = 'Sal*'; Expected = $true }
		@{ Value = 'Sales'; Pattern = 's?les'; Expected = $true }
		@{ Value = 'Sales[1]'; Pattern = 'Sales[1]'; Expected = $true }
		@{ Value = 'Sales1'; Pattern = 'Sales[1]'; Expected = $false }
		@{ Value = 'Archive'; Pattern = 'Sal*'; Expected = $false }
	) {
		& $script:Module { param($v, $p) Test-IaColPattern -Value $v -Pattern $p } $Value $Pattern | Should -Be $Expected
	}

	It 'exclude має пріоритет над include, порожній include — усе' {
		& $script:Module { Test-IaColScopeMatch -Value 'Sales' -Include @() -Exclude @() } | Should -BeTrue
		& $script:Module { Test-IaColScopeMatch -Value 'Sales' -Include @('S*') -Exclude @('Sales') } | Should -BeFalse
		& $script:Module { Test-IaColScopeMatch -Value 'Sales' -Include @('Arch*') -Exclude @() } | Should -BeFalse
	}
}
