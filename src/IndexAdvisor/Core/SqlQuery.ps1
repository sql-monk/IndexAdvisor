# Єдиний конвеєр виконання read-only запитів Invoke-IaSqlQuery (потік Core, CONTRACTS.md 3.1.1, розділ 4.7 ТЗ).

$script:IaCoreSessionPrefix = @'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET LOCK_TIMEOUT {0};
SET DEADLOCK_PRIORITY LOW;

'@

function Resolve-IaCoreConfig {
	<# Конфігурація виклику: передана явно, інакше з поточної сесії, інакше значення за замовчуванням. #>
	[CmdletBinding()]
	param([System.Collections.IDictionary]$Config)
	if ($null -ne $Config) {
		return $Config
	}
	if ($null -ne $script:IaCoreSession) {
		return $script:IaCoreSession.config
	}
	return Get-IaDefaultConfig
}

function Join-IaCoreErrors {
	<# Одна помилка конверта з кількох: код і позиція першої, повідомлення — усі через пробіл. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object[]]$Errors)
	$first = $Errors[0]
	$message = (@($Errors | ForEach-Object { $_.message } | Select-Object -Unique)) -join ' '
	return New-IaError -Code $first.code -Message $message -Line $first.line -Column $first.column
}

function Get-IaCoreSqlDbType {
	<# SqlDbType для значення параметра або $null, якщо тип не підтримується. #>
	[CmdletBinding()]
	param([AllowNull()]$Value)
	if ($null -eq $Value -or $Value -is [System.DBNull]) { return 'NVarChar' }
	if ($Value -is [string] -or $Value -is [char]) { return 'NVarChar' }
	if ($Value -is [bool]) { return 'Bit' }
	if ($Value -is [byte]) { return 'TinyInt' }
	if ($Value -is [short] -or $Value -is [sbyte]) { return 'SmallInt' }
	if ($Value -is [int] -or $Value -is [uint16]) { return 'Int' }
	if ($Value -is [long] -or $Value -is [uint32]) { return 'BigInt' }
	if ($Value -is [decimal] -or $Value -is [uint64]) { return 'Decimal' }
	if ($Value -is [double]) { return 'Float' }
	if ($Value -is [single]) { return 'Real' }
	if ($Value -is [datetime]) { return 'DateTime2' }
	if ($Value -is [System.DateTimeOffset]) { return 'DateTimeOffset' }
	if ($Value -is [timespan]) { return 'Time' }
	if ($Value -is [guid]) { return 'UniqueIdentifier' }
	if ($Value -is [byte[]]) { return 'VarBinary' }
	return $null
}

function Get-IaCoreQueryVariables {
	<# Змінні @Name у тексті (за токенами ScriptDom, без @@-функцій, коментарів і рядків) і змінні, оголошені DECLARE.
	   referenced — словник «ім'я без урахування регістру -> написання в тексті». #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$Fragment)
	$referenced = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$declared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($token in $Fragment.ScriptTokenStream) {
		if ($token.TokenType.ToString() -eq 'Variable' -and -not $token.Text.StartsWith('@@')) {
			if (-not $referenced.ContainsKey($token.Text)) {
				$referenced[$token.Text] = $token.Text
			}
		}
	}
	foreach ($node in (Get-IaCoreFragmentNodes -Fragment $Fragment)) {
		$typeName = $node.GetType().Name
		if (($typeName -eq 'DeclareVariableElement' -or $typeName -eq 'DeclareTableVariableBody') -and $null -ne $node.VariableName) {
			[void]$declared.Add($node.VariableName.Value)
		}
	}
	return [ordered]@{ referenced = $referenced; declared = $declared }
}

function Set-IaCoreRowLimit {
	<# Ліміт рядків для SelectStatement (крок 5): TOP (Fetch + 1) або OFFSET Skip ROWS FETCH NEXT Fetch + 1 ROWS ONLY.
	   Змінює AST на місці. Повертає текст помилки або $null. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][object]$Statement,
		[Parameter(Mandatory)][int]$Fetch,
		[Parameter(Mandatory)][int]$Skip
	)
	$limit = [long]$Fetch + 1
	$query = $Statement.QueryExpression
	$isSpecification = $query.GetType().Name -eq 'QuerySpecification'
	if ($Skip -eq 0) {
		if ($null -ne $query.OffsetClause) {
			$current = Get-IaCoreIntegerValue -Expression $query.OffsetClause.FetchExpression
			if ($null -ne $current -and $current -gt $limit) {
				$query.OffsetClause.FetchExpression = New-IaCoreIntegerLiteral -Value $limit
			}
			return $null
		}
		if ($isSpecification) {
			if ($null -eq $query.TopRowFilter) {
				$expression = New-IaCoreDomObject -TypeName 'ParenthesisExpression' -Property @{ Expression = (New-IaCoreIntegerLiteral -Value $limit) }
				$query.TopRowFilter = New-IaCoreDomObject -TypeName 'TopRowFilter' -Property @{ Expression = $expression }
			}
			elseif (-not $query.TopRowFilter.Percent) {
				# Наявний TOP зменшується до ліміту; TOP зі змінною чи PERCENT лишається — кількість рядків обмежує драйвер.
				$current = Get-IaCoreIntegerValue -Expression $query.TopRowFilter.Expression
				if ($null -ne $current -and $current -gt $limit) {
					$query.TopRowFilter.Expression = New-IaCoreDomObject -TypeName 'ParenthesisExpression' -Property @{ Expression = (New-IaCoreIntegerLiteral -Value $limit) }
				}
			}
			return $null
		}
		if ($null -ne $query.OrderByClause) {
			$query.OffsetClause = New-IaCoreDomObject -TypeName 'OffsetClause' -Property @{
				OffsetExpression = (New-IaCoreIntegerLiteral -Value 0)
				FetchExpression = (New-IaCoreIntegerLiteral -Value $limit)
			}
		}
		# UNION/EXCEPT/INTERSECT без ORDER BY: кількість рядків обмежує драйвер.
		return $null
	}
	if ($null -ne $query.OffsetClause) {
		return 'Запит уже містить OFFSET … FETCH: Skip не підтримується.'
	}
	if ($isSpecification -and $null -ne $query.TopRowFilter) {
		return 'Запит містить TOP: Skip несумісний із TOP.'
	}
	if ($null -eq $query.OrderByClause) {
		if (-not $isSpecification) {
			return 'Skip для запиту з UNION, EXCEPT чи INTERSECT потребує ORDER BY.'
		}
		$nullSelect = New-IaCoreDomObject -TypeName 'SelectScalarExpression' -Property @{ Expression = (New-IaCoreDomObject -TypeName 'NullLiteral') }
		$subquery = New-IaCoreDomObject -TypeName 'QuerySpecification'
		$subquery.SelectElements.Add($nullSelect)
		$orderElement = New-IaCoreDomObject -TypeName 'ExpressionWithSortOrder' -Property @{
			Expression = (New-IaCoreDomObject -TypeName 'ScalarSubquery' -Property @{ QueryExpression = $subquery })
		}
		$orderBy = New-IaCoreDomObject -TypeName 'OrderByClause'
		$orderBy.OrderByElements.Add($orderElement)
		$query.OrderByClause = $orderBy
	}
	$query.OffsetClause = New-IaCoreDomObject -TypeName 'OffsetClause' -Property @{
		OffsetExpression = (New-IaCoreIntegerLiteral -Value $Skip)
		FetchExpression = (New-IaCoreIntegerLiteral -Value $limit)
	}
	return $null
}

function Add-IaCoreMaxdopHint {
	<# OPTION (MAXDOP 1) для SelectStatement (крок 6): наявний MAXDOP замінюється на 1, інші підказки OPTION зберігаються. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$Statement)
	$found = $false
	foreach ($hint in @($Statement.OptimizerHints)) {
		if ($hint.HintKind.ToString() -eq 'MaxDop') {
			$hint.Value = New-IaCoreIntegerLiteral -Value 1
			$found = $true
		}
	}
	if (-not $found) {
		$hint = New-IaCoreDomObject -TypeName 'LiteralOptimizerHint' -Property @{ Value = (New-IaCoreIntegerLiteral -Value 1) }
		$hint.HintKind = [System.Enum]::Parse($hint.HintKind.GetType(), 'MaxDop')
		$Statement.OptimizerHints.Add($hint)
	}
}

function ConvertTo-IaCoreResultRows {
	<# Нормалізація результату драйвера (крок 9): унікальні імена колонок (дублікати -> _2, _3), рядки -> [ordered]. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Result,
		[Parameter(Mandatory)][int]$Fetch
	)
	$sourceColumns = @($Result['columns'])
	$names = [System.Collections.Generic.List[string]]::new()
	$used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$columns = [System.Collections.Generic.List[object]]::new()
	for ($i = 0; $i -lt $sourceColumns.Count; $i++) {
		$baseName = [string]$sourceColumns[$i].name
		if ([string]::IsNullOrEmpty($baseName)) {
			$baseName = 'column' + ($i + 1)
		}
		$name = $baseName
		$suffix = 2
		while (-not $used.Add($name)) {
			$name = '{0}_{1}' -f $baseName, $suffix
			$suffix++
		}
		$names.Add($name)
		$columns.Add([ordered]@{ name = $name; type = [string]$sourceColumns[$i].type })
	}
	$sourceRows = @($Result['rows'])
	$rows = [System.Collections.Generic.List[object]]::new()
	$take = [Math]::Min($sourceRows.Count, $Fetch)
	for ($r = 0; $r -lt $take; $r++) {
		$values = @($sourceRows[$r])
		$row = [ordered]@{}
		for ($i = 0; $i -lt $names.Count; $i++) {
			# Без $(...): підвираз розгорнув би byte[] у масив чисел.
			$cell = $null
			if ($i -lt $values.Count) {
				$cell = $values[$i]
			}
			$row[$names[$i]] = ConvertTo-IaJsonValue -Value $cell
		}
		$rows.Add($row)
	}
	return [ordered]@{
		columns = $columns.ToArray()
		rows = $rows.ToArray()
		truncated = ($sourceRows.Count -gt $Fetch) -or [bool]$Result['hasMoreRows']
	}
}

function Invoke-IaCoreQueryPipeline {
	<# Кроки 1–9 конвеєра. Заповнює $Context і повертає помилку конверта або $null. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Context)
	$config = $Context.config
	$messages = $Context.messages
	$unsafe = $config['unsafe']

	# 1. Перевірка аргументів до підключення.
	if ([string]::IsNullOrWhiteSpace($Context.server)) {
		return New-IaError -Code 'ArgumentInvalid' -Message 'Не задано сервер (Server).'
	}
	if ([string]::IsNullOrWhiteSpace($Context.database)) {
		return New-IaError -Code 'ArgumentInvalid' -Message 'Не задано базу (Database).'
	}
	if ([string]::IsNullOrWhiteSpace($Context.query)) {
		return New-IaError -Code 'ArgumentInvalid' -Message 'Не задано текст запиту (Query).'
	}
	$maxLength = [int]$config['limits']['maxCommandLength']
	if ($Context.query.Length -gt $maxLength) {
		return New-IaError -Code 'CommandTooLong' -Message ("Довжина тексту команди {0} перевищує ліміт limits.maxCommandLength = {1} символів." -f $Context.query.Length, $maxLength)
	}
	if ($null -ne $Context.fetch -and $Context.fetch -lt 0) {
		return New-IaError -Code 'ArgumentInvalid' -Message 'Fetch не може бути від''ємним.'
	}
	if ($Context.skip -lt 0) {
		return New-IaError -Code 'ArgumentInvalid' -Message 'Skip не може бути від''ємним.'
	}
	if ($Context.purpose -eq 'FreeQuery' -and -not [bool]$unsafe['allowFreeQuery']) {
		return New-IaError -Code 'ArgumentInvalid' -Message 'Вільний запит вимкнено: модель може просити дані лише з декларативних інструментів (увімкнення — unsafe.allowFreeQuery).'
	}

	# 2. Fetch: значення за замовчуванням, жорстка межа, попередження про обсяг.
	$fetch = if ($null -eq $Context.fetch) { [int]$config['limits']['defaultFetch'] } else { [int]$Context.fetch }
	$maxRows = [int]$config['limits']['maxRows']
	if ($fetch -gt $maxRows) {
		$messages.Add(("Запитано {0} рядків; обрізано до жорсткої межі limits.maxRows = {1}." -f $fetch, $maxRows))
		$fetch = $maxRows
	}
	$warnRows = [int]$config['limits']['largeResultWarningRows']
	# Попередження стосується даних, що йдуть у контекст моделі напряму (дозапити); колектор читає сторінками по maxRows.
	if ($fetch -gt $warnRows -and $Context.purpose -in @('Tool', 'FreeQuery')) {
		$warning = "Запитано {0} рядків (більше за limits.largeResultWarningRows = {1}): великий обсяг контексту моделі й вартість токенів." -f $fetch, $warnRows
		$messages.Add($warning)
		Write-Warning $warning
	}
	$Context.fetch = $fetch

	# 3. Перевірки: одна інструкція SELECT (якщо не вимкнено) і лише системні джерела (завжди).
	$parsed = ConvertTo-IaSqlFragment -Sql $Context.query
	if ([bool]$unsafe['disableSelectCheck']) {
		$messages.Add('Перевірку «рівно одна інструкція SELECT» вимкнено (unsafe.disableSelectCheck): дозволено лише інструкції читання.')
		$readOnlyErrors = @(Test-IaCoreReadOnlyParsed -Parsed $parsed)
		if ($readOnlyErrors.Count -gt 0) {
			return Join-IaCoreErrors -Errors $readOnlyErrors
		}
	}
	else {
		$selectCheck = Test-IaCoreSelectOnlyParsed -Parsed $parsed
		if (-not $selectCheck.isValid) {
			return Join-IaCoreErrors -Errors @($selectCheck.errors)
		}
	}
	$sourceCheck = Test-IaCoreSourcesParsed -Parsed $parsed
	if (-not $sourceCheck.isValid) {
		return Join-IaCoreErrors -Errors @($sourceCheck.errors)
	}

	# 4. Параметри: лише іменовані @Name, значення — як SqlParameter.
	$variables = Get-IaCoreQueryVariables -Fragment $parsed.fragment
	$bound = [System.Collections.Generic.List[object]]::new()
	$passed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($key in @($Context.parameters.Keys)) {
		$name = [string]$key
		if (-not $name.StartsWith('@')) {
			$name = '@' + $name
		}
		if ($name -notmatch '^@[\p{L}_#][\p{L}\p{Nd}_#$@]*$') {
			return New-IaError -Code 'ArgumentInvalid' -Message ("Неприпустиме ім'я параметра '{0}'." -f $key)
		}
		if (-not $passed.Add($name)) {
			return New-IaError -Code 'ArgumentInvalid' -Message ("Параметр '{0}' передано двічі." -f $name)
		}
		if (-not $variables.referenced.ContainsKey($name) -or $variables.declared.Contains($name)) {
			return New-IaError -Code 'UnknownParameter' -Message ("Параметр '{0}' відсутній у тексті запиту." -f $name)
		}
		$value = $Context.parameters[$key]
		$sqlType = Get-IaCoreSqlDbType -Value $value
		if ($null -eq $sqlType) {
			return New-IaError -Code 'ArgumentInvalid' -Message ("Тип значення параметра '{0}' ({1}) не підтримується: дозволено лише скалярні значення." -f $name, $value.GetType().Name)
		}
		if ($value -is [System.DBNull]) {
			$value = $null
		}
		$bound.Add([ordered]@{ name = $variables.referenced[$name]; value = $value; sqlType = $sqlType })
	}
	foreach ($variable in $variables.referenced.Keys) {
		if (-not $variables.declared.Contains($variable) -and -not $passed.Contains($variable)) {
			return New-IaError -Code 'MissingParameter' -Message ("Змінна '{0}' використовується в запиті, але її значення не передано в Parameters." -f $variables.referenced[$variable])
		}
	}
	$Context.boundParameters = $bound.ToArray()

	# 5–6. Ліміт рядків і OPTION (MAXDOP 1) через AST ScriptDom.
	$disableMaxdop = [bool]$unsafe['disableMaxdop']
	foreach ($statement in (Get-IaCoreStatements -Fragment $parsed.fragment)) {
		if ($statement.GetType().Name -ne 'SelectStatement') {
			continue
		}
		$limitError = Set-IaCoreRowLimit -Statement $statement -Fetch $fetch -Skip $Context.skip
		if ($limitError) {
			return New-IaError -Code 'ArgumentInvalid' -Message $limitError
		}
		if (-not $disableMaxdop) {
			Add-IaCoreMaxdopHint -Statement $statement
		}
	}
	if ($disableMaxdop) {
		$messages.Add('OPTION (MAXDOP 1) не додано (unsafe.disableMaxdop).')
	}
	$queryText = ConvertTo-IaCoreSqlText -Fragment $parsed.fragment
	$Context.commandText = $queryText

	# Повторна перевірка зміненого тексту (захист від помилок перетворення AST).
	$reparsed = ConvertTo-IaSqlFragment -Sql $queryText
	if (-not [bool]$unsafe['disableSelectCheck']) {
		$recheck = Test-IaCoreSelectOnlyParsed -Parsed $reparsed
		if (-not $recheck.isValid) {
			return Join-IaCoreErrors -Errors @($recheck.errors)
		}
	}
	else {
		$readOnlyErrors = @(Test-IaCoreReadOnlyParsed -Parsed $reparsed)
		if ($readOnlyErrors.Count -gt 0) {
			return Join-IaCoreErrors -Errors $readOnlyErrors
		}
	}
	$resourceCheck = Test-IaCoreSourcesParsed -Parsed $reparsed
	if (-not $resourceCheck.isValid) {
		return Join-IaCoreErrors -Errors @($resourceCheck.errors)
	}

	# 7. Префікс сесії в тому самому батчі.
	$lockTimeout = [int]$config['connection']['lockTimeoutMs']
	$commandText = ($script:IaCoreSessionPrefix -f $lockTimeout.ToString([cultureinfo]::InvariantCulture)) + $queryText
	$Context.commandText = $commandText

	# 8. Політика штатного логіна, рядок підключення і таймаути.
	$loginCheck = Test-IaCoreStandardLogin -Config $config
	if (-not $loginCheck.allowed) {
		return New-IaError -Code 'LoginRefused' -Message ($loginCheck.message + ' Увімкнення іншого логіна — unsafe.allowNonStandardLogin.')
	}
	try {
		$connectionArguments = @{ Server = $Context.server; Database = $Context.database; Config = $config }
		if ($Context.applicationIntent) {
			$connectionArguments.ApplicationIntent = $Context.applicationIntent
		}
		$connectionString = New-IaConnectionString @connectionArguments
	}
	catch {
		return New-IaError -Code 'ConnectionFailed' -Message ("Не вдалося підготувати підключення: {0}" -f $_.Exception.Message)
	}
	$commandTimeout = [int]$config['connection']['commandTimeoutSeconds']
	if ([bool]$unsafe['disableTimeouts']) {
		$commandTimeout = 0
		$messages.Add('Таймаут виконання команди вимкнено (unsafe.disableTimeouts); LOCK_TIMEOUT і таймаут підключення діють.')
	}

	# 9. Виконання і нормалізація.
	try {
		$result = Invoke-IaDbCommand -ConnectionString $connectionString -CommandText $commandText -Parameters $Context.boundParameters `
			-CommandTimeoutSeconds $commandTimeout -MaxRows ($fetch + 1)
	}
	catch {
		$target = $_.TargetObject
		if ($target -is [System.Collections.IDictionary] -and $null -ne $target['messages']) {
			foreach ($message in @($target['messages'])) {
				$messages.Add([string]$message)
			}
		}
		return New-IaError -Code (Get-IaCoreErrorCode -ErrorRecord $_) -Message $_.Exception.Message
	}
	foreach ($message in @($result['messages'])) {
		if ($null -ne $message) {
			$messages.Add([string]$message)
		}
	}
	$Context.result = ConvertTo-IaCoreResultRows -Result $result -Fetch $fetch
	return $null
}

function Invoke-IaSqlQuery {
	<# Єдиний конвеєр виконання read-only запитів. Ніколи не кидає винятків на помилках SQL чи валідації:
	   повертає конверт New-IaResponse із success = $false і error. #>
	[CmdletBinding()]
	param(
		[AllowEmptyString()][AllowNull()][string]$Server,
		[AllowEmptyString()][AllowNull()][string]$Database,
		[AllowEmptyString()][AllowNull()][string]$Query,
		[System.Collections.IDictionary]$Parameters = @{},
		[Nullable[int]]$Fetch,
		[int]$Skip = 0,
		[ValidateSet('Collector', 'Tool', 'FreeQuery', 'Topology', 'PermissionCheck')][string]$Purpose = 'Collector',
		[ValidateSet('ReadOnly')][string]$ApplicationIntent,
		[System.Collections.IDictionary]$Config
	)
	$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	$startedAtUtc = [datetime]::UtcNow
	$response = New-IaResponse -Server $Server -Database $Database
	$context = [ordered]@{
		server = $Server
		database = $Database
		query = $Query
		parameters = $(if ($null -eq $Parameters) { @{} } else { $Parameters })
		fetch = $Fetch
		skip = $Skip
		purpose = $Purpose
		applicationIntent = $ApplicationIntent
		config = $null
		unsafeFlags = @()
		messages = [System.Collections.Generic.List[string]]::new()
		boundParameters = $null
		commandText = $Query
		result = $null
	}
	$pipelineError = $null
	try {
		$context.config = Resolve-IaCoreConfig -Config $Config
		$context.unsafeFlags = @(Get-IaUnsafeFlags -Config $context.config)
		$pipelineError = Invoke-IaCoreQueryPipeline -Context $context
	}
	catch {
		$pipelineError = New-IaError -Code (Get-IaCoreErrorCode -ErrorRecord $_) -Message ("Внутрішня помилка конвеєра: {0}" -f $_.Exception.Message)
	}
	$response.success = $null -eq $pipelineError
	$response.error = $pipelineError
	if ($response.success -and $null -ne $context.result) {
		$response.columns = $context.result.columns
		$response.rows = $context.result.rows
		$response.rowCount = @($context.result.rows).Count
		$response.truncated = [bool]$context.result.truncated
	}
	$response.messages = $context.messages.ToArray()
	$stopwatch.Stop()
	$response.durationMs = [int]$stopwatch.ElapsedMilliseconds
	try {
		Write-IaCoreQueryLog -Context $context -Response $response -StartedAtUtc $startedAtUtc -FinishedAtUtc ([datetime]::UtcNow)
	}
	catch {
		Write-Warning ("Не вдалося записати виклик SQL у журнал: {0}" -f $_.Exception.Message)
	}
	return $response
}
