# Виконання інструментів і підтвердження дозапитів моделі користувачем (ТЗ 4.7; CONTRACTS.md 3.3).

function Invoke-IaTool {
	<# Виконує інструмент через Invoke-IaSqlQuery (Purpose Tool; для free_query — FreeQuery). Server/Database з визначення
	   інструмента мають пріоритет над переданими. Аргументи перевіряються Test-IaToolArguments до виконання; помилки
	   повертаються в конверті (ArgumentInvalid), а не винятком. Повертає конверт відповіді (CONTRACTS.md 5.10). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Tool,
		[System.Collections.IDictionary]$Arguments = @{},
		[string]$Server,
		[string]$Database,
		[Nullable[int]]$Fetch,
		[int]$Skip = 0,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[ValidateSet('ReadOnly')][string]$ApplicationIntent
	)
	$effectiveServer = if (-not [string]::IsNullOrWhiteSpace([string]$Tool.server)) { [string]$Tool.server } else { $Server }
	$effectiveDatabase = if (-not [string]::IsNullOrWhiteSpace([string]$Tool.database)) { [string]$Tool.database } else { $Database }
	$check = Test-IaToolArguments -Tool $Tool -Arguments $Arguments
	if (-not $check.isValid) {
		$response = New-IaResponse -Server $effectiveServer -Database $effectiveDatabase
		$response.error = New-IaError -Code 'ArgumentInvalid' -Message "Аргументи інструмента '$($Tool.name)' не пройшли перевірку: $($check.errors -join '; ')"
		$response.messages = @($check.errors)
		return $response
	}
	$isFreeQuery = $Tool.purpose -eq 'FreeQuery'
	if ($isFreeQuery) {
		if (-not [bool](Get-IaToolSetting -Config $Config -Section 'unsafe' -Name 'allowFreeQuery' -Default $false)) {
			$response = New-IaResponse -Server $effectiveServer -Database $effectiveDatabase
			$response.error = New-IaError -Code 'ArgumentInvalid' -Message 'Вільний запит вимкнено: потрібен явний прапорець unsafe.allowFreeQuery.'
			return $response
		}
		$query = [string]$check.arguments['Sql']
		$parameters = [ordered]@{}
		$purpose = 'FreeQuery'
	}
	else {
		$query = [string]$Tool.query
		$parameters = [ordered]@{}
		foreach ($name in @($check.arguments.get_Keys())) {
			$parameters[$name] = $check.arguments[$name]
		}
		$purpose = 'Tool'
	}
	$intentArguments = @{}
	if ($ApplicationIntent) {
		$intentArguments.ApplicationIntent = $ApplicationIntent
	}
	return (Invoke-IaSqlQuery -Server $effectiveServer -Database $effectiveDatabase -Query $query -Parameters $parameters -Fetch $Fetch -Skip $Skip `
			-Purpose $purpose -Config $Config @intentArguments)
}

function Read-IaToolUserInput {
	<# Обгортка Read-Host для діалогу підтвердження дозапитів (шов для моків у тестах). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Prompt)
	return (Read-Host -Prompt $Prompt)
}

function Format-IaToolValue {
	<# Значення аргументу для показу користувачу. #>
	[CmdletBinding()]
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return 'NULL'
	}
	$jsonValue = ConvertTo-IaToolJsonValue -Value $Value
	if ($jsonValue -is [bool]) {
		return $jsonValue.ToString().ToLowerInvariant()
	}
	if ($jsonValue -is [System.IFormattable]) {
		return $jsonValue.ToString($null, [cultureinfo]::InvariantCulture)
	}
	return [string]$jsonValue
}

function Show-IaToolRequest {
	<# Показує дозапит моделі: інструмент, сервер, база, аргументи, fetch, skip, причина, текст запиту. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ToolRequest,
		[System.Collections.IDictionary]$Tool,
		[string]$Title = 'Модель просить додаткові дані'
	)
	$server = if ($ToolRequest.resolvedServer) { $ToolRequest.resolvedServer } else { $ToolRequest.server }
	$database = if ($ToolRequest.resolvedDatabase) { $ToolRequest.resolvedDatabase } else { $ToolRequest.database }
	$serverText = [string]$server
	if ($ToolRequest.resolvedServer -and $ToolRequest.server -and $ToolRequest.resolvedServer -ne $ToolRequest.server) {
		$serverText = "$server (запитано моделлю: $($ToolRequest.server))"
	}
	$arguments = @()
	if ($ToolRequest.arguments -is [System.Collections.IDictionary]) {
		$arguments = @($ToolRequest.arguments.get_Keys() | ForEach-Object { "@$_ = $(Format-IaToolValue -Value $ToolRequest.arguments[$_])" })
	}
	$fetchText = if ($null -ne $ToolRequest.fetch) { [string]$ToolRequest.fetch } else { 'за замовчуванням (limits.defaultFetch)' }
	$skipText = if ($null -ne $ToolRequest.skip) { [string]$ToolRequest.skip } else { '0' }
	$queryText = if ($null -ne $Tool -and $Tool.purpose -eq 'FreeQuery') { [string]$ToolRequest.arguments['Sql'] } elseif ($null -ne $Tool) { [string]$Tool.query } else { '' }
	Write-Host ''
	Write-Host "=== $Title ==="
	Write-Host "Інструмент: $($ToolRequest.tool)$(if ($null -ne $Tool) { " — $($Tool.description)" })"
	if ($null -ne $Tool -and $Tool.purpose -eq 'FreeQuery') {
		Write-Host 'УВАГА: вільний запит (небезпечний режим unsafe.allowFreeQuery).'
	}
	Write-Host "Сервер: $serverText"
	Write-Host "База: $database"
	Write-Host "Аргументи: $(if ($arguments.Count -gt 0) { $arguments -join '; ' } else { '(немає)' })"
	Write-Host "Fetch: $fetchText; Skip: $skipText"
	Write-Host "Причина: $($ToolRequest.reason)"
	Write-Host 'Текст запиту:'
	Write-Host $queryText
}

function Resolve-IaToolChoice {
	<# Відповідь користувача -> Approve | Modify | Reject | $null. #>
	[CmdletBinding()]
	param([AllowNull()][AllowEmptyString()][string]$Answer)
	if ([string]::IsNullOrWhiteSpace($Answer)) {
		return $null
	}
	switch ($Answer.Trim().ToLowerInvariant()) {
		{ $_ -in @('п', 'підтвердити', 'т', 'так', 'y', 'yes', 'a', 'approve') } { return 'Approve' }
		{ $_ -in @('з', 'змінити', 'm', 'modify', 'e', 'edit') } { return 'Modify' }
		{ $_ -in @('в', 'відхилити', 'н', 'ні', 'n', 'no', 'r', 'reject') } { return 'Reject' }
	}
	return $null
}

function ConvertTo-IaToolNonNegativeInt {
	<# Рядок або число -> невід'ємне ціле. Повертає @{ isValid; value; error }. #>
	[CmdletBinding()]
	param(
		[AllowNull()]$Value,
		[Parameter(Mandatory)][string]$Name
	)
	if ($null -eq $Value) {
		return [ordered]@{ isValid = $true; value = $null; error = $null }
	}
	$converted = ConvertTo-IaToolTypedValue -Type 'int' -Value $Value
	if (-not $converted.isValid -or $converted.value -lt 0) {
		return [ordered]@{ isValid = $false; value = $null; error = "$Name має бути невід'ємним цілим числом, отримано '$Value'" }
	}
	return [ordered]@{ isValid = $true; value = $converted.value; error = $null }
}

function Edit-IaToolRequest {
	<# Діалог зміни аргументів, fetch і skip дозапиту з повторною перевіркою. Enter — без змін, '-' — очистити
	   (необов'язковий аргумент отримує default, fetch — значення за замовчуванням, skip — 0).
	   Повертає @{ isValid; errors; toolRequest }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ToolRequest,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Tool
	)
	$errors = [System.Collections.Generic.List[string]]::new()
	$arguments = [ordered]@{}
	if ($ToolRequest.arguments -is [System.Collections.IDictionary]) {
		foreach ($key in @($ToolRequest.arguments.get_Keys())) {
			$arguments[([string]$key) -replace '^@', ''] = $ToolRequest.arguments[$key]
		}
	}
	foreach ($parameter in @($Tool.parameters)) {
		$current = if ($arguments.Contains($parameter.name)) { Format-IaToolValue -Value $arguments[$parameter.name] } else { 'NULL' }
		$suffix = if ($parameter.required) { '' } else { '?' }
		$answer = Read-IaToolUserInput -Prompt "@$($parameter.name) ($($parameter.type)$suffix), поточне: $current [Enter — без змін, '-' — очистити]"
		if ([string]::IsNullOrEmpty($answer)) {
			continue
		}
		if ($answer.Trim() -eq '-') {
			$arguments[$parameter.name] = $null
			continue
		}
		$arguments[$parameter.name] = $answer
	}
	$fetch = $ToolRequest.fetch
	$fetchAnswer = Read-IaToolUserInput -Prompt "Fetch, поточне: $(if ($null -ne $fetch) { $fetch } else { 'за замовчуванням' }) [Enter — без змін, '-' — за замовчуванням]"
	if (-not [string]::IsNullOrEmpty($fetchAnswer)) {
		$fetch = if ($fetchAnswer.Trim() -eq '-') { $null } else { $fetchAnswer }
	}
	$skip = $ToolRequest.skip
	$skipAnswer = Read-IaToolUserInput -Prompt "Skip, поточне: $(if ($null -ne $skip) { $skip } else { 0 }) [Enter — без змін, '-' — 0]"
	if (-not [string]::IsNullOrEmpty($skipAnswer)) {
		$skip = if ($skipAnswer.Trim() -eq '-') { $null } else { $skipAnswer }
	}
	$fetchCheck = ConvertTo-IaToolNonNegativeInt -Value $fetch -Name 'fetch'
	$skipCheck = ConvertTo-IaToolNonNegativeInt -Value $skip -Name 'skip'
	foreach ($check in @($fetchCheck, $skipCheck)) {
		if (-not $check.isValid) {
			$errors.Add($check.error)
		}
	}
	$argumentCheck = Test-IaToolArguments -Tool $Tool -Arguments $arguments
	foreach ($message in $argumentCheck.errors) {
		$errors.Add($message)
	}
	$updated = [ordered]@{}
	foreach ($key in @($ToolRequest.get_Keys())) {
		$updated[$key] = $ToolRequest[$key]
	}
	if ($errors.Count -eq 0) {
		$updated.arguments = $argumentCheck.arguments
		$updated.fetch = $fetchCheck.value
		$updated.skip = $skipCheck.value
	}
	return [ordered]@{ isValid = ($errors.Count -eq 0); errors = $errors.ToArray(); toolRequest = $updated }
}

function Write-IaToolDecisionLog {
	<# Журнал рішення щодо дозапиту моделі (Write-IaLog; значення аргументів маскуються за іменем у Core). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ToolRequest,
		[Parameter(Mandatory)][string]$Decision,
		[AllowNull()][AllowEmptyString()][string]$Reason,
		[ValidateSet('Info', 'Warning', 'Error', 'Security')][string]$Level = 'Info'
	)
	$data = [ordered]@{
		tool = [string]$ToolRequest.tool
		server = [string]$ToolRequest.server
		database = [string]$ToolRequest.database
		resolvedServer = [string]$ToolRequest.resolvedServer
		resolvedDatabase = [string]$ToolRequest.resolvedDatabase
		fetch = if ($null -ne $ToolRequest.fetch) { [string]$ToolRequest.fetch } else { $null }
		skip = if ($null -ne $ToolRequest.skip) { [string]$ToolRequest.skip } else { $null }
		requestReason = [string]$ToolRequest.reason
		decision = $Decision
		decisionReason = $Reason
	}
	if ($ToolRequest.arguments -is [System.Collections.IDictionary]) {
		foreach ($key in @($ToolRequest.arguments.get_Keys())) {
			$data["argument_$key"] = Format-IaToolValue -Value $ToolRequest.arguments[$key]
		}
	}
	Write-IaLog -Message "Дозапит моделі '$($ToolRequest.tool)': рішення $Decision" -Level $Level -Data $data
}

function Request-IaToolApproval {
	<# Показує користувачу дозапит моделі й отримує рішення: Approved | Modified | Rejected | AutoApproved.
	   llm.autoApproveToolRequests -> AutoApproved; run.nonInteractive без автопідтвердження -> Rejected з поясненням.
	   Інтерактивно: підтвердити / змінити (аргументи, fetch, skip з повторною перевіркою) / відхилити.
	   Діалог — через Read-IaToolUserInput. Рішення записується в журнал (Write-IaLog).
	   Повертає @{ decision; toolRequest (можливо змінений); reason }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$ToolRequest,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Tools,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$request = [ordered]@{}
	foreach ($key in @($ToolRequest.get_Keys())) {
		$request[$key] = $ToolRequest[$key]
	}
	$toolName = [string]$request.tool
	$tool = if ($toolName -and $Tools.Contains($toolName)) { $Tools[$toolName] } else { $null }
	$autoApprove = [bool](Get-IaToolSetting -Config $Config -Section 'llm' -Name 'autoApproveToolRequests' -Default $false)
	$nonInteractive = [bool](Get-IaToolSetting -Config $Config -Section 'run' -Name 'nonInteractive' -Default $false)
	$decision = $null
	$reason = $null
	if ($null -eq $tool) {
		$decision = 'Rejected'
		$reason = "Невідомий інструмент '$toolName': дозапит відхилено."
	}
	elseif ($autoApprove) {
		$decision = 'AutoApproved'
		$reason = 'Автопідтвердження дозапитів увімкнено (llm.autoApproveToolRequests).'
		Write-Verbose "Дозапит '$toolName' підтверджено автоматично."
	}
	elseif ($nonInteractive) {
		$decision = 'Rejected'
		$reason = 'Неінтерактивний режим (run.nonInteractive) без автопідтвердження: дозапит відхилено автоматично. ' +
			'Щоб дозволити дозапити моделі, увімкніть llm.autoApproveToolRequests (-AutoApprove).'
	}
	else {
		Show-IaToolRequest -ToolRequest $request -Tool $tool
		$attempts = 0
		$maxAttempts = 3
		while ($null -eq $decision) {
			$choice = Resolve-IaToolChoice -Answer (Read-IaToolUserInput -Prompt 'Виконати дозапит? [П]ідтвердити / [З]мінити / [В]ідхилити')
			switch ($choice) {
				'Approve' {
					$decision = 'Approved'
					$reason = 'Підтверджено користувачем.'
				}
				'Reject' {
					$why = Read-IaToolUserInput -Prompt 'Причина відхилення (Enter — без причини)'
					$decision = 'Rejected'
					$reason = if ([string]::IsNullOrWhiteSpace($why)) { 'Відхилено користувачем.' } else { "Відхилено користувачем: $($why.Trim())" }
				}
				'Modify' {
					$edit = Edit-IaToolRequest -ToolRequest $request -Tool $tool
					if ($edit.isValid) {
						$request = $edit.toolRequest
						$decision = 'Modified'
						$reason = 'Змінено й підтверджено користувачем.'
						Show-IaToolRequest -ToolRequest $request -Tool $tool -Title 'Дозапит після змін'
					}
					else {
						$attempts++
						Write-Host "Зміни не пройшли перевірку: $($edit.errors -join '; ')"
					}
				}
				default {
					$attempts++
					Write-Host 'Невідома відповідь. Введіть П (підтвердити), З (змінити) або В (відхилити).'
				}
			}
			if ($null -eq $decision -and $attempts -ge $maxAttempts) {
				$decision = 'Rejected'
				$reason = 'Немає коректної відповіді користувача: дозапит відхилено.'
			}
		}
	}
	$level = if ($null -ne $tool -and $tool.purpose -eq 'FreeQuery') { 'Security' } else { 'Info' }
	Write-IaToolDecisionLog -ToolRequest $request -Decision $decision -Reason $reason -Level $level
	return [ordered]@{ decision = $decision; toolRequest = $request; reason = $reason }
}
