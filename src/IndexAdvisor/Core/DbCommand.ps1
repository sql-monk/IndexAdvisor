# Шов драйвера SQL Server (Microsoft.Data.SqlClient). Єдине місце, що відкриває підключення до цільового сервера.
# У юніт-тестах мокається; реальна поведінка покривається лише тестами з тегом Integration.

function Initialize-IaCoreSqlClient {
	<# Ліниве завантаження Microsoft.Data.SqlClient: тип уже є — використати; інакше dbatools.library / dbatools; інакше Add-Type. #>
	[CmdletBinding()]
	param()
	$typeName = 'Microsoft.Data.SqlClient.SqlConnection'
	if ($null -ne ([System.Management.Automation.PSTypeName]$typeName).Type) {
		return
	}
	foreach ($moduleName in @('dbatools.library', 'dbatools')) {
		try {
			Import-Module -Name $moduleName -ErrorAction Stop -Verbose:$false
		}
		catch {
			Write-Verbose ("Не вдалося імпортувати {0}: {1}" -f $moduleName, $_.Exception.Message)
		}
		if ($null -ne ([System.Management.Automation.PSTypeName]$typeName).Type) {
			return
		}
	}
	$libraryBase = Get-IaCoreDbatoolsLibraryBase
	if ($libraryBase) {
		$path = Join-Path -Path $libraryBase -ChildPath 'core\lib\Microsoft.Data.SqlClient.dll'
		if (Test-Path -LiteralPath $path) {
			Add-Type -LiteralPath $path
		}
	}
	if ($null -eq ([System.Management.Automation.PSTypeName]$typeName).Type) {
		throw [System.InvalidOperationException]::new('Не знайдено Microsoft.Data.SqlClient: встановіть модуль dbatools.library.')
	}
}

function Get-IaCoreSqlException {
	<# Перший SqlException у ланцюжку винятків або $null. #>
	[CmdletBinding()]
	param([AllowNull()][System.Exception]$Exception)
	$current = $Exception
	while ($null -ne $current) {
		if ($current.GetType().Name -eq 'SqlException') {
			return $current
		}
		$current = $current.InnerException
	}
	return $null
}

function Get-IaCoreErrorCode {
	<# Код помилки конверта для ErrorRecord: ErrorId з $script:IaErrorCodes або класифікація винятку (таймаут -> Timeout). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
	$errorId = ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
	if ($errorId -in $script:IaErrorCodes) {
		return $errorId
	}
	$current = $ErrorRecord.Exception
	while ($null -ne $current) {
		if ($current -is [System.TimeoutException]) {
			return 'Timeout'
		}
		if ($current.GetType().Name -eq 'SqlException') {
			if ($current.Number -eq -2) {
				return 'Timeout'
			}
			return 'SqlError'
		}
		$current = $current.InnerException
	}
	return 'SqlError'
}

# Мережеві обриви до входу (pre-login), після яких повторне підключення зазвичай вдається (VPN, що піднімає тунель на першому з'єднанні):
# 10053/10054 — з'єднання розірвано, 10060 — тайм-аут TCP, 10061 — відмова в підключенні, 64 — мережеве ім'я недоступне,
# 121 — тайм-аут семафора, 233 — немає процесу на іншому кінці, -2 — тайм-аут підключення (у фазі Open це лише рукостискання,
# а не запит). Помилки входу (18456 тощо) не повторюються: логін не блокується.
$script:IaCoreTransientConnectErrors = @(-2, 64, 121, 233, 10053, 10054, 10060, 10061)
$script:IaCoreConnectRetryDelaysMs = @(1000, 3000)

function Test-IaCoreTransientConnectError {
	<# $true, якщо виняток підключення — мережевий обрив до входу (SqlException з номером зі списку $script:IaCoreTransientConnectErrors). #>
	[CmdletBinding()]
	param([AllowNull()][System.Exception]$Exception)
	$sqlException = Get-IaCoreSqlException -Exception $Exception
	if ($null -eq $sqlException) {
		return $false
	}
	$numbers = @([int]$sqlException.Number) + @(foreach ($sqlError in @($sqlException.Errors)) { if ($null -ne $sqlError) { [int]$sqlError.Number } })
	return @($numbers | Where-Object { $_ -in $script:IaCoreTransientConnectErrors }).Count -gt 0
}

function Open-IaCoreSqlConnection {
	<# Відкриває підключення, створене фабрикою NewConnection. При мережевому обриві до входу повторює з паузами RetryDelaysMs,
	   кожна спроба — нове підключення (Pooling = false, тож кешованої помилки пулу немає). Кожен повтор записується в Messages.
	   Повертає відкрите підключення; інша помилка чи вичерпані повтори — виняток останньої спроби. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][scriptblock]$NewConnection,
		[Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Messages,
		[int[]]$RetryDelaysMs = $script:IaCoreConnectRetryDelaysMs
	)
	$attempt = 0
	while ($true) {
		$connection = & $NewConnection
		try {
			$connection.Open()
			return $connection
		}
		catch {
			$connection.Dispose()
			if ($attempt -ge $RetryDelaysMs.Count -or -not (Test-IaCoreTransientConnectError -Exception $_.Exception)) {
				throw
			}
			$sqlException = Get-IaCoreSqlException -Exception $_.Exception
			$Messages.Add(("Підключення обірвалося до входу (Msg {0}); повтор {1} з {2} через {3} мс." -f $sqlException.Number, ($attempt + 1),
					$RetryDelaysMs.Count, $RetryDelaysMs[$attempt]))
			Start-Sleep -Milliseconds $RetryDelaysMs[$attempt]
			$attempt++
		}
	}
}

function Invoke-IaDbCommand {
	<# Шов драйвера: єдине місце, що відкриває SqlConnection (Microsoft.Data.SqlClient). У юніт-тестах мокається.
	   Parameters — масив @{ name = '@Name'; value = ...; sqlType = 'NVarChar'|'Int'|... }.
	   Повертає @{ columns = @(@{ name; type }); rows = @(,[object[]]...); messages = @(); hasMoreRows = $bool }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$ConnectionString,
		[Parameter(Mandatory)][string]$CommandText,
		[object[]]$Parameters = @(),
		[int]$CommandTimeoutSeconds = 30,
		[int]$MaxRows = 5000
	)
	$messages = [System.Collections.Generic.List[string]]::new()
	$connection = $null
	$command = $null
	$reader = $null
	$phase = 'Connect'
	try {
		Initialize-IaCoreSqlClient
		$handler = {
			param($source, $infoArgs)
			foreach ($sqlError in $infoArgs.Errors) {
				$messages.Add([string]$sqlError.Message)
			}
		}.GetNewClosure()
		$factory = {
			$newConnection = New-Object -TypeName 'Microsoft.Data.SqlClient.SqlConnection' -ArgumentList $ConnectionString
			$newConnection.add_InfoMessage($handler)
			$newConnection
		}.GetNewClosure()
		$connection = Open-IaCoreSqlConnection -NewConnection $factory -Messages $messages
		$phase = 'Execute'
		$command = $connection.CreateCommand()
		$command.CommandText = $CommandText
		$command.CommandType = [System.Data.CommandType]::Text
		$command.CommandTimeout = $CommandTimeoutSeconds
		foreach ($parameter in @($Parameters)) {
			if ($null -eq $parameter) {
				continue
			}
			$sqlParameter = $command.CreateParameter()
			$sqlParameter.ParameterName = [string]$parameter.name
			$sqlParameter.SqlDbType = [System.Data.SqlDbType][string]$parameter.sqlType
			$value = $parameter.value
			switch ([string]$parameter.sqlType) {
				'NVarChar' {
					$sqlParameter.Size = $(if ($null -ne $value -and ([string]$value).Length -gt 4000) { -1 } else { 4000 })
				}
				'VarBinary' {
					$sqlParameter.Size = $(if ($null -ne $value -and $value.Length -gt 8000) { -1 } else { 8000 })
				}
			}
			# Без $(...): підвираз розгорнув би byte[] у масив чисел.
			if ($null -eq $value) {
				$sqlParameter.Value = [System.DBNull]::Value
			}
			else {
				$sqlParameter.Value = $value
			}
			[void]$command.Parameters.Add($sqlParameter)
		}
		$reader = $command.ExecuteReader()
		$columns = [System.Collections.Generic.List[object]]::new()
		for ($i = 0; $i -lt $reader.FieldCount; $i++) {
			$columns.Add([ordered]@{ name = $reader.GetName($i); type = $reader.GetDataTypeName($i) })
		}
		$rows = [System.Collections.Generic.List[object]]::new()
		$hasMoreRows = $false
		while ($reader.Read()) {
			if ($rows.Count -ge $MaxRows) {
				$hasMoreRows = $true
				break
			}
			$values = [object[]]::new($reader.FieldCount)
			[void]$reader.GetValues($values)
			$rows.Add($values)
		}
		if ($hasMoreRows) {
			# Решту рядків не дочитуємо: скасування запиту, щоб Close не вичитував результат до кінця.
			try {
				$command.Cancel()
			}
			catch {
				Write-Verbose "Скасування запиту: $($_.Exception.Message)"
			}
		}
		try {
			$reader.Close()
		}
		catch {
			if (-not $hasMoreRows) {
				throw
			}
		}
		return [ordered]@{
			columns = $columns.ToArray()
			rows = $rows.ToArray()
			messages = $messages.ToArray()
			hasMoreRows = $hasMoreRows
		}
	}
	catch {
		$sqlException = Get-IaCoreSqlException -Exception $_.Exception
		$code = if ($phase -eq 'Connect') { 'ConnectionFailed' } else { Get-IaCoreErrorCode -ErrorRecord $_ }
		$message = if ($null -ne $sqlException) {
			'Msg {0}, Level {1}, State {2}, Line {3}: {4}' -f $sqlException.Number, $sqlException.Class, $sqlException.State, $sqlException.LineNumber, $sqlException.Message
		}
		else {
			$_.Exception.Message
		}
		$exception = [System.InvalidOperationException]::new($message, $_.Exception)
		$PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new($exception, $code, [System.Management.Automation.ErrorCategory]::NotSpecified, @{ messages = $messages.ToArray() }))
	}
	finally {
		if ($null -ne $reader) {
			$reader.Dispose()
		}
		if ($null -ne $command) {
			$command.Dispose()
		}
		if ($null -ne $connection) {
			$connection.Close()
			$connection.Dispose()
		}
	}
}
