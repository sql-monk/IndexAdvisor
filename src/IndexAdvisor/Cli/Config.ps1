# YAML-конфігурація IndexAdvisor (CONTRACTS.md, розділ 7): читання, перевірка за Shared/ConfigSchema.psd1, злиття з CLI, шаблон.
# Позиції помилок (рядок і стовпець, з 1) беруться з YamlDotNet.RepresentationModel, що входить до powershell-yaml.

$script:IaCliYamlAssembly = $null
$script:IaCliMandatoryDatasetPaths = @('collector.datasets.indexStructure', 'collector.datasets.instanceStartTime')
$script:IaCliTypeNames = @{
	object = "об'єкт (ключ: значення)"
	map = "словник (ім'я: об'єкт)"
	array = 'список'
	string = 'рядок'
	int = 'ціле число'
	number = 'число'
	bool = 'true або false'
}

function Get-IaCliYamlAssembly {
	<# Збірка YamlDotNet, завантажена модулем powershell-yaml. #>
	[CmdletBinding()]
	param()
	if ($null -ne $script:IaCliYamlAssembly) {
		return $script:IaCliYamlAssembly
	}
	$module = Get-Module -Name 'powershell-yaml' | Select-Object -First 1
	if (-not $module) {
		$module = Import-Module -Name 'powershell-yaml' -PassThru -ErrorAction Stop | Select-Object -First 1
	}
	$assemblies = @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'YamlDotNet' })
	$preferred = $assemblies | Where-Object {
		-not $_.IsDynamic -and $_.Location -and $_.Location.StartsWith($module.ModuleBase, [System.StringComparison]::OrdinalIgnoreCase)
	} | Select-Object -First 1
	if (-not $preferred) {
		$preferred = $assemblies | Select-Object -First 1
	}
	if (-not $preferred) {
		throw 'Збірку YamlDotNet не завантажено: потрібен модуль powershell-yaml.'
	}
	$script:IaCliYamlAssembly = $preferred
	return $preferred
}

function New-IaCliConfigError {
	<# Об'єкт помилки конфігурації @{ line; column; path; message }. #>
	[CmdletBinding()]
	param(
		[AllowNull()]$Line,
		[AllowNull()]$Column,
		[AllowEmptyString()][string]$Path,
		[Parameter(Mandatory)][string]$Message
	)
	return [ordered]@{
		line = $(if ($null -ne $Line) { [int]$Line } else { $null })
		column = $(if ($null -ne $Column) { [int]$Column } else { $null })
		path = $Path
		message = $Message
	}
}

function Join-IaCliPath {
	<# Шлях ключа у вигляді a.b.c. #>
	param([AllowEmptyString()][string]$Parent, [string]$Name)
	if ([string]::IsNullOrEmpty($Parent)) {
		return $Name
	}
	return "$Parent.$Name"
}

function ConvertFrom-IaCliYamlNode {
	<# Перетворює вузол YamlDotNet на нейтральний вузол @{ kind; line; column; ... } для перевірки. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][AllowNull()]$Node)
	if ($null -eq $Node) {
		return @{ kind = 'null'; line = 1; column = 1 }
	}
	$line = [int]$Node.Start.Line
	$column = [int]$Node.Start.Column
	switch ([string]$Node.NodeType) {
		'Mapping' {
			$entries = [System.Collections.Generic.List[object]]::new()
			foreach ($pair in $Node.Children.GetEnumerator()) {
				$keyNode = $pair.Key
				$keyText = if ([string]$keyNode.NodeType -eq 'Scalar') { [string]$keyNode.Value } else { $null }
				$entries.Add(@{
						key = $keyText
						keyLine = [int]$keyNode.Start.Line
						keyColumn = [int]$keyNode.Start.Column
						node = ConvertFrom-IaCliYamlNode -Node $pair.Value
					})
			}
			return @{ kind = 'map'; line = $line; column = $column; entries = $entries }
		}
		'Sequence' {
			$items = [System.Collections.Generic.List[object]]::new()
			foreach ($child in $Node.Children) {
				$items.Add((ConvertFrom-IaCliYamlNode -Node $child))
			}
			return @{ kind = 'seq'; line = $line; column = $column; items = $items }
		}
		'Scalar' {
			$text = [string]$Node.Value
			$style = [string]$Node.Style
			$quoted = $style -in @('SingleQuoted', 'DoubleQuoted', 'Literal', 'Folded')
			if (-not $quoted -and $text -in @('', '~', 'null', 'Null', 'NULL')) {
				return @{ kind = 'null'; line = $line; column = $column }
			}
			return @{ kind = 'scalar'; line = $line; column = $column; text = $text; quoted = $quoted; typed = $false; value = $text }
		}
		default {
			return @{ kind = 'unknown'; line = $line; column = $column }
		}
	}
}

function ConvertTo-IaCliValueNode {
	<# Перетворює значення PowerShell (параметри CLI) на нейтральний вузол без позицій. #>
	[CmdletBinding()]
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return @{ kind = 'null'; line = $null; column = $null }
	}
	if ($Value -is [System.Collections.IDictionary]) {
		$entries = [System.Collections.Generic.List[object]]::new()
		foreach ($key in $Value.Keys) {
			$entries.Add(@{ key = [string]$key; keyLine = $null; keyColumn = $null; node = ConvertTo-IaCliValueNode -Value $Value[$key] })
		}
		return @{ kind = 'map'; line = $null; column = $null; entries = $entries }
	}
	if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
		$items = [System.Collections.Generic.List[object]]::new()
		foreach ($item in $Value) {
			$items.Add((ConvertTo-IaCliValueNode -Value $item))
		}
		return @{ kind = 'seq'; line = $null; column = $null; items = $items }
	}
	if ($Value -is [System.Management.Automation.SwitchParameter]) {
		$Value = $Value.IsPresent
	}
	return @{ kind = 'scalar'; line = $null; column = $null; text = [string]$Value; quoted = $false; typed = $true; value = $Value }
}

function Get-IaCliNodeDescription {
	<# Короткий опис отриманого значення для повідомлення про помилку. #>
	param([hashtable]$Node)
	switch ($Node.kind) {
		'map' { return "об'єкт" }
		'seq' { return 'список' }
		'null' { return 'порожнє значення' }
		'scalar' { return "'$($Node.text)'" }
		default { return 'невідомий вузол' }
	}
}

function Get-IaCliSchemaDefault {
	<# Значення за замовчуванням для вузла схеми (копія, щоб не змінювати схему). #>
	param([Parameter(Mandatory)][hashtable]$Schema)
	switch ($Schema.Type) {
		'object' {
			$result = [ordered]@{}
			foreach ($child in $Schema.Properties) {
				if ($child.Type -eq 'object' -or $child.ContainsKey('Default')) {
					$result[$child.Name] = Get-IaCliSchemaDefault -Schema $child
				}
			}
			return $result
		}
		'map' { return [ordered]@{} }
		'array' { return , @($Schema.Default | Where-Object { $null -ne $_ }) }
		default { return $Schema.Default }
	}
}

function ConvertFrom-IaCliScalar {
	<# Перевіряє й перетворює скалярний вузол на тип схеми (string, int, number, bool). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][hashtable]$Node,
		[Parameter(Mandatory)][hashtable]$Schema,
		[AllowEmptyString()][string]$Path,
		[System.Collections.Generic.List[object]]$Errors
	)
	$type = $Schema.Type
	$typeError = {
		$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message ("Неправильний тип: очікується {0}, отримано {1}." -f $script:IaCliTypeNames[$type], (Get-IaCliNodeDescription -Node $Node))))
	}
	if ($Node.kind -notin @('scalar', 'null')) {
		& $typeError
		return $null
	}
	$value = $null
	switch ($type) {
		'string' {
			if ($Node.kind -eq 'null') {
				$value = ''
			}
			elseif ($Node.typed -and $Node.value -isnot [string]) {
				& $typeError
				return $null
			}
			else {
				$value = [string]$Node.text
			}
		}
		'int' {
			$parsed = [long]0
			if ($Node.kind -eq 'scalar' -and $Node.typed -and ($Node.value -is [int] -or $Node.value -is [long] -or $Node.value -is [int16] -or $Node.value -is [byte])) {
				$parsed = [long]$Node.value
			}
			elseif ($Node.kind -eq 'scalar' -and -not $Node.typed -and -not $Node.quoted -and $Node.text -match '^[-+]?[0-9]+$' -and
				[long]::TryParse($Node.text, [System.Globalization.NumberStyles]::AllowLeadingSign, [cultureinfo]::InvariantCulture, [ref]$parsed)) {
			}
			else {
				& $typeError
				return $null
			}
			if ($parsed -lt [int]::MinValue -or $parsed -gt [int]::MaxValue) {
				$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message "Значення $parsed виходить за межі цілого числа."))
				return $null
			}
			$value = [int]$parsed
		}
		'number' {
			$parsed = [double]0
			if ($Node.kind -eq 'scalar' -and $Node.typed -and ($Node.value -is [int] -or $Node.value -is [long] -or $Node.value -is [double] -or $Node.value -is [decimal] -or $Node.value -is [single])) {
				$parsed = [double]$Node.value
			}
			elseif ($Node.kind -eq 'scalar' -and -not $Node.typed -and -not $Node.quoted -and $Node.text -match '^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$' -and
				[double]::TryParse($Node.text, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$parsed)) {
			}
			else {
				& $typeError
				return $null
			}
			$value = $parsed
		}
		'bool' {
			if ($Node.kind -eq 'scalar' -and $Node.typed -and $Node.value -is [bool]) {
				$value = [bool]$Node.value
			}
			elseif ($Node.kind -eq 'scalar' -and -not $Node.typed -and -not $Node.quoted -and $Node.text -cin @('true', 'True', 'TRUE')) {
				$value = $true
			}
			elseif ($Node.kind -eq 'scalar' -and -not $Node.typed -and -not $Node.quoted -and $Node.text -cin @('false', 'False', 'FALSE')) {
				$value = $false
			}
			else {
				& $typeError
				return $null
			}
		}
		default {
			$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message "Невідомий тип схеми '$type'."))
			return $null
		}
	}
	if ($Schema.ContainsKey('Enum') -and $null -ne $Schema.Enum -and $type -eq 'string') {
		$match = @($Schema.Enum | Where-Object { $_ -eq $value }) | Select-Object -First 1
		if ($null -eq $match) {
			$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message ("Значення '{0}' не входить до допустимих: {1}." -f $value, ($Schema.Enum -join ', '))))
			return $null
		}
		$value = [string]$match
	}
	if ($type -in @('int', 'number')) {
		if ($Schema.ContainsKey('Min') -and $value -lt $Schema.Min) {
			$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message ("Значення {0} менше за мінімально допустиме {1}." -f $value, $Schema.Min)))
			return $null
		}
		if ($Schema.ContainsKey('Max') -and $value -gt $Schema.Max) {
			$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message ("Значення {0} більше за максимально допустиме {1}." -f $value, $Schema.Max)))
			return $null
		}
	}
	if ($Schema.Secret -and -not [string]::IsNullOrEmpty($value)) {
		if (-not (Test-IaSecretReference -Reference $value)) {
			$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message (
						"Секрети не зберігаються в YAML: значення має бути посиланням на захищене сховище або змінну середовища " +
						"(env:ІМ'Я_ЗМІННОЇ, secret:Ім'яСекрету, secret:Сховище/Ім'яСекрету).")))
			return $null
		}
	}
	if ($type -eq 'bool' -and $value -eq $false -and $Path -in $script:IaCliMandatoryDatasetPaths) {
		$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message "Обов'язковий набір даних '$($Path.Split('.')[-1])' не можна вимкнути: без нього аналіз неможливий."))
		return $null
	}
	return $value
}

function ConvertFrom-IaCliConfigNode {
	<# Перевіряє нейтральний вузол за вузлом схеми й повертає значення. Помилки додаються в Errors.
	   Partial — часткова конфігурація (параметри CLI): обов'язкові ключі не перевіряються, замовчування не додаються. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][hashtable]$Node,
		[Parameter(Mandatory)][hashtable]$Schema,
		[AllowEmptyString()][string]$Path = '',
		[System.Collections.Generic.List[object]]$Errors,
		[switch]$Partial
	)
	$type = $Schema.Type
	switch ($type) {
		'object' {
			if ($Node.kind -notin @('map', 'null')) {
				$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message ("Неправильний тип: очікується {0}, отримано {1}." -f $script:IaCliTypeNames.object, (Get-IaCliNodeDescription -Node $Node))))
				return $null
			}
			$properties = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
			foreach ($property in $Schema.Properties) {
				$properties[$property.Name] = $property
			}
			$result = [ordered]@{}
			$entries = if ($Node.kind -eq 'map') { $Node.entries } else { @() }
			foreach ($entry in $entries) {
				$key = $entry.key
				$keyPath = Join-IaCliPath -Parent $Path -Name $key
				if ($null -eq $key -or -not $properties.ContainsKey($key)) {
					$hint = ''
					if ($null -ne $key) {
						$similar = @($properties.Keys | Where-Object { $_ -ieq $key }) | Select-Object -First 1
						if ($similar) {
							$hint = " Можливо, мали на увазі '$similar' (ключі чутливі до регістру)."
						}
					}
					$Errors.Add((New-IaCliConfigError -Line $entry.keyLine -Column $entry.keyColumn -Path $keyPath -Message "Невідомий ключ '$key'.$hint"))
					continue
				}
				$before = $Errors.Count
				$value = ConvertFrom-IaCliConfigNode -Node $entry.node -Schema $properties[$key] -Path $keyPath -Errors $Errors -Partial:$Partial
				if ($Errors.Count -eq $before) {
					$result[$key] = $value
				}
			}
			if (-not $Partial) {
				foreach ($property in $Schema.Properties) {
					if ($result.Contains($property.Name)) {
						continue
					}
					if ($property.Required) {
						$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path (Join-IaCliPath -Parent $Path -Name $property.Name) -Message "Відсутній обов'язковий ключ '$($property.Name)'."))
					}
					elseif ($property.Type -eq 'object' -or $property.ContainsKey('Default')) {
						$result[$property.Name] = Get-IaCliSchemaDefault -Schema $property
					}
				}
			}
			return $result
		}
		'map' {
			if ($Node.kind -notin @('map', 'null')) {
				$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message ("Неправильний тип: очікується {0}, отримано {1}." -f $script:IaCliTypeNames.map, (Get-IaCliNodeDescription -Node $Node))))
				return $null
			}
			$result = [ordered]@{}
			$entries = if ($Node.kind -eq 'map') { $Node.entries } else { @() }
			foreach ($entry in $entries) {
				$key = $entry.key
				$keyPath = Join-IaCliPath -Parent $Path -Name $key
				if ([string]::IsNullOrWhiteSpace($key)) {
					$Errors.Add((New-IaCliConfigError -Line $entry.keyLine -Column $entry.keyColumn -Path $keyPath -Message "Порожнє або складене ім'я елемента словника."))
					continue
				}
				$before = $Errors.Count
				$value = ConvertFrom-IaCliConfigNode -Node $entry.node -Schema $Schema.Values -Path $keyPath -Errors $Errors -Partial:$Partial
				if ($Errors.Count -eq $before) {
					$result[$key] = $value
				}
			}
			return $result
		}
		'array' {
			if ($Node.kind -notin @('seq', 'null')) {
				$Errors.Add((New-IaCliConfigError -Line $Node.line -Column $Node.column -Path $Path -Message ("Неправильний тип: очікується {0}, отримано {1}." -f $script:IaCliTypeNames.array, (Get-IaCliNodeDescription -Node $Node))))
				return $null
			}
			$itemSchema = if ($Schema.Items -is [hashtable]) {
				$Schema.Items
			}
			else {
				$synthetic = @{ Name = 'item'; Type = $(if ($Schema.Items) { [string]$Schema.Items } else { 'string' }) }
				if ($Schema.ContainsKey('Enum')) {
					$synthetic.Enum = $Schema.Enum
				}
				$synthetic
			}
			$list = [System.Collections.Generic.List[object]]::new()
			$items = if ($Node.kind -eq 'seq') { $Node.items } else { @() }
			$index = 0
			foreach ($item in $items) {
				$before = $Errors.Count
				$value = ConvertFrom-IaCliConfigNode -Node $item -Schema $itemSchema -Path ('{0}[{1}]' -f $Path, $index) -Errors $Errors -Partial:$Partial
				if ($Errors.Count -eq $before) {
					$list.Add($value)
				}
				$index++
			}
			return , @($list.ToArray())
		}
		default {
			return ConvertFrom-IaCliScalar -Node $Node -Schema $Schema -Path $Path -Errors $Errors
		}
	}
}

function Merge-IaCliConfig {
	<# Глибоке злиття: значення Overlay перекривають Base; вкладені словники зливаються, масиви замінюються. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Base,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Overlay
	)
	$result = [ordered]@{}
	foreach ($key in $Base.Keys) {
		$result[$key] = $Base[$key]
	}
	foreach ($key in $Overlay.Keys) {
		$value = $Overlay[$key]
		if ($value -is [System.Collections.IDictionary] -and $result[$key] -is [System.Collections.IDictionary]) {
			$result[$key] = Merge-IaCliConfig -Base $result[$key] -Overlay $value
		}
		else {
			$result[$key] = $value
		}
	}
	return $result
}

function Read-IaCliConfigFile {
	<# Читає й перевіряє YAML-файл. Повертає @{ values (лише перевірені значення з файлу + замовчування); errors }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Path)
	$errors = [System.Collections.Generic.List[object]]::new()
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		$errors.Add((New-IaCliConfigError -Line $null -Column $null -Path '' -Message "Файл конфігурації не знайдено: $Path"))
		return @{ values = $null; errors = $errors }
	}
	$text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
	if ($null -eq $text) {
		$text = ''
	}
	$assembly = Get-IaCliYamlAssembly
	$reader = [System.IO.StringReader]::new($text)
	$rootNode = $null
	try {
		$parser = $assembly.GetType('YamlDotNet.Core.Parser')::new($reader)
		$stream = $assembly.GetType('YamlDotNet.RepresentationModel.YamlStream')::new()
		$stream.Load($parser)
		if ($stream.Documents.Count -gt 1) {
			$second = $stream.Documents[1].RootNode
			$errors.Add((New-IaCliConfigError -Line $second.Start.Line -Column $second.Start.Column -Path '' -Message 'Файл містить кілька документів YAML; підтримується лише один.'))
			return @{ values = $null; errors = $errors }
		}
		if ($stream.Documents.Count -eq 1) {
			$rootNode = $stream.Documents[0].RootNode
		}
	}
	catch {
		$exception = $_.Exception
		while ($null -ne $exception -and -not $exception.PSObject.Properties['Start']) {
			$exception = $exception.InnerException
		}
		$line = $null
		$column = $null
		$message = $_.Exception.Message
		if ($null -ne $exception) {
			$line = $exception.Start.Line
			$column = $exception.Start.Column
			$message = $exception.Message
		}
		$errors.Add((New-IaCliConfigError -Line $line -Column $column -Path '' -Message "Помилка синтаксису YAML: $message"))
		return @{ values = $null; errors = $errors }
	}
	finally {
		$reader.Dispose()
	}
	$node = ConvertFrom-IaCliYamlNode -Node $rootNode
	$values = ConvertFrom-IaCliConfigNode -Node $node -Schema (Get-IaConfigSchema) -Path '' -Errors $errors
	return @{ values = $values; errors = $errors }
}

function New-IaCliConfigErrorRecord {
	<# ErrorRecord з ErrorId IaConfigInvalid і TargetObject = масив помилок. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object[]]$Errors)
	$lines = foreach ($item in $Errors) {
		$position = if ($null -ne $item.line) { "рядок $($item.line), стовпець $($item.column)" } else { 'параметри командного рядка' }
		$target = if ($item.path) { " ($($item.path))" } else { '' }
		"  - ${position}${target}: $($item.message)"
	}
	$message = "Конфігурація недійсна:`n" + ($lines -join "`n")
	$exception = [System.ArgumentException]::new($message)
	return [System.Management.Automation.ErrorRecord]::new($exception, 'IaConfigInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, @($Errors))
}

function Get-IaConfig {
	<# YAML (powershell-yaml) + значення за замовчуванням + Overrides (з CLI, пріоритет). Перевірка за Shared/ConfigSchema.psd1 до запуску:
	   невідомі ключі, неправильні типи, enum, min/max, відкриті секрети — помилка з номером рядка.
	   Кидає виняток з ErrorId 'IaConfigInvalid' і TargetObject = масив @{ line; column; path; message }. #>
	[CmdletBinding()]
	param(
		[string]$Path,
		[System.Collections.IDictionary]$Overrides = @{}
	)
	$errors = [System.Collections.Generic.List[object]]::new()
	$config = Get-IaDefaultConfig
	if (-not [string]::IsNullOrWhiteSpace($Path)) {
		$read = Read-IaCliConfigFile -Path $Path
		foreach ($item in $read.errors) {
			$errors.Add($item)
		}
		if ($read.errors.Count -eq 0 -and $read.values -is [System.Collections.IDictionary]) {
			$config = Merge-IaCliConfig -Base $config -Overlay $read.values
		}
	}
	if ($null -ne $Overrides -and $Overrides.Count -gt 0) {
		$overrideNode = ConvertTo-IaCliValueNode -Value $Overrides
		$overrideValues = ConvertFrom-IaCliConfigNode -Node $overrideNode -Schema (Get-IaConfigSchema) -Path '' -Errors $errors -Partial
		if ($overrideValues -is [System.Collections.IDictionary]) {
			$config = Merge-IaCliConfig -Base $config -Overlay $overrideValues
		}
	}
	if ($errors.Count -gt 0) {
		$PSCmdlet.ThrowTerminatingError((New-IaCliConfigErrorRecord -Errors $errors.ToArray()))
	}
	return $config
}

function Test-IaConfig {
	<# Перевірка YAML без запуску. Повертає @{ isValid; errors = @(@{ line; column; path; message }) }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Path)
	$read = Read-IaCliConfigFile -Path $Path
	return [ordered]@{
		isValid = ($read.errors.Count -eq 0)
		errors = @($read.errors.ToArray())
	}
}

function Format-IaCliYamlScalar {
	<# Значення для шаблону YAML: рядки в одинарних лапках, числа в інваріантній культурі. #>
	param([AllowNull()]$Value, [string]$Type)
	if ($null -eq $Value) {
		return "''"
	}
	if ($Type -eq 'bool' -or $Value -is [bool]) {
		return $(if ($Value) { 'true' } else { 'false' })
	}
	if ($Type -in @('int', 'number')) {
		return ([System.Convert]::ToString($Value, [cultureinfo]::InvariantCulture))
	}
	return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-IaCliTemplateComment {
	<# Коментар до ключа шаблону: опис, допустимі значення, межі, обов'язковість, секрет. #>
	param([Parameter(Mandatory)][hashtable]$Schema)
	$parts = [System.Collections.Generic.List[string]]::new()
	$parts.Add(([string]$Schema.Description).TrimEnd('.') + '.')
	if ($Schema.ContainsKey('Enum') -and $Schema.Enum) {
		$parts.Add('Допустимі значення: ' + ($Schema.Enum -join ', ') + '.')
	}
	if ($Schema.ContainsKey('Min') -or $Schema.ContainsKey('Max')) {
		$parts.Add(('Межі: {0}..{1}.' -f $(if ($Schema.ContainsKey('Min')) { $Schema.Min } else { '' }), $(if ($Schema.ContainsKey('Max')) { $Schema.Max } else { '' })))
	}
	if ($Schema.Required) {
		$parts.Add("Обов'язковий.")
	}
	if ($Schema.Secret) {
		$parts.Add("Лише посилання на секрет: env:ІМ'Я_ЗМІННОЇ, secret:Ім'яСекрету або secret:Сховище/Ім'яСекрету.")
	}
	return ($parts -join ' ')
}

function Add-IaCliTemplateNode {
	<# Додає до шаблону YAML ключ схеми з коментарем і значенням (за замовчуванням або з прикладу). #>
	param(
		[Parameter(Mandatory)][hashtable]$Schema,
		[Parameter(Mandatory)][int]$Indent,
		[System.Collections.Generic.List[string]]$Lines,
		[System.Collections.IDictionary]$Example
	)
	$pad = ' ' * $Indent
	$name = $Schema.Name
	if ($Indent -eq 0) {
		$Lines.Add('')
	}
	$Lines.Add("$pad# $(Get-IaCliTemplateComment -Schema $Schema)")
	$hasExample = $null -ne $Example -and $Example.Contains($name)
	switch ($Schema.Type) {
		'object' {
			$Lines.Add("${pad}${name}:")
			$childExample = if ($hasExample) { $Example[$name] } else { $null }
			foreach ($child in $Schema.Properties) {
				Add-IaCliTemplateNode -Schema $child -Indent ($Indent + 2) -Lines $Lines -Example $childExample
			}
		}
		'map' {
			if (-not $Schema.Example -or $Schema.Example.Count -eq 0) {
				$Lines.Add("${pad}${name}: {}")
				break
			}
			$Lines.Add("${pad}${name}:")
			foreach ($exampleName in ($Schema.Example.Keys | Sort-Object)) {
				$Lines.Add("$pad  # Приклад: $($Schema.Values.Description).")
				$Lines.Add("$pad  ${exampleName}:")
				foreach ($child in $Schema.Values.Properties) {
					Add-IaCliTemplateNode -Schema $child -Indent ($Indent + 4) -Lines $Lines -Example $Schema.Example[$exampleName]
				}
			}
		}
		'array' {
			if ($Schema.Items -is [hashtable]) {
				$fields = foreach ($child in $Schema.Items.Properties) {
					$fieldText = "$($child.Name) — $(([string]$child.Description).TrimEnd('.'))"
					if ($child.Required) {
						$fieldText += " (обов'язковий)"
					}
					if ($child.ContainsKey('Min') -or $child.ContainsKey('Max')) {
						$fieldText += " [$($child.Min)..$($child.Max)]"
					}
					$fieldText
				}
				$Lines.Add("$pad# Поля елемента: $($fields -join '; ').")
			}
			$values = if ($hasExample) { @($Example[$name]) } else { @($Schema.Default | Where-Object { $null -ne $_ }) }
			$itemType = if ($Schema.Items -is [string]) { $Schema.Items } else { 'string' }
			if ($values.Count -eq 0) {
				$Lines.Add("${pad}${name}: []")
			}
			else {
				$Lines.Add("${pad}${name}:")
				foreach ($value in $values) {
					$Lines.Add("$pad  - $(Format-IaCliYamlScalar -Value $value -Type $itemType)")
				}
			}
		}
		default {
			$value = if ($hasExample) { $Example[$name] } elseif ($Schema.ContainsKey('Default')) { $Schema.Default } else { $null }
			$Lines.Add("${pad}${name}: $(Format-IaCliYamlScalar -Value $value -Type $Schema.Type)")
		}
	}
}

function New-IaConfigTemplate {
	<# Генерує шаблон YAML з усіма параметрами, значеннями за замовчуванням і коментарями зі схеми.
	   Без Path повертає текст; з Path записує файл (без -Force не перезаписує). #>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[string]$Path,
		[switch]$Force
	)
	$schema = Get-IaConfigSchema
	$lines = [System.Collections.Generic.List[string]]::new()
	$lines.Add("# $($schema.Description). Шаблон згенеровано New-IaConfigTemplate (IndexAdvisor $script:IaToolVersion).")
	$lines.Add('# Перевірка: Test-IaConfig -Path <файл>. Параметри командного рядка мають пріоритет над значеннями з файлу.')
	$lines.Add('# Секрети (паролі, API-ключі) тут не зберігаються — лише посилання env:ІМ''Я_ЗМІННОЇ або secret:Ім''яСекрету.')
	foreach ($property in $schema.Properties) {
		Add-IaCliTemplateNode -Schema $property -Indent 0 -Lines $lines
	}
	$text = ($lines -join "`n") + "`n"
	if ([string]::IsNullOrWhiteSpace($Path)) {
		return $text
	}
	if ((Test-Path -LiteralPath $Path) -and -not $Force) {
		throw "Файл '$Path' уже існує. Щоб перезаписати його, вкажіть -Force."
	}
	if ($PSCmdlet.ShouldProcess($Path, 'Записати шаблон конфігурації IndexAdvisor')) {
		$directory = Split-Path -Path $Path -Parent
		if ($directory -and -not (Test-Path -LiteralPath $directory)) {
			New-Item -ItemType Directory -Path $directory -Force | Out-Null
		}
		$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
		[System.IO.File]::WriteAllText($fullPath, $text, [System.Text.UTF8Encoding]::new($false))
		return Get-Item -LiteralPath $Path
	}
}
