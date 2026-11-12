# Автоматична перевірка рекомендацій моделі (розділ 4.8 ТЗ; CONTRACTS.md, розділ 3.5; id перевірок — recommendation.schema.json).

$script:IaRuleAllowedStatements = @{
	CreateIndex = @{ execute = @('CreateIndex', 'CreateColumnStoreIndex'); rollback = @('DropIndex') }
	DropIndex = @{ execute = @('DropIndex'); rollback = @('CreateIndex', 'CreateColumnStoreIndex') }
	AlterIndex = @{
		execute = @('AlterIndex', 'CreateIndex', 'CreateColumnStoreIndex', 'DropIndex')
		rollback = @('AlterIndex', 'CreateIndex', 'CreateColumnStoreIndex', 'DropIndex')
	}
	Partitioning = @(
		'CreatePartitionFunction', 'CreatePartitionScheme', 'AlterPartitionFunction', 'AlterPartitionScheme', 'DropPartitionFunction',
		'DropPartitionScheme', 'CreateIndex', 'CreateColumnStoreIndex', 'AlterIndex', 'DropIndex', 'AlterTableAdd', 'AlterTableDrop'
	)
}

function Test-IaRuleStatementOnTable {
	<# Чи стосується інструкція таблиці schema.table. #>
	param([Parameter(Mandatory)]$Statement, [string]$Schema, [string]$Table)
	return ($Statement.table -eq $Table -and $Statement.schema -eq $Schema)
}

function Get-IaRuleIndexDefinitionFromSnapshot {
	<# Визначення наявного індексу в тому ж вигляді, що й опис CREATE зі ScriptInfo. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Index)
	$columnstore = ([string]$Index['typeDesc']) -like '*COLUMNSTORE*'
	return [ordered]@{
		name = [string]$Index['name']
		clustered = ([string]$Index['typeDesc']) -like 'CLUSTERED*'
		unique = [bool]($Index['isUnique'] -or $Index['isUniqueConstraint'] -or $Index['isPrimaryKey'])
		columnstore = $columnstore
		keys = $(if ($columnstore) { @() } else { @(Get-IaRuleKeyColumns -Index $Index) })
		includes = $(if ($columnstore) { @(@($Index['keyColumns']) | Where-Object { $_ } | ForEach-Object { [string]$_['name'] }) + @($Index['includedColumns'] | Where-Object { $_ }) } else { @($Index['includedColumns'] | Where-Object { $_ }) })
		filter = $Index['filterDefinition']
		compression = [string]$Index['compression']
		dataSpace = [string]$Index['dataSpaceName']
		dataSpaceType = [string]$Index['dataSpaceType']
	}
}

function Compare-IaRuleIndexDefinition {
	<# Порівняння CREATE зі скрипта з наявним індексом: @{ mismatches = @() (суттєві); warnings = @() }. #>
	param([Parameter(Mandatory)]$Create, [Parameter(Mandatory)][System.Collections.IDictionary]$Existing)
	$definition = Get-IaRuleIndexDefinitionFromSnapshot -Index $Existing
	$mismatches = [System.Collections.Generic.List[string]]::new()
	$warnings = [System.Collections.Generic.List[string]]::new()
	$format = { param($Keys) (@($Keys) | ForEach-Object { if ($_.desc) { "$($_.name) DESC" } else { $_.name } }) -join ', ' }
	if ([bool]$Create.columnstore -ne [bool]$definition.columnstore) {
		$mismatches.Add('тип індексу (columnstore)')
	}
	if ([bool]$Create.clustered -ne [bool]$definition.clustered) {
		$mismatches.Add("кластерність ($(if ($definition.clustered) { 'CLUSTERED' } else { 'NONCLUSTERED' }) у наявного)")
	}
	if (-not $definition.columnstore -and [bool]$Create.unique -ne [bool]$definition.unique) {
		$mismatches.Add("унікальність ($(if ($definition.unique) { 'UNIQUE' } else { 'не UNIQUE' }) у наявного)")
	}
	if (-not (Test-IaRuleSameKeys -First @($Create.keys) -Second @($definition.keys))) {
		$mismatches.Add("ключ ($(& $format $Create.keys) замість $(& $format $definition.keys))")
	}
	if (-not (Test-IaRuleSameSet -First @($Create.includes) -Second @($definition.includes))) {
		$mismatches.Add("INCLUDE ($(@($Create.includes) -join ', ') замість $(@($definition.includes) -join ', '))")
	}
	if ((ConvertTo-IaRuleFilterKey $Create.filter) -ne (ConvertTo-IaRuleFilterKey $definition.filter)) {
		$mismatches.Add("фільтр ($($Create.filter) замість $($definition.filter))")
	}
	$createCompression = if ($Create.options.compression) { $Create.options.compression } else { 'NONE' }
	if ($definition.compression -and $definition.compression -ne 'MIXED' -and $createCompression -ne $definition.compression) {
		$warnings.Add("компресія $createCompression замість $($definition.compression)")
	}
	$createSpace = $Create.dataSpace.name
	if ($definition.dataSpaceType -eq 'PARTITION_SCHEME' -and $createSpace -and $createSpace -ne $definition.dataSpace) {
		$warnings.Add("розміщення ON [$createSpace] замість схеми секціонування [$($definition.dataSpace)]")
	}
	elseif ($definition.dataSpaceType -eq 'ROWS_FILEGROUP' -and $definition.dataSpace -and $definition.dataSpace -ne 'PRIMARY' -and $createSpace -ne $definition.dataSpace) {
		$warnings.Add("розміщення $(if ($createSpace) { "ON [$createSpace]" } else { 'за замовчуванням' }) замість файлової групи [$($definition.dataSpace)]")
	}
	return [ordered]@{ mismatches = @($mismatches); warnings = @($warnings) }
}

function Get-IaRuleCheckStatus {
	<# Статус перевірки з переліків проблем і попереджень. #>
	param([string[]]$Failures = @(), [string[]]$Warnings = @(), [string]$PassedMessage)
	$failures = @($Failures | Where-Object { $_ })
	$warnings = @($Warnings | Where-Object { $_ })
	if ($failures.Count) {
		return @{ status = 'Failed'; message = (@($failures) + @($warnings)) -join '; ' }
	}
	if ($warnings.Count) {
		return @{ status = 'Warning'; message = $warnings -join '; ' }
	}
	return @{ status = 'Passed'; message = $PassedMessage }
}

function Test-IaRecommendation {
	<# Автоматична перевірка рекомендації моделі (розділ 4.8). Повертає @{ status = Passed|Failed|Warning; checks = @(@{ id; status; message }) }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Recommendation,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$checks = [System.Collections.Generic.List[object]]::new()
	$addCheck = {
		param([string]$Id, $Result)
		$checks.Add((New-IaRuleCheck -Id $Id -Status $Result.status -Message $Result.message))
	}
	$action = [string]$Recommendation['action']
	$isPartitionAction = $action -in @('PartitionTable', 'AlterPartitioning')
	$target = $Recommendation['target']
	$schema = [string]$target['schema']
	$tableName = [string]$target['table']
	$indexName = [string]$target['index']
	$tableLabel = "[$schema].[$tableName]"
	$logical = Find-IaRuleLogicalDatabase -Snapshot $Snapshot -Server ([string]$target['server']) -Database ([string]$target['database'])
	$table = if ($logical) { Find-IaRuleTable -Database $logical.primary.database -Schema $schema -Table $tableName } else { $null }
	$existing = Find-IaRuleIndex -Table $table -Name $indexName
	$instance = if ($logical) { $logical.primary.instance } else { $null }
	$partitioning = $Recommendation['partitioning']
	$replaces = @($Recommendation['replacesIndexes'] | Where-Object { $_ })
	$exec = Get-IaRuleScriptInfo -Sql ([string]$Recommendation['executeScript'])
	$roll = Get-IaRuleScriptInfo -Sql ([string]$Recommendation['rollbackScript'])
	$parsed = $exec.parsed -and ($roll.parsed -or $roll.isBlank)
	$allStatements = @($exec.statements) + @($roll.statements)
	$execCreates = @($exec.statements | Where-Object { $_.kind -in @('CreateIndex', 'CreateColumnStoreIndex') -and (Test-IaRuleStatementOnTable -Statement $_ -Schema $schema -Table $tableName) })
	$allCreates = @($allStatements | Where-Object { $_.kind -in @('CreateIndex', 'CreateColumnStoreIndex') -and (Test-IaRuleStatementOnTable -Statement $_ -Schema $schema -Table $tableName) })
	$notParsedMessage = 'Скрипти не розібрано: перевірку пропущено'

	# ObjectsExist: таблиця, колонки, індекс, що змінюється чи видаляється.
	if ($null -eq $logical) {
		& $addCheck 'ObjectsExist' @{ status = 'Failed'; message = "База $($target['server'])/$($target['database']) не знайдена у snapshot" }
	}
	elseif ($null -eq $table) {
		& $addCheck 'ObjectsExist' @{ status = 'Failed'; message = "Таблиця $tableLabel не знайдена в базі $($target['database'])" }
	}
	else {
		$failures = [System.Collections.Generic.List[string]]::new()
		$warnings = [System.Collections.Generic.List[string]]::new()
		if ($action -in @('DropIndex', 'AlterIndex') -and $indexName -and $null -eq $existing) {
			$failures.Add("Індекс [$indexName] не знайдено на $tableLabel")
		}
		if ($isPartitionAction -and $partitioning -isnot [System.Collections.IDictionary]) {
			$failures.Add('Немає опису partitioning')
		}
		$columns = [System.Collections.Generic.List[string]]::new()
		foreach ($statement in $allStatements) {
			if (-not (Test-IaRuleStatementOnTable -Statement $statement -Schema $schema -Table $tableName)) {
				continue
			}
			$names = @()
			if ($statement.kind -in @('CreateIndex', 'CreateColumnStoreIndex')) {
				$names = @($statement.keys | ForEach-Object { $_.name }) + @($statement.includes) + @($statement.filterColumns) + @($statement.dataSpace.columns)
			}
			elseif ($statement.kind -eq 'AlterTableAdd') {
				foreach ($constraint in @($statement.constraints)) {
					$names += @($constraint.keys | ForEach-Object { $_.name }) + @($constraint.dataSpace.columns)
				}
			}
			foreach ($name in $names) {
				if ($name -and $columns -notcontains $name) { $columns.Add([string]$name) }
			}
		}
		if ($partitioning -is [System.Collections.IDictionary] -and $partitioning['partitionColumn'] -and $columns -notcontains $partitioning['partitionColumn']) {
			$columns.Add([string]$partitioning['partitionColumn'])
		}
		if (@($table['columns']).Where({ $null -ne $_ }).Count -eq 0) {
			if ($columns.Count) { $warnings.Add('Колонки таблиці не зібрано: наявність колонок не перевірено') }
		}
		else {
			$absent = @($columns | Where-Object { $null -eq (Find-IaRuleColumn -Table $table -Name $_) })
			if ($absent.Count) {
				$failures.Add("Колонки не існують у ${tableLabel}: $($absent -join ', ')")
			}
		}
		if (-not $exec.parsed -and -not $exec.isBlank) {
			$warnings.Add('Скрипт виконання не розібрано: колонки зі скрипта не перевірено')
		}
		& $addCheck 'ObjectsExist' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage "Таблиця $tableLabel, колонки й індекси існують")
	}

	# NotDuplicate: новий індекс не дублює й не перекриває наявний.
	if ($action -notin @('CreateIndex', 'AlterIndex')) {
		& $addCheck 'NotDuplicate' @{ status = 'Skipped'; message = 'Перевірка стосується лише створення індексу' }
	}
	elseif (-not $exec.parsed -or $null -eq $table) {
		& $addCheck 'NotDuplicate' @{ status = 'Skipped'; message = $notParsedMessage }
	}
	elseif ($execCreates.Count -eq 0) {
		& $addCheck 'NotDuplicate' @{ status = 'Skipped'; message = 'Скрипт виконання не створює індексу' }
	}
	else {
		$failures = [System.Collections.Generic.List[string]]::new()
		$warnings = [System.Collections.Generic.List[string]]::new()
		$activeIndexes = @(Get-IaRuleActiveIndexes -Table $table)
		foreach ($create in $execCreates) {
			$dropExisting = $create.options.dropExisting -eq 'On'
			if (-not $dropExisting -and (Find-IaRuleIndex -Table $table -Name $create.name)) {
				$failures.Add("Індекс з іменем [$($create.name)] уже існує на $tableLabel")
			}
			$comparators = @($activeIndexes | Where-Object { $replaces -notcontains $_['name'] -and -not ($dropExisting -and $_['name'] -eq $create.name) })
			if ($create.columnstore) {
				$columnstore = $comparators | Where-Object { ([string]$_['typeDesc']) -like '*COLUMNSTORE*' } | Select-Object -First 1
				if ($columnstore) {
					$failures.Add("На $tableLabel уже є columnstore-індекс [$($columnstore['name'])]: допускається лише один")
				}
				continue
			}
			$filterKey = ConvertTo-IaRuleFilterKey $create.filter
			foreach ($other in $comparators) {
				if (-not (Test-IaRuleRowstore -Index $other) -or (ConvertTo-IaRuleFilterKey $other['filterDefinition']) -ne $filterKey) {
					continue
				}
				$otherKeys = @(Get-IaRuleKeyColumns -Index $other)
				if (Test-IaRuleSameKeys -First @($create.keys) -Second $otherKeys) {
					$failures.Add("Новий індекс [$($create.name)] дублює ключі наявного [$($other['name'])]")
				}
				elseif (Test-IaRuleKeyPrefix -Short @($create.keys) -Long $otherKeys -Strict) {
					$failures.Add("Новий індекс [$($create.name)] перекривається наявним [$($other['name'])]: його ключі — лівий префікс ключів наявного (розширте INCLUDE наявного)")
				}
				elseif ((Test-IaRuleKeyPrefix -Short $otherKeys -Long @($create.keys) -Strict) -and -not ($other['isPrimaryKey'] -or $other['isUnique'] -or $other['isUniqueConstraint'] -or $other['typeDesc'] -eq 'CLUSTERED')) {
					$warnings.Add("Новий індекс [$($create.name)] перекриває наявний [$($other['name'])]: додайте його до replacesIndexes і окрему рекомендацію DropIndex")
				}
			}
		}
		& $addCheck 'NotDuplicate' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage 'Новий індекс не дублює й не перекриває наявні')
	}

	# DropAllowed: PK, UNIQUE, FK, реплікація, хінти (розділ 4.4).
	if ($action -ne 'DropIndex') {
		& $addCheck 'DropAllowed' @{ status = 'Skipped'; message = 'Перевірка стосується лише видалення індексу' }
	}
	elseif ($null -eq $existing) {
		& $addCheck 'DropAllowed' @{ status = 'Failed'; message = "Індекс [$indexName] не знайдено: дозвіл на видалення не перевірено" }
	}
	else {
		$conditions = @(Get-IaRuleStructuralConditions -Logical $logical -Schema $schema -Table $tableName -Index $indexName)
		$failures = @($conditions | Where-Object { $_.met -eq $false } | ForEach-Object { $_.details })
		$warnings = @($conditions | Where-Object { $null -eq $_.met } | ForEach-Object { "Невідомо: $($_.details)" })
		& $addCheck 'DropAllowed' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage 'Індекс не є PK чи UNIQUE, не підтримує FK, не використовується реплікацією й не згадується в хінтах')
	}

	# SyntaxValid: ScriptDom для скриптів виконання й відкату.
	$failures = [System.Collections.Generic.List[string]]::new()
	foreach ($pair in @(@{ label = 'Скрипт виконання'; info = $exec }, @{ label = 'Скрипт відкату'; info = $roll })) {
		if ($pair.info.exception) {
			$failures.Add("$($pair.label): синтаксис не перевірено, ScriptDom недоступний ($($pair.info.exception))")
		}
		elseif (@($pair.info.errors).Count) {
			$failures.Add("$($pair.label): $(Format-IaRuleParseErrors -Errors $pair.info.errors)")
		}
	}
	if ($exec.isBlank) {
		$failures.Add('Скрипт виконання порожній')
	}
	elseif ($exec.parsed -and @($exec.statements).Count -eq 0) {
		$failures.Add('Скрипт виконання не містить інструкцій')
	}
	$parserName = if ($exec.parserName) { $exec.parserName } else { $roll.parserName }
	& $addCheck 'SyntaxValid' (Get-IaRuleCheckStatus -Failures $failures -PassedMessage "Синтаксис коректний ($parserName)")

	# RollbackMatches: відкат відповідає виконанню.
	if (-not $parsed) {
		& $addCheck 'RollbackMatches' @{ status = 'Skipped'; message = $notParsedMessage }
	}
	else {
		$failures = [System.Collections.Generic.List[string]]::new()
		$warnings = [System.Collections.Generic.List[string]]::new()
		$rollDrops = @($roll.statements | Where-Object { $_.kind -eq 'DropIndex' } | ForEach-Object { @($_.clauses) })
		$rollCreates = @($roll.statements | Where-Object { $_.kind -in @('CreateIndex', 'CreateColumnStoreIndex') })
		if ($roll.isBlank -or @($roll.statements).Count -eq 0) {
			$onlyMaintenance = $action -eq 'AlterIndex' -and @($exec.statements).Count -gt 0 -and
			@($exec.statements | Where-Object { -not ($_.kind -eq 'AlterIndex' -and $_.alterType -in @('Rebuild', 'Reorganize')) }).Count -eq 0
			if ($onlyMaintenance) {
				$warnings.Add('Скрипт відкату порожній: для REBUILD чи REORGANIZE відкат не потрібен, але параметри індексу не відновлюються')
			}
			else {
				$failures.Add('Скрипт відкату порожній')
			}
		}
		elseif ($action -eq 'CreateIndex') {
			foreach ($create in $execCreates) {
				$drop = $rollDrops | Where-Object { $_.index -eq $create.name -and $_.table -eq $create.table -and $_.schema -eq $create.schema } | Select-Object -First 1
				if ($null -eq $drop) {
					$failures.Add("Відкат не видаляє створений індекс [$($create.name)] на [$($create.schema)].[$($create.table)]")
				}
			}
			foreach ($drop in $rollDrops) {
				if (-not ($execCreates | Where-Object { $_.name -eq $drop.index -and $_.table -eq $drop.table -and $_.schema -eq $drop.schema })) {
					$failures.Add("Відкат видаляє індекс [$($drop.index)] на [$($drop.schema)].[$($drop.table)], який скрипт виконання не створює")
				}
			}
		}
		elseif ($action -in @('DropIndex', 'AlterIndex')) {
			$execDrops = @($exec.statements | Where-Object { $_.kind -eq 'DropIndex' } | ForEach-Object { @($_.clauses) })
			$redefined = @($execCreates | Where-Object { $_.options.dropExisting -eq 'On' })
			$needsRecreate = $action -eq 'DropIndex' -or $execDrops.Count -gt 0 -or $redefined.Count -gt 0
			if ($needsRecreate) {
				$recreate = $rollCreates | Where-Object { $_.name -eq $indexName -and (Test-IaRuleStatementOnTable -Statement $_ -Schema $schema -Table $tableName) } | Select-Object -First 1
				if ($null -eq $recreate) {
					$failures.Add("Відкат не створює індекс [$indexName] на $tableLabel заново")
				}
				elseif ($null -eq $existing) {
					$warnings.Add("Індекс [$indexName] не знайдено у snapshot: відповідність відкату наявному визначенню не перевірено")
				}
				else {
					$comparison = Compare-IaRuleIndexDefinition -Create $recreate -Existing $existing
					foreach ($mismatch in $comparison.mismatches) { $failures.Add("Відкат не відтворює індекс [$indexName]: $mismatch") }
					foreach ($warning in $comparison.warnings) { $warnings.Add("Відкат індексу [$indexName]: $warning") }
					if ($action -eq 'AlterIndex' -and $redefined.Count -gt 0 -and $recreate.options.dropExisting -ne 'On' -and
						-not ($roll.statements | Where-Object { $_.kind -eq 'DropIndex' -and @($_.clauses | Where-Object { $_.index -eq $indexName }).Count })) {
						$failures.Add("Відкат створює [$indexName] без DROP_EXISTING = ON і без попереднього видалення")
					}
				}
			}
			else {
				$alters = @($exec.statements | Where-Object { $_.kind -eq 'AlterIndex' })
				foreach ($alter in $alters) {
					$match = $roll.statements | Where-Object { $_.kind -eq 'AlterIndex' -and $_.name -eq $alter.name -and $_.table -eq $alter.table -and $_.schema -eq $alter.schema } | Select-Object -First 1
					if ($null -eq $match) {
						$failures.Add("Відкат не містить ALTER INDEX для [$($alter.name)] на [$($alter.schema)].[$($alter.table)]")
					}
				}
			}
		}
		elseif ($isPartitionAction) {
			foreach ($statement in @($exec.statements | Where-Object { $_.kind -in @('CreatePartitionFunction', 'CreatePartitionScheme') })) {
				$dropKind = $statement.kind -replace '^Create', 'Drop'
				if (-not ($roll.statements | Where-Object { $_.kind -eq $dropKind -and $_.name -eq $statement.name })) {
					$warnings.Add("Відкат не видаляє створений об'єкт [$($statement.name)] ($($statement.kind))")
				}
			}
			foreach ($statement in @($exec.statements | Where-Object { $_.kind -eq 'AlterPartitionFunction' })) {
				if (-not ($roll.statements | Where-Object { $_.kind -eq 'AlterPartitionFunction' -and $_.name -eq $statement.name -and $_.isSplit -ne $statement.isSplit })) {
					$warnings.Add("Відкат не містить зворотної зміни функції [$($statement.name)] ($(if ($statement.isSplit) { 'MERGE' } else { 'SPLIT' }) RANGE)")
				}
			}
			$rollIndexNames = @($rollCreates | ForEach-Object { $_.name }) + @($rollDrops | ForEach-Object { $_.index })
			foreach ($create in $execCreates) {
				if ($rollIndexNames -notcontains $create.name) {
					$warnings.Add("Відкат не повертає індекс [$($create.name)] у попередній стан")
				}
			}
			$rollConstraints = @($roll.statements | Where-Object { $_.kind -eq 'AlterTableAdd' } | ForEach-Object { @($_.constraints | ForEach-Object { $_.name }) })
			foreach ($statement in @($exec.statements | Where-Object { $_.kind -eq 'AlterTableDrop' -and (Test-IaRuleStatementOnTable -Statement $_ -Schema $schema -Table $tableName) })) {
				foreach ($element in @($statement.elements)) {
					if ($rollConstraints -notcontains $element.name) {
						$warnings.Add("Відкат не відновлює обмеження [$($element.name)]")
					}
				}
			}
		}
		& $addCheck 'RollbackMatches' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage 'Скрипт відкату відповідає скрипту виконання')
	}

	# PlatformLimits: ключ ≤ 900/1700 байт, ≤ 32 ключові колонки, ≤ 1023 колонок, один кластерний індекс, ≤ 15000 секцій.
	$constraintAdds = @($allStatements | Where-Object { $_.kind -eq 'AlterTableAdd' -and (Test-IaRuleStatementOnTable -Statement $_ -Schema $schema -Table $tableName) } |
			ForEach-Object { @($_.constraints | Where-Object { $_.type -eq 'UniqueConstraintDefinition' }) })
	$functions = @($allStatements | Where-Object { $_.kind -eq 'CreatePartitionFunction' })
	if (-not $parsed) {
		& $addCheck 'PlatformLimits' @{ status = 'Skipped'; message = $notParsedMessage }
	}
	elseif ($allCreates.Count + $constraintAdds.Count + $functions.Count -eq 0) {
		& $addCheck 'PlatformLimits' @{ status = 'Skipped'; message = 'Скрипти не створюють індексів' }
	}
	else {
		$failures = [System.Collections.Generic.List[string]]::new()
		$warnings = [System.Collections.Generic.List[string]]::new()
		$columnsKnown = $table -and @($table['columns']).Where({ $null -ne $_ }).Count -gt 0
		$definitions = @($allCreates | ForEach-Object { [ordered]@{ label = "індекс [$($_.name)]"; name = $_.name; clustered = $_.clustered; columnstore = $_.columnstore; keys = @($_.keys); includes = @($_.includes); dropExisting = $_.options.dropExisting -eq 'On' } }) +
		@($constraintAdds | ForEach-Object { [ordered]@{ label = "обмеження [$($_.name)]"; name = $_.name; clustered = $_.clustered; columnstore = $false; keys = @($_.keys); includes = @(); dropExisting = $false } })
		foreach ($definition in $definitions) {
			$keyCount = @($definition.keys).Count
			if ($definition.columnstore) {
				if (@($definition.includes).Count -gt 1024) {
					$failures.Add("$($definition.label): columnstore-індекс має понад 1024 колонки")
				}
			}
			else {
				if ($keyCount -gt 32) {
					$failures.Add("$($definition.label): $keyCount ключових колонок (максимум 32)")
				}
				if ($keyCount + @($definition.includes).Count -gt 1023) {
					$failures.Add("$($definition.label): понад 1023 колонки разом з INCLUDE")
				}
				if ($columnsKnown) {
					$keyBytes = 0
					$variable = $false
					foreach ($key in @($definition.keys)) {
						$column = Find-IaRuleColumn -Table $table -Name $key.name
						if ($null -eq $column) {
							continue
						}
						$typeName = [string]$column['typeName']
						if ($script:IaRuleNonKeyTypes -contains $typeName -or [int]$column['maxLength'] -lt 0) {
							$failures.Add("$($definition.label): колонка [$($key.name)] типу $typeName$(if ([int]$column['maxLength'] -lt 0) { '(MAX)' }) не може бути ключовою")
							continue
						}
						$keyBytes += [int]$column['maxLength']
						if ($script:IaRuleVariableTypes -contains $typeName) { $variable = $true }
					}
					$limit = if ($definition.clustered) { 900 } else { 1700 }
					if ($keyBytes -gt $limit) {
						$text = "$($definition.label): максимальний розмір ключа $keyBytes байт перевищує $limit байт для $(if ($definition.clustered) { 'кластерного' } else { 'некластерного' }) індексу"
						if ($variable) { $warnings.Add("$text (вставка довших значень завершиться помилкою)") } else { $failures.Add($text) }
					}
				}
			}
			if ($table -and $definition.clustered -and -not $definition.dropExisting) {
				$droppedNames = @($allStatements | Where-Object { $_.kind -eq 'DropIndex' } | ForEach-Object { @($_.clauses | ForEach-Object { $_.index }) }) +
				@($allStatements | Where-Object { $_.kind -eq 'AlterTableDrop' } | ForEach-Object { @($_.elements | ForEach-Object { $_.name }) })
				foreach ($index in @(Get-IaRuleActiveIndexes -Table $table -IncludeDisabled)) {
					$name = [string]$index['name']
					if (([string]$index['typeDesc']) -like 'CLUSTERED*' -and $name -ne $definition.name -and $replaces -notcontains $name -and $droppedNames -notcontains $name) {
						$failures.Add("$($definition.label): на $tableLabel уже є кластерний індекс [$name]")
					}
				}
			}
			if ($table -and -not $definition.clustered -and -not $definition.dropExisting -and @(Get-IaRuleActiveIndexes -Table $table -IncludeDisabled | Where-Object { ([string]$_['typeDesc']) -notlike 'CLUSTERED*' }).Count + 1 -gt 999) {
				$failures.Add("$($definition.label): на $tableLabel буде понад 999 некластерних індексів")
			}
		}
		foreach ($function in $functions) {
			if ([int]$function.boundaryCount + 1 -gt 15000) {
				$failures.Add("Функція секціонування [$($function.name)]: понад 15000 секцій")
			}
		}
		if (-not $columnsKnown -and ($allCreates.Count + $constraintAdds.Count)) {
			$warnings.Add('Колонки таблиці не зібрано: розмір ключа не перевірено')
		}
		& $addCheck 'PlatformLimits' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage 'Ліміти ключа й кількості колонок дотримано')
	}

	# EditionFeatures: ONLINE/RESUMABLE лише при supportsOnlineIndexOps; на Enterprise без ONLINE = ON — Warning.
	$operations = @($allStatements | Where-Object { $_.kind -in @('CreateIndex', 'CreateColumnStoreIndex') -or ($_.kind -eq 'AlterIndex' -and $_.alterType -eq 'Rebuild') } |
			ForEach-Object { [ordered]@{ label = $(if ($_.kind -eq 'AlterIndex') { "ALTER INDEX [$($_.name)] REBUILD" } else { "CREATE INDEX [$($_.name)]" }); options = $_.options } }) +
	@($constraintAdds | ForEach-Object { [ordered]@{ label = "ADD CONSTRAINT [$($_.name)]"; options = $_.options } })
	if (-not $parsed) {
		& $addCheck 'EditionFeatures' @{ status = 'Skipped'; message = $notParsedMessage }
	}
	elseif ($operations.Count -eq 0) {
		& $addCheck 'EditionFeatures' @{ status = 'Skipped'; message = 'Скрипти не містять створення чи перебудови індексів' }
	}
	elseif ($null -eq $instance) {
		& $addCheck 'EditionFeatures' @{ status = 'Skipped'; message = 'Інстанс не знайдено у snapshot: редакцію не перевірено' }
	}
	else {
		$failures = [System.Collections.Generic.List[string]]::new()
		$warnings = [System.Collections.Generic.List[string]]::new()
		$supportsOnline = [bool]$instance['supportsOnlineIndexOps']
		$edition = [string]$instance['edition']
		foreach ($operation in $operations) {
			$online = $operation.options.online -eq 'On'
			$resumable = $operation.options.resumable -eq 'On'
			if (($online -or $resumable) -and -not $supportsOnline) {
				$failures.Add("$($operation.label): ONLINE/RESUMABLE недоступні в редакції $edition")
			}
			elseif ($resumable -and -not $online) {
				$failures.Add("$($operation.label): RESUMABLE = ON потребує ONLINE = ON")
			}
			elseif ($supportsOnline -and -not $online) {
				$warnings.Add("$($operation.label): на $edition без ONLINE = ON таблиця блокується на час операції")
			}
		}
		& $addCheck 'EditionFeatures' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage "Опції індексів відповідають редакції $edition")
	}

	# PartitionAlignment: вирівнювання індексів зі схемою секціонування.
	if (-not $parsed) {
		& $addCheck 'PartitionAlignment' @{ status = 'Skipped'; message = $notParsedMessage }
	}
	elseif ($isPartitionAction) {
		$failures = [System.Collections.Generic.List[string]]::new()
		$warnings = [System.Collections.Generic.List[string]]::new()
		if ($partitioning -isnot [System.Collections.IDictionary]) {
			$failures.Add('Немає опису partitioning')
		}
		else {
			$column = [string]$partitioning['partitionColumn']
			$scheme = if ($partitioning['schemeName']) { [string]$partitioning['schemeName'] } elseif ($table) { [string]$table['partitionScheme'] } else { '' }
			$execDefinitions = @($exec.statements | Where-Object { $_.kind -in @('CreateIndex', 'CreateColumnStoreIndex') -and (Test-IaRuleStatementOnTable -Statement $_ -Schema $schema -Table $tableName) } |
					ForEach-Object { [ordered]@{ name = $_.name; unique = $_.unique; keys = @($_.keys); dataSpace = $_.dataSpace } }) +
			@($exec.statements | Where-Object { $_.kind -eq 'AlterTableAdd' -and (Test-IaRuleStatementOnTable -Statement $_ -Schema $schema -Table $tableName) } |
					ForEach-Object { @($_.constraints | Where-Object { $_.type -eq 'UniqueConstraintDefinition' }) } |
					ForEach-Object { [ordered]@{ name = $_.name; unique = $true; keys = @($_.keys); dataSpace = $_.dataSpace } })
			foreach ($definition in $execDefinitions) {
				if ($scheme -and $definition.dataSpace.name -eq $scheme) {
					if (@($definition.dataSpace.columns).Count -and $definition.dataSpace.columns[0] -ne $column) {
						$failures.Add("[$($definition.name)] вирівняний за [$($definition.dataSpace.columns[0])], а не за ключем секціонування [$column]")
					}
					if ($definition.unique -and @($definition.keys | Where-Object { $_.name -eq $column }).Count -eq 0) {
						$failures.Add("Унікальний [$($definition.name)] на схемі [$scheme] має містити [$column] у ключі")
					}
				}
			}
			$impact = $partitioning['impact']
			$declared = @()
			if ($impact -is [System.Collections.IDictionary]) {
				$declared = @($impact['nonAlignedIndexes']) + @($impact['primaryKeyAndUniqueChanges']) | Where-Object { $_ } | ForEach-Object { [string]$_ }
			}
			if ($table -and $action -eq 'PartitionTable') {
				# Для нового секціонування: унікальні індекси без ключа секціонування лишаться невирівняними.
				foreach ($index in @(Get-IaRuleActiveIndexes -Table $table)) {
					if (-not ($index['isPrimaryKey'] -or $index['isUnique'] -or $index['isUniqueConstraint'])) {
						continue
					}
					$hasColumn = @(Get-IaRuleKeyColumns -Index $index | Where-Object { $_.name -eq $column }).Count -gt 0
					$redefined = @($execDefinitions | Where-Object { $_.name -eq $index['name'] }).Count -gt 0
					$mentioned = @($declared | Where-Object { $_ -match ('(^|[^\w])' + [regex]::Escape([string]$index['name']) + '([^\w]|$)') }).Count -gt 0
					if (-not $hasColumn -and -not $redefined -and -not $mentioned) {
						$warnings.Add("Унікальний індекс [$($index['name'])] не містить [$column] і не врахований у плані: він лишиться невирівняним")
					}
				}
			}
		}
		& $addCheck 'PartitionAlignment' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage 'Індекси вирівняні зі схемою секціонування або невирівняні враховано в плані')
	}
	elseif ($table -and $table['isPartitioned'] -and $allCreates.Count) {
		$failures = [System.Collections.Generic.List[string]]::new()
		$warnings = [System.Collections.Generic.List[string]]::new()
		$scheme = [string]$table['partitionScheme']
		$column = [string]$table['partitionColumn']
		foreach ($create in $allCreates) {
			$space = $create.dataSpace.name
			$aligned = (-not $space) -or $space -eq $scheme
			if ($aligned -and $space -and @($create.dataSpace.columns).Count -and $create.dataSpace.columns[0] -ne $column) {
				$failures.Add("[$($create.name)] розміщено на [$scheme] за [$($create.dataSpace.columns[0])], а таблицю секціоновано за [$column]")
			}
			if ($aligned -and $create.unique -and @($create.keys | Where-Object { $_.name -eq $column }).Count -eq 0) {
				$failures.Add("Унікальний вирівняний індекс [$($create.name)] має містити стовпець секціонування [$column] у ключі")
			}
			if (-not $aligned) {
				$warnings.Add("[$($create.name)] не вирівняний зі схемою [$scheme] (ON [$space]): SWITCH секцій стане неможливим")
			}
		}
		& $addCheck 'PartitionAlignment' (Get-IaRuleCheckStatus -Failures $failures -Warnings $warnings -PassedMessage "Індекси вирівняні зі схемою секціонування [$scheme]")
	}
	else {
		& $addCheck 'PartitionAlignment' @{ status = 'Skipped'; message = 'Таблиця не секціонована' }
	}

	# SafeScript: лише інструкції, доречні для action, без DML та іншого DDL, і лише для цільового об'єкта.
	if (-not $parsed) {
		& $addCheck 'SafeScript' @{ status = 'Skipped'; message = $notParsedMessage }
	}
	else {
		$failures = [System.Collections.Generic.List[string]]::new()
		$allowedMap = if ($isPartitionAction) { @{ execute = $script:IaRuleAllowedStatements.Partitioning; rollback = $script:IaRuleAllowedStatements.Partitioning } } else { $script:IaRuleAllowedStatements[$action] }
		$childForeignKeys = @()
		if ($logical) {
			foreach ($otherTable in @($logical.primary.database['tables'])) {
				foreach ($fk in @($otherTable['foreignKeys'])) {
					if ($fk -is [System.Collections.IDictionary] -and $fk['referencedSchema'] -eq $schema -and $fk['referencedTable'] -eq $tableName) {
						$childForeignKeys += [ordered]@{ name = [string]$fk['name']; schema = [string]$otherTable['schema']; table = [string]$otherTable['name'] }
					}
				}
			}
		}
		if ($null -eq $allowedMap) {
			$failures.Add("Невідома дія $action")
		}
		else {
			foreach ($part in @(@{ label = 'Скрипт виконання'; key = 'execute'; info = $exec }, @{ label = 'Скрипт відкату'; key = 'rollback'; info = $roll })) {
				# Допоміжні інструкції: USE лише цільової бази; контрольний SELECT — без INTO і лише з системних каталогів.
				foreach ($item in @($part.info.auxiliary)) {
					if ($item.kind -eq 'Use' -and $item.name -ne [string]$Recommendation.target.database) {
						$failures.Add("$($part.label): USE [$($item.name)] — ціль у базі [$($Recommendation.target.database)]")
					}
					elseif ($item.kind -eq 'CatalogQuery' -and -not $item.readOnlySystem) {
						$failures.Add("$($part.label): SELECT дозволено лише без INTO і лише з системних каталогів")
					}
				}
				$allowed = @($allowedMap[$part.key])
				foreach ($statement in @($part.info.statements)) {
					$label = "$($part.label): $($statement.kind)"
					if ($allowed -notcontains $statement.kind) {
						$failures.Add("$label — інструкція недоречна для $action")
						continue
					}
					if ($statement.kind -eq 'AlterIndex' -and $statement.alterType -eq 'Disable') {
						$failures.Add("$label — DISABLE не використовується (розділ 4.4)")
						continue
					}
					if ($statement.kind -in @('AlterTableAdd', 'AlterTableDrop')) {
						if (-not $statement.constraintsOnly) {
							$failures.Add("$label — змінює колонки таблиці [$($statement.schema)].[$($statement.table)]")
							continue
						}
						if (-not (Test-IaRuleStatementOnTable -Statement $statement -Schema $schema -Table $tableName)) {
							# На інших таблицях дозволено лише тимчасово видалити й відновити FK, що посилаються на ціль.
							$names = [System.Collections.Generic.List[string]]::new()
							if ($statement.kind -eq 'AlterTableAdd') {
								foreach ($constraint in @($statement.constraints)) {
									$referencesTarget = $constraint.referencedTable -and $constraint.referencedTable.table -eq $tableName -and $constraint.referencedTable.schema -eq $schema
									$names.Add($(if ($constraint.type -eq 'ForeignKeyConstraintDefinition' -and $referencesTarget) { [string]$constraint.name } else { '' }))
								}
							}
							else {
								foreach ($element in @($statement.elements)) { $names.Add([string]$element.name) }
							}
							$invalid = $false
							foreach ($name in $names) {
								$known = $false
								foreach ($fk in $childForeignKeys) {
									if ($name -and $fk.name -eq $name -and $fk.table -eq $statement.table -and $fk.schema -eq $statement.schema) { $known = $true }
								}
								if (-not $known) { $invalid = $true }
							}
							if ($invalid) {
								$failures.Add("$label — змінює таблицю [$($statement.schema)].[$($statement.table)], яка не є ціллю (дозволено лише FK, що посилаються на ціль)")
							}
						}
						continue
					}
					if ($statement.kind -in @('CreatePartitionFunction', 'CreatePartitionScheme', 'AlterPartitionFunction', 'AlterPartitionScheme', 'DropPartitionFunction', 'DropPartitionScheme')) {
						continue
					}
					if ($statement.kind -eq 'DropIndex') {
						foreach ($clause in @($statement.clauses)) {
							if ($clause.table -ne $tableName -or $clause.schema -ne $schema) {
								$failures.Add("$label — видаляє індекс [$($clause.index)] іншої таблиці [$($clause.schema)].[$($clause.table)]")
							}
							elseif (-not $isPartitionAction -and $action -ne 'AlterIndex' -and $indexName -and $clause.index -ne $indexName) {
								$failures.Add("$label — видаляє індекс [$($clause.index)], а ціль — [$indexName]")
							}
						}
						continue
					}
					if (-not (Test-IaRuleStatementOnTable -Statement $statement -Schema $schema -Table $tableName)) {
						$failures.Add("$label — стосується [$($statement.schema)].[$($statement.table)], а ціль — $tableLabel")
						continue
					}
					if (-not $isPartitionAction -and $indexName -and $statement.name -and $statement.name -ne $indexName) {
						$failures.Add("$label — стосується індексу [$($statement.name)], а ціль — [$indexName]")
						continue
					}
					if ($action -eq 'CreateIndex' -and $part.key -eq 'execute' -and $statement.options.dropExisting -eq 'On') {
						$failures.Add("$label — DROP_EXISTING = ON замінює наявний індекс: це дія AlterIndex")
					}
				}
			}
		}
		& $addCheck 'SafeScript' (Get-IaRuleCheckStatus -Failures $failures -PassedMessage "Скрипти містять лише інструкції, доречні для $action")
	}

	$status = 'Passed'
	if (@($checks | Where-Object { $_.status -eq 'Failed' }).Count) {
		$status = 'Failed'
	}
	elseif (@($checks | Where-Object { $_.status -eq 'Warning' }).Count) {
		$status = 'Warning'
	}
	return [ordered]@{ status = $status; checks = @($checks) }
}
