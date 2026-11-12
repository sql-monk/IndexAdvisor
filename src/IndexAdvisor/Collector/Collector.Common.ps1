# Спільні внутрішні помічники потоку Collector: тексти запитів, виконання через конвеєр Core зі сторінками,
# перетворення значень конверта, попередження, scope. Префікс внутрішніх функцій — IaCol.

$script:IaColQueryCache = @{}
$script:IaColQueriesPath = Join-Path $PSScriptRoot 'Queries'

function Get-IaColQueryText {
	<# Текст запиту колектора з Collector/Queries/<Name>.sql (кешується). Кожен файл — рівно одна інструкція SELECT. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Name)
	if (-not $script:IaColQueryCache.ContainsKey($Name)) {
		$path = Join-Path $script:IaColQueriesPath ($Name + '.sql')
		if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
			throw [System.IO.FileNotFoundException]::new("Запит колектора '$Name' не знайдено: $path")
		}
		$text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).Trim()
		$script:IaColQueryCache[$Name] = $text
	}
	return $script:IaColQueryCache[$Name]
}

function Stop-IaColWithError {
	<# Кидає завершальну помилку з ErrorId (IaCollectionFailed, IaLoginRefused, IaArchiveInvalid). #>
	param(
		[Parameter(Mandatory)][string]$ErrorId,
		[Parameter(Mandatory)][string]$Message,
		[System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidOperation
	)
	$exception = [System.InvalidOperationException]::new($Message)
	throw [System.Management.Automation.ErrorRecord]::new($exception, $ErrorId, $Category, $null)
}

function Invoke-IaColQuery {
	<# Виконує запит колектора лише через Invoke-IaSqlQuery. Великі набори читаються сторінками (Fetch, Skip) до truncated = $false.
	   Повертає @{ success; rows; error; durationMs; pages }. Помилка LoginRefused — виняток IaLoginRefused (політика, не дані). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][string]$Database,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[System.Collections.IDictionary]$Parameters = @{},
		[string]$ApplicationIntent,
		[ValidateSet('Collector', 'Topology')][string]$Purpose = 'Collector',
		[int]$PageSize = 0,
		[switch]$SinglePage
	)
	$query = Get-IaColQueryText -Name $Name
	$maxRows = [int]$Config.limits.maxRows
	$fetch = if ($PageSize -gt 0) { [Math]::Min($PageSize, $maxRows) } else { $maxRows }
	$rows = [System.Collections.Generic.List[object]]::new()
	$skip = 0
	$pages = 0
	$durationMs = 0
	while ($true) {
		$splat = @{
			Server = $Server
			Database = $Database
			Query = $query
			Parameters = $Parameters
			Fetch = $fetch
			Skip = $skip
			Purpose = $Purpose
			Config = $Config
		}
		if ($ApplicationIntent) {
			$splat.ApplicationIntent = $ApplicationIntent
		}
		$response = Invoke-IaSqlQuery @splat
		$pages++
		if ($null -eq $response) {
			return @{ success = $false; rows = $rows.ToArray(); error = (New-IaError -Code 'SqlError' -Message 'Порожня відповідь конвеєра'); durationMs = $durationMs; pages = $pages }
		}
		$durationMs += [long]$response.durationMs
		if (-not $response.success) {
			$errorObject = $response.error
			if ($errorObject -and $errorObject.code -eq 'LoginRefused') {
				Stop-IaColWithError -ErrorId 'IaLoginRefused' -Message ([string]$errorObject.message) -Category PermissionDenied
			}
			if ($null -eq $errorObject) {
				$errorObject = New-IaError -Code 'SqlError' -Message 'Невідома помилка конвеєра'
			}
			return @{ success = $false; rows = $rows.ToArray(); error = $errorObject; durationMs = $durationMs; pages = $pages }
		}
		foreach ($row in @($response.rows)) {
			if ($null -ne $row) {
				$rows.Add($row)
			}
		}
		if ($SinglePage -or -not $response.truncated) {
			break
		}
		$skip += $fetch
	}
	return @{ success = $true; rows = $rows.ToArray(); error = $null; durationMs = $durationMs; pages = $pages }
}

function Get-IaColValue {
	<# Значення колонки рядка конверта ([ordered] словник) або $null. #>
	param($Row, [string]$Name)
	if ($null -eq $Row) {
		return $null
	}
	$value = $Row[$Name]
	if ($value -is [System.DBNull]) {
		return $null
	}
	return $value
}

function ConvertTo-IaColLong {
	<# Ціле з конверта (Core перетворює decimal на рядок). $null лишається $null, якщо не задано Default. #>
	param($Value, $Default = $null)
	if ($null -eq $Value -or $Value -is [System.DBNull] -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
		return $Default
	}
	if ($Value -is [bool]) {
		return [long][int]$Value
	}
	if ($Value -is [string]) {
		return [long][Math]::Round([decimal]::Parse($Value, [cultureinfo]::InvariantCulture))
	}
	return [long][Math]::Round([decimal]$Value)
}

function ConvertTo-IaColDouble {
	<# Число з конверта; Digits — округлення. #>
	param($Value, $Default = $null, [int]$Digits = -1)
	if ($null -eq $Value -or $Value -is [System.DBNull] -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
		return $Default
	}
	$number = if ($Value -is [string]) { [double]::Parse($Value, [cultureinfo]::InvariantCulture) } else { [double]$Value }
	if ($Digits -ge 0) {
		$number = [Math]::Round($number, $Digits)
	}
	return $number
}

function ConvertTo-IaColBool {
	<# bool з конверта (bit, число або рядок). #>
	param($Value, $Default = $false)
	if ($null -eq $Value -or $Value -is [System.DBNull]) {
		return $Default
	}
	if ($Value -is [bool]) {
		return $Value
	}
	if ($Value -is [string]) {
		return $Value.Trim() -in @('1', 'true', 'True', 'TRUE')
	}
	return ([double]$Value) -ne 0
}

function ConvertTo-IaColUtc {
	<# Дата з конверта -> 'yyyy-MM-ddTHH:mm:ss.fffZ' або $null. Запити колектора повертають UTC. #>
	param($Value)
	if ($null -eq $Value -or $Value -is [System.DBNull] -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
		return $null
	}
	if ($Value -is [string] -and $Value -notmatch '(Z|[+-]\d{2}:\d{2})$') {
		$Value = $Value + 'Z'
	}
	return ConvertTo-IaUtcString -Date $Value
}

function ConvertTo-IaColDateTime {
	<# Рядок ISO 8601 або дата -> [datetime] UTC (для параметрів запитів і розрахунків). #>
	param($Value)
	if ($null -eq $Value) {
		return $null
	}
	if ($Value -is [datetime]) {
		return $Value.ToUniversalTime()
	}
	if ($Value -is [System.DateTimeOffset]) {
		return $Value.UtcDateTime
	}
	return [System.DateTimeOffset]::Parse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function New-IaColWarning {
	<# Попередження snapshot ($defs.warning). #>
	param(
		[Parameter(Mandatory)][string]$Code,
		[Parameter(Mandatory)][string]$Message,
		[string]$Dataset,
		[string]$Server,
		[string]$Database
	)
	return [ordered]@{
		code = $Code
		message = $Message
		dataset = $(if ($Dataset) { $Dataset } else { $null })
		server = $(if ($Server) { $Server } else { $null })
		database = $(if ($Database) { $Database } else { $null })
	}
}

function Add-IaColWarning {
	<# Додає попередження до списку і пише його в журнал сесії (збій журналу не зупиняє збір). #>
	param(
		[Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
		[Parameter(Mandatory)][string]$Code,
		[Parameter(Mandatory)][string]$Message,
		[string]$Dataset,
		[string]$Server,
		[string]$Database,
		[switch]$Show
	)
	$warning = New-IaColWarning -Code $Code -Message $Message -Dataset $Dataset -Server $Server -Database $Database
	$List.Add($warning)
	try {
		Write-IaLog -Message ("Колектор [{0}]: {1}" -f $Code, $Message) -Level Warning -Data ([ordered]@{ server = $Server; database = $Database; dataset = $Dataset })
	}
	catch {
		Write-Verbose ("Журнал недоступний: {0}" -f $_.Exception.Message)
	}
	if ($Show) {
		Write-Warning $Message
	}
}

function Test-IaColPattern {
	<# Збіг із шаблоном scope: підтримуються лише * і ?, без урахування регістру. #>
	param([AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Pattern)
	$escaped = $Pattern -replace '([`\[\]])', '`$1'
	return $Value -like $escaped
}

function Test-IaColScopeMatch {
	<# Порожній include означає все; exclude має пріоритет. #>
	param([AllowEmptyString()][string]$Value, [object[]]$Include = @(), [object[]]$Exclude = @())
	$includeList = @($Include | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
	$excludeList = @($Exclude | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
	if ($includeList.Count -gt 0) {
		$matched = $false
		foreach ($pattern in $includeList) {
			if (Test-IaColPattern -Value $Value -Pattern ([string]$pattern)) {
				$matched = $true
				break
			}
		}
		if (-not $matched) {
			return $false
		}
	}
	foreach ($pattern in $excludeList) {
		if (Test-IaColPattern -Value $Value -Pattern ([string]$pattern)) {
			return $false
		}
	}
	return $true
}

function Test-IaColTableInScope {
	<# Схема й таблиця в межах scope. Шаблон таблиці з крапкою зіставляється з 'schema.table', без крапки — з іменем таблиці. #>
	param([Parameter(Mandatory)][string]$Schema, [Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][System.Collections.IDictionary]$Scope)
	if (-not (Test-IaColScopeMatch -Value $Schema -Include @($Scope.schemas.include) -Exclude @($Scope.schemas.exclude))) {
		return $false
	}
	$fullName = $Schema + '.' + $Table
	$test = {
		param([object[]]$Patterns)
		foreach ($pattern in @($Patterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
			$value = if (([string]$pattern).Contains('.')) { $fullName } else { $Table }
			if (Test-IaColPattern -Value $value -Pattern ([string]$pattern)) {
				return $true
			}
		}
		return $false
	}
	$include = @($Scope.tables.include | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
	if ($include.Count -gt 0 -and -not (& $test $include)) {
		return $false
	}
	if (& $test @($Scope.tables.exclude)) {
		return $false
	}
	return $true
}

function Copy-IaColConfigWithTimeout {
	<# Неглибока копія конфігурації з іншим connection.commandTimeoutSeconds (для бюджету часу physical_stats). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][int]$TimeoutSeconds)
	$copy = [ordered]@{}
	foreach ($key in $Config.Keys) {
		$copy[$key] = $Config[$key]
	}
	$connection = [ordered]@{}
	if ($Config.connection) {
		foreach ($key in $Config.connection.Keys) {
			$connection[$key] = $Config.connection[$key]
		}
	}
	$connection['commandTimeoutSeconds'] = [Math]::Max(1, $TimeoutSeconds)
	$copy['connection'] = $connection
	return $copy
}

function Split-IaColBracketList {
	<# '[a], [b]]c]' -> @('a', 'b]c') (формат колонок sys.dm_db_missing_index_details). #>
	param([AllowNull()][string]$Text)
	if ([string]::IsNullOrWhiteSpace($Text)) {
		return , @()
	}
	$result = [System.Collections.Generic.List[string]]::new()
	foreach ($match in [regex]::Matches($Text, '\[((?:[^\]]|\]\])*)\]')) {
		$result.Add($match.Groups[1].Value.Replace(']]', ']'))
	}
	return , $result.ToArray()
}

function Get-IaColUnquotedName {
	<# '[dbo]' -> 'dbo'; '"x"' -> 'x'. #>
	param([AllowNull()][string]$Name)
	if ([string]::IsNullOrEmpty($Name)) {
		return $Name
	}
	$trimmed = $Name.Trim()
	if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
		return $trimmed.Substring(1, $trimmed.Length - 2).Replace(']]', ']')
	}
	if ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"') -and $trimmed.Length -ge 2) {
		return $trimmed.Substring(1, $trimmed.Length - 2).Replace('""', '"')
	}
	return $trimmed
}
