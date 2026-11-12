BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Rules.TestHelpers.ps1')
	Initialize-IaRuleTestScriptDom
	function Invoke-TestPartition {
		param($Snapshot, $Config)
		return InModuleScope IndexAdvisor -Parameters @{ Snapshot = $Snapshot; Config = $Config } { Invoke-IaPartitionAnalysis -Snapshot $Snapshot -Config $Config }
	}
	function Get-TestTable {
		param($Snapshot, [string]$Name)
		return $Snapshot.instances[0].databases[0].tables | Where-Object { $_.name -eq $Name }
	}
	function Set-TestBigTable {
		param($Snapshot, [string]$Name = 'Orders')
		$table = Get-TestTable $Snapshot $Name
		$table.rowCount = 200000000
		$table.reservedMb = 80000.0
		$table.usedMb = 79000.0
	}
	function Test-TestDraft {
		param($Draft, $Snapshot, $Config)
		$recommendation = & (Get-Module IndexAdvisor) { param($Draft) New-IaRecommendation -Draft $Draft -RunId 'run-1' -Module 'Partitioning' -Source 'Rules' } $Draft
		$validation = InModuleScope IndexAdvisor -Parameters @{ Recommendation = $recommendation; Snapshot = $Snapshot; Config = $Config } {
			Test-IaRecommendation -Recommendation $Recommendation -Snapshot $Snapshot -Config $Config
		}
		$recommendation.validation = $validation
		return $recommendation
	}
	function Assert-TestSqlStyle {
		param([string]$Sql)
		foreach ($line in ($Sql -split "`r?`n")) {
			$line.Length | Should -BeLessOrEqual 160
			$line | Should -Not -Match '^ +' -Because 'відступи — табами'
		}
		$Sql | Should -Not -MatchExactly '\b(create|alter|drop|index|table|with|partition|function|scheme|primary|key|values|range|right|include|constraint|references|foreign|unique|clustered|nonclustered|split|merge|next|used)\b'
	}
	function Get-TestSummary {
		param($Validation)
		return (($Validation.checks | ForEach-Object { "$($_.id)=$($_.status): $($_.message)" }) -join ' | ')
	}
}

Describe 'Invoke-IaPartitionAnalysis' {
	BeforeAll {
		Mock -ModuleName IndexAdvisor ConvertTo-IaSqlFragment { Invoke-IaRuleTestParse -Sql $Sql }
	}
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$config = Get-IaTestConfig
	}

	It 'малі таблиці фікстури — без знахідок і чернеток' {
		$result = Invoke-TestPartition $snapshot $config
		@($result.findings).Count | Should -Be 0
		@($result.drafts).Count | Should -Be 0
	}

	It 'пороги розміру й кількості рядків діють разом' {
		Set-TestBigTable $snapshot
		(Get-TestTable $snapshot 'Orders').reservedMb = 1000.0
		@((Invoke-TestPartition $snapshot $config).drafts).Count | Should -Be 0
	}

	Context 'велика несекціонована таблиця з датовими предикатами' {
		BeforeEach {
			Set-TestBigTable $snapshot
			$result = Invoke-TestPartition $snapshot $config
			$draft = @($result.drafts)[0]
		}

		It 'знахідка PartitionCandidate і одна чернетка PartitionTable за OrderDate' {
			$candidate = @($result.findings | Where-Object { $_.ruleId -eq 'PartitionCandidate' })
			$candidate.Count | Should -Be 1
			$candidate[0].target.table | Should -Be 'Orders'
			$candidate[0].details.partitionColumn | Should -Be 'OrderDate'
			$candidate[0].details.dateFilterShare | Should -BeGreaterThan 0.9
			@($result.drafts).Count | Should -Be 1
			$draft.action | Should -Be 'PartitionTable'
			$draft.target.server | Should -Be 'AG1'
			$draft.target.index | Should -BeNullOrEmpty
		}

		It 'чернетка відповідає llm-response.schema.json' {
			$response = [ordered]@{ recommendations = @($draft); toolRequests = @(); notes = $null }
			Test-IaJsonAgainstSchema -Json ($response | ConvertTo-Json -Depth 50) -Schema 'llm-response' | Should -BeTrue
		}

		It 'функція, схема й межі за конвенцією; T-SQL у стилі проєкту' {
			$partitioning = $draft.partitioning
			$partitioning.partitionColumn | Should -Be 'OrderDate'
			$partitioning.functionName | Should -Be 'pf_dbo_datetime27'
			$partitioning.schemeName | Should -Be 'ps_dbo_datetime27'
			$partitioning.boundaries.Count | Should -Be 14
			$partitioning.boundaries[0] | Should -Be "'20251201'"
			$partitioning.boundaries[-1] | Should -Be "'20270101'"
			$partitioning.functionScript | Should -Match '^CREATE PARTITION FUNCTION \[pf_dbo_datetime27\] \(DATETIME2\(7\)\) AS RANGE RIGHT FOR VALUES'
			$partitioning.schemeScript | Should -Be 'CREATE PARTITION SCHEME [ps_dbo_datetime27] AS PARTITION [pf_dbo_datetime27] ALL TO ([PRIMARY]);'
			Assert-TestSqlStyle $draft.executeScript
			Assert-TestSqlStyle $draft.rollbackScript
		}

		It 'оцінка наслідків і вигоди з обслуговування' {
			$impact = $draft.partitioning.impact
			$impact.clusteredIndexRebuild | Should -Match 'PK_Orders'
			$impact.primaryKeyAndUniqueChanges[0] | Should -Match 'PK_Orders: ключ \(OrderId\) -> \(OrderId, OrderDate\)'
			$impact.nonAlignedIndexes.Count | Should -Be 0
			($impact.foreignKeys -join ' ') | Should -Match 'FK_Orders_Customers'
			$impact.replication | Should -Match 'не бере участі'
			$impact.queriesWithoutPartitionFilter | Should -Be @(1003)
			$draft.partitioning.maintenanceBenefits | Should -Match 'SWITCH'
			$draft.partitioning.maintenanceBenefits | Should -Match 'TRUNCATE TABLE'
			$draft.partitioning.eliminationAssessment | Should -Match '1003'
			$draft.partitioning.migrationPlan.Count | Should -BeGreaterThan 3
			$draft.risk.level | Should -Be 'High'
			$draft.affectedQueryIds | Should -Be @(1001, 1002, 1003)
		}

		It 'чернетка проходить перевірку 4.8 і відповідає recommendation.schema.json' {
			$recommendation = Test-TestDraft $draft $snapshot $config
			$recommendation.validation.status | Should -Be 'Passed' -Because (Get-TestSummary $recommendation.validation)
			Test-IaJsonAgainstSchema -Json ($recommendation | ConvertTo-Json -Depth 50) -Schema recommendation | Should -BeTrue
		}

		It 'частка датових запитів нижча за поріг — PartitionNotBeneficial без чернетки' {
			$config.partitioning.minDateFilterShare = 0.99
			$other = Invoke-TestPartition $snapshot $config
			@($other.drafts).Count | Should -Be 0
			$info = @($other.findings | Where-Object { $_.ruleId -eq 'PartitionNotBeneficial' })
			$info.Count | Should -Be 1
			$info[0].severity | Should -Be 'Info'
		}
	}

	It 'купа: створюється кластерний індекс на схемі, відкат — DROP INDEX ... MOVE TO' {
		Set-TestBigTable $snapshot
		$pk = Find-IaRuleTestIndex -Snapshot $snapshot -Index 'PK_Orders'
		$pk.name = $null
		$pk.indexId = 0
		$pk.typeDesc = 'HEAP'
		$pk.isPrimaryKey = $false
		$pk.isUnique = $false
		$draft = @((Invoke-TestPartition $snapshot $config).drafts)[0]
		$draft.executeScript | Should -Match 'CREATE CLUSTERED INDEX \[CI_OrderDate_P\] ON \[dbo\]\.\[Orders\]'
		$draft.rollbackScript | Should -Match 'DROP INDEX \[CI_OrderDate_P\] ON \[dbo\]\.\[Orders\] WITH \(MOVE TO \[PRIMARY\]\);'
		$validation = (Test-TestDraft $draft $snapshot $config).validation
		$validation.status | Should -Be 'Passed' -Because (Get-TestSummary $validation)
	}

	It 'PK, на який посилаються FK: FK тимчасово видаляються, унікальний індекс для FK лишається невирівняним' {
		Set-TestBigTable $snapshot 'Customers'
		$plan = $snapshot.instances[0].databases[0].queryStoreQueries[0].plans[0]
		$plan.indexOperations = @($plan.indexOperations) + @([ordered]@{ database = 'Sales'; schema = 'dbo'; table = 'Customers'; index = 'PK_Customers'; operation = 'Seek'; executionMode = 'Row'; isHinted = $false })
		$plan.predicates = @($plan.predicates) + @([ordered]@{ schema = 'dbo'; table = 'Customers'; column = 'CreatedAt'; operator = 'Range' })
		$draft = @((Invoke-TestPartition $snapshot $config).drafts | Where-Object { $_.target.table -eq 'Customers' })[0]
		$draft.executeScript | Should -Match 'ALTER TABLE \[dbo\]\.\[Orders\] DROP CONSTRAINT \[FK_Orders_Customers\];'
		$draft.executeScript | Should -Match 'CREATE UNIQUE NONCLUSTERED INDEX \[IX_CustomerId_UQ\]'
		$draft.executeScript | Should -Match 'ALTER TABLE \[dbo\]\.\[Orders\] WITH CHECK ADD CONSTRAINT \[FK_Orders_Customers\] FOREIGN KEY'
		($draft.partitioning.impact.nonAlignedIndexes -join ' ') | Should -Match 'UQ_Customers_Email'
		($draft.partitioning.impact.foreignKeys -join ' ') | Should -Match 'FK_Orders_Customers'
		$validation = (Test-TestDraft $draft $snapshot $config).validation
		$validation.status | Should -Be 'Passed' -Because (Get-TestSummary $validation)
	}

	Context 'секціонована таблиця' {
		BeforeEach {
			$orders = Get-TestTable $snapshot 'Orders'
			$orders.isPartitioned = $true
			$orders.partitionScheme = 'ps_dbo_datetime27'
			$orders.partitionFunction = 'pf_dbo_datetime27'
			$orders.partitionColumn = 'OrderDate'
			$orders.partitionRangeRight = $true
			(Find-IaRuleTestIndex -Snapshot $snapshot -Index 'PK_Orders').partitions = @(
				[ordered]@{ partitionNumber = 1; rowCount = 0; boundaryValue = $null }
				[ordered]@{ partitionNumber = 2; rowCount = 1000; boundaryValue = '2026-08-01T00:00:00' }
				[ordered]@{ partitionNumber = 3; rowCount = 0; boundaryValue = '2026-09-01T00:00:00' }
				[ordered]@{ partitionNumber = 4; rowCount = 50000; boundaryValue = '2026-10-01T00:00:00' }
				[ordered]@{ partitionNumber = 5; rowCount = 2000; boundaryValue = '2026-11-01T00:00:00' }
			)
			$snapshot.instances[0].databases[0].queryStoreQueries[1].plans[0].partitionElimination = 'No'
			$result = Invoke-TestPartition $snapshot $config
		}

		It 'partition elimination, перекіс, порожні й переповнені секції' {
			$elimination = @($result.findings | Where-Object { $_.ruleId -eq 'PartitionElimination' })
			$elimination.Count | Should -Be 1
			$elimination[0].details.queriesWithoutElimination | Should -Be @(1002)
			$elimination[0].details.queriesWithoutPartitionFilter | Should -Be @(1003)
			$skew = @($result.findings | Where-Object { $_.ruleId -eq 'PartitionSkew' })
			$skew[0].details.largestPartition | Should -Be 4
			$skew[0].details.medianRows | Should -Be 2000
			@($result.findings | Where-Object { $_.ruleId -eq 'EmptyPartitions' })[0].details.emptyPartitions | Should -Be @(3)
			@($result.findings | Where-Object { $_.ruleId -eq 'PartitionOverflow' })[0].details.partitionNumber | Should -Be 5
			@($result.findings | Where-Object { $_.ruleId -eq 'PartitionCandidate' }).Count | Should -Be 0
		}

		It 'межі на майбутні періоди: чернетка AlterPartitioning зі SPLIT і відкатом MERGE' {
			$future = @($result.findings | Where-Object { $_.ruleId -eq 'PartitionFutureBoundaries' })
			$future[0].details.step | Should -Be 'Month'
			$draft = @($result.drafts)[0]
			$future[0].details.rangeRight | Should -BeTrue
			$draft.action | Should -Be 'AlterPartitioning'
			$draft.confidence | Should -Be 'High'
			$draft.partitioning.migrationPlan[0] | Should -Match 'RANGE RIGHT'
			$draft.partitioning.boundaries | Should -Be @("'20261201'", "'20270101'")
			$draft.executeScript | Should -Match "ALTER PARTITION SCHEME \[ps_dbo_datetime27\] NEXT USED \[PRIMARY\];"
			$draft.executeScript | Should -Match "ALTER PARTITION FUNCTION \[pf_dbo_datetime27\] \(\) SPLIT RANGE \('20261201'\);"
			$draft.rollbackScript | Should -Match "MERGE RANGE \('20270101'\);"
			Assert-TestSqlStyle $draft.executeScript
			$response = [ordered]@{ recommendations = @($draft); toolRequests = @(); notes = $null }
			Test-IaJsonAgainstSchema -Json ($response | ConvertTo-Json -Depth 50) -Schema 'llm-response' | Should -BeTrue
			$validation = (Test-TestDraft $draft $snapshot $config).validation
			$validation.status | Should -Be 'Passed' -Because (Get-TestSummary $validation)
		}

		It 'RANGE LEFT з межами на кінець місяця: нові межі теж на кінець місяця з часом' {
			$orders.partitionRangeRight = $false
			$values = @('2026-07-31T23:59:59.997', '2026-08-31T23:59:59.997', '2026-09-30T23:59:59.997', '2026-10-31T23:59:59.997', $null)
			$partitions = (Find-IaRuleTestIndex -Snapshot $snapshot -Index 'PK_Orders').partitions
			for ($i = 0; $i -lt $values.Count; $i++) { $partitions[$i].boundaryValue = $values[$i] }
			$draft = @((Invoke-TestPartition $snapshot $config).drafts)[0]
			$draft.partitioning.boundaries | Should -Be @("'2026-11-30T23:59:59.997'", "'2026-12-31T23:59:59.997'")
			$draft.partitioning.migrationPlan[0] | Should -Match 'RANGE LEFT'
			$validation = (Test-TestDraft $draft $snapshot $config).validation
			$validation.status | Should -Be 'Passed' -Because (Get-TestSummary $validation)
		}

		It 'невідомий тип RANGE (partitionRangeRight = null) — чернетка з низькою впевненістю й кроком перевірки' {
			$orders.partitionRangeRight = $null
			$result = Invoke-TestPartition $snapshot $config
			$draft = @($result.drafts)[0]
			$draft.confidence | Should -Be 'Low'
			$draft.partitioning.migrationPlan[0] | Should -Match 'boundary_value_on_right'
			@($result.findings | Where-Object { $_.ruleId -eq 'PartitionFutureBoundaries' })[0].message | Should -Match 'тип RANGE невідомий'
		}

		It 'достатньо майбутніх меж — чернетки немає' {
			$config.partitioning.minFuturePartitions = 0
			@((Invoke-TestPartition $snapshot $config).drafts).Count | Should -Be 0
		}
	}
}
