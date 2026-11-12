# Ліниве завантаження ScriptDom і робота з AST T-SQL (потік Core, CONTRACTS.md 3.1).
# Типи ScriptDom не вживаються в атрибутах параметрів і як літерали типів: збірка завантажується лише під час першого виклику.

$script:IaCoreScriptDom = $null
$script:IaCoreScriptDomName = 'Microsoft.SqlServer.TransactSql.ScriptDom'
$script:IaCoreFragmentPropertyCache = @{}

function Get-IaCoreLoadedAssembly {
	<# Найновіша вже завантажена збірка з указаним іменем або $null. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Name)
	return [System.AppDomain]::CurrentDomain.GetAssemblies() |
		Where-Object { $_.GetName().Name -eq $Name } |
		Sort-Object -Property { $_.GetName().Version } -Descending |
		Select-Object -First 1
}

function Get-IaCoreDbatoolsLibraryBase {
	<# Каталог модуля dbatools.library: уже імпортованого, інакше найновішого доступного. $null, якщо модуля немає. #>
	[CmdletBinding()]
	param()
	$module = Get-Module -Name 'dbatools.library' | Sort-Object -Property Version -Descending | Select-Object -First 1
	if ($null -eq $module) {
		$module = Get-Module -ListAvailable -Name 'dbatools.library' | Sort-Object -Property Version -Descending | Select-Object -First 1
	}
	if ($null -eq $module) {
		return $null
	}
	return $module.ModuleBase
}

function Initialize-IaCoreScriptDom {
	<# Завантажує ScriptDom (якщо тип ще не завантажено — з dbatools.library\core\lib) і кешує типи
	   найновішого парсера TSqlNNNParser (не нижче 150) та відповідного генератора скриптів. #>
	[CmdletBinding()]
	param()
	if ($null -ne $script:IaCoreScriptDom) {
		return $script:IaCoreScriptDom
	}
	$assembly = Get-IaCoreLoadedAssembly -Name $script:IaCoreScriptDomName
	if ($null -eq $assembly) {
		$libraryBase = Get-IaCoreDbatoolsLibraryBase
		if (-not $libraryBase) {
			throw [System.InvalidOperationException]::new('Не знайдено ScriptDom: модуль dbatools.library не встановлено.')
		}
		$path = Join-Path -Path $libraryBase -ChildPath 'core\lib\Microsoft.SqlServer.TransactSql.ScriptDom.dll'
		if (-not (Test-Path -LiteralPath $path)) {
			throw [System.InvalidOperationException]::new("Не знайдено збірку ScriptDom: '$path'.")
		}
		Add-Type -LiteralPath $path
		$assembly = Get-IaCoreLoadedAssembly -Name $script:IaCoreScriptDomName
	}
	$parserTypes = foreach ($type in $assembly.GetExportedTypes()) {
		if ($type.Name -match '^TSql(\d+)Parser$' -and [int]$Matches[1] -ge 150) {
			[pscustomobject]@{ Version = [int]$Matches[1]; Type = $type }
		}
	}
	$parser = $parserTypes | Sort-Object -Property Version -Descending | Select-Object -First 1
	if ($null -eq $parser) {
		throw [System.InvalidOperationException]::new('У збірці ScriptDom немає парсера TSql150Parser або новішого.')
	}
	$generatorType = $assembly.GetType("$($script:IaCoreScriptDomName).Sql$($parser.Version)ScriptGenerator")
	if ($null -eq $generatorType) {
		$generatorType = $assembly.GetExportedTypes() |
			Where-Object { $_.Name -match '^Sql(\d+)ScriptGenerator$' } |
			Sort-Object -Property { [int]($_.Name -replace '\D', '') } -Descending |
			Select-Object -First 1
	}
	$script:IaCoreScriptDom = [ordered]@{
		assembly = $assembly
		parserType = $parser.Type
		parserName = $parser.Type.Name
		generatorType = $generatorType
		fragmentType = $assembly.GetType("$($script:IaCoreScriptDomName).TSqlFragment")
	}
	return $script:IaCoreScriptDom
}

function Get-IaScriptDomParser {
	<# Завантажує Microsoft.SqlServer.TransactSql.ScriptDom (з dbatools.library, якщо тип ще не завантажено)
	   і повертає екземпляр найновішого TSqlNNNParser. #>
	[CmdletBinding()]
	param([bool]$InitialQuotedIdentifiers = $true)
	$dom = Initialize-IaCoreScriptDom
	return $dom.parserType::new($InitialQuotedIdentifiers)
}

function ConvertTo-IaSqlFragment {
	<# Розбір T-SQL найновішим доступним парсером ScriptDom (не нижче TSql150Parser).
	   Повертає @{ fragment = TSqlFragment|$null; errors = @(New-IaError ...); parserName }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Sql)
	$parser = Get-IaScriptDomParser
	$parseErrors = $null
	$reader = [System.IO.StringReader]::new($Sql)
	try {
		$fragment = $parser.Parse($reader, [ref]$parseErrors)
	}
	finally {
		$reader.Dispose()
	}
	$errors = @(foreach ($parseError in @($parseErrors)) {
			if ($null -ne $parseError) {
				New-IaError -Code 'SqlError' -Message ("Помилка розбору T-SQL {0}: {1}" -f $parseError.Number, $parseError.Message) -Line $parseError.Line -Column $parseError.Column
			}
		})
	return [ordered]@{
		fragment = $(if ($errors.Count -gt 0) { $null } else { $fragment })
		errors = $errors
		parserName = $parser.GetType().Name
	}
}

function Get-IaCoreFragmentNodes {
	<# Усі вузли AST (сам фрагмент і всі вкладені TSqlFragment) — обхід через рефлексію без класів-візиторів. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$Fragment)
	$fragmentType = (Initialize-IaCoreScriptDom).fragmentType
	$nodes = [System.Collections.Generic.List[object]]::new()
	$stack = [System.Collections.Generic.Stack[object]]::new()
	$stack.Push($Fragment)
	while ($stack.Count -gt 0) {
		$node = $stack.Pop()
		$nodes.Add($node)
		$nodeType = $node.GetType()
		$properties = $script:IaCoreFragmentPropertyCache[$nodeType]
		if ($null -eq $properties) {
			$properties = @($nodeType.GetProperties([System.Reflection.BindingFlags]'Public, Instance') | Where-Object {
					$_.CanRead -and $_.Name -ne 'ScriptTokenStream' -and $_.GetIndexParameters().Count -eq 0 -and (
						$fragmentType.IsAssignableFrom($_.PropertyType) -or (
							$_.PropertyType.IsGenericType -and $_.PropertyType.GetGenericArguments().Count -eq 1 -and
							$fragmentType.IsAssignableFrom($_.PropertyType.GetGenericArguments()[0])))
				})
			$script:IaCoreFragmentPropertyCache[$nodeType] = $properties
		}
		foreach ($property in $properties) {
			$value = $property.GetValue($node)
			if ($null -eq $value) {
				continue
			}
			if ($fragmentType.IsInstanceOfType($value)) {
				$stack.Push($value)
				continue
			}
			foreach ($item in $value) {
				if ($null -ne $item -and $fragmentType.IsInstanceOfType($item)) {
					$stack.Push($item)
				}
			}
		}
	}
	return , $nodes
}

function Get-IaCoreStatements {
	<# Усі інструкції верхнього рівня з усіх батчів TSqlScript. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$Fragment)
	$statements = [System.Collections.Generic.List[object]]::new()
	foreach ($batch in @($Fragment.Batches)) {
		foreach ($statement in @($batch.Statements)) {
			if ($null -ne $statement) {
				$statements.Add($statement)
			}
		}
	}
	return , $statements
}

function New-IaCoreDomObject {
	<# Створює вузол ScriptDom за коротким іменем типу і заповнює властивості. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$TypeName,
		[System.Collections.IDictionary]$Property = @{}
	)
	$dom = Initialize-IaCoreScriptDom
	$type = $dom.assembly.GetType("$($script:IaCoreScriptDomName).$TypeName", $true)
	$instance = [System.Activator]::CreateInstance($type)
	foreach ($key in $Property.Keys) {
		$instance.$key = $Property[$key]
	}
	return $instance
}

function New-IaCoreIntegerLiteral {
	<# Цілочисловий літерал ScriptDom (значення обчислює програма, не користувач). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][long]$Value)
	return New-IaCoreDomObject -TypeName 'IntegerLiteral' -Property @{ Value = $Value.ToString([cultureinfo]::InvariantCulture) }
}

function Get-IaCoreIntegerValue {
	<# Значення цілочислового літерала (з урахуванням дужок) або $null для інших виразів. #>
	[CmdletBinding()]
	param([AllowNull()][object]$Expression)
	$current = $Expression
	while ($null -ne $current -and $current.GetType().Name -eq 'ParenthesisExpression') {
		$current = $current.Expression
	}
	if ($null -ne $current -and $current.GetType().Name -eq 'IntegerLiteral') {
		$parsed = [long]0
		if ([long]::TryParse($current.Value, [System.Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture, [ref]$parsed)) {
			return $parsed
		}
	}
	return $null
}

function ConvertTo-IaCoreSqlText {
	<# Генерує T-SQL з AST генератором, що відповідає версії парсера. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$Fragment)
	$dom = Initialize-IaCoreScriptDom
	$generator = $dom.generatorType::new()
	$generator.Options.IncludeSemicolons = $true
	$text = $null
	$generator.GenerateScript($Fragment, [ref]$text)
	return $text.Trim()
}
