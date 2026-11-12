# Тести репозиторію (CONTRACTS.md, розділ 8) з моком шва Invoke-IaOutRepositoryCommand: лише параметризовані команди, відмова для цільової бази.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')

	function New-TestRepositoryConfig {
		param([string]$Server = 'REPO01', [string]$Database = 'IndexAdvisor')
		$config = Get-IaTestConfig
		$config.repository.enabled = $true
		$config.repository.server = $Server
		$config.repository.database = $Database
		return $config
	}

	function New-TestRepositoryRun {
		$fixture = Get-IaTestFixture -Name 'llm-response.sample.json'
		return , (InModuleScope IndexAdvisor -Parameters @{ Fixture = $fixture } {
				param($Fixture)
				$run = New-IaRunResult -RequestedServer 'AGL-SALES' -Module Indexes -Parameters ([ordered]@{ Server = @('AGL-SALES') })
				$run.finishedAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
				$run.topology = [ordered]@{
					type = 'AG'; requestedServer = 'AGL-SALES'; serverName = 'SQL01'
					availabilityGroups = @([ordered]@{ name = 'AG1'; listenerName = 'AGL-SALES'; replicas = @(
								[ordered]@{ replicaServerName = 'SQL01'; role = 'PRIMARY'; collected = $true }
								[ordered]@{ replicaServerName = 'SQL02'; role = 'SECONDARY'; collected = $true }
							)
						})
				}
				$run.datasets = [ordered]@{ enabled = @('indexStructure'); disabled = @(); warnings = @() }
				$period = [ordered]@{
					server = 'AG1'; database = 'Sales'; sqlserverStartTimeUtc = '2026-09-01T03:00:00.000Z'; lastFailoverUtc = $null
					statsFromUtc = '2026-09-01T03:00:00.000Z'; statsToUtc = '2026-11-10T08:00:00.000Z'; uptimeDays = 70.2
					queryStoreFromUtc = $null; queryStoreToUtc = $null; queryStoreDays = $null; minRequiredDays = 14; isSufficient = $true; warnings = @()
				}
				$run.dataPeriods = @($period)
				$llm = [ordered]@{ provider = 'openai'; model = 'gpt-4.1'; promptTemplateId = 'index-analysis'; promptTemplateVersion = 1; llmCallIds = @() }
				$run.llm.provider = 'openai'
				$run.llm.model = 'gpt-4.1'
				$run.llm.calls = @([ordered]@{ llmCallId = [guid]::NewGuid().ToString(); provider = 'openai'; model = 'gpt-4.1'; purpose = 'Analysis'; inputTokens = 10; outputTokens = 5; costUsd = 0.001; durationMs = 100; success = $true; createdAtUtc = '2026-11-10T08:01:00.000Z' })
				$run.toolRequests = @([ordered]@{ toolRequestId = [guid]::NewGuid().ToString(); llmCallId = 'not-a-guid'; tool = 'table_structure'; server = 'SQL01'; database = 'Sales'; arguments = [ordered]@{ TableName = 'Orders' }; decision = 'Rejected'; response = $null; executedAtUtc = $null })
				$create = New-IaRecommendation -Draft $Fixture.recommendations[0] -RunId $run.runId -Module Indexes -Llm $llm
				$create.dataPeriod = $period
				$create.validation = [ordered]@{ status = 'Passed'; checks = @() }
				$drop = New-IaRecommendation -Draft $Fixture.recommendations[1] -RunId $run.runId -Module Indexes -Llm $llm
				$drop.validation = [ordered]@{ status = 'Passed'; checks = @() }
				$drop.dropEligibility = [ordered]@{ rulesProfile = 'Standard'; isEligible = $false; conditions = @() }
				$drop.title = "Видалити IX_Status'; DROP TABLE dbo.Orders; --"
				$run.recommendations = @($create, $drop)
				$run.verdicts = @([ordered]@{ runId = $run.runId; objectKey = 'ag1|sales|dbo.orders|ix_status'; module = 'Indexes'; analyzedAtUtc = '2026-11-10T08:00:00.000Z'; verdict = 'DropRecommended'; countsTowardSeries = $true; periodDays = 70.2; rulesProfile = 'Standard' })
				$run.warnings = @('Попередження запуску')
				$run
			})
	}
}

Describe 'Save-IaRunToRepository' {
	BeforeEach {
		$script:Captured = $null
		Mock -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand { $script:Captured = @($Commands); 1 }
	}

	It 'записує запуск лише параметризованими командами' {
		$run = New-TestRepositoryRun
		$config = New-TestRepositoryConfig
		InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $config } { param($Run, $Config) Save-IaRunToRepository -RunResult $Run -Config $Config }
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 1 -Exactly -ParameterFilter { $Mode -eq 'NonQuery' }
		$commands = $script:Captured
		$commands.Count | Should -Be 8
		$commands[0].commandText | Should -Match '^DELETE FROM Advisor\.AnalysisRun WHERE RunId = @RunId;$'
		@($commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.AnalysisRun' }).Count | Should -Be 1
		@($commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.RunDataPeriod' }).Count | Should -Be 1
		@($commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.LlmCall' }).Count | Should -Be 1
		@($commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.ToolRequest' }).Count | Should -Be 1
		@($commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.Recommendation' }).Count | Should -Be 2
		@($commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.ObjectVerdict' }).Count | Should -Be 1

		$values = @($run.runId, 'AGL-SALES', 'openai', 'gpt-4.1', 'ag1|sales|dbo.orders|ix_status', 'DROP TABLE', 'Індекс за OrderDate', 'IX_OrderDate_INC', 'Sales')
		foreach ($command in $commands) {
			foreach ($value in $values) {
				$command.commandText | Should -Not -Match ([regex]::Escape($value))
			}
			$textParameters = @([regex]::Matches($command.commandText, '@[A-Za-z]+') | ForEach-Object { $_.Value } | Select-Object -Unique)
			$boundParameters = @($command.parameters | ForEach-Object { $_.name })
			foreach ($name in $textParameters) {
				$boundParameters | Should -Contain $name
			}
			foreach ($name in $boundParameters) {
				$textParameters | Should -Contain $name
			}
		}
		$runInsert = $commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.AnalysisRun' }
		($runInsert.parameters | Where-Object { $_.name -eq '@RunId' }).value | Should -BeOfType [guid]
		($runInsert.parameters | Where-Object { $_.name -eq '@RunId' }).value.ToString() | Should -Be $run.runId
		($runInsert.parameters | Where-Object { $_.name -eq '@StartedAtUtc' }).value | Should -BeOfType [datetime]
		($runInsert.parameters | Where-Object { $_.name -eq '@FinishedAtUtc' }).value.Kind | Should -Be 'Utc'
		($runInsert.parameters | Where-Object { $_.name -eq '@CostUsd' }).sqlType | Should -Be 'Decimal'
		($runInsert.parameters | Where-Object { $_.name -eq '@WarningsJson' }).value | Should -Be '["Попередження запуску"]'
		$dropInsert = $commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.Recommendation' -and ($_.parameters | Where-Object { $_.name -eq '@Action' }).value -eq 'DropIndex' }
		($dropInsert.parameters | Where-Object { $_.name -eq '@Title' }).value | Should -Be "Видалити IX_Status'; DROP TABLE dbo.Orders; --"
		($dropInsert.parameters | Where-Object { $_.name -eq '@IsDropEligible' }).value | Should -BeFalse
		($dropInsert.parameters | Where-Object { $_.name -eq '@PeriodFromUtc' }).value | Should -BeNullOrEmpty
		$toolInsert = $commands | Where-Object { $_.commandText -match 'INSERT INTO Advisor\.ToolRequest' }
		($toolInsert.parameters | Where-Object { $_.name -eq '@LlmCallId' }).value | Should -BeNullOrEmpty
	}

	It 'відмова, якщо база-репозиторій є цільовою базою на тому самому сервері' {
		$run = New-TestRepositoryRun
		foreach ($server in @('SQL01', 'sql02.contoso.local,1433', 'tcp:AGL-SALES', 'AG1')) {
			$config = New-TestRepositoryConfig -Server $server -Database 'Sales'
			{ InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $config } { param($Run, $Config) Save-IaRunToRepository -RunResult $Run -Config $Config } } |
				Should -Throw -ExpectedMessage '*Відмова*'
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 0 -Exactly
	}

	It 'та сама назва бази на іншому сервері або інша база на тому самому сервері — дозволено' {
		$run = New-TestRepositoryRun
		$config = New-TestRepositoryConfig -Server 'REPO01' -Database 'Sales'
		InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $config } { param($Run, $Config) Save-IaRunToRepository -RunResult $Run -Config $Config }
		$config = New-TestRepositoryConfig -Server 'SQL01' -Database 'IndexAdvisor'
		InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $config } { param($Run, $Config) Save-IaRunToRepository -RunResult $Run -Config $Config }
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 2 -Exactly
	}

	It 'repository.enabled = $false — нічого не записує' {
		$run = New-TestRepositoryRun
		$config = New-TestRepositoryConfig
		$config.repository.enabled = $false
		InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $config } { param($Run, $Config) Save-IaRunToRepository -RunResult $Run -Config $Config }
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 0 -Exactly
	}

	It 'без repository.server — помилка з підказкою' {
		$run = New-TestRepositoryRun
		$config = New-TestRepositoryConfig -Server ''
		{ InModuleScope IndexAdvisor -Parameters @{ Run = $run; Config = $config } { param($Run, $Config) Save-IaRunToRepository -RunResult $Run -Config $Config } } |
			Should -Throw -ExpectedMessage '*-NoRepository*'
	}
}

Describe 'Get-IaRecommendationHistory' {
	It 'читає вердикти параметризованим запитом і повертає IndexVerdict від старих до нових' {
		$runA = [guid]::NewGuid()
		$runB = [guid]::NewGuid()
		Mock -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand {
			$script:Captured = @($Commands)
			, @(
				[ordered]@{ RunId = $runB; ObjectKey = 'ag1|sales|dbo.orders|ix_status'; Module = 'Indexes'; AnalyzedAtUtc = [datetime]::new(2026, 10, 20, 8, 0, 0); Verdict = 'Keep'; CountsTowardSeries = $false; PeriodDays = [decimal]10.5; RulesProfile = $null }
				[ordered]@{ RunId = $runA; ObjectKey = 'ag1|sales|dbo.orders|ix_status'; Module = 'Indexes'; AnalyzedAtUtc = [datetime]::new(2026, 10, 1, 8, 0, 0); Verdict = 'DropRecommended'; CountsTowardSeries = $true; PeriodDays = [decimal]40; RulesProfile = 'Standard' }
			)
		}
		$config = New-TestRepositoryConfig
		$history = InModuleScope IndexAdvisor -Parameters @{ Config = $config } {
			param($Config)
			Get-IaRecommendationHistory -ObjectKeys @('AG1|Sales|dbo.Orders|IX_Status', 'ag1|sales|dbo.orders|ix_status') -Module Indexes -Config $Config
		}
		@($history).Count | Should -Be 2
		$history[0].runId | Should -Be $runA.ToString()
		$history[0].analyzedAtUtc | Should -Be '2026-10-01T08:00:00.000Z'
		$history[0].verdict | Should -Be 'DropRecommended'
		$history[0].countsTowardSeries | Should -BeTrue
		$history[1].periodDays | Should -Be 10.5
		$history[1].rulesProfile | Should -BeNullOrEmpty
		$command = $script:Captured[0]
		$command.commandText | Should -Match 'OPENJSON\(@ObjectKeys\)'
		$command.commandText | Should -Not -Match 'ix_status'
		($command.parameters | Where-Object { $_.name -eq '@ObjectKeys' }).value | Should -Be '["ag1|sales|dbo.orders|ix_status"]'
		($command.parameters | Where-Object { $_.name -eq '@Module' }).value | Should -Be 'Indexes'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Reader' }
	}

	It 'без репозиторію або без ключів — порожній масив без звернення до бази' {
		Mock -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand { throw 'не має викликатися' }
		$config = New-TestRepositoryConfig
		$empty = InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) Get-IaRecommendationHistory -ObjectKeys @() -Module Indexes -Config $Config }
		@($empty).Count | Should -Be 0
		$config.repository.enabled = $false
		$disabled = InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) Get-IaRecommendationHistory -ObjectKeys @('a|b|c.d|e') -Module Indexes -Config $Config }
		@($disabled).Count | Should -Be 0
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 0 -Exactly
	}
}

Describe 'Remove-IaExpiredHistory' {
	It 'видаляє запуски, старші за historyRetentionDays, параметром @CutoffUtc' {
		Mock -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand { $script:Captured = @($Commands); , @([ordered]@{ DeletedRuns = 5 }) }
		$config = New-TestRepositoryConfig
		$config.repository.historyRetentionDays = 100
		$removed = InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) Remove-IaExpiredHistory -Config $Config }
		$removed | Should -Be 5
		$command = $script:Captured[0]
		$command.commandText | Should -Match 'DELETE FROM Advisor\.AnalysisRun WHERE StartedAtUtc < @CutoffUtc;'
		$cutoff = ($command.parameters | Where-Object { $_.name -eq '@CutoffUtc' }).value
		$cutoff | Should -BeOfType [datetime]
		([datetime]::UtcNow - $cutoff).TotalDays | Should -BeGreaterThan 99.9
		([datetime]::UtcNow - $cutoff).TotalDays | Should -BeLessThan 100.1
	}

	It '-WhatIf і вимкнений репозиторій — 0 без звернення до бази' {
		Mock -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand { throw 'не має викликатися' }
		$config = New-TestRepositoryConfig
		InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) Remove-IaExpiredHistory -Config $Config -WhatIf } | Should -Be 0
		$config.repository.enabled = $false
		InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) Remove-IaExpiredHistory -Config $Config } | Should -Be 0
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 0 -Exactly
	}

	It 'відмова, якщо база-репозиторій входить до області аналізу на цільовому сервері' {
		Mock -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand { , @([ordered]@{ DeletedRuns = 0 }) }
		$config = New-TestRepositoryConfig -Server 'SQL01' -Database 'IndexAdvisor'
		$config.servers = @('SQL01')
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) Remove-IaExpiredHistory -Config $Config } } | Should -Throw -ExpectedMessage '*Відмова*'
		$config.scope.databases.exclude = @('IndexAdvisor')
		InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) Remove-IaExpiredHistory -Config $Config } | Should -Be 0
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaOutRepositoryCommand -Times 1 -Exactly
	}
}

Describe 'Підключення до репозиторію' {
	It 'рядок підключення не містить пароля; база — repository.database' {
		$config = New-TestRepositoryConfig
		$config.repository.authentication = 'Sql'
		$config.repository.login = 'ia_writer'
		$config.repository.passwordRef = 'env:IA_REPO_PASSWORD'
		$text = InModuleScope IndexAdvisor -Parameters @{ Config = $config } { param($Config) New-IaOutRepositoryConnectionString -Config $Config }
		$text | Should -Match 'Initial Catalog=IndexAdvisor'
		$text | Should -Match 'Data Source=REPO01'
		$text | Should -Not -Match '(?i)password|pwd'
		$text | Should -Not -Match '(?i)integrated security'
	}
}
