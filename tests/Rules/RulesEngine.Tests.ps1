BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Rules.TestHelpers.ps1')
	function Invoke-TestEngine {
		param($Snapshot, $Config)
		return , @(InModuleScope IndexAdvisor -Parameters @{ Snapshot = $Snapshot; Config = $Config } { Invoke-IaRulesEngine -Snapshot $Snapshot -Config $Config })
	}
	function Select-TestFinding {
		param($Findings, [string]$RuleId, [string]$Index)
		return , @($Findings | Where-Object { $_.ruleId -eq $RuleId -and $_.target.index -eq $Index })
	}
}

Describe 'Invoke-IaRulesEngine' {
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$config = Get-IaTestConfig
	}

	It 'повертає канонічні знахідки New-IaFinding' {
		$findings = Invoke-TestEngine $snapshot $config
		$findings.Count | Should -BeGreaterThan 0
		foreach ($finding in $findings) {
			$finding.findingId | Should -Not -BeNullOrEmpty
			$finding.severity | Should -BeIn @('Info', 'Low', 'Medium', 'High')
			$finding.target.server | Should -Be 'AG1'
			$finding.target.objectKey | Should -BeLike 'ag1|sales|*'
		}
	}

	It 'DuplicateIndex: IX_CustomerId_OrderDate_0 дублює ключі IX_CustomerId_OrderDate_INC' {
		$findings = Invoke-TestEngine $snapshot $config
		$duplicate = Select-TestFinding $findings 'DuplicateIndex' 'IX_CustomerId_OrderDate_0'
		$duplicate.Count | Should -Be 1
		$duplicate[0].relatedIndexes | Should -Be @('IX_CustomerId_OrderDate_INC')
		$duplicate[0].severity | Should -Be 'High'
		$duplicate[0].suggestedAction | Should -Be 'DropIndex'
		$duplicate[0].details.includesCovered | Should -BeTrue
		($duplicate[0].details.blockers -join ' ') | Should -Match 'NoForeignKeySupport'
		(Select-TestFinding $findings 'DuplicateIndex' 'IX_CustomerId_OrderDate_INC').Count | Should -Be 0
	}

	It 'DuplicateIndex враховує фільтр і вимкнені індекси' {
		$index = Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_CustomerId_OrderDate_0'
		$index.hasFilter = $true
		$index.filterDefinition = '([Status]=(1))'
		(Select-TestFinding (Invoke-TestEngine $snapshot $config) 'DuplicateIndex' 'IX_CustomerId_OrderDate_0').Count | Should -Be 0
		$index.hasFilter = $false
		$index.filterDefinition = $null
		$index.isDisabled = $true
		@((Invoke-TestEngine $snapshot $config) | Where-Object { $_.ruleId -eq 'DuplicateIndex' }).Count | Should -Be 0
	}

	It 'DuplicateIndex: неповне INCLUDE — AlterIndex' {
		$index = Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_CustomerId_OrderDate_0'
		$index.includedColumns = @('Status')
		$duplicate = Select-TestFinding (Invoke-TestEngine $snapshot $config) 'DuplicateIndex' 'IX_CustomerId_OrderDate_0'
		$duplicate.Count | Should -Be 1
		$duplicate[0].suggestedAction | Should -Be 'AlterIndex'
		$duplicate[0].details.missingIncludes | Should -Be @('Status')
	}

	It 'OverlappingIndex: ключі IX_CustomerId — лівий префікс ширших індексів, видалення обмежене хінтами й FK' {
		$overlap = Select-TestFinding (Invoke-TestEngine $snapshot $config) 'OverlappingIndex' 'IX_CustomerId'
		$overlap.Count | Should -Be 1
		$overlap[0].relatedIndexes | Should -Contain 'IX_CustomerId_OrderDate_INC'
		$overlap[0].severity | Should -Be 'Medium'
		($overlap[0].details.blockers -join ' ') | Should -Match 'NoHintReferences'
		($overlap[0].details.blockers -join ' ') | Should -Match 'NoForeignKeySupport'
		$overlap[0].message | Should -Match 'обмежене'
	}

	It 'OverlappingIndex не стосується унікальних індексів і різних фільтрів' {
		$index = Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_CustomerId'
		$index.hasFilter = $true
		$index.filterDefinition = '([Status]=(2))'
		(Select-TestFinding (Invoke-TestEngine $snapshot $config) 'OverlappingIndex' 'IX_CustomerId').Count | Should -Be 0
		$index.hasFilter = $false
		$index.filterDefinition = $null
		$index.isUnique = $true
		(Select-TestFinding (Invoke-TestEngine $snapshot $config) 'OverlappingIndex' 'IX_CustomerId').Count | Should -Be 0
	}

	It 'WriteOnlyIndex: IX_Status — лише оновлення на обох репліках' {
		$writeOnly = Select-TestFinding (Invoke-TestEngine $snapshot $config) 'WriteOnlyIndex' 'IX_Status'
		$writeOnly.Count | Should -Be 1
		$writeOnly[0].severity | Should -Be 'Medium'
		$writeOnly[0].suggestedAction | Should -Be 'DropIndex'
		$writeOnly[0].details.replicas | Should -Be @('SQL01', 'SQL02')
		$writeOnly[0].details.userUpdates | Should -Be 350000
	}

	It 'WriteOnlyIndex для UNIQUE — Info без дії' {
		$writeOnly = Select-TestFinding (Invoke-TestEngine $snapshot $config) 'WriteOnlyIndex' 'UQ_Customers_Email'
		$writeOnly.Count | Should -Be 1
		$writeOnly[0].severity | Should -Be 'Info'
		$writeOnly[0].suggestedAction | Should -Be 'None'
	}

	It 'UnusedIndex: оновлень менше за rules.writeOnlyMinUpdates' {
		(Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Status').usage.userUpdates = 10
		$findings = Invoke-TestEngine $snapshot $config
		(Select-TestFinding $findings 'UnusedIndex' 'IX_Status').Count | Should -Be 1
		(Select-TestFinding $findings 'WriteOnlyIndex' 'IX_Status').Count | Should -Be 0
	}

	It 'читання на вторинній репліці чи в планах Query Store — індекс використовується' {
		(Find-IaRuleTestIndex -Snapshot $snapshot -Server 'SQL02' -Index 'IX_Status').usage.userSeeks = 5
		(Select-TestFinding (Invoke-TestEngine $snapshot $config) 'WriteOnlyIndex' 'IX_Status').Count | Should -Be 0
		$snapshot = Get-IaTestSnapshot
		(Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Status').queryStoreUsage.planCount = 1
		(Select-TestFinding (Invoke-TestEngine $snapshot $config) 'WriteOnlyIndex' 'IX_Status').Count | Should -Be 0
	}

	It 'без usageStats висновків про використання немає' {
		foreach ($instance in $snapshot.instances) {
			foreach ($table in $instance.databases[0].tables) {
				foreach ($index in $table.indexes) { $index.usage = $null }
			}
		}
		$findings = Invoke-TestEngine $snapshot $config
		@($findings | Where-Object { $_.ruleId -in @('UnusedIndex', 'WriteOnlyIndex', 'ExpensiveIndex') }).Count | Should -Be 0
	}

	It 'ExpensiveIndex: IX_Comment — блокування й латчі, читання підсумовано по репліках' {
		$expensive = Select-TestFinding (Invoke-TestEngine $snapshot $config) 'ExpensiveIndex' 'IX_Comment'
		$expensive.Count | Should -Be 1
		$expensive[0].details.reads | Should -Be 15
		($expensive[0].details.reasons -join ' ') | Should -Match 'блокуваннях'
		($expensive[0].details.reasons -join ' ') | Should -Match 'латчах'
		$expensive[0].details.relaxedRulesApply | Should -BeTrue
	}

	It 'TooManyIndexes: поріг rules.maxIndexesPerTable, вимкнені не рахуються' {
		$config.rules.maxIndexesPerTable = 5
		$tooMany = @((Invoke-TestEngine $snapshot $config) | Where-Object { $_.ruleId -eq 'TooManyIndexes' })
		$tooMany.Count | Should -Be 1
		$tooMany[0].target.table | Should -Be 'Orders'
		$tooMany[0].target.index | Should -BeNullOrEmpty
		$tooMany[0].details.indexCount | Should -Be 6
		(Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Comment').isDisabled = $true
		@((Invoke-TestEngine $snapshot $config) | Where-Object { $_.ruleId -eq 'TooManyIndexes' }).Count | Should -Be 0
	}

	It 'Fragmentation: REBUILD і REORGANIZE за порогами rules.fragmentation' {
		$findings = Invoke-TestEngine $snapshot $config
		$comment = Select-TestFinding $findings 'Fragmentation' 'IX_Comment'
		$comment[0].details.recommendedOperation | Should -Be 'REBUILD'
		$comment[0].severity | Should -Be 'Medium'
		(Select-TestFinding $findings 'Fragmentation' 'IX_CustomerId_OrderDate_INC')[0].details.recommendedOperation | Should -Be 'REORGANIZE'
		(Select-TestFinding $findings 'Fragmentation' 'PK_Orders').Count | Should -Be 0
		(Select-TestFinding $findings 'Fragmentation' 'UQ_Customers_Email').Count | Should -Be 1
		$config.rules.fragmentation.minPageCount = 2000
		(Select-TestFinding (Invoke-TestEngine $snapshot $config) 'Fragmentation' 'UQ_Customers_Email').Count | Should -Be 0
	}

	It 'Fragmentation пропускає skipped і columnstore; купа не ламає аналіз' {
		(Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Comment').physical.skipped = $true
		$orders = $snapshot.instances[0].databases[0].tables | Where-Object { $_.name -eq 'Orders' }
		$columnstore = Copy-IaTestObject (Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Status')
		$columnstore.name = 'CS_Status'
		$columnstore.indexId = 7
		$columnstore.typeDesc = 'NONCLUSTERED COLUMNSTORE'
		$columnstore.physical.avgFragmentationPercent = 90
		$orders.indexes = @($orders.indexes) + @($columnstore)
		$customers = $snapshot.instances[0].databases[0].tables | Where-Object { $_.name -eq 'Customers' }
		$heap = Copy-IaTestObject $customers.indexes[1]
		$heap.name = $null
		$heap.indexId = 0
		$heap.typeDesc = 'HEAP'
		$customers.indexes = @($heap) + @($customers.indexes)
		$findings = Invoke-TestEngine $snapshot $config
		(Select-TestFinding $findings 'Fragmentation' 'IX_Comment').Count | Should -Be 0
		(Select-TestFinding $findings 'Fragmentation' 'CS_Status').Count | Should -Be 0
		(Select-TestFinding $findings 'DuplicateIndex' 'CS_Status').Count | Should -Be 0
		@($findings | Where-Object { $null -eq $_.target.index -and $_.ruleId -ne 'TooManyIndexes' }).Count | Should -Be 0
	}

	It 'MissingIndexCandidate: злитий кандидат з оцінкою' {
		$missing = @((Invoke-TestEngine $snapshot $config) | Where-Object { $_.ruleId -eq 'MissingIndexCandidate' })
		$missing.Count | Should -Be 1
		$missing[0].target.index | Should -Be 'IX_OrderDate_INC'
		$missing[0].suggestedAction | Should -Be 'CreateIndex'
		$missing[0].details.keyColumns | Should -Be @('OrderDate')
		$missing[0].details.includedColumns | Should -Be @('Amount', 'Status')
		$missing[0].details.sourceIndexHandles | Should -Be @(11, 13)
		$missing[0].details.estimate.estimatedSizeMb | Should -BeGreaterThan 0
	}
}

Describe 'Test-IaExpensiveIndex' {
	BeforeAll {
		function Test-Expensive {
			param($Index, $Config)
			return InModuleScope IndexAdvisor -Parameters @{ Index = $Index; Config = $Config } { Test-IaExpensiveIndex -Index $Index -Config $Config }
		}
	}
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$config = Get-IaTestConfig
	}

	It 'IX_Comment — «дорогий»: очікування, записи значно переважають, читань мало' {
		$result = Test-Expensive (Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Comment') $config
		$result.isExpensive | Should -BeTrue
		$result.reasons.Count | Should -Be 4
	}

	It 'PK_Orders — не «дорогий»: читань багато' {
		(Test-Expensive (Find-IaRuleTestIndex -Snapshot $snapshot -Index 'PK_Orders') $config).isExpensive | Should -BeFalse
	}

	It 'без usage — не «дорогий»' {
		$index = Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Comment'
		$index.usage = $null
		(Test-Expensive $index $config).isExpensive | Should -BeFalse
	}

	It 'лише латчі за малої кількості читань — «дорогий»; читань більше за maxReads — ні' {
		$index = [ordered]@{
			usage = [ordered]@{ userSeeks = 5; userScans = 0; userLookups = 0; userUpdates = 0 }
			operational = [ordered]@{ rowLockWaitMs = 0; pageLockWaitMs = 0; pageLatchWaitMs = 70000; pageIoLatchWaitMs = 0 }
		}
		$result = Test-Expensive $index $config
		$result.isExpensive | Should -BeTrue
		($result.reasons -join ' ') | Should -Match 'латчах'
		$index.usage.userSeeks = 5000
		(Test-Expensive $index $config).isExpensive | Should -BeFalse
	}

	It 'без operationalStats «дорогий» визначається лише за співвідношенням записів і читань' {
		$index = [ordered]@{
			usage = [ordered]@{ userSeeks = 5; userScans = 0; userLookups = 0; userUpdates = 50000 }
			operational = $null
		}
		$result = Test-Expensive $index $config
		$result.isExpensive | Should -BeTrue
		($result.reasons -join ' ') | Should -Match 'оновлень 50000 значно більше за читання 5'
		($result.reasons -join ' ') | Should -Not -Match 'блокуваннях|латчах'
		$index.usage.userUpdates = 20
		(Test-Expensive $index $config).isExpensive | Should -BeFalse
	}
}

Describe 'Merge-IaMissingIndexes і Get-IaIndexCreateEstimate' {
	BeforeAll {
		function Invoke-TestMerge {
			param($Snapshot, $Config)
			return , @(InModuleScope IndexAdvisor -Parameters @{ Snapshot = $Snapshot; Config = $Config } { Merge-IaMissingIndexes -Snapshot $Snapshot -Config $Config })
		}
		function Add-TestMissing {
			param($Snapshot, [long]$Handle, [string[]]$Equality = @(), [string[]]$Inequality = @(), [string[]]$Included = @())
			$database = $Snapshot.instances[0].databases[0]
			$database.missingIndexes = @($database.missingIndexes) + @([ordered]@{
					indexHandle = $Handle; groupHandle = $Handle + 1; schema = 'dbo'; table = 'Orders'; objectId = 201
					equalityColumns = @($Equality); inequalityColumns = @($Inequality); includedColumns = @($Included)
					userSeeks = 100; userScans = 0; avgTotalUserCost = 10.0; avgUserImpact = 50.0; lastUserSeekUtc = $null; uniqueCompiles = 1; queryHashes = @()
				})
		}
	}
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$config = Get-IaTestConfig
	}

	It 'зливає два missing index Orders(OrderDate) і пропозицію з плану Query Store' {
		$candidates = Invoke-TestMerge $snapshot $config
		$candidates.Count | Should -Be 1
		$candidate = $candidates[0]
		$candidate.target.server | Should -Be 'AG1'
		$candidate.target.index | Should -Be 'IX_OrderDate_INC'
		$candidate.keyColumns | Should -Be @('OrderDate')
		$candidate.includedColumns | Should -Be @('Amount', 'Status')
		$candidate.sourceIndexHandles | Should -Be @(11, 13)
		$candidate.queryIds | Should -Be @(1002)
		$candidate.userSeeks | Should -Be 5200
		$candidate.avgUserImpact | Should -Be 96.82
		$candidate.estimate.tableWritesPerDay | Should -BeGreaterThan 0
	}

	It 'зливає за префіксом ключа й однакові ключі, несумісні ключі лишає окремо' {
		Add-TestMissing $snapshot 15 -Inequality 'OrderDate', 'Status'
		Add-TestMissing $snapshot 17 -Equality 'CustomerId' -Included 'Status'
		Add-TestMissing $snapshot 19 -Equality 'CustomerId' -Included 'Comment'
		$candidates = Invoke-TestMerge $snapshot $config
		$candidates.Count | Should -Be 2
		$byDate = $candidates | Where-Object { $_.keyColumns[0] -eq 'OrderDate' }
		$byDate.keyColumns | Should -Be @('OrderDate', 'Status')
		$byDate.includedColumns | Should -Be @('Amount')
		$byDate.sourceIndexHandles | Should -Be @(15, 11, 13)
		$byCustomer = $candidates | Where-Object { $_.keyColumns[0] -eq 'CustomerId' }
		$byCustomer.includedColumns | Should -Be @('Status', 'Comment')
		$byCustomer.sourceIndexHandles | Should -Be @(17, 19)
	}

	It 'пропускає кандидата, якого покриває наявний індекс' {
		Add-TestMissing $snapshot 21 -Equality 'CustomerId' -Inequality 'OrderDate' -Included 'Amount'
		$candidates = Invoke-TestMerge $snapshot $config
		$candidates.Count | Should -Be 1
		$candidates[0].keyColumns | Should -Be @('OrderDate')
	}

	It 'оцінка розміру, часу побудови й записів на таблицю за добу' {
		$table = $snapshot.instances[0].databases[0].tables | Where-Object { $_.name -eq 'Orders' }
		$estimate = InModuleScope IndexAdvisor -Parameters @{ Table = $table } { Get-IaIndexCreateEstimate -Table $Table -KeyColumns 'OrderDate' -IncludedColumns 'Amount', 'Status' -UptimeDays 40 }
		$estimate.estimatedSizeMb | Should -Be 180.98
		$estimate.estimatedBuildMinutes | Should -BeGreaterThan 0
		$estimate.tableWritesPerDay | Should -Be 10000
		$table.rowCount = $null
		$empty = InModuleScope IndexAdvisor -Parameters @{ Table = $table } { Get-IaIndexCreateEstimate -Table $Table -KeyColumns 'OrderDate' }
		$empty.estimatedSizeMb | Should -BeNullOrEmpty
		$empty.tableWritesPerDay | Should -BeNullOrEmpty
	}
}
