# Помічники юніт-тестів потоку LLM. Використання: у BeforeAll після TestHelpers.ps1 —
#   . (Join-Path $PSScriptRoot 'LlmTestHelpers.ps1')
# Core (Get-IaScriptDomParser, ConvertTo-IaSqlFragment) ще може бути заглушкою, тому тести мокають ці функції
# справжнім парсером ScriptDom з локальної збірки dbatools.library (ScriptDom не мокається).

function Get-IaLlmTestScriptDomPath {
	<# Шлях до Microsoft.SqlServer.TransactSql.ScriptDom.dll з найновішого dbatools.library. #>
	$module = Get-Module -ListAvailable -Name dbatools.library | Sort-Object -Property Version -Descending | Select-Object -First 1
	if ($null -eq $module) {
		throw 'Для тестів потрібен модуль dbatools.library (ScriptDom).'
	}
	return (Join-Path $module.ModuleBase 'core\lib\Microsoft.SqlServer.TransactSql.ScriptDom.dll')
}

function New-IaLlmTestParser {
	<# Справжній TSql160Parser (збірка завантажується за потреби). #>
	if (-not ('Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -as [type])) {
		Add-Type -LiteralPath (Get-IaLlmTestScriptDomPath)
	}
	return (New-Object -TypeName 'Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -ArgumentList $true)
}

function Register-IaLlmScriptDomMock {
	<# Мокає контрактні функції Core для ScriptDom справжнім парсером. Викликати в BeforeAll/BeforeEach. #>
	Mock -ModuleName IndexAdvisor Get-IaScriptDomParser { New-IaLlmTestParser }
	Mock -ModuleName IndexAdvisor ConvertTo-IaSqlFragment {
		$parser = New-IaLlmTestParser
		$errors = $null
		$fragment = $parser.Parse([System.IO.StringReader]::new($Sql), [ref]$errors)
		@{ fragment = $fragment; errors = @($errors | ForEach-Object { @{ code = 'SqlError'; message = $_.Message; line = $_.Line; column = $_.Column } }); parserName = 'TSql160Parser' }
	}
	Mock -ModuleName IndexAdvisor Write-IaLog { }
}

function New-IaLlmTestConfig {
	<# Конфігурація з тестовими провайдерами всіх типів (ключі — у змінних середовища IA_LLM_TEST_*). #>
	$config = Get-IaTestConfig
	$config.llm.provider = 'openai'
	$config.llm.providers = [ordered]@{
		openai = [ordered]@{ type = 'OpenAI'; model = 'gpt-4.1'; apiKeyRef = 'env:IA_LLM_TEST_OPENAI'; inputPricePer1MTokensUsd = 2; outputPricePer1MTokensUsd = 8 }
		azure = [ordered]@{ type = 'AzureOpenAI'; endpoint = 'https://res.openai.azure.com/'; model = 'gpt4o-deploy'; apiKeyRef = 'env:IA_LLM_TEST_AZURE'; apiVersion = '2024-10-21' }
		claude = [ordered]@{ type = 'Anthropic'; model = 'claude-test'; apiKeyRef = 'env:IA_LLM_TEST_ANTHROPIC' }
		cohere = [ordered]@{ type = 'Cohere'; model = 'command-a'; apiKeyRef = 'env:IA_LLM_TEST_COHERE' }
		local = [ordered]@{ type = 'OpenAICompatible'; endpoint = 'http://localhost:11434/v1'; model = 'qwen2.5-coder'; isLocal = $true }
		checker = [ordered]@{ type = 'OpenAI'; model = 'gpt-checker'; apiKeyRef = 'env:IA_LLM_TEST_OPENAI' }
	}
	$env:IA_LLM_TEST_OPENAI = 'sk-test-openai-0123456789abcdef'
	$env:IA_LLM_TEST_AZURE = 'azure-test-key-0123456789'
	$env:IA_LLM_TEST_ANTHROPIC = 'sk-ant-test-0123456789abcdef'
	$env:IA_LLM_TEST_COHERE = 'cohere-test-key-0123456789'
	return $config
}

function New-IaLlmTestOpenAiResponse {
	<# Відповідь OpenAI chat completions з текстом і usage. #>
	param([string]$Text = '{"recommendations":[],"toolRequests":[],"notes":"ok"}', [int]$InputTokens = 1000, [int]$OutputTokens = 500)
	return [pscustomobject]@{
		id = 'chatcmpl-test'
		choices = @([pscustomobject]@{ index = 0; message = [pscustomobject]@{ role = 'assistant'; content = $Text }; finish_reason = 'stop' })
		usage = [pscustomobject]@{ prompt_tokens = $InputTokens; completion_tokens = $OutputTokens; total_tokens = $InputTokens + $OutputTokens }
	}
}

function New-IaLlmTestHttpException {
	<# Помилка HTTP, як її кидає Invoke-RestMethod. #>
	param([int]$StatusCode, [string]$Body)
	$message = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$StatusCode)
	$exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: $StatusCode.", $message)
	$record = [System.Management.Automation.ErrorRecord]::new($exception, 'WebCmdletWebResponseException', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
	if ($Body) {
		$record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body)
	}
	return $record
}
