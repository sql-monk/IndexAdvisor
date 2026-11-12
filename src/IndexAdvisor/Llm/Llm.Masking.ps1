# Маскування перед відправкою в LLM (ТЗ розділ 6, 4.3.1; CONTRACTS.md 5.13).
# Літерали в текстах запитів очищуються завжди; імена об'єктів маскуються при llm.maskNames
# послідовними псевдонімами srv1, db1, sch1, tbl1, col1, ix1, fk1, mod1. У T-SQL заміна — за токенами ScriptDom.

$script:IaLlmAliasPrefixes = @('srv', 'db', 'sch', 'tbl', 'col', 'ix', 'fk', 'mod')
$script:IaLlmLiteralTokenTypes = @{
	AsciiStringLiteral = 'str'
	UnicodeStringLiteral = 'str'
	HexLiteral = 'bin'
	Integer = 'num'
	Numeric = 'num'
	Real = 'num'
	Money = 'num'
}
$script:IaLlmStringTokenTypes = @('AsciiStringLiteral', 'UnicodeStringLiteral')
$script:IaLlmCommentTokenTypes = @('SingleLineComment', 'MultilineComment')
$script:IaLlmPlaceholderNames = @('str', 'num', 'bin', 'date')
$script:IaLlmDateLiteralRegex = [regex]::new(
	'^\s*(?:\d{4}-?\d{2}-?\d{2}(?:[ T]\d{1,2}:\d{2}(?::\d{2}(?:\.\d{1,7})?)?)?\s*(?:Z|[+-]\d{2}:?\d{2})?|\d{1,2}:\d{2}(?::\d{2}(?:\.\d{1,7})?)?|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}(?:[ T]\d{1,2}:\d{2}(?::\d{2})?)?)\s*$',
	[System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
# Резервне очищення без ScriptDom (або якщо лексер не зміг розібрати текст): рядки (зокрема незакриті), коментарі,
# ідентифікатори в дужках і лапках (залишаються), двійкові та числові літерали.
$script:IaLlmLiteralFallbackRegex = [regex]::new(
	'(?<str>N?''(?:[^'']|'''')*(?:''|$))|(?<cmt>--[^\r\n]*|/\*[\s\S]*?(?:\*/|$))|(?<qid>\[(?:[^\]]|\]\])*\]|"(?:[^"]|"")*")|(?<bin>(?<![\w@#$])0x[0-9A-Fa-f]*)|(?<num>(?<![\w@#$.])\$?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)',
	[System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
$script:IaLlmAliasRegex = [regex]::new(
	'(?<![\p{L}\p{N}@#$])(?:srv|db|sch|tbl|col|ix|fk|mod)\d+(?![\p{L}\p{N}@#$])',
	[System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

# Ключі, значення яких — імена (нормалізовані: без '_' і в нижньому регістрі) -> префікс псевдоніма.
$script:IaLlmNameKeyCategories = @{
	server = 'srv'; servername = 'srv'; connectedto = 'srv'; requestedserver = 'srv'; replicaservername = 'srv'; listenername = 'srv'
	availabilitygroup = 'srv'; availabilitygroupname = 'srv'; agname = 'srv'; instancename = 'srv'
	database = 'db'; databasename = 'db'; dbname = 'db'
	schema = 'sch'; schemaname = 'sch'; referencedschema = 'sch'; referencedschemaname = 'sch'
	table = 'tbl'; tablename = 'tbl'; referencedtable = 'tbl'; referencedtablename = 'tbl'
	column = 'col'; columnname = 'col'; partitioncolumn = 'col'; columns = 'col'; includedcolumns = 'col'; equalitycolumns = 'col'
	inequalitycolumns = 'col'; referencedcolumns = 'col'; keycolumns = 'col'
	index = 'ix'; indexname = 'ix'; referencedindexname = 'ix'; relatedindexes = 'ix'; replacesindexes = 'ix'; nonalignedindexes = 'ix'
	foreignkeyname = 'fk'; fkname = 'fk'; referencedbyforeignkeys = 'fk'; coversforeignkeys = 'fk'; foreignkeys = 'fk'
	modulename = 'mod'; objectname = 'mod'
}
# Інші ключі зі списками колонок (результати інструментів: seekColumns, scanColumns, predicateColumns, columnList тощо).
$script:IaLlmColumnKeyRegex = [regex]::new('(column|columns|columnlist|columnnames)$')
# Категорії, значення яких можуть бути багатокомпонентними (schema.table, schema.module).
$script:IaLlmMultipartCategories = @('tbl', 'mod')
# Тексти запитів із сервера: очищення літералів завжди.
$script:IaLlmLiteralSqlKeys = @('querytext', 'querysqltext', 'sqltext', 'statementtext', 'statement', 'hinttext', 'filterdefinition',
	'definition', 'moduledefinition', 'batchtext', 'sql', 'query', 'querytextsample')
# Скрипти, згенеровані програмою чи моделлю: імена маскуються за токенами, літерали не змінюються.
$script:IaLlmScriptKeys = @('executescript', 'rollbackscript', 'functionscript', 'schemescript')
$script:IaLlmObjectKeyKeys = @('objectkey', 'objectkeys', 'includedobjectkeys')
# Ключі з переліченими значеннями й кодами: збіг з іменем об'єкта тут випадковий, не маскується.
$script:IaLlmNoMaskKeys = @('typedesc', 'type', 'typename', 'operation', 'executionmode', 'workloadcategory', 'topby', 'compression',
	'dataspacetype', 'role', 'agrole', 'replicarole', 'availabilitymode', 'secondaryallowconnections', 'actualstate', 'desiredstate',
	'querycapturemode', 'recoverymodel', 'statedesc', 'edition', 'productversion', 'mode', 'partitionelimination',
	'columnstoresegmentelimination', 'operator', 'source', 'severity', 'ruleid', 'action', 'level', 'confidence', 'code', 'dataset',
	'suggestedaction', 'findingid', 'snapshotid', 'queryhash', 'queryhashes', 'schemaversion', 'toolversion', 'collecteddatasets',
	'enabled', 'disabled', 'module', 'verdict', 'decision', 'llmcallid', 'recommendationid', 'runid', 'requestid', 'status',
	'stoppedreason', 'purpose', 'provider', 'model', 'collectedatutc', 'createdatutc')
# Вбудовані типи й частини дат (не маскуються як ідентифікатори без лапок).
$script:IaLlmSqlBuiltinNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
	'bigint', 'int', 'smallint', 'tinyint', 'bit', 'decimal', 'numeric', 'money', 'smallmoney', 'float', 'real', 'date', 'time', 'datetime',
	'datetime2', 'datetimeoffset', 'smalldatetime', 'char', 'varchar', 'nchar', 'nvarchar', 'text', 'ntext', 'binary', 'varbinary', 'image',
	'uniqueidentifier', 'xml', 'sql_variant', 'geography', 'geometry', 'hierarchyid', 'rowversion', 'timestamp', 'sysname', 'json', 'max',
	'year', 'yy', 'yyyy', 'quarter', 'qq', 'month', 'mm', 'dayofyear', 'dy', 'day', 'dd', 'week', 'wk', 'ww', 'weekday', 'dw', 'hour', 'hh',
	'minute', 'mi', 'second', 'ss', 'millisecond', 'ms', 'microsecond', 'mcs', 'nanosecond', 'ns', 'tzoffset', 'tz', 'iso_week', 'isowk', 'isoww'
), [System.StringComparer]::OrdinalIgnoreCase)
# Вбудовані функції (не маскуються, якщо за ними йде '(').
$script:IaLlmSqlBuiltinFunctions = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
	'count', 'count_big', 'sum', 'avg', 'min', 'max', 'cast', 'convert', 'try_cast', 'try_convert', 'isnull', 'coalesce', 'nullif', 'iif',
	'choose', 'dateadd', 'datediff', 'datediff_big', 'datepart', 'datename', 'datefromparts', 'datetrunc', 'eomonth', 'getdate', 'getutcdate',
	'sysdatetime', 'sysutcdatetime', 'sysdatetimeoffset', 'switchoffset', 'todatetimeoffset', 'year', 'month', 'day', 'len', 'datalength',
	'left', 'right', 'substring', 'charindex', 'patindex', 'replace', 'replicate', 'reverse', 'ltrim', 'rtrim', 'trim', 'upper', 'lower',
	'concat', 'concat_ws', 'string_agg', 'string_split', 'format', 'stuff', 'isnumeric', 'isdate', 'abs', 'ceiling', 'floor', 'round',
	'power', 'sqrt', 'row_number', 'rank', 'dense_rank', 'ntile', 'lag', 'lead', 'first_value', 'last_value', 'newid', 'newsequentialid',
	'object_id', 'object_name', 'object_schema_name', 'schema_name', 'db_id', 'db_name', 'serverproperty', 'databasepropertyex', 'checksum',
	'binary_checksum', 'hashbytes', 'json_value', 'json_query', 'openjson', 'isjson', 'quotename', 'stdev', 'var', 'scope_identity',
	'error_message', 'error_number', 'parse', 'try_parse', 'translate', 'greatest', 'least', 'approx_count_distinct', 'grouping'
), [System.StringComparer]::OrdinalIgnoreCase)

function New-IaMaskingMap {
	<# Порожня мапа маскування: @{ names = [ordered]@{ real -> alias }; reverse = [ordered]@{ alias -> real }; counters = @{} }. #>
	[CmdletBinding()]
	param()
	return [ordered]@{
		names = [ordered]@{}
		reverse = [ordered]@{}
		counters = [ordered]@{}
	}
}

function New-IaLlmMaskState {
	<# Внутрішня: робочий стан маскування — нечутливі до регістру словники з мапи, парсер ScriptDom, регулярний вираз імен. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Map,
		[bool]$MaskNames
	)
	foreach ($key in @('names', 'reverse', 'counters')) {
		if ($Map[$key] -isnot [System.Collections.IDictionary]) {
			$Map[$key] = [ordered]@{}
		}
	}
	$names = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($real in $Map['names'].Keys) {
		$names[[string]$real] = [string]$Map['names'][$real]
	}
	$reverse = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($alias in $Map['reverse'].Keys) {
		$reverse[[string]$alias] = [string]$Map['reverse'][$alias]
	}
	return @{
		map = $Map
		names = $names
		reverse = $reverse
		maskNames = $MaskNames
		parser = $null
		parserResolved = $false
		nameRegex = $null
		nameRegexCount = -1
	}
}

function Get-IaLlmSqlParser {
	<# Внутрішня: парсер ScriptDom (через контрактну Get-IaScriptDomParser), кешований у стані; $null, якщо недоступний. #>
	param([Parameter(Mandatory)][hashtable]$State)
	if (-not $State.parserResolved) {
		$State.parserResolved = $true
		try {
			$State.parser = Get-IaScriptDomParser -ErrorAction Stop
		}
		catch {
			$State.parser = $null
			Write-Verbose "IndexAdvisor LLM: ScriptDom недоступний, використовується резервне очищення регулярними виразами: $($_.Exception.Message)"
		}
	}
	return $State.parser
}

function Get-IaLlmSqlTokens {
	<# Внутрішня: потік токенів ScriptDom; $null, якщо парсер недоступний або лексер повідомив про помилку. #>
	param(
		[AllowEmptyString()][string]$Sql,
		[Parameter(Mandatory)][hashtable]$State
	)
	$parser = Get-IaLlmSqlParser -State $State
	if ($null -eq $parser) {
		return $null
	}
	$errors = $null
	try {
		$tokens = $parser.GetTokenStream([System.IO.StringReader]::new($Sql), [ref]$errors)
	}
	catch {
		return $null
	}
	if (($null -ne $errors -and $errors.Count -gt 0) -or $null -eq $tokens) {
		return $null
	}
	return , $tokens
}

function Get-IaLlmLiteralPlaceholder {
	<# Внутрішня: плейсхолдер для літерала: {str}, {num}, {bin}, {date}. #>
	param(
		[Parameter(Mandatory)][string]$Kind,
		[AllowEmptyString()][string]$Text
	)
	if ($Kind -eq 'str') {
		$content = $Text
		if ($content.StartsWith('N') -or $content.StartsWith('n')) {
			$content = $content.Substring(1)
		}
		$content = $content.Trim("'")
		if ($script:IaLlmDateLiteralRegex.IsMatch($content)) {
			return '{date}'
		}
	}
	return '{' + $Kind + '}'
}

function Remove-IaLlmLiteralsByRegex {
	<# Внутрішня: резервне очищення літералів без ScriptDom (консервативне: незакриті рядки й коментарі теж прибираються). #>
	param([AllowEmptyString()][string]$Sql)
	if ([string]::IsNullOrEmpty($Sql)) {
		return $Sql
	}
	$builder = [System.Text.StringBuilder]::new()
	$position = 0
	foreach ($match in $script:IaLlmLiteralFallbackRegex.Matches($Sql)) {
		$null = $builder.Append($Sql, $position, $match.Index - $position)
		if ($match.Groups['str'].Success) {
			$null = $builder.Append((Get-IaLlmLiteralPlaceholder -Kind 'str' -Text $match.Value))
		}
		elseif ($match.Groups['cmt'].Success) {
			$null = $builder.Append(' ')
		}
		elseif ($match.Groups['bin'].Success) {
			$null = $builder.Append('{bin}')
		}
		elseif ($match.Groups['num'].Success) {
			$null = $builder.Append('{num}')
		}
		else {
			$null = $builder.Append($match.Value)
		}
		$position = $match.Index + $match.Length
	}
	$null = $builder.Append($Sql, $position, $Sql.Length - $position)
	return $builder.ToString()
}

$script:IaLlmPlanXmlLiteralAttributeRegex = [regex]::new(
	'\b(StatementText|ScalarString|ParameterCompiledValue|ParameterRuntimeValue|ConstValue)="([^"]*)"',
	[System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

function Test-IaLlmPlanXml {
	<# Внутрішня: $true для XML плану виконання (showplan). #>
	param([AllowEmptyString()][string]$Value)
	return $Value.TrimStart().StartsWith('<ShowPlanXML', [System.StringComparison]::OrdinalIgnoreCase) -or
		$Value.Contains('schemas.microsoft.com/sqlserver/2004/07/showplan')
}

function Remove-IaLlmPlanXmlLiterals {
	<# Внутрішня: очищення літералів у XML плану: тексти інструкцій, скалярні вирази, значення параметрів і констант. #>
	param(
		[AllowEmptyString()][string]$Xml,
		[Parameter(Mandatory)][hashtable]$State
	)
	$builder = [System.Text.StringBuilder]::new()
	$position = 0
	foreach ($match in $script:IaLlmPlanXmlLiteralAttributeRegex.Matches($Xml)) {
		$decoded = [System.Net.WebUtility]::HtmlDecode($match.Groups[2].Value)
		$cleaned = Convert-IaLlmSqlForward -Sql $decoded -State $State -RemoveLiterals $true -MaskNames $false
		$encoded = [System.Security.SecurityElement]::Escape($cleaned)
		$null = $builder.Append($Xml, $position, $match.Index - $position).Append($match.Groups[1].Value).Append('="').Append($encoded).Append('"')
		$position = $match.Index + $match.Length
	}
	$null = $builder.Append($Xml, $position, $Xml.Length - $position)
	return $builder.ToString()
}

function Remove-IaSqlLiterals {
	<# Замінює рядкові, числові, двійкові та дата-літерали в T-SQL на плейсхолдери (токени ScriptDom). #>
	[CmdletBinding()]
	param([AllowEmptyString()][AllowNull()][string]$Sql)
	if ([string]::IsNullOrEmpty($Sql)) {
		return $Sql
	}
	$state = New-IaLlmMaskState -Map (New-IaMaskingMap) -MaskNames $false
	return (Convert-IaLlmSqlForward -Sql $Sql -State $state -RemoveLiterals $true -MaskNames $false)
}

function Split-IaLlmIdentifier {
	<# Внутрішня: ідентифікатор у лапках чи дужках -> @{ name; open; close }. #>
	param([Parameter(Mandatory)][string]$Text)
	if ($Text.Length -ge 2 -and $Text.StartsWith('[') -and $Text.EndsWith(']')) {
		return @{ name = $Text.Substring(1, $Text.Length - 2).Replace(']]', ']'); open = '['; close = ']' }
	}
	if ($Text.Length -ge 2 -and $Text.StartsWith('"') -and $Text.EndsWith('"')) {
		return @{ name = $Text.Substring(1, $Text.Length - 2).Replace('""', '"'); open = '"'; close = '"' }
	}
	return @{ name = $Text; open = ''; close = '' }
}

function Join-IaLlmIdentifier {
	<# Внутрішня: ім'я -> ідентифікатор у тих самих лапках з екрануванням. #>
	param(
		[Parameter(Mandatory)][string]$Name,
		[AllowEmptyString()][string]$Open
	)
	switch ($Open) {
		'[' { return '[' + $Name.Replace(']', ']]') + ']' }
		'"' { return '"' + $Name.Replace('"', '""') + '"' }
		default { return $Name }
	}
}

function Test-IaLlmRegularIdentifier {
	<# Внутрішня: $true, якщо ім'я можна писати без дужок. #>
	param([AllowEmptyString()][string]$Name)
	return $Name -match '^[\p{L}_@#][\p{L}\p{N}_@#$]*$'
}

function Get-IaLlmNeighbourToken {
	<# Внутрішня: найближчий значущий (не пробіл і не коментар) токен ліворуч (-1) чи праворуч (+1). #>
	param(
		[Parameter(Mandatory)]$Tokens,
		[Parameter(Mandatory)][int]$Index,
		[Parameter(Mandatory)][int]$Direction
	)
	$i = $Index + $Direction
	while ($i -ge 0 -and $i -lt $Tokens.Count) {
		$type = [string]$Tokens[$i].TokenType
		if ($type -ne 'WhiteSpace' -and $type -notin $script:IaLlmCommentTokenTypes) {
			return $Tokens[$i]
		}
		$i += $Direction
	}
	return $null
}

function Test-IaLlmBareIdentifier {
	<# Внутрішня: $true, якщо ім'я можна писати в T-SQL без дужок (один токен Identifier за ScriptDom, не ключове слово). #>
	param(
		[AllowEmptyString()][string]$Name,
		[Parameter(Mandatory)][hashtable]$State
	)
	if (-not (Test-IaLlmRegularIdentifier -Name $Name)) {
		return $false
	}
	if ($null -eq $State['bareCache']) {
		$State['bareCache'] = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
	}
	$cached = $false
	if ($State['bareCache'].TryGetValue($Name, [ref]$cached)) {
		return $cached
	}
	$tokens = Get-IaLlmSqlTokens -Sql $Name -State $State
	$significant = @($tokens | Where-Object { [string]$_.TokenType -notin @('WhiteSpace', 'EndOfFile') })
	$result = ($null -ne $tokens) -and $significant.Count -eq 1 -and [string]$significant[0].TokenType -eq 'Identifier'
	$State['bareCache'][$Name] = $result
	return $result
}

function Get-IaLlmNameRegex {
	<# Внутрішня: регулярний вираз цілих слів — відомих справжніх імен (перебудовується при поповненні мапи). #>
	param([Parameter(Mandatory)][hashtable]$State)
	if ($State.names.Count -eq 0) {
		return $null
	}
	if ($State.nameRegexCount -ne $State.names.Count) {
		$alternatives = @($State.names.Keys | Where-Object { $_ } | Sort-Object -Property Length -Descending | ForEach-Object { [regex]::Escape($_) })
		$pattern = '(?<![\w@#$])(?:' + ($alternatives -join '|') + ')(?![\w@#$])'
		$State.nameRegex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
		$State.nameRegexCount = $State.names.Count
	}
	return $State.nameRegex
}

function Invoke-IaLlmDictionaryReplace {
	<# Внутрішня: однопрохідна заміна збігів регулярного виразу за словником (незнайдене лишається). #>
	param(
		[AllowEmptyString()][string]$Text,
		[AllowNull()][regex]$Regex,
		[Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Lookup,
		[string]$QuoteToDouble
	)
	if ([string]::IsNullOrEmpty($Text) -or $null -eq $Regex) {
		return $Text
	}
	$builder = $null
	$position = 0
	foreach ($match in $Regex.Matches($Text)) {
		$replacement = $null
		if (-not $Lookup.TryGetValue($match.Value, [ref]$replacement)) {
			continue
		}
		if ($QuoteToDouble) {
			$replacement = $replacement.Replace($QuoteToDouble, $QuoteToDouble + $QuoteToDouble)
		}
		if ($null -eq $builder) {
			$builder = [System.Text.StringBuilder]::new()
		}
		$null = $builder.Append($Text, $position, $match.Index - $position).Append($replacement)
		$position = $match.Index + $match.Length
	}
	if ($null -eq $builder) {
		return $Text
	}
	$null = $builder.Append($Text, $position, $Text.Length - $position)
	return $builder.ToString()
}

function Convert-IaLlmProseForward {
	<# Внутрішня: маскування відомих імен у довільному тексті (цілими словами). #>
	param(
		[AllowEmptyString()][string]$Text,
		[Parameter(Mandatory)][hashtable]$State
	)
	return (Invoke-IaLlmDictionaryReplace -Text $Text -Regex (Get-IaLlmNameRegex -State $State) -Lookup $State.names)
}

function Convert-IaLlmProseReverse {
	<# Внутрішня: заміна псевдонімів (зокрема всередині імен на зразок IX_col1_INC) на справжні імена. #>
	param(
		[AllowEmptyString()][string]$Text,
		[Parameter(Mandatory)][hashtable]$State,
		[string]$QuoteToDouble
	)
	if ($State.reverse.Count -eq 0) {
		return $Text
	}
	return (Invoke-IaLlmDictionaryReplace -Text $Text -Regex $script:IaLlmAliasRegex -Lookup $State.reverse -QuoteToDouble $QuoteToDouble)
}

function Convert-IaLlmSqlForward {
	<# Внутрішня: T-SQL -> очищені літерали (за потреби) і масковані імена (за токенами-ідентифікаторами ScriptDom). #>
	param(
		[AllowEmptyString()][string]$Sql,
		[Parameter(Mandatory)][hashtable]$State,
		[bool]$RemoveLiterals,
		[bool]$MaskNames
	)
	if ([string]::IsNullOrEmpty($Sql) -or (-not $RemoveLiterals -and -not $MaskNames)) {
		return $Sql
	}
	$tokens = Get-IaLlmSqlTokens -Sql $Sql -State $State
	if ($null -eq $tokens) {
		$text = $Sql
		if ($RemoveLiterals) {
			$text = Remove-IaLlmLiteralsByRegex -Sql $text
		}
		if ($MaskNames) {
			$text = Convert-IaLlmProseForward -Text $text -State $State
		}
		return $text
	}
	$builder = [System.Text.StringBuilder]::new()
	for ($i = 0; $i -lt $tokens.Count; $i++) {
		$token = $tokens[$i]
		$type = [string]$token.TokenType
		$text = [string]$token.Text
		if ($RemoveLiterals -and $script:IaLlmLiteralTokenTypes.ContainsKey($type)) {
			$null = $builder.Append((Get-IaLlmLiteralPlaceholder -Kind $script:IaLlmLiteralTokenTypes[$type] -Text $text))
			continue
		}
		if ($RemoveLiterals -and $type -in $script:IaLlmCommentTokenTypes) {
			# Коментарі можуть містити значення даних — прибираються.
			$null = $builder.Append(' ')
			continue
		}
		if ($MaskNames -and $type -eq 'Identifier') {
			$alias = $null
			$skip = $script:IaLlmSqlBuiltinNames.Contains($text)
			if (-not $skip -and $script:IaLlmSqlBuiltinFunctions.Contains($text)) {
				$next = Get-IaLlmNeighbourToken -Tokens $tokens -Index $i -Direction 1
				$skip = $null -ne $next -and [string]$next.TokenType -eq 'LeftParenthesis'
			}
			if (-not $skip -and $text -in $script:IaLlmPlaceholderNames) {
				$previous = Get-IaLlmNeighbourToken -Tokens $tokens -Index $i -Direction -1
				$skip = $null -ne $previous -and [string]$previous.TokenType -eq 'LeftCurly'
			}
			if (-not $skip -and $State.names.TryGetValue($text, [ref]$alias)) {
				$null = $builder.Append($alias)
				continue
			}
			$null = $builder.Append($text)
			continue
		}
		if ($MaskNames -and $type -eq 'QuotedIdentifier') {
			$parts = Split-IaLlmIdentifier -Text $text
			$alias = $null
			if ($State.names.TryGetValue($parts.name, [ref]$alias)) {
				$null = $builder.Append((Join-IaLlmIdentifier -Name $alias -Open $parts.open))
				continue
			}
			$null = $builder.Append($text)
			continue
		}
		if ($MaskNames -and ($type -in $script:IaLlmStringTokenTypes -or $type -in $script:IaLlmCommentTokenTypes)) {
			# Імена в рядках скриптів (OBJECT_ID(N'dbo.Orders')) і в коментарях.
			$null = $builder.Append((Convert-IaLlmProseForward -Text $text -State $State))
			continue
		}
		$null = $builder.Append($text)
	}
	return $builder.ToString()
}

function Convert-IaLlmSqlReverse {
	<# Внутрішня: T-SQL з псевдонімами -> справжні імена (ідентифікатори — у дужках за потреби, рядки — з подвоєнням лапок). #>
	param(
		[AllowEmptyString()][string]$Sql,
		[Parameter(Mandatory)][hashtable]$State
	)
	if ([string]::IsNullOrEmpty($Sql) -or $State.reverse.Count -eq 0) {
		return $Sql
	}
	$tokens = Get-IaLlmSqlTokens -Sql $Sql -State $State
	if ($null -eq $tokens) {
		return (Convert-IaLlmProseReverse -Text $Sql -State $State)
	}
	$builder = [System.Text.StringBuilder]::new()
	foreach ($token in $tokens) {
		$type = [string]$token.TokenType
		$text = [string]$token.Text
		if ($type -eq 'Identifier') {
			$real = $null
			if ($State.reverse.TryGetValue($text, [ref]$real)) {
				if (Test-IaLlmBareIdentifier -Name $real -State $State) {
					$null = $builder.Append($real)
				}
				else {
					$null = $builder.Append((Join-IaLlmIdentifier -Name $real -Open '['))
				}
				continue
			}
			$replaced = Convert-IaLlmProseReverse -Text $text -State $State
			if ($replaced -ne $text -and -not (Test-IaLlmBareIdentifier -Name $replaced -State $State)) {
				$replaced = Join-IaLlmIdentifier -Name $replaced -Open '['
			}
			$null = $builder.Append($replaced)
			continue
		}
		if ($type -eq 'QuotedIdentifier') {
			$parts = Split-IaLlmIdentifier -Text $text
			$replaced = Convert-IaLlmProseReverse -Text $parts.name -State $State
			if ($replaced -ne $parts.name) {
				$null = $builder.Append((Join-IaLlmIdentifier -Name $replaced -Open $parts.open))
				continue
			}
			$null = $builder.Append($text)
			continue
		}
		if ($type -in $script:IaLlmStringTokenTypes) {
			$null = $builder.Append((Convert-IaLlmProseReverse -Text $text -State $State -QuoteToDouble "'"))
			continue
		}
		if ($type -in $script:IaLlmCommentTokenTypes) {
			$null = $builder.Append((Convert-IaLlmProseReverse -Text $text -State $State))
			continue
		}
		$null = $builder.Append($text)
	}
	return $builder.ToString()
}

function Add-IaLlmMaskName {
	<# Внутрішня: реєструє справжнє ім'я в мапі (якщо ще немає) і повертає псевдонім. #>
	param(
		[Parameter(Mandatory)][hashtable]$State,
		[AllowNull()][AllowEmptyString()][string]$Name,
		[Parameter(Mandatory)][string]$Category
	)
	if ([string]::IsNullOrWhiteSpace($Name)) {
		return $null
	}
	$alias = $null
	if ($State.names.TryGetValue($Name, [ref]$alias)) {
		return $alias
	}
	$counters = $State.map['counters']
	$number = 0
	if ($counters.Contains($Category)) {
		$number = [int]$counters[$Category]
	}
	do {
		$number++
		$alias = $Category + $number
	} while ($State.reverse.ContainsKey($alias))
	$counters[$Category] = $number
	$State.map['names'][$Name] = $alias
	$State.map['reverse'][$alias] = $Name
	$State.names[$Name] = $alias
	$State.reverse[$alias] = $Name
	return $alias
}

function Split-IaLlmMultipartName {
	<# Внутрішня: 'a.b', '[a].[b]' -> масив частин без дужок. #>
	param([Parameter(Mandatory)][string]$Value)
	$parts = [System.Collections.Generic.List[string]]::new()
	foreach ($match in [regex]::Matches($Value, '\[(?:[^\]]|\]\])*\]|"(?:[^"]|"")*"|[^.]+')) {
		$parts.Add((Split-IaLlmIdentifier -Text $match.Value.Trim()).name)
	}
	return , $parts.ToArray()
}

function Get-IaLlmKeyCategory {
	<# Внутрішня: категорія імені за нормалізованим ключем ($null — ключ не містить імен). #>
	param([AllowEmptyString()][string]$NormalizedKey)
	if ($script:IaLlmNameKeyCategories.ContainsKey($NormalizedKey)) {
		return $script:IaLlmNameKeyCategories[$NormalizedKey]
	}
	if ($NormalizedKey -and $script:IaLlmColumnKeyRegex.IsMatch($NormalizedKey)) {
		return 'col'
	}
	return $null
}

function Add-IaLlmMaskNameValue {
	<# Внутрішня: реєструє значення ключа-імені з урахуванням багатокомпонентних імен (schema.table)
	   і списків колонок через кому ('[OrderDate] DESC, Amount'). #>
	param(
		[Parameter(Mandatory)][hashtable]$State,
		[AllowNull()][AllowEmptyString()][string]$Value,
		[Parameter(Mandatory)][string]$Category
	)
	if ([string]::IsNullOrWhiteSpace($Value)) {
		return
	}
	if ($Category -eq 'col') {
		$parts = $Value.Split(',')
		foreach ($part in $parts) {
			$name = ($part.Trim() -replace '(?i)\s+(ASC|DESC)$', '').Trim()
			if ($name) {
				$null = Add-IaLlmMaskName -State $State -Name (Split-IaLlmIdentifier -Text $name).name -Category 'col'
			}
		}
		return
	}
	if ($Category -in $script:IaLlmMultipartCategories -and $Value.Contains('.')) {
		$parts = Split-IaLlmMultipartName -Value $Value
		if ($parts.Count -ge 2 -and $parts.Count -le 4) {
			$prefixes = @('srv', 'db', 'sch')
			$offset = 3 - ($parts.Count - 1)
			for ($i = 0; $i -lt $parts.Count - 1; $i++) {
				$null = Add-IaLlmMaskName -State $State -Name $parts[$i] -Category $prefixes[$offset + $i]
			}
			$null = Add-IaLlmMaskName -State $State -Name $parts[$parts.Count - 1] -Category $Category
			return
		}
	}
	$null = Add-IaLlmMaskName -State $State -Name $Value -Category $Category
}

function Add-IaLlmObjectKeyNames {
	<# Внутрішня: реєструє частини ключа об'єкта 'server|database|schema.table|index'. #>
	param(
		[Parameter(Mandatory)][hashtable]$State,
		[AllowNull()][AllowEmptyString()][string]$Value
	)
	if ([string]::IsNullOrWhiteSpace($Value)) {
		return
	}
	$parts = $Value.Split('|')
	if ($parts.Count -ne 4) {
		return
	}
	$null = Add-IaLlmMaskName -State $State -Name $parts[0] -Category 'srv'
	$null = Add-IaLlmMaskName -State $State -Name $parts[1] -Category 'db'
	Add-IaLlmMaskNameValue -State $State -Value $parts[2] -Category 'tbl'
	$null = Add-IaLlmMaskName -State $State -Name $parts[3] -Category 'ix'
}

function Get-IaLlmNameCategory {
	<# Внутрішня: категорія ключа 'name' в об'єкті за ключем масиву-батька і формою об'єкта. #>
	param(
		[AllowEmptyString()][string]$ParentKey,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Object
	)
	$has = { param($Key) $null -ne (Get-IaLlmValue -InputObject $Object -Name $Key) }
	switch (Get-IaLlmNormalizedKey -Key $ParentKey) {
		'availabilitygroups' { return 'srv' }
		'databases' { if ((& $has 'databaseId') -or (& $has 'tables') -or (& $has 'compatibilityLevel')) { return 'db' } }
		'tables' { if (& $has 'schema') { return 'tbl' } }
		'columns' { if ((& $has 'typeName') -or (& $has 'columnId')) { return 'col' } }
		'keycolumns' { return 'col' }
		'indexes' { if ((& $has 'typeDesc') -or (& $has 'indexId') -or (& $has 'keyColumns')) { return 'ix' } }
		'foreignkeys' { if ((& $has 'referencedTable') -or (& $has 'referencedColumns')) { return 'fk' } }
	}
	return $null
}

function Register-IaLlmMaskNames {
	<# Внутрішня: обхід об'єкта і реєстрація імен у мапі за ключами (перед заміною, щоб псевдоніми мали правильні префікси). #>
	param(
		[AllowNull()]$Node,
		[AllowEmptyString()][string]$Key,
		[Parameter(Mandatory)][hashtable]$State
	)
	if ($null -eq $Node -or $Node -is [string]) {
		return
	}
	if ($Node -is [System.Management.Automation.PSCustomObject]) {
		$Node = ConvertTo-IaLlmPlainValue -Value $Node
	}
	if ($Node -is [System.Collections.IDictionary]) {
		$nameCategory = Get-IaLlmNameCategory -ParentKey $Key -Object $Node
		foreach ($childKey in @($Node.Keys)) {
			$value = $Node[$childKey]
			$normalized = Get-IaLlmNormalizedKey -Key ([string]$childKey)
			if ($normalized -eq 'name' -and $nameCategory -and $value -is [string]) {
				$null = Add-IaLlmMaskName -State $State -Name $value -Category $nameCategory
			}
			elseif ($normalized -in $script:IaLlmObjectKeyKeys) {
				foreach ($item in @($value)) {
					if ($item -is [string]) {
						Add-IaLlmObjectKeyNames -State $State -Value $item
					}
				}
			}
			elseif ($keyCategory = Get-IaLlmKeyCategory -NormalizedKey $normalized) {
				foreach ($item in @($value)) {
					if ($item -is [string]) {
						Add-IaLlmMaskNameValue -State $State -Value $item -Category $keyCategory
					}
				}
			}
			if ($value -is [System.Collections.IDictionary] -or $value -is [System.Management.Automation.PSCustomObject] -or (Test-IaLlmList -Value $value)) {
				Register-IaLlmMaskNames -Node $value -Key ([string]$childKey) -State $State
			}
		}
		return
	}
	if (Test-IaLlmList -Value $Node) {
		foreach ($item in $Node) {
			Register-IaLlmMaskNames -Node $item -Key $Key -State $State
		}
	}
}

function ConvertTo-IaLlmMaskedString {
	<# Внутрішня: маскування одного рядкового значення з урахуванням ключа. #>
	param(
		[AllowEmptyString()][string]$Value,
		[AllowEmptyString()][string]$Key,
		[Parameter(Mandatory)][hashtable]$State
	)
	if ([string]::IsNullOrEmpty($Value)) {
		return $Value
	}
	$normalized = Get-IaLlmNormalizedKey -Key $Key
	if ($Value.Length -gt 20 -and (Test-IaLlmPlanXml -Value $Value)) {
		# XML плану (дозапит з повним планом): літерали очищуються завжди, імена — як у тексті.
		$cleaned = Remove-IaLlmPlanXmlLiterals -Xml $Value -State $State
		if ($State.maskNames) {
			$cleaned = Convert-IaLlmProseForward -Text $cleaned -State $State
		}
		return $cleaned
	}
	if ($normalized -in $script:IaLlmLiteralSqlKeys) {
		return (Convert-IaLlmSqlForward -Sql $Value -State $State -RemoveLiterals $true -MaskNames $State.maskNames)
	}
	if (-not $State.maskNames) {
		return $Value
	}
	if ($normalized -in $script:IaLlmScriptKeys) {
		return (Convert-IaLlmSqlForward -Sql $Value -State $State -RemoveLiterals $false -MaskNames $true)
	}
	if ($normalized -in $script:IaLlmNoMaskKeys) {
		return $Value
	}
	if ($normalized -in $script:IaLlmObjectKeyKeys) {
		$parts = $Value.Split('|')
		for ($i = 0; $i -lt $parts.Count; $i++) {
			$parts[$i] = Convert-IaLlmProseForward -Text $parts[$i] -State $State
		}
		return ($parts -join '|')
	}
	$alias = $null
	if ($State.names.TryGetValue($Value, [ref]$alias)) {
		return $alias
	}
	return (Convert-IaLlmProseForward -Text $Value -State $State)
}

function ConvertTo-IaLlmMaskedNode {
	<# Внутрішня: глибока копія з маскуванням. #>
	param(
		[AllowNull()]$Node,
		[AllowEmptyString()][string]$Key,
		[Parameter(Mandatory)][hashtable]$State
	)
	if ($null -eq $Node -or $Node -is [System.DBNull]) {
		return $null
	}
	if ($Node -is [string]) {
		return (ConvertTo-IaLlmMaskedString -Value $Node -Key $Key -State $State)
	}
	if ($Node -is [datetime] -or $Node -is [System.DateTimeOffset]) {
		return (ConvertTo-IaUtcString -Date $Node)
	}
	if ($Node -is [System.Management.Automation.PSCustomObject]) {
		$Node = ConvertTo-IaLlmPlainValue -Value $Node
	}
	if ($Node -is [System.Collections.IDictionary]) {
		$copy = [ordered]@{}
		foreach ($childKey in $Node.Keys) {
			$copy[[string]$childKey] = ConvertTo-IaLlmMaskedNode -Node $Node[$childKey] -Key ([string]$childKey) -State $State
		}
		return $copy
	}
	if (Test-IaLlmList -Value $Node) {
		$items = [System.Collections.Generic.List[object]]::new()
		foreach ($item in $Node) {
			$items.Add((ConvertTo-IaLlmMaskedNode -Node $item -Key $Key -State $State))
		}
		return , $items.ToArray()
	}
	return $Node
}

function ConvertFrom-IaLlmMaskedNode {
	<# Внутрішня: глибока копія з заміною псевдонімів на справжні імена. #>
	param(
		[AllowNull()]$Node,
		[AllowEmptyString()][string]$Key,
		[Parameter(Mandatory)][hashtable]$State
	)
	if ($null -eq $Node -or $Node -is [System.DBNull]) {
		return $null
	}
	if ($Node -is [string]) {
		$normalized = Get-IaLlmNormalizedKey -Key $Key
		if ($normalized -in $script:IaLlmScriptKeys -or $normalized -in $script:IaLlmLiteralSqlKeys) {
			return (Convert-IaLlmSqlReverse -Sql $Node -State $State)
		}
		$real = $null
		if ($State.reverse.TryGetValue($Node, [ref]$real)) {
			return $real
		}
		$result = Convert-IaLlmProseReverse -Text $Node -State $State
		if ($normalized -in $script:IaLlmObjectKeyKeys) {
			$result = $result.ToLowerInvariant()
		}
		return $result
	}
	if ($Node -is [datetime] -or $Node -is [System.DateTimeOffset]) {
		return (ConvertTo-IaUtcString -Date $Node)
	}
	if ($Node -is [System.Management.Automation.PSCustomObject]) {
		$Node = ConvertTo-IaLlmPlainValue -Value $Node
	}
	if ($Node -is [System.Collections.IDictionary]) {
		$copy = [ordered]@{}
		foreach ($childKey in $Node.Keys) {
			$copy[[string]$childKey] = ConvertFrom-IaLlmMaskedNode -Node $Node[$childKey] -Key ([string]$childKey) -State $State
		}
		return $copy
	}
	if (Test-IaLlmList -Value $Node) {
		$items = [System.Collections.Generic.List[object]]::new()
		foreach ($item in $Node) {
			$items.Add((ConvertFrom-IaLlmMaskedNode -Node $item -Key $Key -State $State))
		}
		return , $items.ToArray()
	}
	return $Node
}

function ConvertTo-IaMaskedObject {
	<# Глибока копія з маскуванням: тексти запитів завжди очищуються від літералів (Remove-IaSqlLiterals);
	   імена серверів, баз, схем, таблиць, колонок, індексів маскуються, якщо llm.maskNames = $true (мапа поповнюється).
	   Встановлює masking = @{ namesMasked; literalsMasked = $true } на верхньому рівні, якщо там є ключ masking. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowNull()]$InputObject,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Map,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$maskNames = ConvertTo-IaLlmBool -Value (Get-IaLlmValue -InputObject (Get-IaLlmValue -InputObject $Config -Name 'llm') -Name 'maskNames')
	$state = New-IaLlmMaskState -Map $Map -MaskNames $maskNames
	if ($maskNames) {
		Register-IaLlmMaskNames -Node $InputObject -Key '' -State $state
	}
	$result = ConvertTo-IaLlmMaskedNode -Node $InputObject -Key '' -State $state
	if ($result -is [System.Collections.IDictionary] -and $result.Contains('masking')) {
		$previous = $result['masking']
		$wasMasked = ($previous -is [System.Collections.IDictionary]) -and (ConvertTo-IaLlmBool -Value $previous['namesMasked'])
		$result['masking'] = [ordered]@{ namesMasked = [bool]($maskNames -or $wasMasked); literalsMasked = $true }
	}
	return , $result
}

function ConvertFrom-IaMaskedObject {
	<# Глибока копія з заміною псевдонімів на справжні імена (у рядках, зокрема в T-SQL рекомендацій). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowNull()]$InputObject,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Map
	)
	$state = New-IaLlmMaskState -Map $Map -MaskNames $false
	$result = ConvertFrom-IaLlmMaskedNode -Node $InputObject -Key '' -State $state
	return , $result
}
