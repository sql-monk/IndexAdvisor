BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Rules.TestHelpers.ps1')
	$script:now = [datetime]::new(2026, 11, 10, 9, 0, 0, [System.DateTimeKind]::Utc)
	function Get-TestEligibility {
		param($Snapshot, $Config, [string]$Index = 'IX_Status', [object[]]$History = @(), [string]$Table = 'Orders', [object[]]$DataPeriods = @())
		$recommendation = New-IaRuleTestRecommendation -Action 'DropIndex' -Table $Table -Index $Index -ExecuteScript "DROP INDEX [$Index] ON [dbo].[$Table];"
		return InModuleScope IndexAdvisor -Parameters @{ Recommendation = $recommendation; Snapshot = $Snapshot; Config = $Config; History = $History; DataPeriods = $DataPeriods; NowUtc = $script:now } {
			Get-IaDropEligibility -Recommendation $Recommendation -Snapshot $Snapshot -History $History -DataPeriods $DataPeriods -Config $Config -NowUtc $NowUtc
		}
	}
	function Get-TestCondition {
		param($Eligibility, [string]$Id)
		return $Eligibility.conditions | Where-Object { $_.id -eq $Id }
	}
	function New-TestHistoryDate {
		param([int]$Month, [int]$Day)
		return [datetime]::new(2026, $Month, $Day, 9, 0, 0, [System.DateTimeKind]::Utc)
	}
}

Describe 'Get-IaDropEligibility' {
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$config = Get-IaTestConfig
		$config.rules.relaxed.enabled = $false
	}

	Context 'серія видалення (стандартний профіль, IX_Status)' {
		It 'немає історії: 1 з 3, бракує 2 підтверджень, структурні умови виконано' {
			$result = Get-TestEligibility $snapshot $config
			$result.rulesProfile | Should -Be 'Standard'
			$result.relaxedReason | Should -BeNullOrEmpty
			$result.requiredConsecutive | Should -Be 3
			$result.consecutiveCount | Should -Be 1
			$result.missingConfirmations | Should -Be 2
			$result.countsTowardSeries | Should -BeTrue
			$result.notCountedReason | Should -BeNullOrEmpty
			$result.isEligible | Should -BeFalse
			$result.warning | Should -Match '^Ґрунтується на 1 з 3 аналізів; період 16\.3 дн\. \(з 2026-10-25\); бракує 2 підтверджень'
			foreach ($id in 'MinUptimePeriod', 'MinInterval', 'AnalysisWindow', 'NotPrimaryKey', 'NotUnique', 'NoForeignKeySupport', 'NotReplicated', 'NoHintReferences', 'NotUsedInQueryStore', 'CheckedOnAllReplicas') {
				(Get-TestCondition $result $id).met | Should -BeTrue -Because $id
			}
			(Get-TestCondition $result 'ConsecutiveSeries').met | Should -BeFalse
		}

		It '2 попередні зараховані: серію завершено, рекомендація допустима' {
			$history = @(
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 20)
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 30)
			)
			$result = Get-TestEligibility $snapshot $config -History $history
			$result.consecutiveCount | Should -Be 3
			$result.missingConfirmations | Should -Be 0
			$result.isEligible | Should -BeTrue
			$result.warning | Should -BeNullOrEmpty
		}

		It 'Keep посередині обнуляє серію' {
			$history = @(
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 10)
				New-IaRuleTestVerdict -Verdict 'Keep' -AnalyzedAtUtc (New-TestHistoryDate 10 20)
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 30)
			)
			$result = Get-TestEligibility $snapshot $config -History $history
			$result.consecutiveCount | Should -Be 2
			$result.isEligible | Should -BeFalse
			$result.warning | Should -Match 'бракує 1 підтвердження'
		}

		It 'незараховані DropRecommended не обнуляють серію' {
			$history = @(
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 10)
				New-IaRuleTestVerdict -Counts $false -AnalyzedAtUtc (New-TestHistoryDate 10 12)
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 25)
			)
			(Get-TestEligibility $snapshot $config -History $history).isEligible | Should -BeTrue
		}

		It 'короткий період: аналіз не зараховується' {
			$snapshot.instances[1].sqlserverStartTimeUtc = '2026-11-05T08:01:00.000Z'
			$history = @(
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 20)
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 30)
			)
			$result = Get-TestEligibility $snapshot $config -History $history
			$result.countsTowardSeries | Should -BeFalse
			$result.consecutiveCount | Should -Be 2
			$result.notCountedReason | Should -Match 'коротший за мінімальний 14'
			(Get-TestCondition $result 'MinUptimePeriod').met | Should -BeFalse
			$result.isEligible | Should -BeFalse
			$result.warning | Should -Match 'поточний аналіз не зараховано'
		}

		It 'замалий інтервал від попереднього зарахованого' {
			$history = @(
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 25)
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 11 7)
			)
			$result = Get-TestEligibility $snapshot $config -History $history
			$result.countsTowardSeries | Should -BeFalse
			$result.consecutiveCount | Should -Be 2
			(Get-TestCondition $result 'MinInterval').met | Should -BeFalse
			$result.notCountedReason | Should -Match 'минуло 3 дн\., мінімум 7'
		}

		It 'override для таблиці та rebuild індексу підвищують вимоги до періоду' {
			$config.rules.observationOverrides = @([ordered]@{ server = 'AG1'; database = 'Sales'; table = 'dbo.Orders'; minUptimeDays = 30 })
			$result = Get-TestEligibility $snapshot $config
			$result.minUptimeDays | Should -Be 30
			$result.countsTowardSeries | Should -BeFalse
			$config.rules.observationOverrides = @()
			(Find-IaRuleTestIndex -Snapshot $snapshot -Index 'IX_Status').lastRebuildUtc = '2026-11-01T08:01:00.000Z'
			$rebuilt = Get-TestEligibility $snapshot $config
			(Get-TestCondition $rebuilt 'MinUptimePeriod').details | Should -Match 'Період даних 9 дн\. \(з 2026-11-01\)'
			$rebuilt.countsTowardSeries | Should -BeFalse
		}

		It 'використовує передані DataPeriods' {
			$periods = @([ordered]@{ server = 'AG1'; database = 'Sales'; uptimeDays = 3.5; statsFromUtc = '2026-11-06T21:00:00.000Z'; statsToUtc = '2026-11-10T09:00:00.000Z' })
			$result = Get-TestEligibility $snapshot $config -DataPeriods $periods
			$result.countsTowardSeries | Should -BeFalse
			$result.warning | Should -Match 'період 3\.5 дн\.'
		}

		It 'результат відповідає recommendation.schema.json' {
			$recommendation = New-IaRuleTestRecommendation -Action 'DropIndex' -Index 'IX_Status'
			$recommendation.dropEligibility = Get-TestEligibility $snapshot $config
			Test-IaJsonAgainstSchema -Json ($recommendation | ConvertTo-Json -Depth 50) -Schema recommendation | Should -BeTrue
		}
	}

	Context 'структурні умови' {
		BeforeEach {
			$fullHistory = @(
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 20)
				New-IaRuleTestVerdict -AnalyzedAtUtc (New-TestHistoryDate 10 30)
			)
		}

		It 'IX_CustomerId заблоковано хінтами, FK і планами Query Store' {
			$result = Get-TestEligibility $snapshot $config -Index 'IX_CustomerId' -History $fullHistory
			$result.isEligible | Should -BeFalse
			$hints = Get-TestCondition $result 'NoHintReferences'
			$hints.met | Should -BeFalse
			$hints.details | Should -Match 'usp_GetOrdersByCustomer'
			$hints.details | Should -Match 'запит 1003'
			$foreignKeys = Get-TestCondition $result 'NoForeignKeySupport'
			$foreignKeys.met | Should -BeFalse
			$foreignKeys.details | Should -Match 'FK_Orders_Customers'
			(Get-TestCondition $result 'NotUsedInQueryStore').met | Should -BeFalse
			$result.warning | Should -Match 'NoHintReferences'
		}

		It 'хінт знаходиться навіть без даних колектора — за moduleHints і текстом запиту' {
			foreach ($instance in $snapshot.instances) {
				foreach ($table in $instance.databases[0].tables) {
					foreach ($index in $table.indexes) { if ($index.name -eq 'IX_CustomerId') { $index.hintReferences = @() } }
				}
			}
			(Get-TestCondition (Get-TestEligibility $snapshot $config -Index 'IX_CustomerId') 'NoHintReferences').met | Should -BeFalse
		}

		It 'PK і UNIQUE не видаляються; FK, що посилається на PK, блокує' {
			$pk = Get-TestEligibility $snapshot $config -Index 'PK_Orders' -History $fullHistory
			(Get-TestCondition $pk 'NotPrimaryKey').met | Should -BeFalse
			(Get-TestCondition $pk 'NotUnique').met | Should -BeFalse
			$pk.isEligible | Should -BeFalse
			$unique = Get-TestEligibility $snapshot $config -Table 'Customers' -Index 'UQ_Customers_Email' -History $fullHistory
			(Get-TestCondition $unique 'NotUnique').met | Should -BeFalse
			(Get-TestCondition $unique 'NotPrimaryKey').met | Should -BeTrue
			$referenced = Get-TestEligibility $snapshot $config -Table 'Customers' -Index 'PK_Customers'
			(Get-TestCondition $referenced 'NoForeignKeySupport').details | Should -Match 'на індекс спираються FK: FK_Orders_Customers'
		}

		It 'реплікація блокує видалення' {
			(Find-IaRuleTestIndex -Snapshot $snapshot -Server 'SQL02' -Index 'IX_Status').usedByReplication = $true
			$result = Get-TestEligibility $snapshot $config -History $fullHistory
			(Get-TestCondition $result 'NotReplicated').met | Should -BeFalse
			$result.isEligible | Should -BeFalse
		}

		It 'невідомі дані (null) — умова не виконана' {
			foreach ($server in 'SQL01', 'SQL02') {
				$index = Find-IaRuleTestIndex -Snapshot $snapshot -Server $server -Index 'IX_Status'
				$index.usedByReplication = $null
				$index.hintReferences = $null
				$index.referencedByForeignKeys = $null
				$index.queryStoreUsage = $null
			}
			$snapshot.instances[0].databases[0].queryStore = $null
			$result = Get-TestEligibility $snapshot $config -History $fullHistory
			foreach ($id in 'NotReplicated', 'NoHintReferences', 'NoForeignKeySupport', 'NotUsedInQueryStore', 'AnalysisWindow') {
				$condition = Get-TestCondition $result $id
				$condition.met | Should -BeNullOrEmpty -Because $id
				$condition.Contains('met') | Should -BeTrue
			}
			$result.consecutiveCount | Should -Be 3
			$result.isEligible | Should -BeFalse
			$result.warning | Should -Match 'NotReplicated \(невідомо\)'
		}

		It 'репліки AG: не зібрана читабельна репліка — не виконано; без читання — пропускається; індексу немає на репліці — невідомо' {
			$replica = $snapshot.topology.availabilityGroups[0].replicas[1]
			$replica.collected = $false
			$replica.skipReason = 'Помилка підключення'
			(Get-TestCondition (Get-TestEligibility $snapshot $config) 'CheckedOnAllReplicas').met | Should -BeFalse
			$replica.secondaryAllowConnections = 'NO'
			(Get-TestCondition (Get-TestEligibility $snapshot $config) 'CheckedOnAllReplicas').met | Should -BeTrue
			$snapshot = Get-IaTestSnapshot
			$missing = Get-TestCondition (Get-TestEligibility $snapshot $config -Index 'IX_CustomerId_OrderDate_0') 'CheckedOnAllReplicas'
			$missing.met | Should -BeNullOrEmpty
			$missing.details | Should -Match 'SQL02'
		}

		It 'вікно аналізу: на початку місяця має охоплювати весь попередній місяць; Query Store має покривати вікно' {
			$snapshot.analysisWindow = [ordered]@{ fromUtc = '2026-10-04T08:00:00.000Z'; toUtc = '2026-11-03T08:00:00.000Z'; mode = 'Days'; reason = 'analysisWindow.days = 30' }
			(Get-TestCondition (Get-TestEligibility $snapshot $config) 'AnalysisWindow').met | Should -BeFalse
			$snapshot.analysisWindow = [ordered]@{ fromUtc = '2026-10-01T00:00:00.000Z'; toUtc = '2026-11-03T08:00:00.000Z'; mode = 'PreviousMonth'; reason = 'Початок місяця' }
			(Get-TestCondition (Get-TestEligibility $snapshot $config) 'AnalysisWindow').met | Should -BeTrue
			$snapshot.instances[0].databases[0].queryStore.firstIntervalStartUtc = '2026-10-20T00:00:00.000Z'
			$window = Get-TestCondition (Get-TestEligibility $snapshot $config) 'AnalysisWindow'
			$window.met | Should -BeFalse
			$window.details | Should -Match 'покрите не повністю'
		}
	}

	Context 'пом''якшений профіль' {
		BeforeEach {
			$config.rules.relaxed.enabled = $true
		}

		It 'IX_Comment — «дорогий»: N = 1, коротший період, причина в relaxedReason' {
			$result = Get-TestEligibility $snapshot $config -Index 'IX_Comment'
			$result.rulesProfile | Should -Be 'Relaxed'
			$result.relaxedReason | Should -Match 'дорогий'
			$result.relaxedReason | Should -Match 'блокуваннях'
			$result.requiredConsecutive | Should -Be 1
			$result.minUptimeDays | Should -Be 7
			$result.minIntervalDays | Should -Be 7
			$result.consecutiveCount | Should -Be 1
			$result.isEligible | Should -BeTrue
			$result.warning | Should -BeNullOrEmpty
		}

		It 'структурні умови не пом''якшуються' {
			foreach ($server in 'SQL01', 'SQL02') {
				(Find-IaRuleTestIndex -Snapshot $snapshot -Server $server -Index 'IX_Comment').hintReferences = @([ordered]@{ source = 'SqlModule'; objectName = 'dbo.usp_Search'; queryId = $null })
			}
			$result = Get-TestEligibility $snapshot $config -Index 'IX_Comment'
			$result.rulesProfile | Should -Be 'Relaxed'
			$result.isEligible | Should -BeFalse
			$result.warning | Should -Match 'пом''якшені правила'
		}

		It 'вимкнений rules.relaxed — стандартний профіль' {
			$config.rules.relaxed.enabled = $false
			$result = Get-TestEligibility $snapshot $config -Index 'IX_Comment'
			$result.rulesProfile | Should -Be 'Standard'
			$result.isEligible | Should -BeFalse
		}
	}
}

Describe 'New-IaObjectVerdicts' {
	BeforeAll {
		function Get-TestVerdicts {
			param([object[]]$Recommendations, [string[]]$Keys, [string]$Module = 'Indexes', [object[]]$DataPeriods = @())
			$parameters = @{ Recommendations = $Recommendations; Keys = $Keys; Module = $Module; DataPeriods = $DataPeriods; Config = (Get-IaTestConfig); NowUtc = $script:now }
			return , @(InModuleScope IndexAdvisor -Parameters $parameters {
					New-IaObjectVerdicts -RunId 'run-1' -Module $Module -Recommendations $Recommendations -IncludedObjectKeys $Keys -DataPeriods $DataPeriods -Config $Config -NowUtc $NowUtc
				})
		}
	}
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$periods = @(InModuleScope IndexAdvisor -Parameters @{ Snapshot = $snapshot; Config = (Get-IaTestConfig) } { Get-IaDataPeriod -Snapshot $Snapshot -Config $Config })
		$drop = New-IaRuleTestRecommendation -Action 'DropIndex' -Index 'IX_Status'
		$drop.validation = [ordered]@{ status = 'Passed'; checks = @() }
		$drop.dropEligibility = [ordered]@{ countsTowardSeries = $true; rulesProfile = 'Relaxed' }
		$drop.dataPeriod = $periods | Where-Object { $_.database -eq 'Sales' }
	}

	It 'DropRecommended для DropIndex, що пройшов перевірку; Keep для решти' {
		$verdicts = Get-TestVerdicts @($drop) @('ag1|sales|dbo.orders|ix_status', 'AG1|Sales|dbo.Orders|IX_Comment', 'ag1|sales|dbo.orders|ix_comment') -DataPeriods $periods
		$verdicts.Count | Should -Be 2
		$status = $verdicts | Where-Object { $_.objectKey -eq 'ag1|sales|dbo.orders|ix_status' }
		$status.verdict | Should -Be 'DropRecommended'
		$status.countsTowardSeries | Should -BeTrue
		$status.rulesProfile | Should -Be 'Relaxed'
		$status.periodDays | Should -Be 16.25
		$status.runId | Should -Be 'run-1'
		$status.module | Should -Be 'Indexes'
		$status.analyzedAtUtc | Should -Be '2026-11-10T09:00:00.000Z'
		$comment = $verdicts | Where-Object { $_.objectKey -eq 'ag1|sales|dbo.orders|ix_comment' }
		$comment.verdict | Should -Be 'Keep'
		$comment.rulesProfile | Should -BeNullOrEmpty
		$comment.periodDays | Should -Be 16.25
	}

	It 'DropIndex, що не пройшов перевірку, дає Keep; модуль Partitioning — лише Keep' {
		$drop.validation.status = 'Failed'
		(Get-TestVerdicts @($drop) @('ag1|sales|dbo.orders|ix_status'))[0].verdict | Should -Be 'Keep'
		$drop.validation.status = 'Passed'
		(Get-TestVerdicts @($drop) @('ag1|sales|dbo.orders|ix_status') -Module 'Partitioning')[0].verdict | Should -Be 'Keep'
	}
}
