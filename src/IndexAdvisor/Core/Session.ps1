# Сесія і Markdown-журнал (потік Core, CONTRACTS.md 5.11): один файл журналу на сесію.

$script:IaCoreSession = $null
$script:IaCoreSessionStats = $null

function Get-IaCoreUserName {
	<# Поточний обліковий запис Windows у форматі DOMAIN\user. #>
	[CmdletBinding()]
	param()
	return [System.Environment]::UserDomainName + '\' + [System.Environment]::UserName
}

function Resolve-IaCorePath {
	<# Абсолютний шлях файлової системи (відносний — від поточного каталогу PowerShell). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Path)
	return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-IaCoreFence {
	<# Огорожа Markdown-блоку коду, довша за будь-яку послідовність зворотних лапок у тексті. #>
	[CmdletBinding()]
	param([AllowNull()][AllowEmptyString()][string]$Text)
	$longest = 0
	foreach ($match in [regex]::Matches([string]$Text, '`+')) {
		if ($match.Length -gt $longest) {
			$longest = $match.Length
		}
	}
	return ('`' * [Math]::Max(3, $longest + 1))
}

function Add-IaCoreLogText {
	<# Дописує текст у журнал поточної сесії. Помилка запису не перериває роботу (лише попередження). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
	$session = $script:IaCoreSession
	if ($null -eq $session) {
		return
	}
	try {
		[System.IO.File]::AppendAllText($session.logPath, $Text, [System.Text.UTF8Encoding]::new($false))
	}
	catch {
		Write-Warning ("Не вдалося записати журнал '{0}': {1}" -f $session.logPath, $_.Exception.Message)
	}
}

function Start-IaSession {
	<# Починає сесію: sessionId, Markdown-журнал logging.path/IndexAdvisor_<yyyyMMdd_HHmmss>_<sessionId8>.md,
	   записує активні небезпечні прапорці з попередженням. Зберігає сесію в модулі. Повертає об'єкт сесії
	   @{ sessionId; startedAtUtc; logPath; config; unsafeFlags; command }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[string]$Command = 'Invoke-IndexAdvisor'
	)
	if ($null -ne $script:IaCoreSession) {
		Stop-IaSession
	}
	$sessionId = [guid]::NewGuid().ToString()
	$startedAt = [datetime]::UtcNow
	$logRoot = [string]$Config['logging']['path']
	if ([string]::IsNullOrWhiteSpace($logRoot)) {
		$logRoot = './logs'
	}
	$logDirectory = Resolve-IaCorePath -Path $logRoot
	if (-not (Test-Path -LiteralPath $logDirectory)) {
		$null = New-Item -ItemType Directory -Path $logDirectory -Force
	}
	$fileName = 'IndexAdvisor_{0}_{1}.md' -f $startedAt.ToString('yyyyMMdd_HHmmss', [cultureinfo]::InvariantCulture), $sessionId.Substring(0, 8)
	$unsafeFlags = @(Get-IaUnsafeFlags -Config $Config)
	$session = [ordered]@{
		sessionId = $sessionId
		startedAtUtc = ConvertTo-IaUtcString -Date $startedAt
		logPath = Join-Path -Path $logDirectory -ChildPath $fileName
		config = $Config
		unsafeFlags = $unsafeFlags
		command = $Command
	}
	$parametersJson = ConvertTo-Json -InputObject (Protect-IaCoreLogData -Value $Config) -Depth 30
	$fence = Get-IaCoreFence -Text $parametersJson
	$header = [System.Text.StringBuilder]::new()
	[void]$header.AppendLine("# Журнал IndexAdvisor — сесія $sessionId")
	[void]$header.AppendLine()
	[void]$header.AppendLine("- Сесія: $sessionId")
	[void]$header.AppendLine("- Початок (UTC): $($session.startedAtUtc)")
	[void]$header.AppendLine("- Користувач: $(Get-IaCoreUserName)")
	[void]$header.AppendLine("- Хост: $([System.Environment]::MachineName)")
	[void]$header.AppendLine("- Команда: $Command")
	[void]$header.AppendLine("- Версія: $($script:IaToolVersion)")
	[void]$header.AppendLine("- Небезпечні режими: $(if ($unsafeFlags.Count -gt 0) { $unsafeFlags -join ', ' } else { 'немає' })")
	[void]$header.AppendLine()
	[void]$header.AppendLine('## Параметри (санітизовані)')
	[void]$header.AppendLine()
	[void]$header.AppendLine("$($fence)json")
	[void]$header.AppendLine($parametersJson)
	[void]$header.AppendLine($fence)
	[void]$header.AppendLine()
	[System.IO.File]::WriteAllText($session.logPath, $header.ToString(), [System.Text.UTF8Encoding]::new($false))
	$script:IaCoreSession = $session
	$script:IaCoreSessionStats = @{ queries = 0; failed = 0 }
	if ($unsafeFlags.Count -gt 0) {
		Write-IaLog -Level Warning -Message ("Активні небезпечні режими: {0}. Обмеження безпеки послаблено; це позначається в журналі й у кожній рекомендації." -f ($unsafeFlags -join ', ')) `
			-Data ([ordered]@{ unsafeFlags = $unsafeFlags })
	}
	return $session
}

function Get-IaSession {
	<# Поточна сесія або $null. #>
	[CmdletBinding()]
	param()
	return $script:IaCoreSession
}

function Stop-IaSession {
	<# Завершує сесію і дописує підсумок у журнал. #>
	[CmdletBinding()]
	param()
	$session = $script:IaCoreSession
	if ($null -eq $session) {
		return
	}
	$finishedAt = [datetime]::UtcNow
	$started = [System.DateTimeOffset]::Parse($session.startedAtUtc, [cultureinfo]::InvariantCulture).UtcDateTime
	$stats = $script:IaCoreSessionStats
	$summary = [System.Text.StringBuilder]::new()
	[void]$summary.AppendLine('## Завершення сесії')
	[void]$summary.AppendLine()
	[void]$summary.AppendLine("- Завершення (UTC): $(ConvertTo-IaUtcString -Date $finishedAt)")
	[void]$summary.AppendLine(("- Тривалість, с: {0}" -f [Math]::Round(($finishedAt - $started).TotalSeconds, 1).ToString([cultureinfo]::InvariantCulture)))
	[void]$summary.AppendLine("- Викликів SQL: $($stats.queries)")
	[void]$summary.AppendLine("- З них неуспішних або заблокованих: $($stats.failed)")
	[void]$summary.AppendLine()
	Add-IaCoreLogText -Text $summary.ToString()
	$script:IaCoreSession = $null
	$script:IaCoreSessionStats = $null
}

function Write-IaLog {
	<# Запис у Markdown-журнал поточної сесії (без сесії — лише Write-Verbose). Data маскується Protect-IaLogValue. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Message,
		[ValidateSet('Info', 'Warning', 'Error', 'Security')][string]$Level = 'Info',
		[System.Collections.IDictionary]$Data
	)
	if ($null -eq $script:IaCoreSession) {
		Write-Verbose "[$Level] $Message"
		return
	}
	$text = [System.Text.StringBuilder]::new()
	[void]$text.AppendLine(("**{0} · {1}** — {2}" -f (ConvertTo-IaUtcString -Date ([datetime]::UtcNow)), $Level, (Protect-IaLogValue -Name '' -Value $Message)))
	if ($null -ne $Data -and $Data.Count -gt 0) {
		[void]$text.AppendLine()
		$protected = Protect-IaCoreLogData -Value $Data
		foreach ($key in $protected.Keys) {
			[void]$text.AppendLine(("- {0}: {1}" -f $key, (Format-IaCoreLogValue -Value $protected[$key])))
		}
	}
	[void]$text.AppendLine()
	Add-IaCoreLogText -Text $text.ToString()
}

function Write-IaCoreQueryLog {
	<# Розділ журналу для одного виклику конвеєра SQL (5.11), зокрема заблокованого. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Context,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Response,
		[Parameter(Mandatory)][datetime]$StartedAtUtc,
		[Parameter(Mandatory)][datetime]$FinishedAtUtc
	)
	if ($null -ne $script:IaCoreSessionStats) {
		$script:IaCoreSessionStats.queries++
		if (-not $Response.success) {
			$script:IaCoreSessionStats.failed++
		}
	}
	if ($null -eq $script:IaCoreSession) {
		Write-Verbose ("SQL {0}: {1}/{2}, Purpose {3}, успіх {4}, рядків {5}" -f $Response.requestId, $Response.server, $Response.database, $Context.purpose, $Response.success, $Response.rowCount)
		return
	}
	$text = [System.Text.StringBuilder]::new()
	[void]$text.AppendLine("### $($Response.requestId)")
	[void]$text.AppendLine()
	[void]$text.AppendLine("- Початок (UTC): $(ConvertTo-IaUtcString -Date $StartedAtUtc)")
	[void]$text.AppendLine("- Завершення (UTC): $(ConvertTo-IaUtcString -Date $FinishedAtUtc)")
	[void]$text.AppendLine("- Тривалість, мс: $($Response.durationMs)")
	[void]$text.AppendLine("- Сервер: $($Response.server)")
	[void]$text.AppendLine("- База: $($Response.database)")
	[void]$text.AppendLine("- Purpose: $($Context.purpose)")
	if ($Context.applicationIntent) {
		[void]$text.AppendLine("- ApplicationIntent: $($Context.applicationIntent)")
	}
	[void]$text.AppendLine("- Fetch: $(if ($null -eq $Context.fetch) { 'за замовчуванням' } else { $Context.fetch })")
	[void]$text.AppendLine("- Skip: $($Context.skip)")
	[void]$text.AppendLine("- Кількість рядків: $($Response.rowCount)")
	[void]$text.AppendLine("- Truncated: $(Format-IaCoreLogValue -Value ([bool]$Response.truncated))")
	[void]$text.AppendLine("- Успіх: $(Format-IaCoreLogValue -Value ([bool]$Response.success))")
	if (@($Context.unsafeFlags).Count -gt 0) {
		[void]$text.AppendLine("- Небезпечні режими: $(@($Context.unsafeFlags) -join ', ')")
	}
	$parameterLines = [System.Collections.Generic.List[string]]::new()
	if ($null -ne $Context.boundParameters) {
		foreach ($parameter in $Context.boundParameters) {
			$value = Protect-IaLogValue -Name $parameter.name -Value (ConvertTo-IaJsonValue -Value $parameter.value)
			$parameterLines.Add(("  - {0} ({1}) = {2}" -f $parameter.name, $parameter.sqlType, (Format-IaCoreLogValue -Value $value)))
		}
	}
	elseif ($null -ne $Context.parameters) {
		foreach ($key in $Context.parameters.Keys) {
			$value = Protect-IaLogValue -Name ([string]$key) -Value (ConvertTo-IaJsonValue -Value $Context.parameters[$key])
			$parameterLines.Add(("  - {0} = {1}" -f $key, (Format-IaCoreLogValue -Value $value)))
		}
	}
	if ($parameterLines.Count -gt 0) {
		[void]$text.AppendLine('- Параметри:')
		foreach ($line in $parameterLines) {
			[void]$text.AppendLine($line)
		}
	}
	else {
		[void]$text.AppendLine('- Параметри: немає')
	}
	if (@($Response.messages).Count -gt 0) {
		[void]$text.AppendLine('- Повідомлення:')
		foreach ($message in @($Response.messages)) {
			[void]$text.AppendLine("  - $(Protect-IaLogValue -Name '' -Value ([string]$message))")
		}
	}
	if ($null -ne $Response.error) {
		[void]$text.AppendLine(("- Помилка: {0}: {1}" -f $Response.error.code, (Protect-IaLogValue -Name '' -Value ([string]$Response.error.message))))
	}
	$commandText = [string]$Context.commandText
	$fence = Get-IaCoreFence -Text $commandText
	[void]$text.AppendLine()
	[void]$text.AppendLine("$($fence)sql")
	[void]$text.AppendLine($commandText)
	[void]$text.AppendLine($fence)
	[void]$text.AppendLine()
	Add-IaCoreLogText -Text $text.ToString()
}
