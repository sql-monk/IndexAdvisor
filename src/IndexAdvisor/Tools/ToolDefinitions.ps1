# Декларативні інструменти для дозапитів моделі: розбір Markdown-визначень, JSON-схема, перевірка аргументів.
# ТЗ 4.7; CONTRACTS.md 3.3 і 6.

$script:IaToolNamePattern = '^[a-z][a-z0-9_]{2,63}$'
$script:IaToolParameterTypes = @('string', 'int', 'bigint', 'decimal', 'bool', 'datetime', 'guid')
$script:IaToolSectionNames = @('Description', 'Method', 'Server', 'Database', 'Parameters', 'Query')
$script:IaToolAttributeNames = @('enum', 'min', 'max', 'maxLength', 'default')
$script:IaToolFreeQueryName = 'free_query'

function Get-IaToolSetting {
	<# Значення конфігурації Section.Name або Default, якщо секції чи ключа немає. #>
	[CmdletBinding()]
	param(
		[System.Collections.IDictionary]$Config,
		[Parameter(Mandatory)][string]$Section,
		[Parameter(Mandatory)][string]$Name,
		[AllowNull()]$Default
	)
	if ($null -eq $Config -or -not $Config.Contains($Section)) {
		return $Default
	}
	$sectionValue = $Config[$Section]
	if ($sectionValue -isnot [System.Collections.IDictionary] -or -not $sectionValue.Contains($Name) -or $null -eq $sectionValue[$Name]) {
		return $Default
	}
	return $sectionValue[$Name]
}

function New-IaToolDefinitionError {
	<# ErrorRecord з ErrorId 'IaToolDefinitionInvalid': ім'я файлу і причина. #>
	[CmdletBinding()]
	param(
		[AllowEmptyString()][string]$Path,
		[Parameter(Mandatory)][string]$Reason
	)
	$fileName = if ($Path) { [System.IO.Path]::GetFileName($Path) } else { '<невідомий файл>' }
	if (-not $fileName) {
		$fileName = $Path
	}
	$message = "Невалідне визначення інструмента '$fileName': $Reason"
	$exception = [System.IO.InvalidDataException]::new($message)
	return [System.Management.Automation.ErrorRecord]::new($exception, 'IaToolDefinitionInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $Path)
}

function New-IaToolParseException {
	<# Виняток розбору з причиною (перетворюється на IaToolDefinitionInvalid у ConvertFrom-IaToolMarkdown). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Message)
	return [System.IO.InvalidDataException]::new($Message)
}

function Test-IaToolNumber {
	<# Чи є значення числом .NET (bool і рядки — ні). #>
	[CmdletBinding()]
	[OutputType([bool])]
	param([AllowNull()]$Value)
	return ($Value -is [int] -or $Value -is [long] -or $Value -is [short] -or $Value -is [byte] -or $Value -is [sbyte] -or
		$Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [double] -or $Value -is [single] -or
		$Value -is [decimal] -or $Value -is [System.Numerics.BigInteger])
}

function ConvertTo-IaToolTypedValue {
	<# Безпечне приведення значення до типу параметра інструмента. Рядки приводяться до чисел, дат, guid і bool
	   лише за суворим форматом (InvariantCulture). Повертає @{ isValid; value; error }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Type,
		[AllowNull()]$Value
	)
	$invariant = [cultureinfo]::InvariantCulture
	$fail = { param($message) [ordered]@{ isValid = $false; value = $null; error = $message } }
	$ok = { param($typedValue) [ordered]@{ isValid = $true; value = $typedValue; error = $null } }
	if ($null -eq $Value) {
		return (& $fail 'значення відсутнє')
	}
	switch ($Type) {
		'string' {
			if ($Value -is [string]) {
				return (& $ok $Value)
			}
			if ($Value -is [char]) {
				return (& $ok ([string]$Value))
			}
			return (& $fail "очікується рядок, отримано $($Value.GetType().Name)")
		}
		{ $_ -in @('int', 'bigint') } {
			$number = $null
			if ($Value -is [string]) {
				$text = $Value.Trim()
				$parsed = [decimal]0
				if ($text -match '^[+-]?\d{1,28}$' -and [decimal]::TryParse($text, [System.Globalization.NumberStyles]::AllowLeadingSign, $invariant, [ref]$parsed)) {
					$number = $parsed
				}
			}
			elseif (Test-IaToolNumber -Value $Value) {
				try {
					$number = [decimal]$Value
				}
				catch {
					$number = $null
				}
			}
			if ($null -eq $number -or $number -ne [decimal]::Truncate($number)) {
				return (& $fail "очікується ціле число, отримано '$Value'")
			}
			if ($Type -eq 'int') {
				if ($number -lt [int]::MinValue -or $number -gt [int]::MaxValue) {
					return (& $fail "значення '$Value' поза межами типу int")
				}
				return (& $ok ([int]$number))
			}
			if ($number -lt [long]::MinValue -or $number -gt [long]::MaxValue) {
				return (& $fail "значення '$Value' поза межами типу bigint")
			}
			return (& $ok ([long]$number))
		}
		'decimal' {
			$number = $null
			if ($Value -is [string]) {
				$text = $Value.Trim()
				$parsed = [decimal]0
				$styles = [System.Globalization.NumberStyles]::AllowLeadingSign -bor [System.Globalization.NumberStyles]::AllowDecimalPoint -bor
					[System.Globalization.NumberStyles]::AllowExponent
				if ($text -match '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$' -and [decimal]::TryParse($text, $styles, $invariant, [ref]$parsed)) {
					$number = $parsed
				}
			}
			elseif (Test-IaToolNumber -Value $Value) {
				try {
					$number = [decimal]$Value
				}
				catch {
					$number = $null
				}
			}
			if ($null -eq $number) {
				return (& $fail "очікується число, отримано '$Value'")
			}
			return (& $ok $number)
		}
		'bool' {
			if ($Value -is [bool]) {
				return (& $ok $Value)
			}
			if ($Value -is [string]) {
				switch ($Value.Trim().ToLowerInvariant()) {
					'true' { return (& $ok $true) }
					'1' { return (& $ok $true) }
					'false' { return (& $ok $false) }
					'0' { return (& $ok $false) }
				}
			}
			return (& $fail "очікується true або false, отримано '$Value'")
		}
		'datetime' {
			if ($Value -is [System.DateTimeOffset]) {
				return (& $ok ([datetime]::SpecifyKind($Value.UtcDateTime, [System.DateTimeKind]::Utc)))
			}
			if ($Value -is [datetime]) {
				$utc = switch ($Value.Kind) {
					([System.DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) }
					([System.DateTimeKind]::Local) { $Value.ToUniversalTime() }
					default { $Value }
				}
				return (& $ok $utc)
			}
			if ($Value -is [string]) {
				$text = $Value.Trim()
				$parsed = [System.DateTimeOffset]::MinValue
				$styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
				if ($text -match '^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d{1,7})?)?)?(Z|[+-]\d{2}:\d{2})?$' -and
					[System.DateTimeOffset]::TryParse($text, $invariant, $styles, [ref]$parsed)) {
					return (& $ok ([datetime]::SpecifyKind($parsed.UtcDateTime, [System.DateTimeKind]::Utc)))
				}
			}
			return (& $fail "очікується дата ISO 8601 (наприклад 2026-11-01T00:00:00Z), отримано '$Value'")
		}
		'guid' {
			if ($Value -is [guid]) {
				return (& $ok $Value)
			}
			if ($Value -is [string]) {
				$parsed = [guid]::Empty
				if ([guid]::TryParse($Value.Trim(), [ref]$parsed)) {
					return (& $ok $parsed)
				}
			}
			return (& $fail "очікується uniqueidentifier, отримано '$Value'")
		}
		default {
			return (& $fail "непідтримуваний тип '$Type'")
		}
	}
}

function Test-IaToolValueConstraints {
	<# Перевіряє типізоване значення на enum, min, max, maxLength параметра. Повертає @{ errors; value } (value — з
	   нормалізованим регістром для enum рядків). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Parameter,
		[Parameter(Mandatory)][AllowNull()]$Value
	)
	$errors = [System.Collections.Generic.List[string]]::new()
	$normalized = $Value
	if ($null -ne $Parameter.enum) {
		$match = $null
		foreach ($allowed in @($Parameter.enum)) {
			if ($Parameter.type -eq 'string') {
				if ([string]::Equals([string]$allowed, [string]$Value, [System.StringComparison]::OrdinalIgnoreCase)) {
					$match = $allowed
					break
				}
			}
			elseif ([decimal]$allowed -eq [decimal]$Value) {
				$match = $allowed
				break
			}
		}
		if ($null -eq $match) {
			$errors.Add("значення '$Value' не входить до дозволених: $(@($Parameter.enum) -join ', ')")
		}
		else {
			$normalized = $match
		}
	}
	if ($null -ne $Parameter.min -and [decimal]$Value -lt [decimal]$Parameter.min) {
		$errors.Add("значення $Value менше за мінімум $($Parameter.min)")
	}
	if ($null -ne $Parameter.max -and [decimal]$Value -gt [decimal]$Parameter.max) {
		$errors.Add("значення $Value більше за максимум $($Parameter.max)")
	}
	if ($null -ne $Parameter.maxLength -and ([string]$Value).Length -gt [int]$Parameter.maxLength) {
		$errors.Add("довжина $(([string]$Value).Length) перевищує maxLength $($Parameter.maxLength)")
	}
	return [ordered]@{ errors = @($errors); value = $normalized }
}

function ConvertTo-IaToolJsonValue {
	<# Типізоване значення аргументу -> JSON-сумісне: дата -> ISO 8601 UTC, guid -> рядок. #>
	[CmdletBinding()]
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return $null
	}
	if ($Value -is [datetime] -or $Value -is [System.DateTimeOffset]) {
		return (ConvertTo-IaUtcString -Date $Value)
	}
	if ($Value -is [guid]) {
		return $Value.ToString()
	}
	return $Value
}

function ConvertTo-IaToolJsonArguments {
	<# Словник аргументів -> [ordered] з JSON-сумісними значеннями (для журналу, записів і моделі). #>
	[CmdletBinding()]
	param([AllowNull()]$Arguments)
	$result = [ordered]@{}
	if ($Arguments -is [System.Collections.IDictionary]) {
		foreach ($key in @($Arguments.get_Keys())) {
			$result[[string]$key] = ConvertTo-IaToolJsonValue -Value $Arguments[$key]
		}
	}
	return $result
}

function Get-IaToolQueryVariables {
	<# Імена змінних @Name у тексті T-SQL поза рядковими літералами, коментарями й ідентифікаторами в [] та "".
	   Системні функції @@NAME пропускаються. Повертає масив імен без '@' у порядку першої появи. #>
	[CmdletBinding()]
	param([AllowEmptyString()][string]$Sql)
	$names = [System.Collections.Generic.List[string]]::new()
	$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	$length = $Sql.Length
	$position = 0
	while ($position -lt $length) {
		$char = $Sql[$position]
		$next = if ($position + 1 -lt $length) { $Sql[$position + 1] } else { [char]0 }
		if ($char -eq "'" -or $char -eq '"' -or $char -eq '[') {
			$closing = if ($char -eq '[') { ']' } else { $char }
			$position++
			while ($position -lt $length) {
				if ($Sql[$position] -eq $closing) {
					if ($position + 1 -lt $length -and $Sql[$position + 1] -eq $closing) {
						$position += 2
						continue
					}
					break
				}
				$position++
			}
			$position++
			continue
		}
		if ($char -eq '-' -and $next -eq '-') {
			while ($position -lt $length -and $Sql[$position] -ne "`n") {
				$position++
			}
			continue
		}
		if ($char -eq '/' -and $next -eq '*') {
			$depth = 1
			$position += 2
			while ($position -lt $length -and $depth -gt 0) {
				if ($Sql[$position] -eq '/' -and $position + 1 -lt $length -and $Sql[$position + 1] -eq '*') {
					$depth++
					$position += 2
					continue
				}
				if ($Sql[$position] -eq '*' -and $position + 1 -lt $length -and $Sql[$position + 1] -eq '/') {
					$depth--
					$position += 2
					continue
				}
				$position++
			}
			continue
		}
		if ($char -eq '@') {
			$match = [regex]::Match($Sql.Substring($position), '^@@?[A-Za-z0-9_#$@]*')
			$token = $match.Value
			if (-not $token.StartsWith('@@') -and $token.Length -gt 1) {
				$name = $token.Substring(1)
				if ($seen.Add($name)) {
					$names.Add($name)
				}
			}
			$position += [Math]::Max(1, $token.Length)
			continue
		}
		$position++
	}
	return , $names.ToArray()
}

function ConvertFrom-IaToolParameterLine {
	<# Розбирає рядок '- @Name: type[?] [{attr=value, ...}] - опис' у параметр інструмента. Кидає виняток розбору. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Line,
		[Parameter(Mandatory)][int]$LineNumber
	)
	$pattern = '^\s*-\s+@(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?<type>[A-Za-z]+)(?<optional>\?)?\s*(?:\{(?<attrs>[^{}]*)\})?\s+-\s+(?<desc>\S.*)$'
	$match = [regex]::Match($Line, $pattern)
	if (-not $match.Success) {
		throw (New-IaToolParseException "рядок $LineNumber`: некоректне оголошення параметра '$($Line.Trim())'; очікується '- @Name: type[?] [{attr=value}] - опис'")
	}
	$name = $match.Groups['name'].Value
	$type = $match.Groups['type'].Value
	if ($type -cnotin $script:IaToolParameterTypes) {
		throw (New-IaToolParseException "рядок $LineNumber`: невідомий тип '$type' параметра @$name; дозволено: $($script:IaToolParameterTypes -join ', ')")
	}
	$parameter = [ordered]@{
		name = $name
		type = $type
		required = -not $match.Groups['optional'].Success
		description = $match.Groups['desc'].Value.Trim()
		enum = $null
		min = $null
		max = $null
		maxLength = $null
		default = $null
		hasDefault = $false
	}
	if (-not $match.Groups['attrs'].Success) {
		return $parameter
	}
	$attributes = [ordered]@{}
	$attrsText = $match.Groups['attrs'].Value
	if ($attrsText.Trim() -eq '') {
		throw (New-IaToolParseException "рядок $LineNumber`: порожній блок атрибутів параметра @$name")
	}
	foreach ($part in ($attrsText -split ',')) {
		$pair = [regex]::Match($part, '^\s*(?<key>[A-Za-z]+)\s*=(?<value>.*)$')
		if (-not $pair.Success) {
			throw (New-IaToolParseException "рядок $LineNumber`: некоректний атрибут '$($part.Trim())' параметра @$name; очікується attr=value")
		}
		$key = $script:IaToolAttributeNames | Where-Object { $_ -eq $pair.Groups['key'].Value } | Select-Object -First 1
		if (-not $key) {
			throw (New-IaToolParseException "рядок $LineNumber`: невідомий атрибут '$($pair.Groups['key'].Value)' параметра @$name; дозволено: $($script:IaToolAttributeNames -join ', ')")
		}
		if ($attributes.Contains($key)) {
			throw (New-IaToolParseException "рядок $LineNumber`: атрибут '$key' параметра @$name повторюється")
		}
		$attributes[$key] = $pair.Groups['value'].Value.Trim()
	}
	$isNumeric = $type -in @('int', 'bigint', 'decimal')
	foreach ($key in @($attributes.get_Keys())) {
		$raw = $attributes[$key]
		if ($key -ne 'default' -and $raw -eq '') {
			throw (New-IaToolParseException "рядок $LineNumber`: атрибут '$key' параметра @$name без значення")
		}
		switch ($key) {
			'enum' {
				if ($type -notin @('string', 'int', 'bigint', 'decimal')) {
					throw (New-IaToolParseException "рядок $LineNumber`: enum не підтримується для типу $type (@$name)")
				}
				$values = [System.Collections.Generic.List[object]]::new()
				foreach ($item in ($raw -split '\|')) {
					$itemText = $item.Trim()
					if ($itemText -eq '') {
						throw (New-IaToolParseException "рядок $LineNumber`: порожнє значення enum параметра @$name")
					}
					$converted = ConvertTo-IaToolTypedValue -Type $type -Value $itemText
					if (-not $converted.isValid) {
						throw (New-IaToolParseException "рядок $LineNumber`: значення enum '$itemText' параметра @$name — $($converted.error)")
					}
					foreach ($existing in $values) {
						if ([string]::Equals([string]$existing, [string]$converted.value, [System.StringComparison]::OrdinalIgnoreCase)) {
							throw (New-IaToolParseException "рядок $LineNumber`: значення enum '$itemText' параметра @$name повторюється")
						}
					}
					$values.Add($converted.value)
				}
				$parameter.enum = $values.ToArray()
			}
			{ $_ -in @('min', 'max') } {
				if (-not $isNumeric) {
					throw (New-IaToolParseException "рядок $LineNumber`: атрибут $key дозволено лише для числових типів (@${name}: $type)")
				}
				$converted = ConvertTo-IaToolTypedValue -Type $type -Value $raw
				if (-not $converted.isValid) {
					throw (New-IaToolParseException "рядок $LineNumber`: атрибут $key параметра @$name — $($converted.error)")
				}
				$parameter[$key] = $converted.value
			}
			'maxLength' {
				if ($type -ne 'string') {
					throw (New-IaToolParseException "рядок $LineNumber`: атрибут maxLength дозволено лише для типу string (@${name}: $type)")
				}
				$converted = ConvertTo-IaToolTypedValue -Type 'int' -Value $raw
				if (-not $converted.isValid -or $converted.value -lt 1) {
					throw (New-IaToolParseException "рядок $LineNumber`: maxLength параметра @$name має бути цілим числом ≥ 1")
				}
				$parameter.maxLength = $converted.value
			}
		}
	}
	if ($null -ne $parameter.min -and $null -ne $parameter.max -and [decimal]$parameter.min -gt [decimal]$parameter.max) {
		throw (New-IaToolParseException "рядок $LineNumber`: min більший за max у параметра @$name")
	}
	if ($attributes.Contains('default')) {
		if ($parameter.required) {
			throw (New-IaToolParseException "рядок $LineNumber`: default дозволено лише для необов'язкового параметра (тип з '?'): @$name")
		}
		$converted = ConvertTo-IaToolTypedValue -Type $type -Value $attributes['default']
		if (-not $converted.isValid) {
			throw (New-IaToolParseException "рядок $LineNumber`: default параметра @$name — $($converted.error)")
		}
		$check = Test-IaToolValueConstraints -Parameter $parameter -Value $converted.value
		if ($check.errors.Count -gt 0) {
			throw (New-IaToolParseException "рядок $LineNumber`: default параметра @$name не відповідає обмеженням: $($check.errors -join '; ')")
		}
		$parameter.default = $check.value
		$parameter.hasDefault = $true
	}
	return $parameter
}

function ConvertFrom-IaToolMarkdownText {
	<# Розбір тексту Markdown-інструмента (CONTRACTS.md, розділ 6). Кидає виняток розбору з причиною. #>
	[CmdletBinding()]
	param([AllowEmptyString()][string]$Text)
	$lines = $Text -split '\r?\n'
	$name = $null
	$current = $null
	$sections = [ordered]@{}
	$inFence = $false
	$fenceCount = 0
	$sqlLines = [System.Collections.Generic.List[string]]::new()
	for ($index = 0; $index -lt $lines.Count; $index++) {
		$line = $lines[$index]
		$lineNumber = $index + 1
		if ($inFence) {
			if ($line -match '^\s*```\s*$') {
				$inFence = $false
				continue
			}
			$sqlLines.Add($line)
			continue
		}
		if ($line -match '^\s*```(?<lang>.*)$') {
			$language = $Matches['lang'].Trim()
			if ($current -ne 'Query') {
				throw (New-IaToolParseException "рядок $lineNumber`: блок коду дозволено лише в розділі '## Query'")
			}
			if ($language -ne 'sql') {
				throw (New-IaToolParseException "рядок $lineNumber`: блок у розділі '## Query' має бути ``````sql")
			}
			$fenceCount++
			if ($fenceCount -gt 1) {
				throw (New-IaToolParseException "рядок $lineNumber`: розділ '## Query' має містити рівно один ``````sql-блок")
			}
			$inFence = $true
			continue
		}
		if ($line -match '^#\s+(?<title>.*)$') {
			if ($null -ne $name -or $null -ne $current) {
				throw (New-IaToolParseException "рядок $lineNumber`: заголовок першого рівня має бути один і на початку файлу")
			}
			$name = $Matches['title'].Trim()
			continue
		}
		if ($line -match '^##\s+(?<title>.*)$') {
			if ($null -eq $name) {
				throw (New-IaToolParseException "рядок $lineNumber`: файл має починатися з заголовка '# <назва>'")
			}
			$title = $Matches['title'].Trim()
			$canonical = $script:IaToolSectionNames | Where-Object { $_ -eq $title } | Select-Object -First 1
			if (-not $canonical) {
				throw (New-IaToolParseException "рядок $lineNumber`: невідомий розділ '## $title'; дозволено: $($script:IaToolSectionNames -join ', ')")
			}
			if ($sections.Contains($canonical)) {
				throw (New-IaToolParseException "рядок $lineNumber`: розділ '## $canonical' повторюється")
			}
			$sections[$canonical] = [System.Collections.Generic.List[object]]::new()
			$current = $canonical
			continue
		}
		if ($line -match '^#{3,}\s') {
			throw (New-IaToolParseException "рядок $lineNumber`: заголовки нижче другого рівня не підтримуються")
		}
		if ($line.Trim() -eq '') {
			continue
		}
		if ($null -eq $current) {
			throw (New-IaToolParseException "рядок $lineNumber`: текст поза розділами")
		}
		if ($current -eq 'Query') {
			throw (New-IaToolParseException "рядок $lineNumber`: у розділі '## Query' дозволено лише ``````sql-блок")
		}
		$sections[$current].Add([ordered]@{ lineNumber = $lineNumber; text = $line })
	}
	if ($inFence) {
		throw (New-IaToolParseException 'незакритий ```sql-блок у розділі ''## Query''')
	}
	if ([string]::IsNullOrWhiteSpace($name)) {
		throw (New-IaToolParseException "відсутній заголовок '# <назва>'")
	}
	if ($name -cnotmatch $script:IaToolNamePattern) {
		throw (New-IaToolParseException "назва '$name' не відповідає шаблону $($script:IaToolNamePattern)")
	}
	if ($name -eq $script:IaToolFreeQueryName) {
		throw (New-IaToolParseException "назва '$name' зарезервована для вбудованого вільного запиту (unsafe.allowFreeQuery)")
	}
	foreach ($required in @('Description', 'Method', 'Query')) {
		if (-not $sections.Contains($required)) {
			throw (New-IaToolParseException "відсутній обов'язковий розділ '## $required'")
		}
	}
	$description = (@($sections['Description'] | ForEach-Object { $_.text.Trim() }) -join "`n").Trim()
	if ($description -eq '') {
		throw (New-IaToolParseException "розділ '## Description' порожній")
	}
	$methodLines = @($sections['Method'])
	if ($methodLines.Count -ne 1 -or $methodLines[0].text.Trim() -cne 'Query') {
		throw (New-IaToolParseException "розділ '## Method' має містити рівно одне значення 'Query' (лише read-only SELECT)")
	}
	$fixed = [ordered]@{ Server = $null; Database = $null }
	foreach ($sectionName in @('Server', 'Database')) {
		if (-not $sections.Contains($sectionName)) {
			continue
		}
		$values = @($sections[$sectionName])
		if ($values.Count -gt 1) {
			throw (New-IaToolParseException "рядок $($values[1].lineNumber)`: розділ '## $sectionName' має містити не більше одного значення")
		}
		if ($values.Count -eq 1) {
			$value = $values[0].text.Trim()
			$maxLength = if ($sectionName -eq 'Database') { 128 } else { 256 }
			if ($value.Length -gt $maxLength -or $value -match '[\s;''"]') {
				throw (New-IaToolParseException "рядок $($values[0].lineNumber)`: некоректне значення розділу '## $sectionName': '$value'")
			}
			$fixed[$sectionName] = $value
		}
	}
	$parameters = [System.Collections.Generic.List[object]]::new()
	$parameterNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	if ($sections.Contains('Parameters')) {
		foreach ($entry in $sections['Parameters']) {
			$parameter = ConvertFrom-IaToolParameterLine -Line $entry.text -LineNumber $entry.lineNumber
			if (-not $parameterNames.Add($parameter.name)) {
				throw (New-IaToolParseException "рядок $($entry.lineNumber)`: параметр @$($parameter.name) оголошено двічі")
			}
			$parameters.Add($parameter)
		}
	}
	if ($fenceCount -ne 1) {
		throw (New-IaToolParseException "розділ '## Query' має містити рівно один ``````sql-блок")
	}
	$query = ($sqlLines -join "`n").Trim()
	if ($query -eq '') {
		throw (New-IaToolParseException "порожній текст запиту в розділі '## Query'")
	}
	$queryVariables = Get-IaToolQueryVariables -Sql $query
	$queryVariableSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$queryVariables, [System.StringComparer]::OrdinalIgnoreCase)
	$undeclared = @($queryVariables | Where-Object { -not $parameterNames.Contains($_) })
	if ($undeclared.Count -gt 0) {
		throw (New-IaToolParseException "змінні запиту не оголошено в '## Parameters': $(($undeclared | ForEach-Object { "@$_" }) -join ', ')")
	}
	$unused = @($parameters | Where-Object { -not $queryVariableSet.Contains($_.name) } | ForEach-Object { "@$($_.name)" })
	if ($unused.Count -gt 0) {
		throw (New-IaToolParseException "параметри оголошено, але не використано в запиті: $($unused -join ', ')")
	}
	return [ordered]@{
		name = $name
		description = $description
		method = 'Query'
		server = $fixed.Server
		database = $fixed.Database
		parameters = $parameters.ToArray()
		query = $query
		path = $null
		purpose = 'Tool'
	}
}

function ConvertFrom-IaToolMarkdown {
	<# Розбирає один Markdown-файл інструмента (CONTRACTS.md, розділ 6). Повертає ToolDefinition:
	   @{ name; description; method; server; database; parameters = @(@{ name; type; required; description; enum; min; max;
	   maxLength; default; hasDefault }); query; path; purpose = 'Tool' }. Невалідний файл — виняток 'IaToolDefinitionInvalid'. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Path)
	try {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
			throw (New-IaToolParseException 'файл не знайдено')
		}
		$text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
		if ($null -eq $text) {
			$text = ''
		}
		$tool = ConvertFrom-IaToolMarkdownText -Text $text
		$tool.path = (Resolve-Path -LiteralPath $Path).ProviderPath
		return $tool
	}
	catch {
		$PSCmdlet.ThrowTerminatingError((New-IaToolDefinitionError -Path $Path -Reason $_.Exception.Message))
	}
}

function New-IaToolFreeQueryDefinition {
	<# Вбудований інструмент free_query (лише при unsafe.allowFreeQuery): текст запиту — параметр @Sql, Purpose FreeQuery. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$maxLength = [int](Get-IaToolSetting -Config $Config -Section 'limits' -Name 'maxCommandLength' -Default 10000)
	return [ordered]@{
		name = $script:IaToolFreeQueryName
		description = 'Вільний запит (небезпечний режим unsafe.allowFreeQuery): рівно одна інструкція SELECT лише з системних каталогів, ' +
			'DMV і Query Store; змінні @Name не підтримуються. Використовуй лише якщо жоден інший інструмент не дає потрібних даних.'
		method = 'Query'
		server = $null
		database = $null
		parameters = @(
			[ordered]@{
				name = 'Sql'
				type = 'string'
				required = $true
				description = 'Текст запиту: одна інструкція SELECT із sys.*, DMV або Query Store'
				enum = $null
				min = $null
				max = $null
				maxLength = $maxLength
				default = $null
				hasDefault = $false
			}
		)
		query = $null
		path = $null
		purpose = 'FreeQuery'
	}
}

function Import-IaToolDefinitions {
	<# Завантажує всі *.md з Path (за замовчуванням tools.definitionsPath або вбудований Tools/Definitions).
	   Строгий режим (tools.strict): невалідний файл — виняток IaToolDefinitionInvalid; без строгого режиму файл пропускається
	   з попередженням. Дублікати назв заборонені завжди. free_query додається лише при unsafe.allowFreeQuery = $true.
	   Повертає [ordered] name -> ToolDefinition. #>
	[CmdletBinding()]
	param(
		[string]$Path,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$strict = [bool](Get-IaToolSetting -Config $Config -Section 'tools' -Name 'strict' -Default $true)
	if (-not $Path) {
		$Path = [string](Get-IaToolSetting -Config $Config -Section 'tools' -Name 'definitionsPath' -Default '')
	}
	if (-not $Path) {
		$Path = Join-Path $script:IaModuleRoot 'Tools\Definitions'
	}
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
		$PSCmdlet.ThrowTerminatingError((New-IaToolDefinitionError -Path $Path -Reason "каталог інструментів '$Path' не знайдено"))
	}
	$tools = [ordered]@{}
	$sources = @{}
	$files = @(Get-ChildItem -LiteralPath $Path -Filter '*.md' -File | Sort-Object -Property Name)
	foreach ($file in $files) {
		try {
			$tool = ConvertFrom-IaToolMarkdown -Path $file.FullName
		}
		catch {
			if ($strict) {
				$PSCmdlet.ThrowTerminatingError($_)
			}
			$warning = "Інструмент пропущено (tools.strict = false): $($_.Exception.Message)"
			Write-Warning $warning
			Write-IaLog -Message $warning -Level Warning -Data ([ordered]@{ file = $file.FullName })
			continue
		}
		if ($tools.Contains($tool.name)) {
			$reason = "назва '$($tool.name)' вже оголошена у файлі '$($sources[$tool.name])'; дублікати назв заборонені"
			$PSCmdlet.ThrowTerminatingError((New-IaToolDefinitionError -Path $file.FullName -Reason $reason))
		}
		$tools[$tool.name] = $tool
		$sources[$tool.name] = $file.Name
	}
	if ([bool](Get-IaToolSetting -Config $Config -Section 'unsafe' -Name 'allowFreeQuery' -Default $false)) {
		$tools[$script:IaToolFreeQueryName] = New-IaToolFreeQueryDefinition -Config $Config
	}
	return $tools
}

function ConvertTo-IaToolJsonSchema {
	<# JSON-схема інструмента для моделі: @{ name; description; parameters = @{ type = 'object'; properties; required;
	   additionalProperties = $false } }. Ім'я властивості — без '@'. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Tool)
	$properties = [ordered]@{}
	$required = [System.Collections.Generic.List[string]]::new()
	foreach ($parameter in @($Tool.parameters)) {
		$property = [ordered]@{}
		switch ($parameter.type) {
			'string' { $property.type = 'string' }
			'int' { $property.type = 'integer' }
			'bigint' { $property.type = 'integer' }
			'decimal' { $property.type = 'number' }
			'bool' { $property.type = 'boolean' }
			'datetime' {
				$property.type = 'string'
				$property.format = 'date-time'
			}
			'guid' {
				$property.type = 'string'
				$property.format = 'uuid'
			}
		}
		if ($parameter.description) {
			$property.description = $parameter.description
		}
		if ($null -ne $parameter.enum) {
			$property.enum = @($parameter.enum | ForEach-Object { ConvertTo-IaToolJsonValue -Value $_ })
		}
		if ($null -ne $parameter.min) {
			$property.minimum = $parameter.min
		}
		if ($null -ne $parameter.max) {
			$property.maximum = $parameter.max
		}
		if ($null -ne $parameter.maxLength) {
			$property.maxLength = $parameter.maxLength
		}
		if ($parameter.hasDefault) {
			$property.default = ConvertTo-IaToolJsonValue -Value $parameter.default
		}
		$properties[$parameter.name] = $property
		if ($parameter.required) {
			$required.Add($parameter.name)
		}
	}
	return [ordered]@{
		name = $Tool.name
		description = $Tool.description
		parameters = [ordered]@{
			type = 'object'
			properties = $properties
			required = $required.ToArray()
			additionalProperties = $false
		}
	}
}

function Test-IaToolArguments {
	<# Перевіряє аргументи дозапиту: типи (з безпечним приведенням рядків), обов'язковість, enum, min, max, maxLength;
	   невідомі аргументи — помилка; відсутні необов'язкові отримують default (або $null).
	   Повертає @{ isValid; errors = @(); arguments = [ordered] ім'я без '@' -> типізоване значення }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Tool,
		[System.Collections.IDictionary]$Arguments = @{}
	)
	$errors = [System.Collections.Generic.List[string]]::new()
	$typed = [ordered]@{}
	$declared = @{}
	foreach ($parameter in @($Tool.parameters)) {
		$declared[$parameter.name] = $parameter
	}
	$provided = @{}
	if ($null -ne $Arguments) {
		foreach ($key in @($Arguments.get_Keys())) {
			$name = ([string]$key) -replace '^@', ''
			if (-not $declared.ContainsKey($name)) {
				$errors.Add("невідомий аргумент '$key' інструмента '$($Tool.name)'")
				continue
			}
			if ($provided.ContainsKey($name)) {
				$errors.Add("аргумент '$name' передано більше одного разу")
				continue
			}
			$provided[$name] = $Arguments[$key]
		}
	}
	foreach ($parameter in @($Tool.parameters)) {
		$name = $parameter.name
		if (-not $provided.ContainsKey($name) -or $null -eq $provided[$name]) {
			if ($parameter.required) {
				$errors.Add("обов'язковий аргумент '$name' не задано")
				continue
			}
			$typed[$name] = if ($parameter.hasDefault) { $parameter.default } else { $null }
			continue
		}
		$converted = ConvertTo-IaToolTypedValue -Type $parameter.type -Value $provided[$name]
		if (-not $converted.isValid) {
			$errors.Add("аргумент '$name': $($converted.error)")
			continue
		}
		$check = Test-IaToolValueConstraints -Parameter $parameter -Value $converted.value
		if ($check.errors.Count -gt 0) {
			foreach ($message in $check.errors) {
				$errors.Add("аргумент '$name': $message")
			}
			continue
		}
		$typed[$name] = $check.value
	}
	return [ordered]@{
		isValid = ($errors.Count -eq 0)
		errors = $errors.ToArray()
		arguments = $typed
	}
}
