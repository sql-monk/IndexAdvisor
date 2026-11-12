# Розбір T-SQL рекомендацій через ScriptDom (ConvertTo-IaSqlFragment, потік Core) у прості описи інструкцій.
# Типи ScriptDom не згадуються як літерали: збірка завантажується ліниво, тип визначається через GetType().Name.

function ConvertFrom-IaRuleSchemaObject {
	<# SchemaObjectName -> @{ schema; table } (схема за замовчуванням dbo). #>
	param([AllowNull()]$Name)
	if ($null -eq $Name -or $null -eq $Name.BaseIdentifier) {
		return $null
	}
	$schema = if ($Name.SchemaIdentifier) { [string]$Name.SchemaIdentifier.Value } else { 'dbo' }
	return [ordered]@{ schema = $schema; table = [string]$Name.BaseIdentifier.Value }
}

function Get-IaRuleColumnName {
	<# Ім'я колонки з ColumnReferenceExpression (останній ідентифікатор). #>
	param([AllowNull()]$ColumnReference)
	if ($null -eq $ColumnReference -or $null -eq $ColumnReference.MultiPartIdentifier) {
		return $null
	}
	$identifiers = $ColumnReference.MultiPartIdentifier.Identifiers
	return [string]$identifiers[$identifiers.Count - 1].Value
}

function Get-IaRuleIndexOptions {
	<# Опції індексу: ONLINE, RESUMABLE, DROP_EXISTING (On/Off) і DATA_COMPRESSION. #>
	param([AllowNull()]$Options)
	$result = [ordered]@{ online = $null; resumable = $null; dropExisting = $null; compression = $null }
	if ($null -eq $Options) {
		return $result
	}
	foreach ($option in $Options) {
		if ($null -eq $option) {
			continue
		}
		switch ([string]$option.OptionKind) {
			'Online' { $result.online = [string]$option.OptionState }
			'Resumable' { $result.resumable = [string]$option.OptionState }
			'DropExisting' { $result.dropExisting = [string]$option.OptionState }
			'DataCompression' { $result.compression = ([string]$option.CompressionLevel).ToUpperInvariant() }
		}
	}
	return $result
}

function Get-IaRuleFragmentIdentifiers {
	<# Ідентифікатори (імена колонок) у фрагменті, наприклад у фільтрі індексу. #>
	param([AllowNull()]$Fragment)
	$names = [System.Collections.Generic.List[string]]::new()
	if ($null -eq $Fragment -or $null -eq $Fragment.ScriptTokenStream) {
		return @()
	}
	for ($i = $Fragment.FirstTokenIndex; $i -le $Fragment.LastTokenIndex; $i++) {
		$token = $Fragment.ScriptTokenStream[$i]
		if ([string]$token.TokenType -in @('Identifier', 'QuotedIdentifier')) {
			$names.Add($token.Text.Trim([char[]]'[]"'))
		}
	}
	return $names.ToArray()
}

function Get-IaRuleFragmentText {
	<# Текст фрагмента з вихідного скрипта. #>
	param([AllowNull()]$Fragment, [string]$Sql)
	if ($null -eq $Fragment -or $Fragment.StartOffset -lt 0 -or $Fragment.StartOffset + $Fragment.FragmentLength -gt $Sql.Length) {
		return $null
	}
	return $Sql.Substring($Fragment.StartOffset, $Fragment.FragmentLength)
}

function Get-IaRuleDataSpace {
	<# Файлова група або схема секціонування з ON ...: @{ name; columns }. #>
	param([AllowNull()]$OnClause)
	if ($null -eq $OnClause -or $null -eq $OnClause.Name) {
		return [ordered]@{ name = $null; columns = @() }
	}
	$columns = @()
	if ($OnClause.PartitionSchemeColumns) {
		$columns = @($OnClause.PartitionSchemeColumns | ForEach-Object { [string]$_.Value })
	}
	return [ordered]@{ name = [string]$OnClause.Name.Value; columns = $columns }
}

function ConvertFrom-IaRuleStatement {
	<# Опис інструкції ScriptDom: @{ kind; schema; table; name; ... }. Невідомі інструкції — kind = ім'я типу ScriptDom. #>
	param([Parameter(Mandatory)]$Statement, [string]$Sql)
	$type = $Statement.GetType().Name
	$info = [ordered]@{ kind = $type; schema = $null; table = $null; name = $null }
	$setTable = {
		param($ObjectName)
		$parsed = ConvertFrom-IaRuleSchemaObject -Name $ObjectName
		if ($parsed) {
			$info.schema = $parsed.schema
			$info.table = $parsed.table
		}
	}
	switch ($type) {
		'CreateIndexStatement' {
			$info.kind = 'CreateIndex'
			. $setTable $Statement.OnName
			$info.name = [string]$Statement.Name.Value
			$info.clustered = $Statement.Clustered -eq $true
			$info.unique = [bool]$Statement.Unique
			$info.columnstore = $false
			$info.keys = @(foreach ($column in $Statement.Columns) { [ordered]@{ name = Get-IaRuleColumnName $column.Column; desc = [string]$column.SortOrder -eq 'Descending' } })
			$info.includes = @(foreach ($column in $Statement.IncludeColumns) { Get-IaRuleColumnName $column })
			$info.filter = Get-IaRuleFragmentText -Fragment $Statement.FilterPredicate -Sql $Sql
			$info.filterColumns = @(Get-IaRuleFragmentIdentifiers -Fragment $Statement.FilterPredicate)
			$info.options = Get-IaRuleIndexOptions -Options $Statement.IndexOptions
			$info.dataSpace = Get-IaRuleDataSpace -OnClause $Statement.OnFileGroupOrPartitionScheme
		}
		'CreateColumnStoreIndexStatement' {
			$info.kind = 'CreateColumnStoreIndex'
			. $setTable $Statement.OnName
			$info.name = [string]$Statement.Name.Value
			$info.clustered = [bool]$Statement.Clustered
			$info.unique = $false
			$info.columnstore = $true
			$info.keys = @()
			$info.includes = @(foreach ($column in $Statement.Columns) { Get-IaRuleColumnName $column })
			$info.filter = Get-IaRuleFragmentText -Fragment $Statement.FilterPredicate -Sql $Sql
			$info.filterColumns = @(Get-IaRuleFragmentIdentifiers -Fragment $Statement.FilterPredicate)
			$info.options = Get-IaRuleIndexOptions -Options $Statement.IndexOptions
			$info.dataSpace = Get-IaRuleDataSpace -OnClause $Statement.OnFileGroupOrPartitionScheme
		}
		'DropIndexStatement' {
			$info.kind = 'DropIndex'
			$info.clauses = @(foreach ($clause in $Statement.DropIndexClauses) {
					if ($clause.GetType().Name -eq 'DropIndexClause') {
						$object = ConvertFrom-IaRuleSchemaObject -Name $clause.Object
						[ordered]@{ index = [string]$clause.Index.Value; schema = $object.schema; table = $object.table }
					}
					else {
						$child = $clause.Index
						[ordered]@{
							index = [string]$child.ChildIdentifier.Value
							schema = $(if ($child.SchemaIdentifier) { [string]$child.SchemaIdentifier.Value } else { 'dbo' })
							table = [string]$child.BaseIdentifier.Value
						}
					}
				})
			if ($info.clauses.Count -gt 0) {
				$info.schema = $info.clauses[0].schema
				$info.table = $info.clauses[0].table
				$info.name = $info.clauses[0].index
			}
		}
		'AlterIndexStatement' {
			$info.kind = 'AlterIndex'
			. $setTable $Statement.OnName
			$info.all = [bool]$Statement.All
			$info.name = if ($Statement.All -or $null -eq $Statement.Name) { $null } else { [string]$Statement.Name.Value }
			$info.alterType = [string]$Statement.AlterIndexType
			$info.options = Get-IaRuleIndexOptions -Options $Statement.IndexOptions
		}
		'CreatePartitionFunctionStatement' {
			$info.kind = 'CreatePartitionFunction'
			$info.name = [string]$Statement.Name.Value
			$info.boundaryCount = @($Statement.BoundaryValues).Count
		}
		'CreatePartitionSchemeStatement' {
			$info.kind = 'CreatePartitionScheme'
			$info.name = [string]$Statement.Name.Value
			$info.function = [string]$Statement.PartitionFunction.Value
		}
		'AlterPartitionFunctionStatement' {
			$info.kind = 'AlterPartitionFunction'
			$info.name = [string]$Statement.Name.Value
			$info.isSplit = [bool]$Statement.IsSplit
		}
		'AlterPartitionSchemeStatement' {
			$info.kind = 'AlterPartitionScheme'
			$info.name = [string]$Statement.Name.Value
		}
		'DropPartitionFunctionStatement' {
			$info.kind = 'DropPartitionFunction'
			$info.name = [string]$Statement.Name.Value
		}
		'DropPartitionSchemeStatement' {
			$info.kind = 'DropPartitionScheme'
			$info.name = [string]$Statement.Name.Value
		}
		'AlterTableAddTableElementStatement' {
			$info.kind = 'AlterTableAdd'
			. $setTable $Statement.SchemaObjectName
			$definition = $Statement.Definition
			$info.constraintsOnly = (@($definition.ColumnDefinitions).Count -eq 0 -and @($definition.Indexes).Count -eq 0)
			$info.constraints = @(foreach ($constraint in $definition.TableConstraints) {
					$constraintType = $constraint.GetType().Name
					$entry = [ordered]@{
						type = $constraintType
						name = $(if ($constraint.ConstraintIdentifier) { [string]$constraint.ConstraintIdentifier.Value } else { $null })
						isPrimaryKey = $false; unique = $false; clustered = $false; keys = @(); options = (Get-IaRuleIndexOptions -Options $null)
						dataSpace = [ordered]@{ name = $null; columns = @() }
					}
					if ($constraintType -eq 'UniqueConstraintDefinition') {
						$entry.isPrimaryKey = [bool]$constraint.IsPrimaryKey
						$entry.unique = $true
						$entry.clustered = if ($null -eq $constraint.Clustered) { [bool]$constraint.IsPrimaryKey } else { [bool]$constraint.Clustered }
						$entry.keys = @(foreach ($column in $constraint.Columns) { [ordered]@{ name = Get-IaRuleColumnName $column.Column; desc = [string]$column.SortOrder -eq 'Descending' } })
						$entry.options = Get-IaRuleIndexOptions -Options $constraint.IndexOptions
						$entry.dataSpace = Get-IaRuleDataSpace -OnClause $constraint.OnFileGroupOrPartitionScheme
					}
					elseif ($constraintType -eq 'ForeignKeyConstraintDefinition') {
						$entry.keys = @(foreach ($column in $constraint.Columns) { [ordered]@{ name = [string]$column.Value; desc = $false } })
						$entry.referencedTable = ConvertFrom-IaRuleSchemaObject -Name $constraint.ReferenceTableName
					}
					$entry
				})
		}
		'AlterTableDropTableElementStatement' {
			$info.kind = 'AlterTableDrop'
			. $setTable $Statement.SchemaObjectName
			$info.elements = @(foreach ($element in $Statement.AlterTableDropTableElements) { [ordered]@{ type = [string]$element.TableElementType; name = [string]$element.Name.Value } })
			$info.constraintsOnly = @($info.elements | Where-Object { $_.type -ne 'Constraint' }).Count -eq 0
		}
	}
	return $info
}

function Test-IaRuleExistenceGuard {
	<# $true, якщо IF — лише перевірка існування об'єкта без ELSE: умова читає тільки системні каталоги (sys.*, INFORMATION_SCHEMA)
	   і вбудовані функції (OBJECT_ID, INDEXPROPERTY …) — та сама перевірка джерел, що й для запитів колектора. #>
	param([Parameter(Mandatory)]$Statement)
	if ($Statement.GetType().Name -ne 'IfStatement' -or $null -ne $Statement.ElseStatement -or $null -eq $Statement.Predicate) {
		return $false
	}
	$sources = Test-IaCoreSourcesParsed -Parsed ([ordered]@{ errors = @(); fragment = $Statement.Predicate })
	return [bool]$sources.isValid
}

function Expand-IaRuleGuardedStatements {
	<# Інструкції з урахуванням ідемпотентних обгорток: тіло IF [NOT] EXISTS (...) BEGIN … END розгортається (рекурсивно), кожна вкладена
	   інструкція позначається guarded = $true. IF з іншою умовою чи з ELSE залишається інструкцією IfStatement (перевірка її відхиляє). #>
	param([Parameter(Mandatory)]$Statement, [string]$Sql, [AllowNull()][string]$Guard)
	if (Test-IaRuleExistenceGuard -Statement $Statement) {
		$guardText = Get-IaRuleFragmentText -Fragment $Statement.Predicate -Sql $Sql
		$inner = $Statement.ThenStatement
		$children = if ($inner.GetType().Name -eq 'BeginEndBlockStatement') { @($inner.StatementList.Statements) } else { @($inner) }
		foreach ($child in @($children | Where-Object { $null -ne $_ })) {
			Expand-IaRuleGuardedStatements -Statement $child -Sql $Sql -Guard $guardText
		}
		return
	}
	$info = ConvertFrom-IaRuleStatement -Statement $Statement -Sql $Sql
	if ($Guard) {
		$info.guarded = $true
		$info.guard = $Guard
	}
	$info
}

function Get-IaRuleScriptInfo {
	<# Розбір скрипта: @{ isBlank; parsed; errors; statements; parserName; exception }.
	   Ідемпотентні обгортки IF [NOT] EXISTS із системних каталогів розгортаються (Expand-IaRuleGuardedStatements). #>
	param([AllowNull()][AllowEmptyString()][string]$Sql)
	$result = [ordered]@{ isBlank = [string]::IsNullOrWhiteSpace($Sql); parsed = $false; errors = @(); statements = @(); parserName = $null; exception = $null }
	if ($result.isBlank) {
		return $result
	}
	try {
		$parse = ConvertTo-IaSqlFragment -Sql $Sql
	}
	catch {
		$result.exception = $_.Exception.Message
		return $result
	}
	$result.parserName = [string]$parse.parserName
	$result.errors = @($parse.errors | Where-Object { $null -ne $_ })
	if ($result.errors.Count -gt 0 -or $null -eq $parse.fragment) {
		return $result
	}
	$statements = [System.Collections.Generic.List[object]]::new()
	foreach ($batch in $parse.fragment.Batches) {
		foreach ($statement in $batch.Statements) {
			foreach ($info in @(Expand-IaRuleGuardedStatements -Statement $statement -Sql $Sql -Guard $null)) {
				$statements.Add($info)
			}
		}
	}
	$result.parsed = $true
	$result.statements = $statements.ToArray()
	return $result
}

function Format-IaRuleParseErrors {
	<# Помилки розбору у вигляді тексту. #>
	param([object[]]$Errors)
	return (@($Errors | Select-Object -First 3 | ForEach-Object {
				$line = if ($_ -is [System.Collections.IDictionary]) { $_['line'] } else { $_.line }
				$column = if ($_ -is [System.Collections.IDictionary]) { $_['column'] } else { $_.column }
				$message = if ($_ -is [System.Collections.IDictionary]) { $_['message'] } else { $_.message }
				"рядок $line, стовпець ${column}: $message"
			}) -join '; ')
}
