# Тести звітів (CONTRACTS.md, розділ 9) на рекомендаціях, побудованих New-IaRecommendation з tests/Fixtures/llm-response.sample.json.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')

	function New-TestReportRun {
		<# RunResult: CreateIndex (Passed), DropIndex (Passed, умови 4.4 не виконано), відхилена перевіркою рекомендація з HTML-небезпечним текстом. #>
		param([bool]$DropEligible = $false)
		$fixture = Get-IaTestFixture -Name 'llm-response.sample.json'
		return , (InModuleScope IndexAdvisor -Parameters @{ Fixture = $fixture; DropEligible = $DropEligible } {
				param($Fixture, $DropEligible)
				$run = New-IaRunResult -RequestedServer 'AGL-SALES' -Module Indexes
				$run.startedAtUtc = '2026-11-10T08:00:00.000Z'
				$run.finishedAtUtc = '2026-11-10T08:05:00.000Z'
				$period = [ordered]@{
					server = 'AG1'; database = 'Sales'; sqlserverStartTimeUtc = '2026-09-01T03:00:00.000Z'; lastFailoverUtc = $null
					statsFromUtc = '2026-09-01T03:00:00.000Z'; statsToUtc = '2026-11-10T08:00:00.000Z'; uptimeDays = 70.2
					queryStoreFromUtc = '2026-08-12T00:00:00.000Z'; queryStoreToUtc = '2026-11-10T08:00:00.000Z'; queryStoreDays = 90.33
					minRequiredDays = 14; isSufficient = $true; warnings = @()
				}
				$run.dataPeriods = @($period)
				$run.topology = [ordered]@{ type = 'AG'; availabilityGroups = @([ordered]@{ name = 'AG1'; listenerName = 'AGL-SALES'; replicas = @([ordered]@{ replicaServerName = 'SQL01'; role = 'PRIMARY'; collected = $true }) }) }
				$run.datasets = [ordered]@{ enabled = @('indexStructure', 'instanceStartTime', 'usageStats'); disabled = @('queryStore'); warnings = @([ordered]@{ dataset = 'queryStore'; code = 'DatasetDisabled'; message = 'Без Query Store рекомендація на видалення ґрунтується лише на DMV.' }) }
				$run.llm.provider = 'openai'
				$run.llm.model = 'gpt-4.1'
				$run.llm.totalInputTokens = 1500
				$run.llm.totalOutputTokens = 300
				$run.llm.totalCostUsd = 0.0123
				$run.llm.calls = @([ordered]@{ llmCallId = [guid]::NewGuid().ToString(); provider = 'openai'; model = 'gpt-4.1'; purpose = 'Analysis'; inputTokens = 1500; outputTokens = 300; costUsd = 0.0123; durationMs = 900; success = $true })
				$run.toolRequests = @([ordered]@{ toolRequestId = [guid]::NewGuid().ToString(); tool = 'index_usage_stats'; server = 'SQL01'; database = 'Sales'; arguments = [ordered]@{ SchemaName = 'dbo'; TableName = 'Orders' }; reason = 'Потрібна статистика'; decision = 'Approved'; decisionReason = 'Підтверджено користувачем'; response = [ordered]@{ success = $true; rowCount = 3; truncated = $false } })
				$run.unsafeFlags = @('disableMaxdop')
				$run.findings = @(New-IaFinding -RuleId 'UnusedIndex' -Severity Medium -Target (New-IaTarget -Server 'AG1' -Database 'Sales' -Schema 'dbo' -Table 'Orders' -Index 'IX_Status') -Message 'Індекс не використовується')
				$llm = [ordered]@{ provider = 'openai'; model = 'gpt-4.1'; promptTemplateId = 'index-analysis'; promptTemplateVersion = 1; llmCallIds = @() }

				$create = New-IaRecommendation -Draft $Fixture.recommendations[0] -RunId $run.runId -Module Indexes -Llm $llm
				$create.dataPeriod = $period
				$create.validation = [ordered]@{ status = 'Passed'; checks = @([ordered]@{ id = 'SyntaxValid'; status = 'Passed'; message = 'ScriptDom: помилок немає' }) }

				$drop = New-IaRecommendation -Draft $Fixture.recommendations[1] -RunId $run.runId -Module Indexes -Llm $llm
				$drop.dataPeriod = $period
				$drop.validation = [ordered]@{ status = 'Passed'; checks = @() }
				$drop.dropEligibility = [ordered]@{
					rulesProfile = 'Standard'; relaxedReason = $null; requiredConsecutive = 3; consecutiveCount = 1; missingConfirmations = 2
					minIntervalDays = 7; minUptimeDays = 14; countsTowardSeries = $true; notCountedReason = $null
					conditions = @(
						[ordered]@{ id = 'ConsecutiveSeries'; met = $DropEligible; details = '1 з 3 аналізів' }
						[ordered]@{ id = 'MinUptimePeriod'; met = $true; details = '70.2 дн. >= 14' }
						[ordered]@{ id = 'NotPrimaryKey'; met = $true; details = 'не PK' }
						[ordered]@{ id = 'NotUsedInQueryStore'; met = $(if ($DropEligible) { $true } else { $null }); details = 'Query Store не зібрано' }
					)
					isEligible = $DropEligible
					warning = 'Ґрунтується на 1 з 3 аналізів; період 70.2 дн. (з 2026-09-01); бракує 2 підтверджень'
				}
				$drop.warnings = @('Ґрунтується на 1 з 3 аналізів; період 70.2 дн. (з 2026-09-01); бракує 2 підтверджень')

				$rejectedDraft = Copy-IaObject -InputObject $Fixture.recommendations[0]
				$rejectedDraft.target.index = 'IX_Bad'
				$rejectedDraft.title = 'Небезпечний <script>alert(1)</script> & "лапки"'
				$rejectedDraft.executeScript = 'CREATE INDEX [IX_Bad] ON [dbo].[Missing] ([X]);'
				$rejected = New-IaRecommendation -Draft $rejectedDraft -RunId $run.runId -Module Indexes -Llm $llm
				$rejected.validation = [ordered]@{ status = 'Failed'; checks = @([ordered]@{ id = 'ObjectsExist'; status = 'Failed'; message = 'Таблиці dbo.Missing не існує <b>' }) }

				$run.recommendations = @($drop, $rejected, $create)
				$run
			})
	}
}

Describe 'Export-IaReport' {
	BeforeEach {
		$script:Config = Get-IaTestConfig -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
		$script:Config.output.formats = @('Markdown', 'Sql', 'Html', 'Json', 'Console')
	}

	It 'створює всі файли в каталозі <дата>_<сервер>_<runId8>' {
		$run = New-TestReportRun
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		$directory = Split-Path -Path ($files | Where-Object { $_ -like '*recommendations.md' }) -Parent
		Split-Path -Path $directory -Leaf | Should -Match ('^20261110_080000_AGL-SALES_' + $run.runId.Replace('-', '').Substring(0, 8) + '$')
		foreach ($name in @('recommendations.md', 'report.html', 'result.json', 'sql\001_CreateIndex_Orders_IX_OrderDate_INC.sql', 'sql\001_CreateIndex_Orders_IX_OrderDate_INC_rollback.sql',
				'sql\002_DropIndex_Orders_IX_Status.sql', 'sql\002_DropIndex_Orders_IX_Status_rollback.sql')) {
			Join-Path $directory $name | Should -Exist
		}
		@(Get-ChildItem -LiteralPath (Join-Path $directory 'sql') -Filter '003_*').Count | Should -Be 0
		@($files).Count | Should -Be 7
	}

	It 'Markdown містить період, умови 4.4, обидва скрипти й розділ відхилених' {
		$run = New-TestReportRun
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		$md = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*recommendations.md' }) -Raw
		$md | Should -Match '## Період даних'
		$md | Should -Match '2026-09-01T03:00:00\.000Z'
		$md | Should -Match '70\.2'
		$md | Should -Match '## Зібрані набори даних'
		$md | Should -Match 'Вимкнено: queryStore'
		$md | Should -Match '## Маскування'
		$md | Should -Match 'УВАГА:\*\* Увімкнено небезпечні режими: disableMaxdop'
		$md | Should -Match 'gpt-4\.1'
		$md | Should -Match 'index_usage_stats'
		$md | Should -Match 'Підтверджено користувачем'
		$md | Should -Match '### 001\. CreateIndex dbo\.Orders\.IX_OrderDate_INC'
		$md | Should -Match '### 002\. DropIndex dbo\.Orders\.IX_Status'
		$md | Should -Match 'Умови безпечного видалення \(розділ 4\.4\)'
		$md | Should -Match '\| Рекомендація видалення в N аналізах поспіль \(ConsecutiveSeries\) \| не виконано \|'
		$md | Should -Match '\| Мінімальний період роботи сервера \(MinUptimePeriod\) \| виконано \|'
		$md | Should -Match '\(NotUsedInQueryStore\) \| невідомо \|'
		$md | Should -Match 'Ґрунтується на 1 з 3 потрібних аналізів поспіль; бракує підтверджень: 2'
		$md | Should -Match 'Профіль правил: стандартний'
		$md | Should -Match ([regex]::Escape('CREATE NONCLUSTERED INDEX [IX_OrderDate_INC] ON [dbo].[Orders]'))
		$md | Should -Match ([regex]::Escape('DROP INDEX [IX_OrderDate_INC] ON [dbo].[Orders];'))
		$md | Should -Match ([regex]::Escape('DROP INDEX [IX_Status] ON [dbo].[Orders];'))
		$md | Should -Match ([regex]::Escape('CREATE NONCLUSTERED INDEX [IX_Status] ON [dbo].[Orders] ([Status]) WITH (ONLINE = ON);'))
		$md | Should -Match '## Відхилені перевіркою'
		$md | Should -Match '### 003\. CreateIndex dbo\.Orders\.IX_Bad'
		$md | Should -Not -Match '<script>'
		$md.IndexOf('### 001.') | Should -BeLessThan $md.IndexOf('### 002.')
		$md.IndexOf('### 002.') | Should -BeLessThan $md.IndexOf('## Відхилені перевіркою')
	}

	It 'HTML самодостатній, містить період, умови 4.4 і скрипти, усі дані екрановано' {
		$run = New-TestReportRun
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		$html = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*report.html' }) -Raw
		$html | Should -Match '^<!DOCTYPE html>'
		$html | Should -Match '<meta charset="utf-8">'
		$html | Should -Not -Match '<script'
		$html | Should -Not -Match '<link'
		$html | Should -Not -Match '(src|href)\s*='
		$html | Should -Not -Match 'https?://'
		$html | Should -Match ([regex]::Escape('Небезпечний &lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;лапки&quot;'))
		$html | Should -Match ([regex]::Escape('Таблиці dbo.Missing не існує &lt;b&gt;'))
		$html | Should -Match 'Період даних'
		$html | Should -Match '2026-09-01T03:00:00\.000Z'
		$html | Should -Match 'Умови безпечного видалення \(розділ 4\.4\)'
		$html | Should -Match '<td>не виконано</td>'
		$html | Should -Match '<td>невідомо</td>'
		$html | Should -Match ([regex]::Escape('CREATE NONCLUSTERED INDEX [IX_OrderDate_INC] ON [dbo].[Orders]'))
		$html | Should -Match ([regex]::Escape('DROP INDEX [IX_Status] ON [dbo].[Orders];'))
		$html | Should -Match 'Відхилені перевіркою'
	}

	It 'SQL-скрипт видалення з невиконаними умовами 4.4 закоментовано з поясненням' {
		$run = New-TestReportRun
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		$dropFile = $files | Where-Object { $_ -like '*002_DropIndex_Orders_IX_Status.sql' }
		$lines = Get-Content -LiteralPath $dropFile
		@($lines | Where-Object { $_ -notmatch '^\s*--' -and $_ -match 'DROP\s+INDEX' }).Count | Should -Be 0
		$lines | Should -Contain '-- DROP INDEX [IX_Status] ON [dbo].[Orders];'
		($lines -join "`n") | Should -Match 'умови безпечного видалення \(розділ 4\.4\) виконано не всі'
		($lines -join "`n") | Should -Match 'Рекомендація видалення в N аналізах поспіль \(не виконано\)'
		($lines -join "`n") | Should -Match "runId: $($run.runId)"
		($lines -join "`n") | Should -Match 'Сервер: AG1; база: Sales'
		($lines -join "`n") | Should -Match 'Ризик: Medium'
		$rollback = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*002_DropIndex_Orders_IX_Status_rollback.sql' })
		$rollback | Should -Contain 'CREATE NONCLUSTERED INDEX [IX_Status] ON [dbo].[Orders] ([Status]) WITH (ONLINE = ON);'
		$create = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*001_CreateIndex_Orders_IX_OrderDate_INC.sql' })
		@($create | Where-Object { $_ -match '^CREATE NONCLUSTERED INDEX \[IX_OrderDate_INC\]' }).Count | Should -Be 1
		$create[0] | Should -Match '^-- '
	}

	It 'SQL-скрипт видалення з виконаними умовами 4.4 не закоментовано' {
		$run = New-TestReportRun -DropEligible $true
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		$lines = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*002_DropIndex_Orders_IX_Status.sql' })
		$lines | Should -Contain 'DROP INDEX [IX_Status] ON [dbo].[Orders];'
	}

	It 'дані в заголовку SQL не можуть вийти з коментаря' {
		$run = New-TestReportRun
		$run.recommendations[1].validation.status = 'Passed'
		$run.recommendations[1].title = "Рядок 1`nDROP TABLE dbo.Orders; */"
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		$file = $files | Where-Object { $_ -like '*IX_Bad.sql' }
		$lines = Get-Content -LiteralPath $file
		@($lines | Where-Object { $_ -match 'DROP TABLE' -and $_ -notmatch '^-- ' }).Count | Should -Be 0
	}

	It 'result.json містить RunResult, а Console — підсумок' {
		$run = New-TestReportRun
		$information = $null
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } {
			param($Run, $Config)
			Export-IaReport -RunResult $Run -Config $Config -InformationVariable info 6>$null
			$script:CapturedInformation = $info
		}
		$json = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*result.json' }) -Raw | ConvertFrom-Json -AsHashtable
		$json.runId | Should -Be $run.runId
		@($json.recommendations).Count | Should -Be 3
		$information = InModuleScope IndexAdvisor { $script:CapturedInformation }
		($information | ForEach-Object { $_.MessageData.ToString() }) -join "`n" | Should -Match 'AGL-SALES'
		($information | ForEach-Object { $_.MessageData.ToString() }) -join "`n" | Should -Match 'відхилено перевіркою: 1'
	}

	It 'лише Console — файлів не створює' {
		$script:Config.output.formats = @('Console')
		$run = New-TestReportRun
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		@($files).Count | Should -Be 0
		Test-Path -LiteralPath $script:Config.output.path | Should -BeFalse
	}

	It 'звіт для невдалого запуску без даних не падає' {
		$run = InModuleScope IndexAdvisor { $r = New-IaRunResult -RequestedServer 'SQL09' -Module Indexes; $r.status = 'Failed'; $r.exitCode = 4; $r.errors = @([ordered]@{ stage = 'Збір даних'; code = 'CollectionFailed'; message = 'немає підключення' }); $r }
		$files = InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $script:Config } { param($Run, $Config) Export-IaReport -RunResult $Run -Config $Config 6>$null }
		$md = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*recommendations.md' }) -Raw
		$md | Should -Match 'Період даних не визначено'
		$md | Should -Match 'немає підключення'
	}
}
