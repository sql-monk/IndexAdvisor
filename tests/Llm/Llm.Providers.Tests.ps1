BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'LlmTestHelpers.ps1')
	$script:Messages = @(
		[ordered]@{ role = 'system'; content = 'Системні правила. Відповідай JSON.' }
		[ordered]@{ role = 'user'; content = 'Контекст: {"tables":[]}' }
	)
}

Describe 'Get-IaLlmProviderConfig' {
	BeforeEach {
		$script:Config = New-IaLlmTestConfig
	}

	It 'доповнює значення за замовчуванням зі схеми і додає name' {
		$provider = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Get-IaLlmProviderConfig -Name 'claude' -Config $Config }
		$provider.name | Should -Be 'claude'
		$provider.type | Should -Be 'Anthropic'
		$provider.maxTokensPerRequest | Should -Be 4096
		$provider.maxContextTokens | Should -Be 100000
		$provider.timeoutSeconds | Should -Be 120
		$provider.retryCount | Should -Be 3
		$provider.isLocal | Should -BeFalse
	}

	It 'llm.model перевизначає модель лише основного провайдера' {
		$script:Config.llm.model = 'gpt-override'
		$result = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } {
			param($Config)
			@{
				main = (Get-IaLlmProviderConfig -Name 'openai' -Config $Config).model
				ignored = (Get-IaLlmProviderConfig -Name 'openai' -Config $Config -IgnoreModelOverride).model
				other = (Get-IaLlmProviderConfig -Name 'checker' -Config $Config).model
			}
		}
		$result.main | Should -Be 'gpt-override'
		$result.ignored | Should -Be 'gpt-4.1'
		$result.other | Should -Be 'gpt-checker'
	}

	It 'кидає IaConfigInvalid, якщо провайдера немає' {
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Get-IaLlmProviderConfig -Name 'missing' -Config $Config } } |
			Should -Throw -ErrorId 'IaConfigInvalid*'
	}

	It 'вимагає endpoint для <Type>' -TestCases @(@{ Type = 'AzureOpenAI' }, @{ Type = 'OpenAICompatible' }) {
		$script:Config.llm.providers['broken'] = [ordered]@{ type = $Type; model = 'm'; apiKeyRef = 'env:IA_LLM_TEST_OPENAI' }
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Get-IaLlmProviderConfig -Name 'broken' -Config $Config } } |
			Should -Throw -ErrorId 'IaConfigInvalid*'
	}

	It 'відхиляє відкритий ключ у apiKeyRef і не показує його' {
		$script:Config.llm.providers['plain'] = [ordered]@{ type = 'OpenAI'; model = 'm'; apiKeyRef = 'sk-plaintext-SECRET-123456' }
		$caught = $null
		try {
			InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Get-IaLlmProviderConfig -Name 'plain' -Config $Config }
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaConfigInvalid*'
		$caught.Exception.Message | Should -Not -Match 'plaintext-SECRET'
	}

	It 'нормалізує регістр типу провайдера' {
		$script:Config.llm.providers['lower'] = [ordered]@{ type = 'openaicompatible'; endpoint = 'http://localhost:1234/v1'; model = 'm' }
		(InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Get-IaLlmProviderConfig -Name 'lower' -Config $Config }).type |
			Should -Be 'OpenAICompatible'
	}
}

Describe 'Assert-IaProviderAllowed (llm.localOnly)' {
	BeforeEach {
		$script:Config = New-IaLlmTestConfig
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse }
		Mock -ModuleName IndexAdvisor Write-IaLog { }
	}

	It 'без localOnly дозволяє будь-якого провайдера' {
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Assert-IaProviderAllowed -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Config $Config } } |
			Should -Not -Throw
	}

	It 'з localOnly забороняє <Name>' -TestCases @(@{ Name = 'openai' }, @{ Name = 'claude' }, @{ Name = 'azure' }) {
		$script:Config.llm.localOnly = $true
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Name = $Name } { param($Config, $Name) Assert-IaProviderAllowed -ProviderConfig (Get-IaLlmProviderConfig -Name $Name -Config $Config) -Config $Config } } |
			Should -Throw -ErrorId 'IaProviderNotAllowed*'
	}

	It 'з localOnly забороняє OpenAICompatible без isLocal' {
		$script:Config.llm.localOnly = $true
		$script:Config.llm.providers.local.isLocal = $false
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Assert-IaProviderAllowed -ProviderConfig (Get-IaLlmProviderConfig -Name 'local' -Config $Config) -Config $Config } } |
			Should -Throw -ErrorId 'IaProviderNotAllowed*'
	}

	It 'з localOnly дозволяє OpenAICompatible з isLocal = true' {
		$script:Config.llm.localOnly = $true
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Assert-IaProviderAllowed -ProviderConfig (Get-IaLlmProviderConfig -Name 'local' -Config $Config) -Config $Config } } |
			Should -Not -Throw
	}

	It 'Invoke-IaLlmChat у режимі localOnly не надсилає запит зовнішньому провайдеру' {
		$script:Config.llm.localOnly = $true
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
				param($Config, $Messages)
				Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
			} } | Should -Throw -ErrorId 'IaProviderNotAllowed*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 0 -Exactly
	}
}

Describe 'Invoke-IaLlmChat: формати запитів і розбір відповідей' {
	BeforeEach {
		$script:Config = New-IaLlmTestConfig
		Mock -ModuleName IndexAdvisor Write-IaLog { }
		Mock -ModuleName IndexAdvisor Start-Sleep { }
	}

	It 'OpenAI: /v1/chat/completions, Bearer, JSON-режим, max_completion_tokens; токени з usage і вартість' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse -Text '{"recommendations":[],"toolRequests":[]}' -InputTokens 1000 -OutputTokens 500 }
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -JsonResponse -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$body = ConvertFrom-Json -InputObject $Body -AsHashtable
			"$Uri" -eq 'https://api.openai.com/v1/chat/completions' -and $Method -eq 'Post' -and
			$Headers['Authorization'] -eq 'Bearer sk-test-openai-0123456789abcdef' -and
			$body.model -eq 'gpt-4.1' -and $body.max_completion_tokens -eq 4096 -and $body.response_format.type -eq 'json_object' -and
			$body.messages.Count -eq 2 -and $body.messages[0].role -eq 'system' -and $TimeoutSec -eq 120
		}
		$response.success | Should -BeTrue
		$response.provider | Should -Be 'openai'
		$response.model | Should -Be 'gpt-4.1'
		$response.purpose | Should -Be 'Analysis'
		$response.text | Should -Be '{"recommendations":[],"toolRequests":[]}'
		$response.inputTokens | Should -Be 1000
		$response.outputTokens | Should -Be 500
		$response.costUsd | Should -Be ([decimal]0.006)
		$response.finishReason | Should -Be 'stop'
		$response.llmCallId | Should -Not -BeNullOrEmpty
		$response.createdAtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
		@($response.Keys) | Should -Be @('llmCallId', 'provider', 'model', 'purpose', 'text', 'inputTokens', 'outputTokens', 'cacheWriteTokens', 'cacheReadTokens', 'costUsd', 'durationMs',
			'finishReason', 'createdAtUtc', 'promptTemplateId', 'promptTemplateVersion', 'success', 'error')
	}

	It 'Azure OpenAI: /openai/deployments/{model}/chat/completions?api-version=, заголовок api-key' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse }
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'azure' -Config $Config) -Messages $Messages -JsonResponse -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$body = ConvertFrom-Json -InputObject $Body -AsHashtable
			"$Uri" -eq 'https://res.openai.azure.com/openai/deployments/gpt4o-deploy/chat/completions?api-version=2024-10-21' -and
			$Headers['api-key'] -eq 'azure-test-key-0123456789' -and -not $Headers.Contains('Authorization') -and
			$body.max_tokens -eq 4096 -and $body.response_format.type -eq 'json_object'
		}
		$response.success | Should -BeTrue
	}

	It 'Anthropic: /v1/messages, x-api-key, anthropic-version, system окремо' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			[pscustomobject]@{
				id = 'msg_test'; type = 'message'; role = 'assistant'; stop_reason = 'end_turn'
				content = @([pscustomobject]@{ type = 'text'; text = '{"recommendations":[],' }, [pscustomobject]@{ type = 'text'; text = '"toolRequests":[]}' })
				usage = [pscustomobject]@{ input_tokens = 321; output_tokens = 45 }
			}
		}
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'claude' -Config $Config) -Messages $Messages -MaxTokens 1000 -JsonResponse -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$body = ConvertFrom-Json -InputObject $Body -AsHashtable
			"$Uri" -eq 'https://api.anthropic.com/v1/messages' -and
			$Headers['x-api-key'] -eq 'sk-ant-test-0123456789abcdef' -and $Headers['anthropic-version'] -eq '2023-06-01' -and
			$body.model -eq 'claude-test' -and $body.max_tokens -eq 1000 -and $body.system[0].text -like 'Системні правила*' -and
			$body.system[0].cache_control.type -eq 'ephemeral' -and $body.cache_control.type -eq 'ephemeral' -and
			$body.messages.Count -eq 1 -and $body.messages[0].role -eq 'user'
		}
		$response.text | Should -Be '{"recommendations":[],"toolRequests":[]}'
		$response.inputTokens | Should -Be 321
		$response.outputTokens | Should -Be 45
		$response.finishReason | Should -Be 'end_turn'
	}

	It 'Anthropic: кеш промптів — повний розмір промпту з usage і вартість запису та читання кешу' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			[pscustomobject]@{
				id = 'msg_cache'; type = 'message'; role = 'assistant'; stop_reason = 'end_turn'
				content = @([pscustomobject]@{ type = 'text'; text = '{"recommendations":[],"toolRequests":[]}' })
				usage = [pscustomobject]@{ input_tokens = 1000; cache_creation_input_tokens = 200000; cache_read_input_tokens = 800000; output_tokens = 100000 }
			}
		}
		$config = New-IaLlmTestConfig
		$config.llm.providers.claude.inputPricePer1MTokensUsd = 4
		$config.llm.providers.claude.outputPricePer1MTokensUsd = 20
		$config.llm.providers.claude.cacheReadPricePer1MTokensUsd = 0.2
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'claude' -Config $Config) -Messages $Messages -MaxTokens 1000 -JsonResponse -Config $Config
		}
		$response.inputTokens | Should -Be 1001000
		$response.cacheWriteTokens | Should -Be 200000
		$response.cacheReadTokens | Should -Be 800000
		# 1000 × 4 + 200000 × 5 (1,25 × 4) + 800000 × 0,2 + 100000 × 20 — за 1 млн токенів.
		$response.costUsd | Should -Be ([decimal]3.164)
	}

	It 'Anthropic: promptCaching = false — system рядком, без cache_control' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			[pscustomobject]@{
				id = 'msg_nocache'; type = 'message'; role = 'assistant'; stop_reason = 'end_turn'
				content = @([pscustomobject]@{ type = 'text'; text = '{"recommendations":[],"toolRequests":[]}' })
				usage = [pscustomobject]@{ input_tokens = 10; output_tokens = 5 }
			}
		}
		$config = New-IaLlmTestConfig
		$config.llm.providers.claude.promptCaching = $false
		$null = InModuleScope IndexAdvisor -Parameters @{ Config = $config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'claude' -Config $Config) -Messages $Messages -MaxTokens 1000 -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$body = ConvertFrom-Json -InputObject $Body -AsHashtable
			$body.system -is [string] -and -not $body.ContainsKey('cache_control')
		}
	}

	It 'Cohere: /v2/chat, Bearer, response_format; текст з message.content' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			[pscustomobject]@{
				id = 'c1'; finish_reason = 'COMPLETE'
				message = [pscustomobject]@{ role = 'assistant'; content = @([pscustomobject]@{ type = 'text'; text = '{"recommendations":[],"toolRequests":[]}' }) }
				usage = [pscustomobject]@{ billed_units = [pscustomobject]@{ input_tokens = 200; output_tokens = 20 }; tokens = [pscustomobject]@{ input_tokens = 210; output_tokens = 21 } }
			}
		}
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'cohere' -Config $Config) -Messages $Messages -JsonResponse -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$body = ConvertFrom-Json -InputObject $Body -AsHashtable
			"$Uri" -eq 'https://api.cohere.com/v2/chat' -and $Headers['Authorization'] -eq 'Bearer cohere-test-key-0123456789' -and
			$body.model -eq 'command-a' -and $body.response_format.type -eq 'json_object' -and $body.messages.Count -eq 2 -and $body.max_tokens -eq 4096
		}
		$response.text | Should -Be '{"recommendations":[],"toolRequests":[]}'
		$response.inputTokens | Should -Be 210
		$response.outputTokens | Should -Be 21
		$response.finishReason | Should -Be 'COMPLETE'
	}

	It 'OpenAICompatible: endpoint + /chat/completions, без ключа; без usage — оцінка Measure-IaTokens' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			[pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"recommendations":[],"toolRequests":[],"notes":"локально"}' }; finish_reason = 'stop' }) }
		}
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'local' -Config $Config) -Messages $Messages -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$body = ConvertFrom-Json -InputObject $Body -AsHashtable
			"$Uri" -eq 'http://localhost:11434/v1/chat/completions' -and -not $Headers.Contains('Authorization') -and
			$body.model -eq 'qwen2.5-coder' -and $body.max_tokens -eq 4096 -and -not $body.Contains('response_format')
		}
		$response.success | Should -BeTrue
		$response.inputTokens | Should -BeGreaterThan 0
		$response.outputTokens | Should -BeGreaterThan 0
		$response.costUsd | Should -Be 0
	}

	It 'MaxTokens не перевищує maxTokensPerRequest провайдера' {
		$script:Config.llm.providers.openai.maxTokensPerRequest = 2000
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse }
		$null = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -MaxTokens 50000 -Config $Config
		}
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { (ConvertFrom-Json -InputObject $Body -AsHashtable).max_completion_tokens -eq 2000 }
	}

	It 'без apiKeyRef для хмарного провайдера кидає IaSecretNotFound' {
		$script:Config.llm.providers.openai.apiKeyRef = ''
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse }
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
				param($Config, $Messages)
				Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
			} } | Should -Throw -ErrorId 'IaSecretNotFound*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 0 -Exactly
	}
}

Describe 'Invoke-IaLlmChat: повтори, таймаут і помилки' {
	BeforeEach {
		$script:Config = New-IaLlmTestConfig
		$script:Config.llm.providers.openai.retryCount = 2
		$script:Config.llm.providers.openai.timeoutSeconds = 15
		$script:Attempt = 0
		Mock -ModuleName IndexAdvisor Write-IaLog { }
		Mock -ModuleName IndexAdvisor Start-Sleep { }
	}

	It 'повторює на 429 і 503 з паузою, потім успіх' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			$script:Attempt++
			if ($script:Attempt -eq 1) { throw (New-IaLlmTestHttpException -StatusCode 429) }
			if ($script:Attempt -eq 2) { throw (New-IaLlmTestHttpException -StatusCode 503) }
			New-IaLlmTestOpenAiResponse
		}
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
		}
		$response.success | Should -BeTrue
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 3 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Start-Sleep -Times 2 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 1000 }
		Should -Invoke -ModuleName IndexAdvisor Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 2000 }
	}

	It 'після вичерпання повторів на 500 повертає success = false без винятку' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { throw (New-IaLlmTestHttpException -StatusCode 500 -Body '{"error":{"message":"internal"}}') }
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
		}
		$response.success | Should -BeFalse
		$response.error | Should -Match 'HTTP 500: internal'
		$response.inputTokens | Should -Be 0
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 3 -Exactly
	}

	It 'не повторює на 400' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { throw (New-IaLlmTestHttpException -StatusCode 400) }
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
		}
		$response.success | Should -BeFalse
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Start-Sleep -Times 0 -Exactly
	}

	It 'повторює на таймауті і передає timeoutSeconds у -TimeoutSec' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { throw [System.TimeoutException]::new('The request was canceled due to the configured HttpClient.Timeout of 15 seconds elapsing.') }
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
		}
		$response.success | Should -BeFalse
		$response.error | Should -Match '^Таймаут'
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 3 -Exactly -ParameterFilter { $TimeoutSec -eq 15 }
	}

	It 'не пропускає ключ API в помилку й журнал' {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { throw (New-IaLlmTestHttpException -StatusCode 401 -Body '{"error":{"message":"Incorrect API key provided: sk-test-openai-0123456789abcdef"}}') }
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
		}
		$response.error | Should -Match 'HTTP 401'
		$response.error | Should -Not -Match '0123456789abcdef'
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -Times 0 -ParameterFilter { ($Message + ($Data | ConvertTo-Json -Compress)) -match '0123456789abcdef' }
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -Times 0 -ParameterFilter { ($Data | ConvertTo-Json -Compress -Depth 5) -match 'Системні правила' }
	}
}

Describe 'Облік токенів, вартості й бюджет' {
	BeforeEach {
		$script:Config = New-IaLlmTestConfig
		Mock -ModuleName IndexAdvisor Write-IaLog { }
		Mock -ModuleName IndexAdvisor Invoke-RestMethod { New-IaLlmTestOpenAiResponse -InputTokens 1000 -OutputTokens 500 }
		$ledgerPath = $script:Config.llm.budgetLedgerPath
		if (Test-Path -LiteralPath $ledgerPath) {
			Remove-Item -LiteralPath $ledgerPath -Force
		}
		function Write-TestLedger {
			param([object[]]$Entries)
			$directory = Split-Path -Path $script:Config.llm.budgetLedgerPath -Parent
			$null = New-Item -ItemType Directory -Path $directory -Force
			Set-Content -LiteralPath $script:Config.llm.budgetLedgerPath -Value (ConvertTo-Json -InputObject $Entries -Depth 5) -Encoding utf8
		}
		$script:Now = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)
	}

	It 'Get-IaLlmCost рахує за цінами провайдера, Measure-IaTokens оцінює текст' {
		$result = InModuleScope IndexAdvisor {
			@{
				cost = Get-IaLlmCost -ProviderConfig @{ inputPricePer1MTokensUsd = 3; outputPricePer1MTokensUsd = 15 } -InputTokens 2000000 -OutputTokens 100000
				free = Get-IaLlmCost -ProviderConfig @{} -InputTokens 1000 -OutputTokens 1000
				empty = Measure-IaTokens -Text ''
				short = Measure-IaTokens -Text 'SELECT 1;'
				cyrillic = Measure-IaTokens -Text ('ї' * 100)
			}
		}
		$result.cost | Should -Be ([decimal]7.5)
		$result.free | Should -Be 0
		$result.empty | Should -Be 0
		$result.short | Should -BeGreaterThan 0
		$result.cyrillic | Should -BeGreaterThan 50
	}

	It 'записує кожен успішний виклик в облік' {
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Purpose ToolFollowUp -Config $Config
		}
		$ledger = @(Get-Content -LiteralPath $script:Config.llm.budgetLedgerPath -Raw | ConvertFrom-Json -AsHashtable)
		$ledger.Count | Should -Be 1
		$ledger[0].provider | Should -Be 'openai'
		$ledger[0].model | Should -Be 'gpt-4.1'
		$ledger[0].inputTokens | Should -Be 1000
		$ledger[0].outputTokens | Should -Be 500
		$ledger[0].costUsd | Should -Be 0.006
		$ledger[0].purpose | Should -Be 'ToolFollowUp'
		$response.costUsd | Should -Be ([decimal]0.006)
	}

	It 'Get-IaBudgetStatus рахує денні й місячні витрати провайдера' {
		Write-TestLedger -Entries @(
			[ordered]@{ utc = $script:Now; provider = 'openai'; model = 'gpt-4.1'; inputTokens = 1; outputTokens = 1; costUsd = 0.25; purpose = 'Analysis' }
			[ordered]@{ utc = $script:Now; provider = 'claude'; model = 'x'; inputTokens = 1; outputTokens = 1; costUsd = 5; purpose = 'Analysis' }
			[ordered]@{ utc = '2020-01-15T10:00:00.000Z'; provider = 'openai'; model = 'gpt-4.1'; inputTokens = 1; outputTokens = 1; costUsd = 100; purpose = 'Analysis' }
		)
		$script:Config.llm.providers.openai.dailyBudgetUsd = 1
		$script:Config.llm.providers.openai.monthlyBudgetUsd = 10
		$status = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config } { param($Config) Get-IaBudgetStatus -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Config $Config }
		$status.provider | Should -Be 'openai'
		$status.dailySpentUsd | Should -Be 0.25
		$status.monthlySpentUsd | Should -Be 0.25
		$status.dailyBudgetUsd | Should -Be 1
		$status.monthlyBudgetUsd | Should -Be 10
		$status.isExceeded | Should -BeFalse
	}

	It 'кидає IaBudgetExceeded до виклику, якщо <Kind> бюджет вичерпано' -TestCases @(@{ Kind = 'денний'; Key = 'dailyBudgetUsd' }, @{ Kind = 'місячний'; Key = 'monthlyBudgetUsd' }) {
		Write-TestLedger -Entries @([ordered]@{ utc = $script:Now; provider = 'openai'; model = 'gpt-4.1'; inputTokens = 1; outputTokens = 1; costUsd = 2; purpose = 'Analysis' })
		$script:Config.llm.providers.openai[$Key] = 2
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
				param($Config, $Messages)
				Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
			} } | Should -Throw -ErrorId 'IaBudgetExceeded*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 0 -Exactly
	}

	It 'враховує оцінку вартості майбутнього запиту' {
		Write-TestLedger -Entries @([ordered]@{ utc = $script:Now; provider = 'openai'; model = 'gpt-4.1'; inputTokens = 1; outputTokens = 1; costUsd = 0.99; purpose = 'Analysis' })
		$script:Config.llm.providers.openai.dailyBudgetUsd = 1
		$script:Config.llm.providers.openai.outputPricePer1MTokensUsd = 10
		# Вихід 4096 токенів x 10 USD / 1 млн = 0,041 USD > залишку 0,01 USD.
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
				param($Config, $Messages)
				Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
			} } | Should -Throw -ErrorId 'IaBudgetExceeded*'
	}

	It 'нульовий бюджет означає «без ліміту»' {
		Write-TestLedger -Entries @([ordered]@{ utc = $script:Now; provider = 'openai'; model = 'gpt-4.1'; inputTokens = 1; outputTokens = 1; costUsd = 1000; purpose = 'Analysis' })
		$response = InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
			param($Config, $Messages)
			Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config
		}
		$response.success | Should -BeTrue
		@(Get-Content -LiteralPath $script:Config.llm.budgetLedgerPath -Raw | ConvertFrom-Json).Count | Should -Be 2
	}

	It 'пошкоджений облік при заданому бюджеті блокує виклики' {
		$directory = Split-Path -Path $script:Config.llm.budgetLedgerPath -Parent
		$null = New-Item -ItemType Directory -Path $directory -Force
		Set-Content -LiteralPath $script:Config.llm.budgetLedgerPath -Value '{ broken' -Encoding utf8
		$script:Config.llm.providers.openai.dailyBudgetUsd = 100
		{ InModuleScope IndexAdvisor -Parameters @{ Config = $script:Config; Messages = $script:Messages } {
				param($Config, $Messages)
				Invoke-IaLlmChat -ProviderConfig (Get-IaLlmProviderConfig -Name 'openai' -Config $Config) -Messages $Messages -Config $Config -WarningAction SilentlyContinue
			} } | Should -Throw -ErrorId 'IaBudgetExceeded*'
	}
}
