# Тести конвеєра Invoke-IndexAdvisor (CONTRACTS.md, розділ 4) з моками всіх функцій інших потоків.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')

	$script:Root = (Get-PSDrive TestDrive).Root

	function New-TestRunConfig {
		<# YAML-конфігурація для конвеєра з тимчасовими каталогами. #>
		param([string]$Extra = '', [bool]$Repository = $false, [string]$Name = 'run.yaml')
		$rootText = $script:Root.Replace("'", "''")
		$text = @"
version: 1
servers:
  - SQL01
llm:
  provider: openai
  providers:
    openai:
      type: OpenAI
      model: gpt-4.1
      apiKeyRef: 'secret:IndexAdvisor-openai'
output:
  path: '$rootText\out'
archive:
  path: '$rootText\archive'
logging:
  path: '$rootText\logs'
repository:
  enabled: $(if ($Repository) { 'true' } else { 'false' })
  server: 'REPO01'
$Extra
"@
		$path = Join-Path $script:Root $Name
		[System.IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
		return $path
	}

	function New-TestPeriod {
		param([AllowNull()][string]$Database, [double]$UptimeDays = 70.2, [bool]$Sufficient = $true)
		return [ordered]@{
			server = 'AG1'
			database = $Database
			sqlserverStartTimeUtc = '2026-09-01T03:00:00.000Z'
			lastFailoverUtc = $null
			statsFromUtc = '2026-09-01T03:00:00.000Z'
			statsToUtc = '2026-11-10T08:00:00.000Z'
			uptimeDays = $UptimeDays
			queryStoreFromUtc = '2026-08-12T00:00:00.000Z'
			queryStoreToUtc = '2026-11-10T08:00:00.000Z'
			queryStoreDays = 90.33
			minRequiredDays = 14
			isSufficient = $Sufficient
			warnings = @()
		}
	}

	function New-TestAnalysis {
		param([string]$StoppedReason = 'Completed', [string]$TemplateId = 'index-analysis')
		$fixture = Get-IaTestFixture -Name 'llm-response.sample.json'
		return [ordered]@{
			recommendations = @($fixture.recommendations)
			notes = $fixture.notes
			calls = @([ordered]@{
					llmCallId = [guid]::NewGuid().ToString(); provider = 'openai'; model = 'gpt-4.1'; purpose = 'Analysis'
					inputTokens = 1000; outputTokens = 200; costUsd = 0.01; durationMs = 10; success = $true
				})
			toolRequests = @()
			totalInputTokens = 1000
			totalOutputTokens = 200
			totalCostUsd = 0.01
			stoppedReason = $StoppedReason
			error = $(if ($StoppedReason -eq 'Error') { 'HTTP 500' } else { $null })
			prompt = [ordered]@{ templateId = $TemplateId; templateVersion = 1 }
		}
	}

	function New-TestEligibility {
		return [ordered]@{
			rulesProfile = 'Standard'; relaxedReason = $null; requiredConsecutive = 3; consecutiveCount = 1; missingConfirmations = 2
			minIntervalDays = 7; minUptimeDays = 14; countsTowardSeries = $true; notCountedReason = $null
			conditions = @([ordered]@{ id = 'ConsecutiveSeries'; met = $false; details = '1 з 3' })
			isEligible = $false
			warning = 'Ґрунтується на 1 з 3 аналізів; бракує 2 підтверджень'
		}
	}
}

Describe 'Invoke-IndexAdvisor' {
	BeforeAll {
		$script:ConfigPath = New-TestRunConfig
	}

	BeforeEach {
		$global:LASTEXITCODE = $null
		Mock -ModuleName IndexAdvisor Test-IaSecretReference { $true }
		Mock -ModuleName IndexAdvisor Start-IaSession { [ordered]@{ sessionId = 'session-1' } }
		Mock -ModuleName IndexAdvisor Stop-IaSession { }
		Mock -ModuleName IndexAdvisor Write-IaLog { }
		Mock -ModuleName IndexAdvisor Get-IaUnsafeFlags { @() }
		Mock -ModuleName IndexAdvisor Assert-IaStandardLogin { [ordered]@{ login = 'index-advisor'; authentication = 'Sql'; isStandard = $true; warnings = @() } }
		Mock -ModuleName IndexAdvisor Get-IaLlmProviderConfig { [ordered]@{ name = $Name; type = 'OpenAI'; model = 'gpt-4.1' } }
		Mock -ModuleName IndexAdvisor Assert-IaProviderAllowed { }
		Mock -ModuleName IndexAdvisor Import-IaToolDefinitions { [ordered]@{ table_structure = [ordered]@{ name = 'table_structure' } } }
		Mock -ModuleName IndexAdvisor ConvertTo-IaToolJsonSchema { [ordered]@{ name = $Tool.name } }
		Mock -ModuleName IndexAdvisor Get-IaAnalysisWindow { [ordered]@{ fromUtc = '2026-10-11T08:00:00.000Z'; toUtc = '2026-11-10T08:00:00.000Z'; mode = 'Days'; reason = 'test' } }
		Mock -ModuleName IndexAdvisor Invoke-IaCollection { Get-IaTestSnapshot }
		Mock -ModuleName IndexAdvisor Get-IaLoginPermissions { [ordered]@{ login = 'other'; excessive = @([ordered]@{ permission = 'db_datareader'; scope = 'Database'; details = '' }); warnings = @() } }
		Mock -ModuleName IndexAdvisor Get-IaDataPeriod { , @((New-TestPeriod -Database $null), (New-TestPeriod -Database 'Sales')) }
		Mock -ModuleName IndexAdvisor Invoke-IaRulesEngine { @() }
		Mock -ModuleName IndexAdvisor Invoke-IaPartitionAnalysis { [ordered]@{ findings = @(); drafts = @() } }
		Mock -ModuleName IndexAdvisor New-IaMaskingMap { [ordered]@{} }
		Mock -ModuleName IndexAdvisor New-IaLlmContext {
			[ordered]@{ payload = [ordered]@{ module = $Module }; includedObjectKeys = @('ag1|sales|dbo.orders|ix_status'); truncatedObjects = @(); estimatedTokens = 10; module = $Module }
		}
		Mock -ModuleName IndexAdvisor ConvertTo-IaMaskedObject { $InputObject }
		Mock -ModuleName IndexAdvisor ConvertFrom-IaMaskedObject { $InputObject }
		Mock -ModuleName IndexAdvisor New-IaPrompt { [ordered]@{ templateId = $TemplateName; templateVersion = 1; messages = @(); toolSchemas = @($ToolSchemas); responseSchema = @{} } }
		Mock -ModuleName IndexAdvisor Save-IaSnapshotArchive { 'archive.zip' }
		Mock -ModuleName IndexAdvisor Read-IaSnapshotArchive {
			[ordered]@{
				manifest = [ordered]@{ requestedServer = 'AGL-SALES'; namesMasked = $true; literalsMasked = $true }
				snapshot = (Get-IaTestSnapshot)
				prompts = @()
				maskingMap = [ordered]@{ srv1 = 'SQL01' }
			}
		}
		Mock -ModuleName IndexAdvisor Invoke-IaAnalysisLoop { New-TestAnalysis -TemplateId $Prompt.templateId }
		Mock -ModuleName IndexAdvisor Invoke-IaCrossCheck { [ordered]@{ recommendations = $Recommendations; calls = @() } }
		Mock -ModuleName IndexAdvisor Test-IaRecommendation { [ordered]@{ status = 'Passed'; checks = @() } }
		Mock -ModuleName IndexAdvisor Get-IaDropEligibility { New-TestEligibility }
		Mock -ModuleName IndexAdvisor New-IaObjectVerdicts {
			@([ordered]@{ runId = $RunId; objectKey = 'ag1|sales|dbo.orders|ix_status'; module = $Module; analyzedAtUtc = '2026-11-10T08:00:00.000Z'; verdict = 'DropRecommended'; countsTowardSeries = $true; periodDays = 70.2; rulesProfile = 'Standard' })
		}
		Mock -ModuleName IndexAdvisor Remove-IaExpiredArchives { @() }
		Mock -ModuleName IndexAdvisor Export-IaReport { @() }
		Mock -ModuleName IndexAdvisor Save-IaRunToRepository { }
		Mock -ModuleName IndexAdvisor Get-IaRecommendationHistory { @() }
		Mock -ModuleName IndexAdvisor Remove-IaExpiredHistory { 0 }
	}

	It 'без жодної таблиці в контексті модель не викликається, у запуску — попередження' {
		Mock -ModuleName IndexAdvisor New-IaLlmContext {
			[ordered]@{ payload = [ordered]@{ module = $Module; databases = @() }; includedObjectKeys = @(); truncatedObjects = @(); estimatedTokens = 10; module = $Module }
		}
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -PassThru 2>$null 3>$null
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaAnalysisLoop -Times 0 -Exactly
		$messages = @($results[0].warnings | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_.message } else { [string]$_ } }) -join ' | '
		$messages | Should -Match 'Аналіз моделлю \(Indexes\) пропущено'
	}

	It 'успішний запуск: код 0, RunResult з рекомендаціями, умовами 4.4 і періодом' {
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -PassThru 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 0
		@($results).Count | Should -Be 1
		$run = $results[0]
		$run.status | Should -Be 'Succeeded'
		$run.exitCode | Should -Be 0
		$run.requestedServer | Should -Be 'SQL01'
		@($run.recommendations).Count | Should -Be 2
		@($run.dataPeriods).Count | Should -Be 2
		$run.archivePath | Should -Be 'archive.zip'
		$run.llm.totalInputTokens | Should -Be 1000
		@($run.verdicts).Count | Should -Be 1
		$drop = $run.recommendations | Where-Object { $_.action -eq 'DropIndex' }
		$drop.dropEligibility.isEligible | Should -BeFalse
		$drop.dataPeriod.database | Should -Be 'Sales'
		$drop.warnings | Should -Contain 'Ґрунтується на 1 з 3 аналізів; бракує 2 підтверджень'
		$drop.llm.promptTemplateId | Should -Be 'index-analysis'
		$create = $run.recommendations | Where-Object { $_.action -eq 'CreateIndex' }
		$create.validation.status | Should -Be 'Passed'
		$create.dropEligibility | Should -BeNullOrEmpty
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCollection -Times 1 -Exactly -ParameterFilter { $Server -eq 'SQL01' }
		Should -Invoke -ModuleName IndexAdvisor Save-IaSnapshotArchive -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Get-IaDropEligibility -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Get-IaRecommendationHistory -Times 1 -Exactly -ParameterFilter { @($ObjectKeys) -contains 'ag1|sales|dbo.orders|ix_status' }
		Should -Invoke -ModuleName IndexAdvisor Export-IaReport -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Save-IaRunToRepository -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Stop-IaSession -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCrossCheck -Times 0 -Exactly
	}

	It 'історія з репозиторію передається в Get-IaDropEligibility як плоский масив' {
		Mock -ModuleName IndexAdvisor Get-IaRecommendationHistory {
			, @([ordered]@{ runId = 'r1'; objectKey = 'ag1|sales|dbo.orders|ix_status'; module = 'Indexes'; analyzedAtUtc = '2026-10-01T08:00:00.000Z'; verdict = 'DropRecommended'; countsTowardSeries = $true; periodDays = 40; rulesProfile = 'Standard' })
		}
		Invoke-IndexAdvisor -Config $script:ConfigPath 2>$null 3>$null
		Should -Invoke -ModuleName IndexAdvisor Get-IaDropEligibility -Times 1 -Exactly -ParameterFilter {
			@($History).Count -eq 1 -and $History[0].runId -eq 'r1' -and @($DataPeriods).Count -eq 2
		}
	}
	It 'без -PassThru нічого не повертає, але встановлює LASTEXITCODE' {
		$output = Invoke-IndexAdvisor -Config $script:ConfigPath 2>$null 3>$null
		$output | Should -BeNullOrEmpty
		$global:LASTEXITCODE | Should -Be 0
	}

	It 'ConfigError: недійсний YAML — код 2, збору немає' {
		$bad = New-TestRunConfig -Extra "module: Wrong" -Name 'bad.yaml'
		Invoke-IndexAdvisor -Config $bad 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 2
		Should -Invoke -ModuleName IndexAdvisor Start-IaSession -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCollection -Times 0 -Exactly
	}

	It 'ConfigError: не задано провайдера LLM або сервера' {
		Invoke-IndexAdvisor -Config $script:ConfigPath -Provider '' 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 2
		$noServers = New-TestRunConfig -Name 'noservers.yaml'
		(Get-Content -LiteralPath $noServers -Raw).Replace("servers:`n  - SQL01`n", '') | Set-Content -LiteralPath $noServers -NoNewline
		Invoke-IndexAdvisor -Config $noServers 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 2
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCollection -Times 0 -Exactly
	}

	It 'ConfigError: провайдер не дозволений (localOnly) — до збору з серверів' {
		Mock -ModuleName IndexAdvisor Assert-IaProviderAllowed { Write-Error -Message 'Лише локальна модель' -ErrorId 'IaProviderNotAllowed' -ErrorAction Stop }
		Invoke-IndexAdvisor -Config $script:ConfigPath -LocalOnly 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 2
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCollection -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Stop-IaSession -Times 1 -Exactly
	}

	It 'ConnectionRefused: нештатний логін — код 3' {
		Mock -ModuleName IndexAdvisor Assert-IaStandardLogin { Write-Error -Message 'Логін не штатний' -ErrorId 'IaLoginRefused' -ErrorAction Stop }
		Invoke-IndexAdvisor -Config $script:ConfigPath 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 3
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCollection -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Stop-IaSession -Times 1 -Exactly
	}

	It 'нештатний логін з прапорцем: перевірка прав на кожному інстансі й базі, попередження' {
		Mock -ModuleName IndexAdvisor Assert-IaStandardLogin { [ordered]@{ login = 'CONTOSO\dba'; authentication = 'Windows'; isStandard = $false; warnings = @() } }
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -AllowNonStandardLogin -PassThru 2>$null 3>$null
		Should -Invoke -ModuleName IndexAdvisor Get-IaLoginPermissions -Times 2 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -ParameterFilter { $Level -eq 'Security' }
		($results[0].warnings -join ' ') | Should -Match 'db_datareader'
		$global:LASTEXITCODE | Should -Be 1
	}

	It 'кілька серверів: окремі запуски, найгірший код серед них' {
		Mock -ModuleName IndexAdvisor Invoke-IaCollection -ParameterFilter { $Server -eq 'SQL02' } { throw 'Не вдалося підключитися' }
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -Server 'SQL01', 'SQL02' -PassThru 2>$null 3>$null
		@($results).Count | Should -Be 2
		$results[0].runId | Should -Not -Be $results[1].runId
		$results[0].exitCode | Should -Be 0
		$results[1].exitCode | Should -Be 4
		$results[1].status | Should -Be 'Failed'
		$global:LASTEXITCODE | Should -Be 4
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCollection -Times 2 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Export-IaReport -Times 2 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaAnalysisLoop -Times 1 -Exactly
	}

	It 'збій збору: IaCollectionFailed — 4, IaLoginRefused під час підключення — 3' {
		Mock -ModuleName IndexAdvisor Invoke-IaCollection -ParameterFilter { $Server -eq 'SQL01' } { Write-Error -Message 'Збір не вдався' -ErrorId 'IaCollectionFailed' -ErrorAction Stop }
		Mock -ModuleName IndexAdvisor Invoke-IaCollection -ParameterFilter { $Server -eq 'SQL02' } { Write-Error -Message 'Логін не штатний' -ErrorId 'IaLoginRefused' -ErrorAction Stop }
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -Server 'SQL01' -PassThru 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 4
		$results[0].errors[0].code | Should -Be 'CollectionFailed'
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -Server 'SQL02' -PassThru 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 3
		$results[0].errors[0].code | Should -Be 'ConnectionRefused'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaAnalysisLoop -Times 0 -Exactly
	}
	It 'репозиторій: запис, якщо увімкнено; -NoRepository — без запису' {
		$withRepository = New-TestRunConfig -Repository $true -Name 'repo.yaml'
		Invoke-IndexAdvisor -Config $withRepository 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 0
		Should -Invoke -ModuleName IndexAdvisor Save-IaRunToRepository -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Remove-IaExpiredHistory -Times 1 -Exactly

		Invoke-IndexAdvisor -Config $withRepository -NoRepository 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 0
		Should -Invoke -ModuleName IndexAdvisor Save-IaRunToRepository -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Get-IaRecommendationHistory -ParameterFilter { $Config.repository.enabled -eq $false }
	}

	It '-FromArchive: без збору й без нового архіву, розмаскування snapshot' {
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -FromArchive 'C:\archive\run.zip' -PassThru 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 0
		$results[0].fromArchive | Should -Be 'C:\archive\run.zip'
		$results[0].requestedServer | Should -Be 'AGL-SALES'
		$results[0].masking.namesMasked | Should -BeTrue
		Should -Invoke -ModuleName IndexAdvisor Read-IaSnapshotArchive -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\archive\run.zip' }
		Should -Invoke -ModuleName IndexAdvisor ConvertFrom-IaMaskedObject -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCollection -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Save-IaSnapshotArchive -Times 0 -Exactly
	}

	It '-FromArchive: недійсний архів — CollectionFailed' {
		Mock -ModuleName IndexAdvisor Read-IaSnapshotArchive { Write-Error -Message 'Архів пошкоджено' -ErrorId 'IaArchiveInvalid' -ErrorAction Stop }
		$results = Invoke-IndexAdvisor -Config $script:ConfigPath -FromArchive 'C:\archive\bad.zip' -PassThru 2>$null 3>$null
		$global:LASTEXITCODE | Should -Be 4
		$results[0].status | Should -Be 'Failed'
	}

	It 'неінтерактивний режим і автопідтвердження передаються в конфігурацію аналізу' {
		Invoke-IndexAdvisor -Config $script:ConfigPath -NonInteractive -AutoApprove 2>$null 3>$null
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaAnalysisLoop -Times 1 -Exactly -ParameterFilter {
			$Config.run.nonInteractive -eq $true -and $Config.llm.autoApproveToolRequests -eq $true
		}
	}

	It 'модуль Both: два аналізи, у payload партиціонування додаються чернетки модуля' {
		Mock -ModuleName IndexAdvisor Invoke-IaPartitionAnalysis { [ordered]@{ findings = @(); drafts = @([ordered]@{ action = 'PartitionTable' }) } }
		Invoke-IndexAdvisor -Config $script:ConfigPath -Module Both 2>$null 3>$null
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaAnalysisLoop -Times 2 -Exactly
		Should -Invoke -ModuleName IndexAdvisor New-IaPrompt -Times 1 -Exactly -ParameterFilter { $TemplateName -eq 'partition-analysis' -and @($Payload.drafts).Count -eq 1 }
		Should -Invoke -ModuleName IndexAdvisor New-IaPrompt -Times 1 -Exactly -ParameterFilter { $TemplateName -eq 'index-analysis' }
	}

	It 'cross-check викликається, якщо задано llm.crossCheckProvider' {
		Invoke-IndexAdvisor -Config $script:ConfigPath -CrossCheckProvider 'openai' 2>$null 3>$null
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaCrossCheck -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Get-IaLlmProviderConfig -ParameterFilter { $IgnoreModelOverride }
	}

	Context 'коди повернення' {
		It 'короткий період — SuccessWithWarnings (1)' {
			Mock -ModuleName IndexAdvisor Get-IaDataPeriod { @((New-TestPeriod -Database 'Sales' -UptimeDays 3 -Sufficient $false)) }
			$results = Invoke-IndexAdvisor -Config $script:ConfigPath -PassThru 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 1
			($results[0].warnings -join ' ') | Should -Match 'коротший за мінімальний'
			(($results[0].recommendations | Where-Object { $_.action -eq 'CreateIndex' }).warnings -join ' ') | Should -Match 'коротший за мінімальний'
		}

		It 'рекомендація, що не пройшла перевірку 4.8 — 1' {
			Mock -ModuleName IndexAdvisor Test-IaRecommendation { [ordered]@{ status = 'Failed'; checks = @([ordered]@{ id = 'ObjectsExist'; status = 'Failed'; message = 'немає таблиці' }) } }
			Invoke-IndexAdvisor -Config $script:ConfigPath 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 1
		}

		It 'неповні умови 4.4 не дають коду 1' {
			Invoke-IndexAdvisor -Config $script:ConfigPath 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 0
		}

		It 'небезпечні режими — попередження в кожній рекомендації і код 1' {
			Mock -ModuleName IndexAdvisor Get-IaUnsafeFlags { @('disableMaxdop') }
			$results = Invoke-IndexAdvisor -Config $script:ConfigPath -UnsafeDisableMaxdop -PassThru 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 1
			@($results[0].unsafeFlags) | Should -Be @('disableMaxdop')
			foreach ($rec in $results[0].recommendations) {
				($rec.warnings -join ' ') | Should -Match 'disableMaxdop'
			}
		}

		It 'помилка моделі — LlmFailed (5)' {
			Mock -ModuleName IndexAdvisor Invoke-IaAnalysisLoop { New-TestAnalysis -StoppedReason 'Error' }
			$results = Invoke-IndexAdvisor -Config $script:ConfigPath -PassThru 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 5
			@($results[0].verdicts).Count | Should -Be 0
			Should -Invoke -ModuleName IndexAdvisor New-IaObjectVerdicts -Times 0 -Exactly
		}

		It 'перевищення бюджету — LlmFailed (5)' {
			Mock -ModuleName IndexAdvisor Invoke-IaAnalysisLoop { Write-Error -Message 'Бюджет вичерпано' -ErrorId 'IaBudgetExceeded' -ErrorAction Stop }
			Invoke-IndexAdvisor -Config $script:ConfigPath 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 5
		}

		It 'помилка репозиторію — RepositoryFailed (6)' {
			$withRepository = New-TestRunConfig -Repository $true -Name 'repo-fail.yaml'
			Mock -ModuleName IndexAdvisor Save-IaRunToRepository { throw 'Немає доступу до репозиторію' }
			$results = Invoke-IndexAdvisor -Config $withRepository -PassThru 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 6
			$results[0].status | Should -Be 'Partial'
		}

		It 'непередбачена помилка — Unexpected (9)' {
			Mock -ModuleName IndexAdvisor Invoke-IaRulesEngine { throw 'збій' }
			$results = Invoke-IndexAdvisor -Config $script:ConfigPath -PassThru 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 9
			$results[0].status | Should -Be 'Failed'
			Should -Invoke -ModuleName IndexAdvisor Export-IaReport -Times 1 -Exactly
		}

		It 'частковий збір (репліку не зібрано) — 1 і статус Partial' {
			Mock -ModuleName IndexAdvisor Invoke-IaCollection {
				$snapshot = Get-IaTestSnapshot
				$snapshot.topology.availabilityGroups[0].replicas[1].collected = $false
				$snapshot.topology.availabilityGroups[0].replicas[1].skipReason = 'ALLOW_CONNECTIONS = NO'
				$snapshot
			}
			$results = Invoke-IndexAdvisor -Config $script:ConfigPath -PassThru 2>$null 3>$null
			$global:LASTEXITCODE | Should -Be 1
			$results[0].status | Should -Be 'Partial'
		}
	}
}

Describe 'bin/IndexAdvisor.ps1' {
	It 'імпортує модуль, передає параметри й завершується кодом повернення' {
		$entry = Join-Path $PSScriptRoot '..\..\bin\IndexAdvisor.ps1'
		Test-Path -LiteralPath $entry | Should -BeTrue
		$text = Get-Content -LiteralPath $entry -Raw
		$text | Should -Match 'Import-Module'
		$text | Should -Match 'Invoke-IndexAdvisor @arguments'
		$text | Should -Match 'exit \$exitCode'
		$entryParameters = (Get-Command -Name $entry).Parameters.Keys
		$moduleParameters = (Get-Command -Name Invoke-IndexAdvisor).Parameters.Keys | Where-Object { $_ -ne 'PassThru' -and $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters }
		foreach ($name in $moduleParameters) {
			$entryParameters | Should -Contain $name
		}
	}

	It 'для недійсної конфігурації процес завершується з кодом 2' {
		$bad = Join-Path $TestDrive 'bad-entry.yaml'
		Set-Content -LiteralPath $bad -Value "version: 1`nmodule: Wrong"
		$entry = Join-Path $PSScriptRoot '..\..\bin\IndexAdvisor.ps1'
		& pwsh -NoProfile -NonInteractive -File $entry -Config $bad 2>$null | Out-Null
		$LASTEXITCODE | Should -Be 2
	}
}

Describe 'Чернетки модуля партиціонування в промпті й рішення моделі' {
	BeforeAll {
		function New-CliTestPartitionDraft {
			param([string]$Table)
			[ordered]@{
				action = 'AlterPartitioning'
				target = [ordered]@{ server = 'AG1'; database = 'Sales'; schema = 'dbo'; table = $Table; index = $null }
				title = "Додати майбутні межі секцій для $Table"
				rationale = 'Попереду менше двох порожніх секцій.'
				risk = [ordered]@{ level = 'Low'; description = 'SPLIT порожньої секції — зміна метаданих.' }
				executeScript = 'ALTER PARTITION SCHEME [ps_dbo_date] NEXT USED [PRIMARY]; ALTER PARTITION FUNCTION [pf_dbo_date]() SPLIT RANGE (''2027-01-01'');'
				rollbackScript = 'ALTER PARTITION FUNCTION [pf_dbo_date]() MERGE RANGE (''2027-01-01'');'
				confidence = 'High'
				partitioning = [ordered]@{ partitionColumn = 'OrderDate'; functionScript = 'CREATE PARTITION FUNCTION ...'; schemeScript = 'CREATE PARTITION SCHEME ...'; boundaries = @('2027-01-01') }
			}
		}
	}

	It 'компактна чернетка має draftId і не містить SQL-скриптів' {
		$compact = & (Get-Module IndexAdvisor) { param($d) ConvertTo-IaCliCompactDraft -Draft $d -DraftId 'D01' } (New-CliTestPartitionDraft -Table 'Orders')
		$compact.draftId | Should -Be 'D01'
		$compact.Contains('executeScript') | Should -BeFalse
		$compact.Contains('rollbackScript') | Should -BeFalse
		$compact.partitioning.Contains('functionScript') | Should -BeFalse
		$compact.partitioning.boundaries | Should -Be @('2027-01-01')
		$compact.title | Should -Match 'Orders'
	}

	It 'Confirm — рекомендація правил зі скриптами чернетки; Reject — відкинуто з попередженням; без рішення — з попередженням' {
		$entries = @(
			@{ id = 'D01'; draft = (New-CliTestPartitionDraft -Table 'Orders') }
			@{ id = 'D02'; draft = (New-CliTestPartitionDraft -Table 'Customers') }
			@{ id = 'D03'; draft = (New-CliTestPartitionDraft -Table 'Archive') }
		)
		$decisions = @(
			[ordered]@{ draftId = 'D01'; decision = 'Confirm'; reason = 'Межі потрібні.' }
			[ordered]@{ draftId = 'D02'; decision = 'Reject'; reason = 'Таблицю не секціоновано.' }
			[ordered]@{ draftId = 'D99'; decision = 'Confirm'; reason = $null }
		)
		$result = & (Get-Module IndexAdvisor) {
			param($e, $d)
			$run = New-IaRunResult -RequestedServer 'AGL-SALES' -Module 'Partitioning'
			$recs = @(Merge-IaCliDraftDecisions -DraftEntries $e -Decisions $d -Run $run -Module Partitioning)
			@{ run = $run; recs = $recs }
		} $entries $decisions
		@($result.recs).Count | Should -Be 2
		$result.recs[0].target.table | Should -Be 'Orders'
		$result.recs[0].source | Should -Be 'Rules'
		$result.recs[0].executeScript | Should -Match 'SPLIT RANGE'
		$result.recs[0].warnings[0] | Should -Match 'підтверджено моделлю: Межі потрібні'
		$result.recs[1].target.table | Should -Be 'Archive'
		$result.recs[1].warnings[0] | Should -Match 'не оцінила'
		$messages = @($result.run.warnings | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { $_.message } else { [string]$_ } }) -join ' | '
		$messages | Should -Match 'D02.*Таблицю не секціоновано'
		$messages | Should -Match "невідомої чернетки 'D99'"
	}
}
