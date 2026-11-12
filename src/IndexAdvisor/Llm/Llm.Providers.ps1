# Шар LLM-провайдерів з однаковим інтерфейсом (ТЗ розділ 5; CONTRACTS.md 3.4, 5.5).
# OpenAI, Azure OpenAI, Anthropic, Cohere, OpenAI-сумісні локальні моделі (Ollama, vLLM, LM Studio).
# Модель отримує лише метадані; доступу до серверів у неї немає. Ключі API не логуються й не потрапляють у помилки.

$script:IaLlmProviderTypes = @('OpenAI', 'Anthropic', 'Cohere', 'AzureOpenAI', 'OpenAICompatible')
$script:IaLlmDefaultEndpoints = @{
	OpenAI = 'https://api.openai.com/v1'
	Anthropic = 'https://api.anthropic.com'
	Cohere = 'https://api.cohere.com'
}
$script:IaLlmDefaultAzureApiVersion = '2024-10-21'
$script:IaLlmDefaultAnthropicVersion = '2023-06-01'
$script:IaLlmMaxRetryDelaySeconds = 60

function Get-IaLlmProviderSchema {
	<# Внутрішня: вузол схеми конфігурації для одного провайдера (llm.providers.<name>). #>
	$llmNode = (Get-IaConfigSchema).Properties | Where-Object { $_.Name -eq 'llm' } | Select-Object -First 1
	$providersNode = $llmNode.Properties | Where-Object { $_.Name -eq 'providers' } | Select-Object -First 1
	return $providersNode.Values
}

function Get-IaLlmProviderConfig {
	<# Налаштування провайдера llm.providers[Name] з доповненими значеннями за замовчуванням, ключем name і
	   перевизначенням llm.model (лише для основного провайдера). Кидає виняток, якщо провайдера немає. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[switch]$IgnoreModelOverride
	)
	$llm = Get-IaLlmValue -InputObject $Config -Name 'llm'
	$providers = Get-IaLlmValue -InputObject $llm -Name 'providers'
	$source = $null
	$providerName = $Name
	if ($providers -is [System.Collections.IDictionary]) {
		foreach ($key in $providers.Keys) {
			if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
				$source = $providers[$key]
				$providerName = [string]$key
				break
			}
		}
	}
	if ($source -isnot [System.Collections.IDictionary]) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category ObjectNotFound -Message "Провайдера '$Name' немає в llm.providers."))
	}

	$result = [ordered]@{ name = $providerName }
	foreach ($property in (Get-IaLlmProviderSchema).Properties) {
		$value = Get-IaLlmValue -InputObject $source -Name $property.Name
		if ($null -eq $value -and $property.ContainsKey('Default')) {
			$value = $property.Default
		}
		$result[$property.Name] = $value
	}

	$type = $script:IaLlmProviderTypes | Where-Object { [string]::Equals($_, [string]$result['type'], [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
	if (-not $type) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category InvalidData -Message (
			"llm.providers.$providerName.type: '$($result['type'])' не підтримується; допустимо: $($script:IaLlmProviderTypes -join ', ').")))
	}
	$result['type'] = $type
	$result['endpoint'] = [string]$result['endpoint']
	$result['apiKeyRef'] = [string]$result['apiKeyRef']
	$result['apiVersion'] = [string]$result['apiVersion']
	$result['isLocal'] = ConvertTo-IaLlmBool -Value $result['isLocal']

	if (-not $IgnoreModelOverride) {
		$mainProvider = [string](Get-IaLlmValue -InputObject $llm -Name 'provider')
		$modelOverride = [string](Get-IaLlmValue -InputObject $llm -Name 'model')
		if ($modelOverride -and [string]::Equals($mainProvider, $providerName, [System.StringComparison]::OrdinalIgnoreCase)) {
			$result['model'] = $modelOverride
		}
	}
	if ([string]::IsNullOrWhiteSpace([string]$result['model'])) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category InvalidData -Message "llm.providers.$providerName.model: модель не задано."))
	}
	if ($type -in @('AzureOpenAI', 'OpenAICompatible') -and [string]::IsNullOrWhiteSpace($result['endpoint'])) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category InvalidData -Message "llm.providers.$providerName.endpoint: для типу $type endpoint обов'язковий."))
	}
	if ($result['apiKeyRef'] -and -not (Test-IaSecretReference -Reference $result['apiKeyRef'])) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category InvalidData -Message (
			"llm.providers.$providerName.apiKeyRef: потрібне посилання на секрет (env:ІМ'Я, secret:Ім'я або secret:Сховище/Ім'я), " +
			'а не сам ключ. Значення не показується з міркувань безпеки.')))
	}
	return $result
}

function Assert-IaProviderAllowed {
	<# Режим llm.localOnly: дозволено лише type = OpenAICompatible з isLocal = $true; інакше виняток 'IaProviderNotAllowed'. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$localOnly = ConvertTo-IaLlmBool -Value (Get-IaLlmValue -InputObject (Get-IaLlmValue -InputObject $Config -Name 'llm') -Name 'localOnly')
	if (-not $localOnly) {
		return
	}
	$type = [string](Get-IaLlmValue -InputObject $ProviderConfig -Name 'type')
	$isLocal = ConvertTo-IaLlmBool -Value (Get-IaLlmValue -InputObject $ProviderConfig -Name 'isLocal')
	if ($type -ne 'OpenAICompatible' -or -not $isLocal) {
		$name = [string](Get-IaLlmValue -InputObject $ProviderConfig -Name 'name')
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaProviderNotAllowed' -Category SecurityError -Message (
			"Увімкнено режим «тільки локальна модель» (llm.localOnly): провайдер '$name' типу '$type' заборонений. " +
			'Дозволено лише тип OpenAICompatible з isLocal = true.')))
	}
}

function Get-IaLlmSetting {
	<# Внутрішня: значення налаштування провайдера з урахуванням значення за замовчуванням зі схеми. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][string]$Name
	)
	$value = Get-IaLlmValue -InputObject $ProviderConfig -Name $Name
	if ($null -eq $value -or ($value -is [string] -and $value -eq '' -and $Name -notin @('endpoint', 'apiKeyRef', 'apiVersion'))) {
		$node = (Get-IaLlmProviderSchema).Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
		if ($node -and $node.ContainsKey('Default')) {
			$value = $node.Default
		}
	}
	return $value
}

function Join-IaLlmOpenAiUri {
	<# Внутрішня: URI chat completions для OpenAI та OpenAI-сумісних серверів (база з /v1 або без). #>
	param([Parameter(Mandatory)][string]$Endpoint)
	$base = $Endpoint.TrimEnd('/')
	if ($base -match '/chat/completions$') {
		return $base
	}
	if ($base -notmatch '/v\d+$') {
		$base += '/v1'
	}
	return "$base/chat/completions"
}

function New-IaLlmHttpRequest {
	<# Внутрішня: @{ uri; headers; body (JSON) } для типу провайдера. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][System.Collections.IDictionary[]]$Messages,
		[Parameter(Mandatory)][int]$MaxTokens,
		[bool]$JsonResponse,
		[AllowNull()][AllowEmptyString()][string]$ApiKey
	)
	$type = [string]$ProviderConfig['type']
	$model = [string]$ProviderConfig['model']
	$endpoint = ([string]$ProviderConfig['endpoint']).Trim()
	if (-not $endpoint -and $script:IaLlmDefaultEndpoints.ContainsKey($type)) {
		$endpoint = $script:IaLlmDefaultEndpoints[$type]
	}
	$endpoint = $endpoint.TrimEnd('/')
	$chatMessages = @(foreach ($message in $Messages) {
		[ordered]@{ role = ([string]$message['role']).ToLowerInvariant(); content = [string]$message['content'] }
	})
	$headers = [ordered]@{}
	$body = [ordered]@{}
	switch ($type) {
		{ $_ -in @('OpenAI', 'OpenAICompatible') } {
			$uri = Join-IaLlmOpenAiUri -Endpoint $endpoint
			if ($ApiKey) {
				$headers['Authorization'] = "Bearer $ApiKey"
			}
			$body['model'] = $model
			$body['messages'] = $chatMessages
			# OpenAI приймає max_completion_tokens для всіх чат-моделей; локальні сервери — max_tokens.
			if ($type -eq 'OpenAI') {
				$body['max_completion_tokens'] = $MaxTokens
			}
			else {
				$body['max_tokens'] = $MaxTokens
			}
			if ($JsonResponse) {
				$body['response_format'] = [ordered]@{ type = 'json_object' }
			}
			break
		}
		'AzureOpenAI' {
			$apiVersion = [string]$ProviderConfig['apiVersion']
			if (-not $apiVersion) {
				$apiVersion = $script:IaLlmDefaultAzureApiVersion
			}
			$uri = '{0}/openai/deployments/{1}/chat/completions?api-version={2}' -f $endpoint, [uri]::EscapeDataString($model), [uri]::EscapeDataString($apiVersion)
			$headers['api-key'] = $ApiKey
			$body['messages'] = $chatMessages
			# Нові версії API (з 2024-12-01) підтримують max_completion_tokens (потрібен для o-серії); старші — лише max_tokens.
			if ([string]::CompareOrdinal($apiVersion, '2024-12-01') -ge 0) {
				$body['max_completion_tokens'] = $MaxTokens
			}
			else {
				$body['max_tokens'] = $MaxTokens
			}
			if ($JsonResponse) {
				$body['response_format'] = [ordered]@{ type = 'json_object' }
			}
			break
		}
		'Anthropic' {
			$uri = if ($endpoint -match '/messages$') { $endpoint } elseif ($endpoint -match '/v1$') { "$endpoint/messages" } else { "$endpoint/v1/messages" }
			$apiVersion = [string]$ProviderConfig['apiVersion']
			if (-not $apiVersion) {
				$apiVersion = $script:IaLlmDefaultAnthropicVersion
			}
			$headers['x-api-key'] = $ApiKey
			$headers['anthropic-version'] = $apiVersion
			$system = (@($chatMessages | Where-Object { $_.role -eq 'system' } | ForEach-Object { $_.content }) -join "`n`n")
			if ($JsonResponse) {
				$system = ($system + "`n`nВідповідай лише одним JSON-об'єктом, без Markdown і без тексту поза JSON.").Trim()
			}
			# Кешування промптів: явна точка кешу на статичному системному промпті (спільний для запусків і серверів у межах TTL)
			# і автоматичне кешування діалогу на рівні запиту — у циклі дозапитів великий контекст читається з кешу.
			$caching = $null -eq $ProviderConfig['promptCaching'] -or [bool]$ProviderConfig['promptCaching']
			$body['model'] = $model
			$body['max_tokens'] = $MaxTokens
			if ($system -and $caching) {
				# Пряме присвоєння масиву: вираз if розгорнув би масив з одного блоку в об'єкт, а API чекає масив блоків.
				$body['system'] = @([ordered]@{ type = 'text'; text = $system; cache_control = [ordered]@{ type = 'ephemeral' } })
			}
			elseif ($system) {
				$body['system'] = $system
			}
			$body['messages'] = @($chatMessages | Where-Object { $_.role -ne 'system' })
			if ($caching) {
				$body['cache_control'] = [ordered]@{ type = 'ephemeral' }
			}
			break
		}
		'Cohere' {
			$uri = if ($endpoint -match '/chat$') { $endpoint } elseif ($endpoint -match '/v2$') { "$endpoint/chat" } else { "$endpoint/v2/chat" }
			$headers['Authorization'] = "Bearer $ApiKey"
			$body['model'] = $model
			$body['messages'] = $chatMessages
			$body['max_tokens'] = $MaxTokens
			if ($JsonResponse) {
				$body['response_format'] = [ordered]@{ type = 'json_object' }
			}
			break
		}
		default {
			throw (New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category InvalidData -Message "Тип провайдера '$type' не підтримується.")
		}
	}
	$headers['Accept'] = 'application/json'
	return @{
		uri = $uri
		headers = $headers
		body = (ConvertTo-Json -InputObject $body -Depth 20 -Compress)
	}
}

function ConvertFrom-IaLlmHttpResponse {
	<# Внутрішня: @{ text; finishReason; inputTokens; outputTokens } з відповіді провайдера (токени — $null, якщо usage немає). #>
	param(
		[Parameter(Mandatory)][string]$Type,
		[AllowNull()]$Response
	)
	if ($Response -is [string]) {
		$Response = ConvertFrom-Json -InputObject $Response -Depth 50 -ErrorAction Stop
	}
	if ($null -eq $Response) {
		throw 'Порожня відповідь провайдера.'
	}
	$text = $null
	$finishReason = $null
	$inputTokens = $null
	$outputTokens = $null
	$cacheWrite = 0
	$cacheRead = 0
	switch ($Type) {
		'Anthropic' {
			$content = Get-IaLlmValue -InputObject $Response -Name 'content'
			$parts = @($content) | Where-Object { [string](Get-IaLlmValue -InputObject $_ -Name 'type') -eq 'text' }
			if ($parts) {
				$text = (@($parts | ForEach-Object { [string](Get-IaLlmValue -InputObject $_ -Name 'text') }) -join '')
			}
			$finishReason = Get-IaLlmValue -InputObject $Response -Name 'stop_reason'
			$usage = Get-IaLlmValue -InputObject $Response -Name 'usage'
			$outputTokens = Get-IaLlmValue -InputObject $usage -Name 'output_tokens'
			# input_tokens — лише некешований залишок; повний розмір промпту = input + запис у кеш + читання з кешу.
			$uncached = Get-IaLlmValue -InputObject $usage -Name 'input_tokens'
			$cacheWrite = [long]((Get-IaLlmValue -InputObject $usage -Name 'cache_creation_input_tokens') ?? 0)
			$cacheRead = [long]((Get-IaLlmValue -InputObject $usage -Name 'cache_read_input_tokens') ?? 0)
			$inputTokens = if ($null -ne $uncached) { [long]$uncached + $cacheWrite + $cacheRead } else { $null }
			break
		}
		'Cohere' {
			$message = Get-IaLlmValue -InputObject $Response -Name 'message'
			$content = Get-IaLlmValue -InputObject $message -Name 'content'
			if ($content -is [string]) {
				$text = $content
			}
			else {
				$parts = @($content) | Where-Object { $null -ne $_ -and [string](Get-IaLlmValue -InputObject $_ -Name 'type') -eq 'text' }
				if ($parts) {
					$text = (@($parts | ForEach-Object { [string](Get-IaLlmValue -InputObject $_ -Name 'text') }) -join '')
				}
			}
			$finishReason = Get-IaLlmValue -InputObject $Response -Name 'finish_reason'
			$usage = Get-IaLlmValue -InputObject $Response -Name 'usage'
			$tokens = Get-IaLlmValue -InputObject $usage -Name 'tokens'
			if ($null -eq $tokens) {
				$tokens = Get-IaLlmValue -InputObject $usage -Name 'billed_units'
			}
			$inputTokens = Get-IaLlmValue -InputObject $tokens -Name 'input_tokens'
			$outputTokens = Get-IaLlmValue -InputObject $tokens -Name 'output_tokens'
			break
		}
		default {
			$choices = Get-IaLlmValue -InputObject $Response -Name 'choices'
			$choice = @($choices) | Select-Object -First 1
			$message = Get-IaLlmValue -InputObject $choice -Name 'message'
			$content = Get-IaLlmValue -InputObject $message -Name 'content'
			if ($content -is [string]) {
				$text = $content
			}
			elseif ($null -ne $content) {
				$text = (@(@($content) | ForEach-Object { [string](Get-IaLlmValue -InputObject $_ -Name 'text') }) -join '')
			}
			$finishReason = Get-IaLlmValue -InputObject $choice -Name 'finish_reason'
			$usage = Get-IaLlmValue -InputObject $Response -Name 'usage'
			$inputTokens = Get-IaLlmValue -InputObject $usage -Name 'prompt_tokens'
			$outputTokens = Get-IaLlmValue -InputObject $usage -Name 'completion_tokens'
			# Автоматичне кешування OpenAI: cached_tokens входять у prompt_tokens і оплачуються зі знижкою.
			$cacheRead = [long]((Get-IaLlmValue -InputObject (Get-IaLlmValue -InputObject $usage -Name 'prompt_tokens_details') -Name 'cached_tokens') ?? 0)
		}
	}
	if ([string]::IsNullOrEmpty($text)) {
		throw 'Відповідь провайдера не містить тексту.'
	}
	return @{
		text = $text
		finishReason = $(if ($null -ne $finishReason) { [string]$finishReason } else { $null })
		inputTokens = $(if ($null -ne $inputTokens) { [long]$inputTokens } else { $null })
		outputTokens = $(if ($null -ne $outputTokens) { [long]$outputTokens } else { $null })
		cacheWriteTokens = [long]$(if ($cacheWrite) { $cacheWrite } else { 0 })
		cacheReadTokens = [long]$(if ($cacheRead) { $cacheRead } else { 0 })
	}
}

function Protect-IaLlmSecretText {
	<# Внутрішня: прибирає з тексту ключ API (та схожі на ключі фрагменти) і обрізає довгі повідомлення. #>
	param(
		[AllowNull()][AllowEmptyString()][string]$Text,
		[AllowNull()][AllowEmptyString()][string]$Secret
	)
	if ([string]::IsNullOrEmpty($Text)) {
		return $Text
	}
	if ($Secret -and $Secret.Length -ge 4) {
		$Text = $Text.Replace($Secret, '***')
	}
	$Text = [regex]::Replace($Text, '(?i)(bearer\s+|api[-_]?key["'':=\s]+|x-api-key["'':=\s]+)[^\s"'',;]{6,}', '$1***')
	$Text = [regex]::Replace($Text, '\b(sk|rk|pk)-[A-Za-z0-9_\-]{8,}', '$1-***')
	if ($Text.Length -gt 1000) {
		$Text = $Text.Substring(0, 1000) + '…'
	}
	return $Text
}

function Test-IaLlmTimeoutException {
	<# Внутрішня: $true, якщо виняток (або вкладений) означає таймаут HTTP-запиту. #>
	param([AllowNull()][System.Exception]$Exception)
	$current = $Exception
	while ($null -ne $current) {
		if ($current -is [System.TimeoutException] -or $current -is [System.OperationCanceledException]) {
			return $true
		}
		if ($current.Message -match '(?i)timed out|timeout') {
			return $true
		}
		$current = $current.InnerException
	}
	return $false
}

function Get-IaLlmHttpFailure {
	<# Внутрішня: класифікація помилки виклику: @{ retryable; statusCode; isTimeout; retryAfterSeconds; message }. #>
	param(
		[Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
		[AllowNull()][AllowEmptyString()][string]$Secret
	)
	$exception = $ErrorRecord.Exception
	$statusCode = $null
	$retryAfter = $null
	$response = $null
	if ($null -ne $exception.PSObject.Properties['Response']) {
		$response = $exception.Response
	}
	if ($null -ne $response) {
		try {
			$statusCode = [int]$response.StatusCode
		}
		catch {
			$statusCode = $null
		}
		try {
			$retryHeader = $response.Headers.RetryAfter
			if ($null -ne $retryHeader) {
				if ($null -ne $retryHeader.Delta) {
					$retryAfter = [Math]::Ceiling($retryHeader.Delta.TotalSeconds)
				}
				elseif ($null -ne $retryHeader.Date) {
					$retryAfter = [Math]::Ceiling(($retryHeader.Date - [System.DateTimeOffset]::UtcNow).TotalSeconds)
				}
			}
		}
		catch {
			$retryAfter = $null
		}
	}
	if ($null -eq $statusCode -and $null -ne $exception.PSObject.Properties['StatusCode'] -and $null -ne $exception.StatusCode) {
		$statusCode = [int]$exception.StatusCode
	}
	$isTimeout = ($null -eq $statusCode) -and (Test-IaLlmTimeoutException -Exception $exception)
	$detail = $null
	if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
		$detail = $ErrorRecord.ErrorDetails.Message
		try {
			$parsed = ConvertFrom-Json -InputObject $detail -Depth 10 -ErrorAction Stop
			$errorNode = Get-IaLlmValue -InputObject $parsed -Name 'error'
			$inner = if ($errorNode -is [string]) { $errorNode } else { Get-IaLlmValue -InputObject $errorNode -Name 'message' }
			if (-not $inner) {
				$inner = Get-IaLlmValue -InputObject $parsed -Name 'message'
			}
			if ($inner) {
				$detail = [string]$inner
			}
		}
		catch {
			$detail = $ErrorRecord.ErrorDetails.Message
		}
	}
	if (-not $detail) {
		$detail = $exception.Message
	}
	$prefix = if ($null -ne $statusCode) { "HTTP $statusCode" } elseif ($isTimeout) { 'Таймаут' } else { 'Помилка виклику' }
	return @{
		retryable = $isTimeout -or $statusCode -eq 429 -or ($null -ne $statusCode -and $statusCode -ge 500 -and $statusCode -le 599)
		statusCode = $statusCode
		isTimeout = $isTimeout
		retryAfterSeconds = $retryAfter
		message = Protect-IaLlmSecretText -Text ('{0}: {1}' -f $prefix, $detail) -Secret $Secret
	}
}

function Test-IaLlmTruncatedFinish {
	<# $true, якщо відповідь обрізано лімітом вихідних токенів: max_tokens (Anthropic), length (OpenAI, Azure OpenAI, сумісні), MAX_TOKENS (Cohere). #>
	param([AllowNull()][AllowEmptyString()][string]$FinishReason)
	return ([string]$FinishReason) -in @('max_tokens', 'length', 'MAX_TOKENS')
}

function New-IaLlmResponseObject {
	<# Внутрішня: порожній LlmResponse (CONTRACTS.md, розділ 5.5). #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][string]$Purpose
	)
	return [ordered]@{
		llmCallId = [guid]::NewGuid().ToString()
		provider = [string](Get-IaLlmValue -InputObject $ProviderConfig -Name 'name')
		model = [string](Get-IaLlmValue -InputObject $ProviderConfig -Name 'model')
		purpose = $Purpose
		text = $null
		inputTokens = 0
		outputTokens = 0
		cacheWriteTokens = 0
		cacheReadTokens = 0
		costUsd = [decimal]0
		durationMs = 0
		finishReason = $null
		createdAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
		promptTemplateId = $null
		promptTemplateVersion = $null
		success = $false
		error = $null
	}
}

function Invoke-IaLlmChat {
	<# Єдиний інтерфейс провайдерів (Invoke-RestMethod): перевірка бюджету до виклику, повтори, таймаут,
	   облік токенів і вартості після виклику. Messages — масив @{ role = 'system'|'user'|'assistant'; content }.
	   Повертає LlmResponse (CONTRACTS.md, розділ 5.5). Перевищення бюджету — виняток 'IaBudgetExceeded'. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][System.Collections.IDictionary[]]$Messages,
		[int]$MaxTokens = 0,
		[switch]$JsonResponse,
		[ValidateSet('Analysis', 'ToolFollowUp', 'CrossCheck')][string]$Purpose = 'Analysis',
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	Assert-IaProviderAllowed -ProviderConfig $ProviderConfig -Config $Config

	$type = $script:IaLlmProviderTypes | Where-Object { [string]::Equals($_, [string](Get-IaLlmValue -InputObject $ProviderConfig -Name 'type'), [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
	if (-not $type) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaConfigInvalid' -Category InvalidData -Message "Тип провайдера '$(Get-IaLlmValue -InputObject $ProviderConfig -Name 'type')' не підтримується."))
	}
	$settings = [ordered]@{ type = $type }
	foreach ($name in @('name', 'model', 'endpoint', 'apiKeyRef', 'apiVersion', 'maxTokensPerRequest', 'timeoutSeconds', 'retryCount', 'inputPricePer1MTokensUsd', 'outputPricePer1MTokensUsd',
			'cacheWritePricePer1MTokensUsd', 'cacheReadPricePer1MTokensUsd', 'promptCaching', 'dailyBudgetUsd', 'monthlyBudgetUsd')) {
		$settings[$name] = Get-IaLlmSetting -ProviderConfig $ProviderConfig -Name $name
	}
	$limit = [int]$settings['maxTokensPerRequest']
	$effectiveMaxTokens = if ($MaxTokens -gt 0) { [Math]::Min($MaxTokens, $limit) } else { $limit }
	$timeoutSeconds = [int]$settings['timeoutSeconds']
	$maxAttempts = 1 + [Math]::Max(0, [int]$settings['retryCount'])

	# Перевірка бюджету до виклику: вже витрачене + оцінка цього запиту (вхід за оцінкою, вихід — за лімітом).
	$estimatedInput = Measure-IaTokens -Text ((@($Messages | ForEach-Object { [string]$_['content'] })) -join "`n")
	$estimatedCost = Get-IaLlmCost -ProviderConfig $settings -InputTokens $estimatedInput -OutputTokens $effectiveMaxTokens
	try {
		Assert-IaLlmBudget -ProviderConfig $settings -Config $Config -EstimatedCostUsd $estimatedCost
	}
	catch {
		Write-IaLlmLog -Message "LLM: виклик заблоковано бюджетом ($($settings['name']))." -Level Warning -Data ([ordered]@{ provider = $settings['name']; purpose = $Purpose })
		$PSCmdlet.ThrowTerminatingError($_)
	}

	$apiKey = $null
	if ($settings['apiKeyRef']) {
		$apiKey = Get-IaSecret -Reference ([string]$settings['apiKeyRef']) -AsPlainText
	}
	elseif ($type -ne 'OpenAICompatible') {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaSecretNotFound' -Category InvalidData -Message (
			"llm.providers.$($settings['name']).apiKeyRef: для провайдера типу $type потрібне посилання на API-ключ у захищеному сховищі.")))
	}

	$request = New-IaLlmHttpRequest -ProviderConfig $settings -Messages $Messages -MaxTokens $effectiveMaxTokens -JsonResponse ([bool]$JsonResponse) -ApiKey $apiKey
	$result = New-IaLlmResponseObject -ProviderConfig $settings -Purpose $Purpose
	$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	$parsed = $null
	$attempt = 0
	while ($true) {
		$attempt++
		try {
			$raw = Invoke-RestMethod -Method Post -Uri $request.uri -Headers $request.headers -Body $request.body `
				-ContentType 'application/json; charset=utf-8' -TimeoutSec $timeoutSeconds -ErrorAction Stop
			$parsed = ConvertFrom-IaLlmHttpResponse -Type $type -Response $raw
			break
		}
		catch {
			$failure = Get-IaLlmHttpFailure -ErrorRecord $_ -Secret $apiKey
			if ($failure.retryable -and $attempt -lt $maxAttempts) {
				$delaySeconds = [Math]::Min($script:IaLlmMaxRetryDelaySeconds, [Math]::Pow(2, $attempt - 1))
				if ($null -ne $failure.retryAfterSeconds -and $failure.retryAfterSeconds -gt 0) {
					$delaySeconds = [Math]::Min($script:IaLlmMaxRetryDelaySeconds, $failure.retryAfterSeconds)
				}
				Write-IaLlmLog -Message "LLM: спроба $attempt з $maxAttempts невдала ($($failure.message)); повтор через $delaySeconds с." -Level Warning `
					-Data ([ordered]@{ provider = $settings['name']; model = $settings['model']; purpose = $Purpose; attempt = $attempt })
				Start-Sleep -Milliseconds ([int]($delaySeconds * 1000))
				continue
			}
			$result['error'] = $failure.message
			break
		}
	}
	$stopwatch.Stop()
	$result['durationMs'] = [long]$stopwatch.Elapsed.TotalMilliseconds

	if ($null -ne $parsed) {
		$inputTokens = $parsed.inputTokens
		if ($null -eq $inputTokens) {
			$inputTokens = Measure-IaTokens -Text ((@($Messages | ForEach-Object { [string]$_['content'] })) -join "`n")
		}
		$outputTokens = $parsed.outputTokens
		if ($null -eq $outputTokens) {
			$outputTokens = Measure-IaTokens -Text $parsed.text
		}
		$cacheWrite = [long]$parsed.cacheWriteTokens
		$cacheRead = [long]$parsed.cacheReadTokens
		$result['text'] = $parsed.text
		$result['finishReason'] = $parsed.finishReason
		$result['inputTokens'] = [long]$inputTokens
		$result['outputTokens'] = [long]$outputTokens
		$result['cacheWriteTokens'] = $cacheWrite
		$result['cacheReadTokens'] = $cacheRead
		$uncached = [Math]::Max([long]0, [long]$inputTokens - $cacheWrite - $cacheRead)
		$result['costUsd'] = Get-IaLlmCost -ProviderConfig $settings -InputTokens $uncached -OutputTokens $outputTokens -CacheWriteTokens $cacheWrite -CacheReadTokens $cacheRead
		$result['success'] = $true
		try {
			Add-IaLlmLedgerEntry -Config $Config -Entry ([ordered]@{
				utc = $result['createdAtUtc']
				provider = $result['provider']
				model = $result['model']
				inputTokens = $result['inputTokens']
				outputTokens = $result['outputTokens']
				costUsd = $result['costUsd']
				purpose = $Purpose
			})
		}
		catch {
			Write-Warning "IndexAdvisor: не вдалося записати облік витрат LLM: $($_.Exception.Message)"
		}
	}
	Write-IaLlmLog -Message ('LLM-виклик {0}: {1}/{2}, {3}, успіх = {4}.' -f $result['llmCallId'], $result['provider'], $result['model'], $Purpose, $result['success']) `
		-Level $(if ($result['success']) { 'Info' } else { 'Error' }) -Data ([ordered]@{
			llmCallId = $result['llmCallId']
			provider = $result['provider']
			model = $result['model']
			purpose = $Purpose
			attempts = $attempt
			inputTokens = $result['inputTokens']
			outputTokens = $result['outputTokens']
			cacheWriteTokens = $result['cacheWriteTokens']
			cacheReadTokens = $result['cacheReadTokens']
			costUsd = $result['costUsd']
			durationMs = $result['durationMs']
			finishReason = $result['finishReason']
			error = $result['error']
		})
	return $result
}
