# Тести циклу дозапитів моделі (Invoke-IaAnalysisLoop), потік Tools. SQL і LLM замокано.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Tools.TestHelpers.ps1')
	$script:module = Get-Module IndexAdvisor
	$script:tools = & $script:module { param($c) Import-IaToolDefinitions -Config $c } (Get-IaTestConfig)
	$script:recommendation = (Get-IaTestFixture -Name 'llm-response.sample.json').recommendations[0]
	$script:prompt = [ordered]@{
		templateId = 'index-analysis'
		templateVersion = 1
		messages = @(
			[ordered]@{ role = 'system'; content = 'Ти — DBA.' }
			[ordered]@{ role = 'user'; content = '{"payload":{}}' }
		)
		toolSchemas = @()
		responseSchema = $null
	}
	$script:provider = [ordered]@{ name = 'test'; type = 'OpenAI'; model = 'test-model' }

	function New-TestUsageRequest {
		param(
			[string]$Server = 'AG1',
			[string]$Database = 'Sales',
			[string]$Table = 'Orders',
			[string]$Tool = 'index_usage_stats',
			[hashtable]$ExtraArguments = @{}
		)
		$arguments = [ordered]@{ SchemaName = 'dbo'; TableName = $Table }
		foreach ($key in $ExtraArguments.Keys) {
			$arguments[$key] = $ExtraArguments[$key]
		}
		return [ordered]@{
			tool = $Tool
			server = $Server
			database = $Database
			arguments = $arguments
			fetch = 50
			skip = $null
			reason = 'Потрібна статистика використання'
		}
	}

	function Set-TestModelTexts {
		param([string[]]$Texts)
		$script:modelTexts = [System.Collections.Generic.Queue[string]]::new()
		foreach ($text in $Texts) {
			$script:modelTexts.Enqueue($text)
		}
		$script:chatCalls = [System.Collections.Generic.List[object]]::new()
	}

	function New-TestLoopConfig {
		param([switch]$AutoApprove)
		$config = Get-IaTestConfig
		$config.llm.autoApproveToolRequests = [bool]$AutoApprove
		return $config
	}

	function Invoke-TestLoop {
		param([System.Collections.IDictionary]$Config, [System.Collections.IDictionary]$MaskingMap, [System.Collections.IDictionary]$Snapshot)
		if ($null -eq $Snapshot) {
			$Snapshot = Get-IaTestSnapshot
		}
		return (& $script:module {
				param($p, $s, $pc, $t, $m, $c)
				Invoke-IaAnalysisLoop -Prompt $p -Snapshot $s -ProviderConfig $pc -Tools $t -MaskingMap $m -Config $c
			} $script:prompt $Snapshot $script:provider $script:tools $MaskingMap $Config)
	}
}

Describe 'Invoke-IaAnalysisLoop' {
	BeforeEach {
		$script:inputTokens = 100
		Mock -ModuleName IndexAdvisor Write-IaLog {}
		Mock -ModuleName IndexAdvisor Write-Host {}
		Mock -ModuleName IndexAdvisor Read-IaToolUserInput { throw 'Діалог не очікується' }
		Mock -ModuleName IndexAdvisor Invoke-IaLlmChat {
			$script:chatCalls.Add([ordered]@{ purpose = $Purpose; messages = @($Messages); json = [bool]$JsonResponse })
			if ($script:modelTexts.Count -eq 0) {
				throw 'Немає підготовлених відповідей моделі'
			}
			New-TestLlmResponse -Text $script:modelTexts.Dequeue() -Purpose $Purpose -InputTokens $script:inputTokens
		}
		Mock -ModuleName IndexAdvisor ConvertFrom-IaLlmResponse {
			$parsed = $Text | ConvertFrom-Json -AsHashtable
			[ordered]@{ recommendations = @($parsed.recommendations); toolRequests = @($parsed.toolRequests); notes = $parsed.notes; parseErrors = @() }
		}
		Mock -ModuleName IndexAdvisor ConvertTo-IaMaskedObject { $InputObject }
		Mock -ModuleName IndexAdvisor ConvertFrom-IaMaskedObject { $InputObject }
		Mock -ModuleName IndexAdvisor New-IaMaskingMap { [ordered]@{ names = [ordered]@{}; reverse = [ordered]@{}; counters = @{} } }
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery { New-TestEnvelope -Server $Server -Database $Database }
	}

	It 'відповідь без дозапитів: Completed, облік токенів і вартості, calls без тексту' {
		Set-TestModelTexts -Texts @(New-TestModelText -Recommendations @($script:recommendation) -Notes 'Нотатка')
		$result = Invoke-TestLoop -Config (New-TestLoopConfig)
		$result.stoppedReason | Should -Be 'Completed'
		@($result.recommendations).Count | Should -Be 1
		$result.recommendations[0].action | Should -Be 'CreateIndex'
		$result.notes | Should -Be 'Нотатка'
		@($result.calls).Count | Should -Be 1
		$result.calls[0].Contains('text') | Should -BeFalse
		$result.calls[0].promptTemplateId | Should -Be 'index-analysis'
		$result.calls[0].promptTemplateVersion | Should -Be 1
		@($result.toolRequests).Count | Should -Be 0
		$result.totalInputTokens | Should -Be 100
		$result.totalOutputTokens | Should -Be 50
		$result.totalCostUsd | Should -Be 0.01
		$result.error | Should -BeNullOrEmpty
		$result.prompt.templateId | Should -Be 'index-analysis'
		$script:chatCalls[0].purpose | Should -Be 'Analysis'
		$script:chatCalls[0].json | Should -BeTrue
		@($script:chatCalls[0].messages).Count | Should -Be 2
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 0 -Exactly
	}

	It 'дозапит з автопідтвердженням: AG -> primary, результат маскується й передається моделі' {
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest -Server 'AG1'))
			(New-TestModelText -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config (New-TestLoopConfig -AutoApprove)
		$result.stoppedReason | Should -Be 'Completed'
		@($result.calls).Count | Should -Be 2
		$result.totalInputTokens | Should -Be 200
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly -ParameterFilter {
			$Server -eq 'SQL01' -and $Database -eq 'Sales' -and $Purpose -eq 'Tool' -and $Fetch -eq 50 -and $Parameters.TableName -eq 'Orders'
		}
		Should -Invoke -ModuleName IndexAdvisor ConvertTo-IaMaskedObject -Times 1 -Exactly -ParameterFilter { $InputObject.type -eq 'toolResults' }
		$record = @($result.toolRequests)[0]
		$record.decision | Should -Be 'AutoApproved'
		$record.tool | Should -Be 'index_usage_stats'
		$record.server | Should -Be 'SQL01'
		$record.database | Should -Be 'Sales'
		$record.llmCallId | Should -Be $result.calls[0].llmCallId
		$record.arguments.TableName | Should -Be 'Orders'
		$record.arguments.MinUpdates | Should -Be 0
		$record.response.success | Should -BeTrue
		$record.response.rowCount | Should -Be 1
		$record.executedAtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
		$record.toolRequestId | Should -Not -BeNullOrEmpty
		$second = $script:chatCalls[1]
		$second.purpose | Should -Be 'ToolFollowUp'
		@($second.messages).Count | Should -Be 4
		$second.messages[2].role | Should -Be 'assistant'
		$second.messages[3].role | Should -Be 'user'
		$followUp = $second.messages[3].content | ConvertFrom-Json -AsHashtable
		$followUp.type | Should -Be 'toolResults'
		$followUp.results[0].decision | Should -Be 'AutoApproved'
		$followUp.results[0].result.rows[0].indexName | Should -Be 'IX_Status'
		$followUp.remainingToolRequests | Should -Be 9
	}

	It 'ім''я репліки -> ця репліка; requestedServer (listener) -> primary' -TestCases @(
		@{ Server = 'SQL02'; Expected = 'SQL02' }
		@{ Server = 'sql02'; Expected = 'SQL02' }
		@{ Server = 'AGL-SALES'; Expected = 'SQL01' }
		@{ Server = ''; Expected = 'SQL01' }
	) {
		param($Server, $Expected)
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest -Server $Server))
			(New-TestModelText)
		)
		$result = Invoke-TestLoop -Config (New-TestLoopConfig -AutoApprove)
		@($result.toolRequests)[0].decision | Should -Be 'AutoApproved'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly -ParameterFilter { $Server -eq $Expected -and $Database -eq 'Sales' }
	}

	It 'вторинна репліка з <Mode>: ApplicationIntent = <Intent>' -TestCases @(
		@{ Mode = 'READ_ONLY'; Intent = 'ReadOnly' }
		@{ Mode = 'ALL'; Intent = '' }
	) {
		param($Mode, $Intent)
		$snapshot = Get-IaTestSnapshot
		$snapshot.topology.availabilityGroups[0].replicas[1].secondaryAllowConnections = $Mode
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest -Server 'SQL02'))
			(New-TestModelText)
		)
		Invoke-TestLoop -Config (New-TestLoopConfig -AutoApprove) -Snapshot $snapshot | Out-Null
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly -ParameterFilter { $Server -eq 'SQL02' -and [string]$ApplicationIntent -eq $Intent }
	}

	It 'Blocked для сервера чи бази поза знімком: <Case>' -TestCases @(
		@{ Case = 'чужий сервер'; Request = @{ Server = 'OTHER01' }; Reason = '*OTHER01*' }
		@{ Case = 'чужа база'; Request = @{ Database = 'HR' }; Reason = '*HR*' }
		@{ Case = 'невідомий інструмент'; Request = @{ Tool = 'drop_index' }; Reason = '*невідомий інструмент*' }
		@{ Case = 'невідомий аргумент'; Request = @{ ExtraArguments = @{ Foo = 1 } }; Reason = "*невідомий аргумент 'Foo'*" }
		@{ Case = 'неправильний тип аргументу'; Request = @{ ExtraArguments = @{ MinUpdates = 'багато' } }; Reason = "*'MinUpdates'*" }
	) {
		param($Case, $Request, $Reason)
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest @Request))
			(New-TestModelText -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config (New-TestLoopConfig -AutoApprove)
		$result.stoppedReason | Should -Be 'Completed'
		$record = @($result.toolRequests)[0]
		$record.decision | Should -Be 'Blocked'
		$record.decisionReason | Should -BeLike $Reason
		$record.response | Should -BeNullOrEmpty
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -ParameterFilter { $Level -eq 'Warning' -and $Data.decision -eq 'Blocked' }
		($script:chatCalls[1].messages[3].content | ConvertFrom-Json -AsHashtable).results[0].decision | Should -Be 'Blocked'
	}

	It 'неінтерактивний режим без автопідтвердження: Rejected, SQL не виконується' {
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest))
			(New-TestModelText -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config (New-TestLoopConfig)
		@($result.toolRequests)[0].decision | Should -Be 'Rejected'
		@($result.toolRequests)[0].decisionReason | Should -BeLike '*nonInteractive*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 0 -Exactly
		$result.stoppedReason | Should -Be 'Completed'
	}

	It 'ToolLimit: понад ліміт дозапити блокуються, моделі надсилається вимога фінальної відповіді' {
		$config = New-TestLoopConfig -AutoApprove
		$config.limits.maxToolRequestsPerAnalysis = 1
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @((New-TestUsageRequest), (New-TestUsageRequest -Table 'Customers')))
			(New-TestModelText -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config $config
		$result.stoppedReason | Should -Be 'ToolLimit'
		@($result.toolRequests).Count | Should -Be 2
		$result.toolRequests[0].decision | Should -Be 'AutoApproved'
		$result.toolRequests[1].decision | Should -Be 'Blocked'
		$result.toolRequests[1].decisionReason | Should -BeLike '*maxToolRequestsPerAnalysis*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly
		$followUp = $script:chatCalls[1].messages[3].content | ConvertFrom-Json -AsHashtable
		$followUp.remainingToolRequests | Should -Be 0
		$followUp.instruction | Should -BeLike '*фінальну відповідь без дозапитів*'
		@($result.recommendations).Count | Should -Be 1
	}

	It 'ToolLimit: модель ігнорує вимогу фінальної відповіді — зупинка без нового виклику' {
		$config = New-TestLoopConfig -AutoApprove
		$config.limits.maxToolRequestsPerAnalysis = 1
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest))
			(New-TestModelText -ToolRequests @(New-TestUsageRequest -Table 'Customers') -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config $config
		$result.stoppedReason | Should -Be 'ToolLimit'
		@($result.calls).Count | Should -Be 2
		$result.toolRequests[1].decision | Should -Be 'Blocked'
		@($result.recommendations).Count | Should -Be 1
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaLlmChat -Times 2 -Exactly
	}

	It 'ліміт 0: усі дозапити блокуються одразу' {
		$config = New-TestLoopConfig -AutoApprove
		$config.limits.maxToolRequestsPerAnalysis = 0
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest))
			(New-TestModelText -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config $config
		$result.stoppedReason | Should -Be 'ToolLimit'
		$result.toolRequests[0].decision | Should -Be 'Blocked'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 0 -Exactly
	}

	It 'TokenLimit: наступний виклик перевищив би ліміт — дозапит не виконується' {
		$config = New-TestLoopConfig -AutoApprove
		$config.limits.maxTokensPerAnalysis = 1000
		$script:inputTokens = 600
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest) -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config $config
		$result.stoppedReason | Should -Be 'TokenLimit'
		$result.toolRequests[0].decision | Should -Be 'Blocked'
		$result.toolRequests[0].decisionReason | Should -BeLike '*maxTokensPerAnalysis*'
		@($result.recommendations).Count | Should -Be 1
		$result.notes | Should -BeLike '*ліміт токенів*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaLlmChat -Times 1 -Exactly
	}

	It 'BudgetExceeded: виняток IaBudgetExceeded зупиняє цикл' {
		Mock -ModuleName IndexAdvisor Invoke-IaLlmChat { Write-Error -Message 'Денний бюджет вичерпано' -ErrorId 'IaBudgetExceeded' -ErrorAction Stop }
		Set-TestModelTexts -Texts @()
		$result = Invoke-TestLoop -Config (New-TestLoopConfig)
		$result.stoppedReason | Should -Be 'BudgetExceeded'
		$result.error | Should -BeLike '*бюджет*'
		@($result.recommendations).Count | Should -Be 0
	}

	It 'Error: невдала відповідь моделі' {
		Mock -ModuleName IndexAdvisor Invoke-IaLlmChat { New-TestLlmResponse -Text $null -Success $false -ErrorValue 'HTTP 500' }
		$result = Invoke-TestLoop -Config (New-TestLoopConfig)
		$result.stoppedReason | Should -Be 'Error'
		$result.error | Should -BeLike '*HTTP 500*'
		@($result.calls).Count | Should -Be 1
	}

	It 'Error: відповідь не відповідає схемі й нічого не містить' {
		Mock -ModuleName IndexAdvisor ConvertFrom-IaLlmResponse { [ordered]@{ recommendations = @(); toolRequests = @(); notes = $null; parseErrors = @('не JSON') } }
		Set-TestModelTexts -Texts @('не JSON')
		$result = Invoke-TestLoop -Config (New-TestLoopConfig)
		$result.stoppedReason | Should -Be 'Error'
		$result.error | Should -BeLike '*не JSON*'
	}

	It 'Error: відповідь обрізано лімітом вихідних токенів — пояснення з maxTokensPerRequest замість помилки розбору' -TestCases @(
		@{ FinishReason = 'max_tokens' }
		@{ FinishReason = 'length' }
	) {
		Mock -ModuleName IndexAdvisor Invoke-IaLlmChat {
			$response = New-TestLlmResponse -Text '{"recommendations":[{"action":"AlterPartitioning","risk":' -Purpose $Purpose
			$response.finishReason = $FinishReason
			$response
		}
		Mock -ModuleName IndexAdvisor ConvertFrom-IaLlmResponse {
			[ordered]@{ recommendations = @(); toolRequests = @(); draftDecisions = @(); notes = $null; parseErrors = @('Unexpected end when deserializing object') }
		}
		$result = Invoke-TestLoop -Config (New-TestLoopConfig)
		$result.stoppedReason | Should -Be 'Error'
		$result.error | Should -BeLike "*обрізано лімітом вихідних токенів*finish_reason = $FinishReason*maxTokensPerRequest*"
	}

	It 'рішення щодо чернеток (draftDecisions) повертаються разом з рекомендаціями' {
		Mock -ModuleName IndexAdvisor ConvertFrom-IaLlmResponse {
			[ordered]@{
				recommendations = @()
				toolRequests = @()
				draftDecisions = @([ordered]@{ draftId = 'D01'; decision = 'Confirm'; reason = $null }, [ordered]@{ draftId = 'D02'; decision = 'Reject'; reason = 'Немає вигоди' })
				notes = $null
				parseErrors = @()
			}
		}
		Set-TestModelTexts -Texts @('{"recommendations":[],"toolRequests":[]}')
		$result = Invoke-TestLoop -Config (New-TestLoopConfig)
		$result.stoppedReason | Should -Be 'Completed'
		@($result.draftDecisions).Count | Should -Be 2
		$result.draftDecisions[1].decision | Should -Be 'Reject'
	}

	It 'розмасковує дозапит перед виконанням і фінальні рекомендації' {
		$testMap = [ordered]@{ names = [ordered]@{ Orders = 'tbl1' }; reverse = [ordered]@{ tbl1 = 'Orders' }; counters = @{} }
		Mock -ModuleName IndexAdvisor ConvertFrom-IaMaskedObject {
			$json = ConvertTo-Json -InputObject $InputObject -Depth 50
			$json.Replace('tbl1', 'Orders') | ConvertFrom-Json -AsHashtable
		}
		$maskedRecommendation = ConvertTo-Json -InputObject $script:recommendation -Depth 20 | ConvertFrom-Json -AsHashtable
		$maskedRecommendation.target.table = 'tbl1'
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest -Table 'tbl1'))
			(New-TestModelText -Recommendations @($maskedRecommendation))
		)
		$result = Invoke-TestLoop -Config (New-TestLoopConfig -AutoApprove) -MaskingMap $testMap
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly -ParameterFilter { $Parameters.TableName -eq 'Orders' }
		Should -Invoke -ModuleName IndexAdvisor ConvertFrom-IaMaskedObject -ParameterFilter { $Map.reverse.tbl1 -eq 'Orders' }
		Should -Invoke -ModuleName IndexAdvisor ConvertTo-IaMaskedObject -Times 1 -Exactly -ParameterFilter { $Map.reverse.tbl1 -eq 'Orders' }
		Should -Invoke -ModuleName IndexAdvisor New-IaMaskingMap -Times 0 -Exactly
		$result.recommendations[0].target.table | Should -Be 'Orders'
		$result.toolRequests[0].arguments.TableName | Should -Be 'Orders'
	}

	It 'без мапи маскування результат усе одно проходить ConvertTo-IaMaskedObject (очищення літералів)' {
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest))
			(New-TestModelText)
		)
		$null = Invoke-TestLoop -Config (New-TestLoopConfig -AutoApprove)
		Should -Invoke -ModuleName IndexAdvisor New-IaMaskingMap -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor ConvertTo-IaMaskedObject -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor ConvertFrom-IaMaskedObject -Times 0 -Exactly
	}

	It 'помилка SQL передається моделі в конверті, цикл продовжується' {
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery {
			$envelope = New-TestEnvelope -Server $Server -Database $Database
			$envelope.success = $false
			$envelope.rowCount = 0
			$envelope.rows = @()
			$envelope.error = [ordered]@{ code = 'Timeout'; message = 'Перевищено таймаут'; line = $null; column = $null }
			$envelope
		}
		Set-TestModelTexts -Texts @(
			(New-TestModelText -ToolRequests @(New-TestUsageRequest))
			(New-TestModelText -Recommendations @($script:recommendation))
		)
		$result = Invoke-TestLoop -Config (New-TestLoopConfig -AutoApprove)
		$result.stoppedReason | Should -Be 'Completed'
		$result.toolRequests[0].response.success | Should -BeFalse
		$result.toolRequests[0].response.error.code | Should -Be 'Timeout'
		($script:chatCalls[1].messages[3].content | ConvertFrom-Json -AsHashtable).results[0].result.error.code | Should -Be 'Timeout'
	}
}
