# Перевірки тексту запиту перед виконанням (потік Core, розділ 4.7 ТЗ «Обмеження доступу»).
# Будь-яка помилка розбору або перевірки — запит невалідний (fail closed).

$script:IaCoreSystemSchemas = @('sys', 'INFORMATION_SCHEMA')
$script:IaCoreXmlMethods = @('value', 'query', 'exist', 'nodes')
$script:IaCoreSystemClrTypes = @('geography', 'geometry', 'hierarchyid')
$script:IaCoreReadOnlyStatementTypes = @('SelectStatement', 'DeclareVariableStatement', 'SetVariableStatement')
$script:IaCoreUncheckedTableReferences = @(
	'QueryDerivedTable', 'InlineDerivedTable', 'JoinParenthesisTableReference', 'QualifiedJoin', 'UnqualifiedJoin',
	'OdbcQualifiedJoinTableReference', 'PivotedTableReference', 'UnpivotedTableReference', 'GlobalFunctionTableReference',
	'BuiltInFunctionTableReference', 'OpenJsonTableReference', 'OpenXmlTableReference', 'VariableMethodCallTableReference'
)

function Get-IaCoreStatementKind {
	<# Зрозуміла назва типу інструкції для повідомлень. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$Statement)
	return ($Statement.GetType().Name -replace 'Statement$', '')
}

function Test-IaCoreSelectOnlyParsed {
	<# Перевірка «рівно один батч, рівно одна SelectStatement без INTO» за результатом ConvertTo-IaSqlFragment. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Parsed)
	$errors = [System.Collections.Generic.List[object]]::new()
	if (@($Parsed.errors).Count -gt 0 -or $null -eq $Parsed.fragment) {
		foreach ($parseError in @($Parsed.errors)) {
			$errors.Add((New-IaError -Code 'NotSingleSelect' -Message ("Текст не розбирається ScriptDom ({0}): {1}" -f $Parsed.parserName, $parseError.message) -Line $parseError.line -Column $parseError.column))
		}
		if ($errors.Count -eq 0) {
			$errors.Add((New-IaError -Code 'NotSingleSelect' -Message 'Текст не розбирається ScriptDom.'))
		}
		return [ordered]@{ isValid = $false; statementCount = 0; errors = $errors.ToArray() }
	}
	$batches = @($Parsed.fragment.Batches)
	$statements = Get-IaCoreStatements -Fragment $Parsed.fragment
	if ($batches.Count -gt 1) {
		$errors.Add((New-IaError -Code 'NotSingleSelect' -Message ("Очікується рівно один батч, знайдено {0} (розділювач GO заборонено)." -f $batches.Count)))
	}
	if ($statements.Count -eq 0) {
		$errors.Add((New-IaError -Code 'NotSingleSelect' -Message 'Текст не містить жодної інструкції SELECT.'))
	}
	elseif ($statements.Count -gt 1) {
		$errors.Add((New-IaError -Code 'NotSingleSelect' -Message ("Очікується рівно одна інструкція SELECT, знайдено {0}." -f $statements.Count)))
	}
	foreach ($statement in $statements) {
		$typeName = $statement.GetType().Name
		if ($typeName -ne 'SelectStatement') {
			$errors.Add((New-IaError -Code 'NotSingleSelect' -Message ("Інструкцію {0} заборонено: дозволено лише одну інструкцію SELECT." -f (Get-IaCoreStatementKind -Statement $statement)) -Line $statement.StartLine -Column $statement.StartColumn))
		}
		elseif ($null -ne $statement.Into) {
			$errors.Add((New-IaError -Code 'NotSingleSelect' -Message 'SELECT INTO заборонено: програма не створює жодних об''єктів.' -Line $statement.StartLine -Column $statement.StartColumn))
		}
	}
	return [ordered]@{ isValid = ($errors.Count -eq 0); statementCount = $statements.Count; errors = $errors.ToArray() }
}

function Test-IaCoreReadOnlyParsed {
	<# Запобіжник для unsafe.disableSelectCheck: навіть тоді дозволено лише один батч з інструкціями читання
	   (SELECT без INTO, DECLARE і SET змінної). Повертає масив помилок (порожній — перевірку пройдено). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Parsed)
	$errors = [System.Collections.Generic.List[object]]::new()
	if (@($Parsed.errors).Count -gt 0 -or $null -eq $Parsed.fragment) {
		$errors.Add((New-IaError -Code 'NotSingleSelect' -Message 'Текст не розбирається ScriptDom; виконання заборонено навіть при unsafe.disableSelectCheck.'))
		return $errors.ToArray()
	}
	$batches = @($Parsed.fragment.Batches)
	$statements = Get-IaCoreStatements -Fragment $Parsed.fragment
	if ($batches.Count -gt 1) {
		$errors.Add((New-IaError -Code 'NotSingleSelect' -Message ("Очікується рівно один батч, знайдено {0} (розділювач GO заборонено)." -f $batches.Count)))
	}
	if ($statements.Count -eq 0) {
		$errors.Add((New-IaError -Code 'NotSingleSelect' -Message 'Текст не містить жодної інструкції.'))
	}
	foreach ($statement in $statements) {
		$typeName = $statement.GetType().Name
		if ($typeName -notin $script:IaCoreReadOnlyStatementTypes -or ($typeName -eq 'SelectStatement' -and $null -ne $statement.Into)) {
			$errors.Add((New-IaError -Code 'NotSingleSelect' -Message ("Інструкцію {0} заборонено навіть при unsafe.disableSelectCheck: програма ніколи не змінює цільові бази." -f (Get-IaCoreStatementKind -Statement $statement)) -Line $statement.StartLine -Column $statement.StartColumn))
		}
	}
	return $errors.ToArray()
}

function Get-IaCoreObjectNameText {
	<# Повне ім'я SchemaObjectName для повідомлень. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][object]$Name)
	return (@($Name.Identifiers) | ForEach-Object { $_.Value }) -join '.'
}

function Test-IaCoreSystemObjectName {
	<# Помилка (рядок) або $null: джерело має бути sys.* чи INFORMATION_SCHEMA.* (з префіксом бази чи без) або CTE цього запиту. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][object]$Name,
		[Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$CteNames,
		[string]$Kind = 'Джерело'
	)
	$fullName = Get-IaCoreObjectNameText -Name $Name
	if ($null -ne $Name.ServerIdentifier) {
		return "$Kind '$fullName' звертається до зв'язаного сервера — заборонено."
	}
	if ($null -eq $Name.SchemaIdentifier -and $null -eq $Name.DatabaseIdentifier -and $null -ne $Name.BaseIdentifier -and $CteNames.Contains($Name.BaseIdentifier.Value)) {
		return $null
	}
	if ($null -ne $Name.SchemaIdentifier -and $Name.SchemaIdentifier.Value -in $script:IaCoreSystemSchemas) {
		return $null
	}
	return "$Kind '$fullName' не є системним каталогом: дозволено лише sys.*, INFORMATION_SCHEMA.*, CTE цього запиту і вбудовані функції."
}

function Test-IaCoreSourcesParsed {
	<# Перевірка джерел за результатом ConvertTo-IaSqlFragment. Повертає @{ isValid; errors }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Parsed)
	$errors = [System.Collections.Generic.List[object]]::new()
	if (@($Parsed.errors).Count -gt 0 -or $null -eq $Parsed.fragment) {
		$errors.Add((New-IaError -Code 'ForbiddenSource' -Message 'Неможливо перевірити джерела: текст не розбирається ScriptDom.'))
		return [ordered]@{ isValid = $false; errors = $errors.ToArray() }
	}
	$nodes = Get-IaCoreFragmentNodes -Fragment $Parsed.fragment
	$cteNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($node in $nodes) {
		if ($node.GetType().Name -eq 'CommonTableExpression' -and $null -ne $node.ExpressionName) {
			[void]$cteNames.Add($node.ExpressionName.Value)
		}
	}
	foreach ($node in $nodes) {
		$typeName = $node.GetType().Name
		$message = $null
		switch -Regex ($typeName) {
			'^NamedTableReference$' {
				$message = Test-IaCoreSystemObjectName -Name $node.SchemaObject -CteNames $cteNames
				break
			}
			'^SchemaObjectFunctionTableReference$' {
				$name = $node.SchemaObject
				$identifiers = @($name.Identifiers)
				$isXmlMethod = $identifiers.Count -ge 2 -and $null -eq $name.ServerIdentifier -and $name.BaseIdentifier.Value -in $script:IaCoreXmlMethods -and
					-not ($null -ne $name.SchemaIdentifier -and $name.SchemaIdentifier.Value -in $script:IaCoreSystemSchemas)
				if (-not $isXmlMethod) {
					$message = Test-IaCoreSystemObjectName -Name $name -CteNames ([System.Collections.Generic.HashSet[string]]::new()) -Kind 'Таблична функція'
				}
				break
			}
			'^FunctionCall$' {
				$target = $node.CallTarget
				if ($null -eq $target) {
					break
				}
				$functionName = $node.FunctionName.Value
				switch ($target.GetType().Name) {
					'MultiPartIdentifierCallTarget' {
						$parts = @($target.MultiPartIdentifier.Identifiers | ForEach-Object { $_.Value })
						$isSystem = $parts.Count -le 2 -and $parts[-1] -in $script:IaCoreSystemSchemas
						if (-not $isSystem -and $functionName -notin $script:IaCoreXmlMethods) {
							$message = "Функцію '{0}.{1}' заборонено: дозволено лише вбудовані та системні (sys.*) функції." -f ($parts -join '.'), $functionName
						}
					}
					'ExpressionCallTarget' {
					}
					'UserDefinedTypeCallTarget' {
						$typeName2 = $target.SchemaObjectName
						if ($null -ne $typeName2.SchemaIdentifier -or $typeName2.BaseIdentifier.Value -notin $script:IaCoreSystemClrTypes) {
							$message = "Виклик методу типу '{0}' заборонено." -f (Get-IaCoreObjectNameText -Name $typeName2)
						}
					}
					default {
						$message = "Виклик функції '$functionName' заборонено."
					}
				}
				break
			}
			'^NextValueForExpression$' {
				$message = 'NEXT VALUE FOR заборонено: послідовність змінюється під час читання.'
				break
			}
			'^(ExecuteStatement|ExecuteInsertSource|ExecutableProcedureReference|ExecutableStringList|ExecuteSpecification)$' {
				$message = 'EXEC/EXECUTE (зокрема sp_executesql) заборонено.'
				break
			}
			'^(OpenRowset|OpenQuery|AdHoc|BulkOpenRowset|InternalOpenRowset)' {
				$message = 'OPENROWSET, OPENQUERY і OPENDATASOURCE заборонено: дозволено лише системні каталоги.'
				break
			}
			'^VariableTableReference$' {
				$message = 'Таблична змінна як джерело заборонена: дозволено лише системні каталоги.'
				break
			}
			'^DataModificationTableReference$' {
				$message = 'Вкладена інструкція зміни даних заборонена.'
				break
			}
			'TableReference$' {
				if ($typeName -in $script:IaCoreUncheckedTableReferences) {
					break
				}
				foreach ($property in $node.GetType().GetProperties()) {
					if ($property.PropertyType.Name -eq 'SchemaObjectName') {
						$objectName = $property.GetValue($node)
						if ($null -ne $objectName) {
							$message = Test-IaCoreSystemObjectName -Name $objectName -CteNames $cteNames
							if ($message) {
								break
							}
						}
					}
				}
				break
			}
		}
		if ($message) {
			$errors.Add((New-IaError -Code 'ForbiddenSource' -Message $message -Line $node.StartLine -Column $node.StartColumn))
		}
	}
	return [ordered]@{ isValid = ($errors.Count -eq 0); errors = $errors.ToArray() }
}

function Test-IaSelectOnly {
	<# Розбір ScriptDom: рівно один батч і рівно одна інструкція SELECT без INTO.
	   Повертає @{ isValid; statementCount; errors = @(New-IaError ...) }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Sql)
	try {
		$parsed = ConvertTo-IaSqlFragment -Sql $Sql
		return Test-IaCoreSelectOnlyParsed -Parsed $parsed
	}
	catch {
		return [ordered]@{
			isValid = $false
			statementCount = 0
			errors = @(New-IaError -Code 'NotSingleSelect' -Message ("Перевірку SELECT не виконано: {0}" -f $_.Exception.Message))
		}
	}
}

function Test-IaSystemSourcesOnly {
	<# Джерела лише sys.*, INFORMATION_SCHEMA.*, CTE цього ж запиту та вбудовані функції; OPENROWSET/OPENQUERY/OPENDATASOURCE,
	   користувацькі таблиці, функції і NEXT VALUE FOR заборонені. Повертає @{ isValid; errors }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Sql)
	try {
		$parsed = ConvertTo-IaSqlFragment -Sql $Sql
		return Test-IaCoreSourcesParsed -Parsed $parsed
	}
	catch {
		return [ordered]@{
			isValid = $false
			errors = @(New-IaError -Code 'ForbiddenSource' -Message ("Перевірку джерел не виконано: {0}" -f $_.Exception.Message))
		}
	}
}
