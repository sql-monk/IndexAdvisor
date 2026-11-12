BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'LlmTestHelpers.ps1')
	Register-IaLlmScriptDomMock

	function New-TestRecommendations {
		$drafts = (Get-IaTestFixture -Name 'llm-response.sample.json').recommendations
		$highRisk = (Get-IaTestFixture -Name 'llm-response.sample.json').recommendations[0]
		$highRisk.risk.level = 'High'
		$highRisk.target.index = 'IX_OrderDate_Big'
		return InModuleScope IndexAdvisor -Parameters @{ Drafts = @($drafts[0], $drafts[1], $highRisk) } {
			param($Drafts)
			, @($Drafts | ForEach-Object { New-IaRecommendation -Draft $_ -RunId 'run-1' -Module 'Indexes' })
		}
	}

	function Invoke-TestCrossCheck {
		param([object[]]$Recommendations, $Payload, $MaskingMap, $Config)
		return InModuleScope IndexAdvisor -Parameters @{ Recommendations = $Recommendations; Payload = $Payload; MaskingMap = $MaskingMap; Config = $Config } {
			param($Recommendations, $Payload, $MaskingMap, $Config)
			if ($MaskingMap) {
				Invoke-IaCrossCheck -Recommendations $Recommendations -Payload $Payload -MaskingMap $MaskingMap -Config $Config
			}
			else {
				Invoke-IaCrossCheck -Recommendations $Recommendations -Payload $Payload -Config $Config
			}
		}
	}
}

Describe 'Invoke-IaCrossCheck' {
	BeforeEach {
		$script:Config = New-IaLlmTestConfig
		$script:Config.llm.crossCheckProvider = 'checker'
		$script:Payload = [ordered]@{ module = 'Indexes'; masking = [ordered]@{ namesMasked = $false; literalsMasked = $true }; databases = @() }
		$script:Recommendations = New-TestRecommendations
		Mock -ModuleName IndexAdvisor Start-Sleep { }
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse -Text '{"verdict":"Disagree","notes":"Індекс IX_Status читають на вторинній репліці."}' -InputTokens 100 -OutputTokens 20 }
	}

	It 'без llm.crossCheckProvider нічого не викликає' {
		$script:Config.llm.crossCheckProvider = ''
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config
		$result.calls.Count | Should -Be 0
		$result.recommendations.Count | Should -Be 3
		$result.recommendations[1].crossCheck | Should -BeNullOrEmpty
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 0 -Exactly
	}

	It 'перевіряє лише критичні (DropIndex або risk High) і заповнює crossCheck' {
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config
		$result.calls.Count | Should -Be 2
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
			$body = ConvertFrom-Json -InputObject $Body -AsHashtable
			$body.model -eq 'gpt-checker' -and $body.response_format.type -eq 'json_object' -and $body.messages[1].content -match '"recommendation"'
		}
		$result.recommendations[0].crossCheck | Should -BeNullOrEmpty
		$drop = $result.recommendations[1].crossCheck
		$drop.provider | Should -Be 'checker'
		$drop.model | Should -Be 'gpt-checker'
		$drop.verdict | Should -Be 'Disagree'
		$drop.notes | Should -Match 'вторинній репліці'
		$drop.llmCallId | Should -Be $result.calls[0].llmCallId
		$result.recommendations[2].crossCheck.verdict | Should -Be 'Disagree'
		$result.calls[0].purpose | Should -Be 'CrossCheck'
		$result.calls[0].promptTemplateId | Should -Be 'cross-check'
		$result.calls[0].promptTemplateVersion | Should -Be 1
	}

	It 'друга модель не підпадає під перевизначення llm.model' {
		$script:Config.llm.provider = 'checker'
		$script:Config.llm.model = 'override-model'
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config
		$result.recommendations[1].crossCheck.model | Should -Be 'gpt-checker'
	}

	It 'маскує рекомендацію перед відправкою і розмасковує notes' {
		$script:Config.llm.maskNames = $true
		$map = InModuleScope IndexAdvisor { New-IaMaskingMap }
		$snapshotMasked = InModuleScope IndexAdvisor -Parameters @{ Snapshot = (Get-IaTestSnapshot); Map = $map; Config = $script:Config } {
			param($Snapshot, $Map, $Config)
			ConvertTo-IaMaskedObject -InputObject $Snapshot -Map $Map -Config $Config
		}
		$statusAlias = $map.names['IX_Status']
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse -Text ('{"verdict":"Agree","notes":"' + $statusAlias + ' не використовується."}') }
		$payload = [ordered]@{ module = 'Indexes'; masking = $snapshotMasked.masking; databases = @() }
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $payload -MaskingMap $map -Config $script:Config
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 0 -ParameterFilter { $Body -match 'IX_Status|Orders|Sales|AG1' }
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Body -match [regex]::Escape($statusAlias) -or $Body -match 'ix\d+' }
		$result.recommendations[1].crossCheck.verdict | Should -Be 'Agree'
		$result.recommendations[1].crossCheck.notes | Should -Be 'IX_Status не використовується.'
		$result.recommendations[1].target.index | Should -Be 'IX_Status'
	}

	It 'при llm.maskNames без мапи кидає IaConfigInvalid' {
		$script:Config.llm.maskNames = $true
		{ Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config } | Should -Throw -ErrorId 'IaConfigInvalid*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 0 -Exactly
	}

	It 'нерозбірна відповідь — Uncertain з поясненням' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse -Text 'Важко сказати.' }
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config
		$result.recommendations[1].crossCheck.verdict | Should -Be 'Uncertain'
		$result.recommendations[1].crossCheck.notes | Should -Match 'Не вдалося розібрати'
	}

	It 'помилка виклику — Uncertain з текстом помилки' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { throw (New-IaLlmTestHttpException -StatusCode 400 -Body '{"error":{"message":"bad request"}}') }
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config
		$result.calls.Count | Should -Be 2
		$result.calls[0].success | Should -BeFalse
		$result.recommendations[1].crossCheck.verdict | Should -Be 'Uncertain'
		$result.recommendations[1].crossCheck.notes | Should -Match 'HTTP 400'
	}

	It 'вичерпаний бюджет — Uncertain без винятку й без викликів' {
		$script:Config.llm.providers.checker.dailyBudgetUsd = 1
		$directory = Split-Path -Path $script:Config.llm.budgetLedgerPath -Parent
		$null = New-Item -ItemType Directory -Path $directory -Force
		$now = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)
		Set-Content -LiteralPath $script:Config.llm.budgetLedgerPath -Encoding utf8 -Value (ConvertTo-Json -InputObject @([ordered]@{ utc = $now; provider = 'checker'; model = 'gpt-checker'; inputTokens = 1; outputTokens = 1; costUsd = 5; purpose = 'CrossCheck' }))
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config
		$result.calls.Count | Should -Be 0
		$result.recommendations[1].crossCheck.verdict | Should -Be 'Uncertain'
		$result.recommendations[1].crossCheck.notes | Should -Match 'бюджет'
		$result.recommendations[2].crossCheck.verdict | Should -Be 'Uncertain'
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 0 -Exactly
	}

	It 'crossCheck відповідає схемі рекомендації' {
		$result = Invoke-TestCrossCheck -Recommendations $script:Recommendations -Payload $script:Payload -Config $script:Config
		$json = ConvertTo-Json -InputObject $result.recommendations[1] -Depth 20
		Test-IaJsonAgainstSchema -Json $json -Schema 'recommendation' | Should -BeTrue
	}
}
