# Цикл «модель просить дані -> користувач підтверджує -> дані в контекст моделі» (ТЗ 4.3, 4.7; CONTRACTS.md 3.3, 5.6).

function Find-IaToolInstance {
	<# Інстанс зі snapshot за іменем (serverName або connectedTo, без урахування регістру) або $null. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[AllowEmptyString()][AllowNull()][string]$Name
	)
	if ([string]::IsNullOrWhiteSpace($Name)) {
		return $null
	}
	foreach ($instance in @($Snapshot.instances)) {
		if ($null -eq $instance) {
			continue
		}
		if ($instance.serverName -eq $Name -or $instance.connectedTo -eq $Name) {
			return $instance
		}
	}
	return $null
}

function Get-IaToolAgPrimaryInstance {
	<# Зібраний інстанс primary-репліки групи доступності. Повертає @{ instance; reason }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$AvailabilityGroup
	)
	$primary = @($AvailabilityGroup.replicas) | Where-Object { $null -ne $_ -and $_.role -eq 'PRIMARY' } | Select-Object -First 1
	if ($null -eq $primary) {
		return [ordered]@{ instance = $null; reason = "у групі доступності '$($AvailabilityGroup.name)' немає primary-репліки в зібраних даних" }
	}
	$instance = Find-IaToolInstance -Snapshot $Snapshot -Name $primary.replicaServerName
	if ($null -eq $instance) {
		return [ordered]@{ instance = $null; reason = "primary-репліку '$($primary.replicaServerName)' групи '$($AvailabilityGroup.name)' не зібрано" }
	}
	return [ordered]@{ instance = $instance; reason = $null }
}

function Resolve-IaToolTarget {
	<# Перевіряє, що server/database дозапиту в межах зібраного snapshot, і визначає, куди підключатися:
	   ім'я AG (або її listener) чи requestedServer -> primary-репліка; ім'я репліки/інстансу -> вона; база має бути серед
	   зібраних на цьому інстансі. Порожній server -> requestedServer; порожня база допустима, лише якщо на інстансі зібрано
	   одну базу. Повертає @{ isAllowed; server (куди підключатися); database; instanceName; reason }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[AllowEmptyString()][AllowNull()][string]$Server,
		[AllowEmptyString()][AllowNull()][string]$Database
	)
	$blocked = { param($message) [ordered]@{ isAllowed = $false; server = $null; database = $null; instanceName = $null; reason = $message } }
	$topology = if ($Snapshot.topology -is [System.Collections.IDictionary]) { $Snapshot.topology } else { @{} }
	$requested = if ($Snapshot.requestedServer) { [string]$Snapshot.requestedServer } else { [string]$topology.requestedServer }
	$serverName = if ([string]::IsNullOrWhiteSpace($Server)) { $requested } else { $Server.Trim() }
	if ([string]::IsNullOrWhiteSpace($serverName)) {
		return (& $blocked 'не вказано сервер дозапиту')
	}
	$instance = $null
	foreach ($ag in @($topology.availabilityGroups)) {
		if ($null -eq $ag) {
			continue
		}
		if ($ag.name -eq $serverName -or ($ag.listenerName -and $ag.listenerName -eq $serverName)) {
			$primary = Get-IaToolAgPrimaryInstance -Snapshot $Snapshot -AvailabilityGroup $ag
			if ($null -eq $primary.instance) {
				return (& $blocked $primary.reason)
			}
			$instance = $primary.instance
			break
		}
	}
	if ($null -eq $instance) {
		$instance = Find-IaToolInstance -Snapshot $Snapshot -Name $serverName
	}
	if ($null -eq $instance -and $serverName -eq $requested) {
		$groups = @($topology.availabilityGroups | Where-Object { $null -ne $_ })
		$instances = @($Snapshot.instances | Where-Object { $null -ne $_ })
		if ($topology.type -eq 'AG' -and $groups.Count -eq 1) {
			$primary = Get-IaToolAgPrimaryInstance -Snapshot $Snapshot -AvailabilityGroup $groups[0]
			if ($null -eq $primary.instance) {
				return (& $blocked $primary.reason)
			}
			$instance = $primary.instance
		}
		elseif ($topology.type -ne 'AG' -and $instances.Count -eq 1) {
			$instance = $instances[0]
		}
	}
	if ($null -eq $instance) {
		return (& $blocked "сервер '$serverName' не входить до зібраного знімка (дозволено: ім'я AG, запитаний сервер або зібрана репліка)")
	}
	$databases = @($instance.databases | Where-Object { $null -ne $_ })
	# Увага: змінні PowerShell нечутливі до регістру — локальна змінна не може зватися $database (це параметр $Database).
	$databaseEntry = $null
	if ([string]::IsNullOrWhiteSpace($Database)) {
		if ($databases.Count -ne 1) {
			return (& $blocked "не вказано базу дозапиту, а на інстансі '$($instance.serverName)' зібрано баз: $($databases.Count)")
		}
		$databaseEntry = $databases[0]
	}
	else {
		$requestedDatabase = $Database.Trim()
		$databaseEntry = $databases | Where-Object { $_.name -eq $requestedDatabase } | Select-Object -First 1
	}
	if ($null -eq $databaseEntry) {
		return (& $blocked "базу '$Database' не зібрано на інстансі '$($instance.serverName)'")
	}
	$connectTo = if ($instance.connectedTo) { [string]$instance.connectedTo } else { [string]$instance.serverName }
	# Вторинна репліка з ALLOW_CONNECTIONS = READ_ONLY приймає підключення до бази AG лише з ApplicationIntent=ReadOnly (QUESTIONS п. 9).
	$applicationIntent = $null
	if ($instance.agRole -eq 'SECONDARY' -and $databaseEntry.availabilityGroup) {
		foreach ($ag in @($topology.availabilityGroups | Where-Object { $null -ne $_ -and $_.name -eq $databaseEntry.availabilityGroup })) {
			$replica = @($ag.replicas | Where-Object { $null -ne $_ -and $_.replicaServerName -eq $instance.serverName }) | Select-Object -First 1
			if ($null -ne $replica -and $replica.secondaryAllowConnections -eq 'READ_ONLY') {
				$applicationIntent = 'ReadOnly'
			}
		}
	}
	return [ordered]@{
		isAllowed = $true; server = $connectTo; database = [string]$databaseEntry.name; instanceName = [string]$instance.serverName
		applicationIntent = $applicationIntent; reason = $null
	}
}

function New-IaToolRequestRecord {
	<# Порожній ToolRequestRecord (CONTRACTS.md 5.6). #>
	[CmdletBinding()]
	param([AllowNull()][AllowEmptyString()][string]$LlmCallId)
	return [ordered]@{
		toolRequestId = [guid]::NewGuid().ToString()
		llmCallId = $LlmCallId
		tool = $null
		server = $null
		database = $null
		arguments = [ordered]@{}
		fetch = $null
		skip = $null
		reason = $null
		decision = $null
		decisionReason = $null
		response = $null
		executedAtUtc = $null
	}
}

function New-IaToolBlockedOutcome {
	<# Запис і результат для моделі для дозапиту, заблокованого програмою (decision Blocked). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Record,
		[Parameter(Mandatory)][string]$Reason
	)
	$Record.decision = 'Blocked'
	$Record.decisionReason = $Reason
	Write-IaLog -Message "Дозапит моделі '$($Record.tool)' заблоковано: $Reason" -Level Warning -Data ([ordered]@{
			tool = [string]$Record.tool
			server = [string]$Record.server
			database = [string]$Record.database
			decision = 'Blocked'
			decisionReason = $Reason
		})
	return [ordered]@{ record = $Record; result = (New-IaToolModelResult -Record $Record -Envelope $null) }
}

function New-IaToolModelResult {
	<# Результат дозапиту для моделі (до маскування): запит, рішення і дані конверта. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Record,
		[AllowNull()]$Envelope
	)
	$result = [ordered]@{
		tool = $Record.tool
		server = $Record.server
		database = $Record.database
		arguments = $Record.arguments
		fetch = $Record.fetch
		skip = $Record.skip
		decision = $Record.decision
		decisionReason = $Record.decisionReason
		result = $null
	}
	if ($null -ne $Envelope) {
		$result.result = [ordered]@{
			success = $Envelope.success
			rowCount = $Envelope.rowCount
			truncated = $Envelope.truncated
			columns = @($Envelope.columns)
			rows = @($Envelope.rows)
			messages = @($Envelope.messages)
			error = $Envelope.error
		}
	}
	return $result
}

function Invoke-IaToolRequestStep {
	<# Обробка одного дозапиту моделі: розмаскування, перевірка інструмента й аргументів, межі snapshot, підтвердження,
	   виконання. Повертає @{ record (ToolRequestRecord); result (для моделі, ще не маскований) }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowNull()]$Request,
		[AllowNull()][AllowEmptyString()][string]$LlmCallId,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Tools,
		[System.Collections.IDictionary]$MaskingMap,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$record = New-IaToolRequestRecord -LlmCallId $LlmCallId
	if ($Request -isnot [System.Collections.IDictionary]) {
		return (New-IaToolBlockedOutcome -Record $record -Reason 'дозапит має бути JSON-об''єктом')
	}
	$unmasked = if ($null -ne $MaskingMap) { ConvertFrom-IaMaskedObject -InputObject $Request -Map $MaskingMap } else { $Request }
	if ($unmasked -isnot [System.Collections.IDictionary]) {
		$unmasked = $Request
	}
	$record.tool = if ($null -ne $unmasked.tool) { [string]$unmasked.tool } else { $null }
	$record.server = if ($null -ne $unmasked.server) { [string]$unmasked.server } else { $null }
	$record.database = if ($null -ne $unmasked.database) { [string]$unmasked.database } else { $null }
	$record.fetch = $unmasked.fetch
	$record.skip = $unmasked.skip
	$record.reason = if ($null -ne $unmasked.reason) { [string]$unmasked.reason } else { $null }
	$rawArguments = $unmasked.arguments
	if ($rawArguments -is [System.Collections.IDictionary]) {
		$record.arguments = ConvertTo-IaToolJsonArguments -Arguments $rawArguments
	}
	if ([string]::IsNullOrWhiteSpace($record.tool) -or -not $Tools.Contains($record.tool)) {
		return (New-IaToolBlockedOutcome -Record $record -Reason "невідомий інструмент '$($record.tool)'; дозволено: $(@($Tools.get_Keys()) -join ', ')")
	}
	$tool = $Tools[$record.tool]
	if ($null -ne $rawArguments -and $rawArguments -isnot [System.Collections.IDictionary]) {
		return (New-IaToolBlockedOutcome -Record $record -Reason 'arguments має бути JSON-об''єктом')
	}
	$fetchCheck = ConvertTo-IaToolNonNegativeInt -Value $unmasked.fetch -Name 'fetch'
	$skipCheck = ConvertTo-IaToolNonNegativeInt -Value $unmasked.skip -Name 'skip'
	$problems = @(@($fetchCheck, $skipCheck) | Where-Object { -not $_.isValid } | ForEach-Object { $_.error })
	$argumentCheck = Test-IaToolArguments -Tool $tool -Arguments $(if ($null -ne $rawArguments) { $rawArguments } else { @{} })
	$problems += @($argumentCheck.errors)
	if ($problems.Count -gt 0) {
		return (New-IaToolBlockedOutcome -Record $record -Reason "аргументи не пройшли перевірку: $($problems -join '; ')")
	}
	$record.arguments = ConvertTo-IaToolJsonArguments -Arguments $argumentCheck.arguments
	$requestedServer = if (-not [string]::IsNullOrWhiteSpace([string]$tool.server)) { [string]$tool.server } else { $record.server }
	$requestedDatabase = if (-not [string]::IsNullOrWhiteSpace([string]$tool.database)) { [string]$tool.database } else { $record.database }
	$target = Resolve-IaToolTarget -Snapshot $Snapshot -Server $requestedServer -Database $requestedDatabase
	if (-not $target.isAllowed) {
		return (New-IaToolBlockedOutcome -Record $record -Reason "поза межами зібраного знімка: $($target.reason)")
	}
	$normalized = [ordered]@{
		tool = $record.tool
		server = $requestedServer
		database = $requestedDatabase
		resolvedServer = $target.server
		resolvedDatabase = $target.database
		arguments = $argumentCheck.arguments
		fetch = $fetchCheck.value
		skip = $skipCheck.value
		reason = $record.reason
	}
	try {
		$approval = Request-IaToolApproval -ToolRequest $normalized -Tools $Tools -Config $Config
	}
	catch {
		$approval = [ordered]@{ decision = 'Rejected'; toolRequest = $normalized; reason = "Помилка діалогу підтвердження: $($_.Exception.Message)" }
	}
	$approved = if ($approval.toolRequest -is [System.Collections.IDictionary]) { $approval.toolRequest } else { $normalized }
	$record.server = $target.server
	$record.database = $target.database
	$record.decision = $approval.decision
	$record.decisionReason = $approval.reason
	$record.arguments = ConvertTo-IaToolJsonArguments -Arguments $approved.arguments
	$record.fetch = $approved.fetch
	$record.skip = $approved.skip
	if ($approval.decision -notin @('Approved', 'Modified', 'AutoApproved')) {
		return [ordered]@{ record = $record; result = (New-IaToolModelResult -Record $record -Envelope $null) }
	}
	$executionTool = [ordered]@{}
	foreach ($key in @($tool.get_Keys())) {
		$executionTool[$key] = $tool[$key]
	}
	$executionTool.server = $target.server
	$executionTool.database = $target.database
	$skip = if ($null -ne $approved.skip) { [int]$approved.skip } else { 0 }
	try {
		$intentArguments = @{}
		if ($target.applicationIntent) {
			$intentArguments.ApplicationIntent = $target.applicationIntent
		}
		$envelope = Invoke-IaTool -Tool $executionTool -Arguments $approved.arguments -Server $target.server -Database $target.database `
			-Fetch $approved.fetch -Skip $skip -Config $Config @intentArguments
	}
	catch {
		$code = if ($_.FullyQualifiedErrorId -like 'IaLoginRefused*') { 'LoginRefused' } else { 'SqlError' }
		$envelope = New-IaResponse -Server $target.server -Database $target.database
		$envelope.error = New-IaError -Code $code -Message $_.Exception.Message
	}
	$record.executedAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
	$record.response = [ordered]@{
		success = [bool]$envelope.success
		rowCount = $envelope.rowCount
		truncated = [bool]$envelope.truncated
		durationMs = $envelope.durationMs
		error = $envelope.error
	}
	return [ordered]@{ record = $record; result = (New-IaToolModelResult -Record $record -Envelope $envelope) }
}

function ConvertTo-IaToolCallRecord {
	<# LlmResponse без тексту для LlmAnalysisResult.calls; шаблон промпту береться з Prompt, якщо не заданий. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Response,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Prompt
	)
	$call = [ordered]@{}
	foreach ($key in @($Response.get_Keys())) {
		if ($key -ne 'text') {
			$call[$key] = $Response[$key]
		}
	}
	if ($null -eq $call.promptTemplateId) {
		$call.promptTemplateId = $Prompt.templateId
	}
	if ($null -eq $call.promptTemplateVersion) {
		$call.promptTemplateVersion = $Prompt.templateVersion
	}
	return $call
}

function Invoke-IaAnalysisLoop {
	<# Цикл «модель просить дані -> користувач підтверджує -> дані в контекст» до відповіді без toolRequests
	   або до лімітів limits.maxToolRequestsPerAnalysis / limits.maxTokensPerAnalysis. Snapshot — НЕмаскований
	   (для перевірки, що server/database дозапиту в межах зібраного). Аргументи дозапиту розмасковуються перед виконанням,
	   результат маскується перед передачею моделі. Повертає LlmAnalysisResult (CONTRACTS.md, розділ 5.6). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Prompt,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Tools,
		[System.Collections.IDictionary]$MaskingMap,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$maxToolRequests = [int](Get-IaToolSetting -Config $Config -Section 'limits' -Name 'maxToolRequestsPerAnalysis' -Default 10)
	$maxTokens = [long](Get-IaToolSetting -Config $Config -Section 'limits' -Name 'maxTokensPerAnalysis' -Default 200000)
	# Мапа для маскування результатів дозапитів: та сама, що й для промпту; без неї — нова (літерали очищуються завжди).
	$resultMap = if ($null -ne $MaskingMap) { $MaskingMap } else { New-IaMaskingMap }
	$messages = [System.Collections.Generic.List[System.Collections.IDictionary]]::new()
	foreach ($message in @($Prompt.messages)) {
		if ($null -ne $message) {
			$messages.Add([ordered]@{ role = [string]$message.role; content = [string]$message.content })
		}
	}
	$calls = [System.Collections.Generic.List[object]]::new()
	$records = [System.Collections.Generic.List[object]]::new()
	$loopNotes = [System.Collections.Generic.List[string]]::new()
	$totalInput = [long]0
	$totalOutput = [long]0
	$totalCost = [double]0
	$executedCount = 0
	$limitReached = $false
	$finalOnly = $false
	$purpose = 'Analysis'
	$lastParsed = $null
	$stoppedReason = $null
	$errorText = $null
	while ($null -eq $stoppedReason) {
		try {
			$response = Invoke-IaLlmChat -ProviderConfig $ProviderConfig -Messages $messages.ToArray() -JsonResponse -Purpose $purpose -Config $Config
		}
		catch {
			if ($_.FullyQualifiedErrorId -like 'IaBudgetExceeded*') {
				$stoppedReason = 'BudgetExceeded'
				$errorText = "Бюджет LLM вичерпано: $($_.Exception.Message)"
			}
			else {
				$stoppedReason = 'Error'
				$errorText = "Помилка виклику моделі: $($_.Exception.Message)"
			}
			break
		}
		if ($response -isnot [System.Collections.IDictionary]) {
			$stoppedReason = 'Error'
			$errorText = 'Виклик моделі не повернув відповіді.'
			break
		}
		$calls.Add((ConvertTo-IaToolCallRecord -Response $response -Prompt $Prompt))
		$callInput = [long]$(if ($null -ne $response.inputTokens) { $response.inputTokens } else { 0 })
		$callOutput = [long]$(if ($null -ne $response.outputTokens) { $response.outputTokens } else { 0 })
		$totalInput += $callInput
		$totalOutput += $callOutput
		if ($null -ne $response.costUsd) {
			$totalCost += [double]$response.costUsd
		}
		if (-not $response.success) {
			$stoppedReason = 'Error'
			$errorText = if ($response.error) { "Модель повернула помилку: $(if ($response.error -is [string]) { $response.error } else { ConvertTo-Json -InputObject $response.error -Depth 10 -Compress })" } else { 'Модель повернула помилку.' }
			break
		}
		$parsed = ConvertFrom-IaLlmResponse -Text ([string]$response.text)
		$requests = @($parsed.toolRequests | Where-Object { $null -ne $_ })
		$draftCount = @($parsed.recommendations | Where-Object { $null -ne $_ }).Count + @($parsed.draftDecisions | Where-Object { $null -ne $_ }).Count
		$parseErrors = @($parsed.parseErrors | Where-Object { $null -ne $_ })
		if ($parseErrors.Count -gt 0) {
			$parseText = ($parseErrors | ForEach-Object { if ($_ -is [string]) { $_ } else { ConvertTo-Json -InputObject $_ -Depth 5 -Compress } }) -join '; '
			if ($draftCount -eq 0 -and $requests.Count -eq 0) {
				$stoppedReason = 'Error'
				# Відповідь, обрізана лімітом вихідних токенів, — неповний JSON: пояснення замість помилки розбору.
				$errorText = if (Test-IaLlmTruncatedFinish -FinishReason ([string]$response.finishReason)) {
					$limit = Get-IaLlmSetting -ProviderConfig $ProviderConfig -Name 'maxTokensPerRequest'
					"Відповідь моделі обрізано лімітом вихідних токенів (finish_reason = $($response.finishReason), maxTokensPerRequest = $limit): JSON неповний. " +
					'Збільште llm.providers.<провайдер>.maxTokensPerRequest; у моделей з мисленням (Claude Opus 5.5, o-серія OpenAI) мислення входить у цей ліміт.'
				}
				else {
					"Відповідь моделі не відповідає схемі llm-response: $parseText"
				}
				break
			}
			$loopNotes.Add("Помилки розбору відповіді моделі: $parseText")
		}
		$lastParsed = $parsed
		$messages.Add([ordered]@{ role = 'assistant'; content = [string]$response.text })
		if ($requests.Count -eq 0) {
			$stoppedReason = if ($limitReached) { 'ToolLimit' } else { 'Completed' }
			break
		}
		if ($finalOnly) {
			foreach ($request in $requests) {
				$records.Add((Invoke-IaToolLimitBlock -Request $request -LlmCallId $response.llmCallId -MaskingMap $MaskingMap `
							-Reason 'ліміт дозапитів на аналіз вичерпано (limits.maxToolRequestsPerAnalysis)').record)
			}
			$stoppedReason = 'ToolLimit'
			break
		}
		if (($totalInput + $totalOutput + $callInput + $callOutput) -gt $maxTokens) {
			foreach ($request in $requests) {
				$records.Add((Invoke-IaToolLimitBlock -Request $request -LlmCallId $response.llmCallId -MaskingMap $MaskingMap `
							-Reason 'ліміт токенів на аналіз вичерпано (limits.maxTokensPerAnalysis)').record)
			}
			$stoppedReason = 'TokenLimit'
			break
		}
		$results = [System.Collections.Generic.List[object]]::new()
		foreach ($request in $requests) {
			if ($executedCount -ge $maxToolRequests) {
				$limitReached = $true
				$outcome = Invoke-IaToolLimitBlock -Request $request -LlmCallId $response.llmCallId -MaskingMap $MaskingMap `
					-Reason 'ліміт дозапитів на аналіз вичерпано (limits.maxToolRequestsPerAnalysis)'
			}
			else {
				$executedCount++
				$outcome = Invoke-IaToolRequestStep -Request $request -LlmCallId $response.llmCallId -Snapshot $Snapshot -Tools $Tools `
					-MaskingMap $MaskingMap -Config $Config
			}
			$records.Add($outcome.record)
			$results.Add($outcome.result)
		}
		$remaining = [Math]::Max(0, $maxToolRequests - $executedCount)
		if ($remaining -eq 0) {
			$finalOnly = $true
		}
		$instruction = if ($finalOnly) {
			'Ліміт дозапитів на цей аналіз вичерпано. Дай фінальну відповідь без дозапитів: toolRequests має бути порожнім масивом.'
		}
		else {
			"Результати дозапитів. Продовж аналіз і відповідай JSON за схемою llm-response. Залишилось дозапитів: $remaining."
		}
		$followUp = [ordered]@{
			type = 'toolResults'
			results = $results.ToArray()
			remainingToolRequests = $remaining
			instruction = $instruction
		}
		$maskedFollowUp = ConvertTo-IaMaskedObject -InputObject $followUp -Map $resultMap -Config $Config
		$messages.Add([ordered]@{ role = 'user'; content = (ConvertTo-Json -InputObject $maskedFollowUp -Depth 50 -Compress) })
		$purpose = 'ToolFollowUp'
	}
	$recommendations = @()
	$draftDecisions = @()
	$modelNotes = $null
	if ($null -ne $lastParsed) {
		$final = [ordered]@{
			recommendations = @($lastParsed.recommendations | Where-Object { $null -ne $_ })
			draftDecisions = @($lastParsed.draftDecisions | Where-Object { $null -ne $_ })
			notes = $lastParsed.notes
		}
		if ($null -ne $MaskingMap) {
			$final = ConvertFrom-IaMaskedObject -InputObject $final -Map $MaskingMap
		}
		$recommendations = @($final.recommendations | Where-Object { $null -ne $_ })
		$draftDecisions = @($final.draftDecisions | Where-Object { $null -ne $_ })
		$modelNotes = $final.notes
	}
	if ($stoppedReason -ne 'Completed') {
		$stopText = switch ($stoppedReason) {
			'ToolLimit' { 'Аналіз завершено після вичерпання ліміту дозапитів (limits.maxToolRequestsPerAnalysis).' }
			'TokenLimit' { 'Аналіз зупинено: вичерпано ліміт токенів (limits.maxTokensPerAnalysis); рекомендації — з останньої відповіді моделі.' }
			'BudgetExceeded' { 'Аналіз зупинено: вичерпано бюджет LLM; рекомендації — з останньої відповіді моделі.' }
			default { 'Аналіз зупинено через помилку; рекомендації — з останньої успішної відповіді моделі.' }
		}
		$loopNotes.Add($stopText)
	}
	$notesParts = @(@($modelNotes) + @($loopNotes) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
	$notes = if ($notesParts.Count -gt 0) { ($notesParts | ForEach-Object { [string]$_ }) -join "`n" } else { $null }
	$logLevel = if ($stoppedReason -in @('Completed', 'ToolLimit')) { 'Info' } else { 'Warning' }
	Write-IaLog -Message "LLM-аналіз завершено: $stoppedReason" -Level $logLevel -Data ([ordered]@{
			stoppedReason = $stoppedReason
			calls = [string]$calls.Count
			toolRequests = [string]$records.Count
			inputTokens = [string]$totalInput
			outputTokens = [string]$totalOutput
			costUsd = $totalCost.ToString([cultureinfo]::InvariantCulture)
			error = $errorText
		})
	return [ordered]@{
		recommendations = $recommendations
		draftDecisions = $draftDecisions
		notes = $notes
		calls = $calls.ToArray()
		toolRequests = $records.ToArray()
		totalInputTokens = $totalInput
		totalOutputTokens = $totalOutput
		totalCostUsd = $totalCost
		stoppedReason = $stoppedReason
		error = $errorText
		prompt = [ordered]@{ templateId = $Prompt.templateId; templateVersion = $Prompt.templateVersion }
	}
}

function Invoke-IaToolLimitBlock {
	<# Дозапит, не виконаний через ліміт: розмаскування для запису і рішення Blocked. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowNull()]$Request,
		[AllowNull()][AllowEmptyString()][string]$LlmCallId,
		[System.Collections.IDictionary]$MaskingMap,
		[Parameter(Mandatory)][string]$Reason
	)
	$record = New-IaToolRequestRecord -LlmCallId $LlmCallId
	if ($Request -is [System.Collections.IDictionary]) {
		$unmasked = if ($null -ne $MaskingMap) { ConvertFrom-IaMaskedObject -InputObject $Request -Map $MaskingMap } else { $Request }
		if ($unmasked -isnot [System.Collections.IDictionary]) {
			$unmasked = $Request
		}
		$record.tool = if ($null -ne $unmasked.tool) { [string]$unmasked.tool } else { $null }
		$record.server = if ($null -ne $unmasked.server) { [string]$unmasked.server } else { $null }
		$record.database = if ($null -ne $unmasked.database) { [string]$unmasked.database } else { $null }
		$record.fetch = $unmasked.fetch
		$record.skip = $unmasked.skip
		$record.reason = if ($null -ne $unmasked.reason) { [string]$unmasked.reason } else { $null }
		if ($unmasked.arguments -is [System.Collections.IDictionary]) {
			$record.arguments = ConvertTo-IaToolJsonArguments -Arguments $unmasked.arguments
		}
	}
	return (New-IaToolBlockedOutcome -Record $record -Reason $Reason)
}
