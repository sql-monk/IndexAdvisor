# Модуль рекомендацій щодо партиціонування (розділ 4.6 ТЗ; CONTRACTS.md, розділ 3.5). Нічого не виконує:
# лише знахідки й чернетки у форматі contracts/llm-response.schema.json (recommendations[i] з partitioning).

function Format-IaRuleQuotedName {
	<# Ідентифікатор у квадратних дужках. #>
	param([Parameter(Mandatory)][string]$Name)
	return '[' + $Name.Replace(']', ']]') + ']'
}

function Format-IaRuleSqlList {
	<# Список через кому з переносом рядків (до ~140 символів у рядку, продовження з відступом табами). #>
	param([string[]]$Items, [string]$Indent = "`t`t")
	$lines = [System.Collections.Generic.List[string]]::new()
	$current = ''
	foreach ($item in @($Items)) {
		$piece = if ($current) { ", $item" } else { $item }
		if ($current -and ($current.Length + $piece.Length) -gt 140) {
			$lines.Add($current + ',')
			$current = $item
		}
		else {
			$current += $piece
		}
	}
	if ($current) {
		$lines.Add($current)
	}
	return ($lines -join ("`r`n" + $Indent))
}

function Format-IaRuleColumnType {
	<# Тип колонки для T-SQL (ВЕЛИКИМИ): DATETIME2(7), DECIMAL(18, 2), NVARCHAR(400). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Column)
	$type = ([string]$Column['typeName']).ToLowerInvariant()
	$upper = $type.ToUpperInvariant()
	switch -regex ($type) {
		'^(datetime2|datetimeoffset|time)$' { return '{0}({1})' -f $upper, [int]$Column['scale'] }
		'^(decimal|numeric)$' { return '{0}({1}, {2})' -f $upper, [int]$Column['precision'], [int]$Column['scale'] }
		'^(nvarchar|nchar)$' { return $(if ([int]$Column['maxLength'] -lt 0) { "$upper(MAX)" } else { '{0}({1})' -f $upper, ([int]$Column['maxLength'] / 2) }) }
		'^(varchar|char|varbinary|binary)$' { return $(if ([int]$Column['maxLength'] -lt 0) { "$upper(MAX)" } else { '{0}({1})' -f $upper, [int]$Column['maxLength'] }) }
	}
	return $upper
}

function Get-IaRulePartitionObjectName {
	<# Ім'я функції чи схеми секціонування за конвенцією pf_<схема>_<тип>/ps_<схема>_<тип> (тип без дужок і ком, у нижньому регістрі). #>
	param([Parameter(Mandatory)][ValidateSet('pf', 'ps')][string]$Prefix, [Parameter(Mandatory)][string]$Schema, [Parameter(Mandatory)][string]$TypeSql)
	return '{0}_{1}_{2}' -f $Prefix, $Schema, ($TypeSql.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Format-IaRuleIndexOptionsSql {
	<# WITH (...) для індексу або обмеження. #>
	param([AllowNull()]$Index, [bool]$DropExisting, [bool]$Online)
	$options = [System.Collections.Generic.List[string]]::new()
	if ($DropExisting) { $options.Add('DROP_EXISTING = ON') }
	if ($Online) { $options.Add('ONLINE = ON') }
	if ($Index -is [System.Collections.IDictionary]) {
		if ([string]$Index['compression'] -in @('ROW', 'PAGE')) { $options.Add("DATA_COMPRESSION = $($Index['compression'])") }
		if ([int]$Index['fillFactor'] -gt 0 -and [int]$Index['fillFactor'] -lt 100) { $options.Add("FILLFACTOR = $([int]$Index['fillFactor'])") }
	}
	if ($options.Count -eq 0) {
		return $null
	}
	return 'WITH (' + ($options -join ', ') + ')'
}

function Format-IaRuleKeyListSql {
	<# Ключові колонки з напрямком. #>
	param([object[]]$Keys)
	return Format-IaRuleSqlList -Items @($Keys | ForEach-Object { '{0} {1}' -f (Format-IaRuleQuotedName $_.name), $(if ($_.desc) { 'DESC' } else { 'ASC' }) })
}

function Format-IaRuleIndexCreateSql {
	<# CREATE INDEX за визначенням зі snapshot (для перенесення на схему секціонування чи назад). DataSpace — готовий текст після ON. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Index,
		[Parameter(Mandatory)][string]$Schema,
		[Parameter(Mandatory)][string]$Table,
		[Parameter(Mandatory)][string]$DataSpace,
		[bool]$DropExisting,
		[bool]$Online
	)
	$name = Format-IaRuleQuotedName $Index['name']
	$tableSql = '{0}.{1}' -f (Format-IaRuleQuotedName $Schema), (Format-IaRuleQuotedName $Table)
	$typeDesc = [string]$Index['typeDesc']
	$lines = [System.Collections.Generic.List[string]]::new()
	if ($typeDesc -eq 'CLUSTERED COLUMNSTORE') {
		$lines.Add("CREATE CLUSTERED COLUMNSTORE INDEX $name ON $tableSql")
		$with = Format-IaRuleIndexOptionsSql -Index $null -DropExisting $DropExisting -Online $false
	}
	elseif ($typeDesc -eq 'NONCLUSTERED COLUMNSTORE') {
		$columns = @(@($Index['keyColumns']) | Where-Object { $_ } | ForEach-Object { [string]$_['name'] }) + @($Index['includedColumns'] | Where-Object { $_ })
		$lines.Add("CREATE NONCLUSTERED COLUMNSTORE INDEX $name ON $tableSql (" + (Format-IaRuleSqlList -Items @($columns | ForEach-Object { Format-IaRuleQuotedName $_ })) + ')')
		$with = Format-IaRuleIndexOptionsSql -Index $null -DropExisting $DropExisting -Online $Online
	}
	else {
		$unique = if ($Index['isUnique'] -or $Index['isUniqueConstraint'] -or $Index['isPrimaryKey']) { 'UNIQUE ' } else { '' }
		$lines.Add("CREATE $unique$typeDesc INDEX $name ON $tableSql (" + (Format-IaRuleKeyListSql -Keys @(Get-IaRuleKeyColumns -Index $Index)) + ')')
		$included = @($Index['includedColumns'] | Where-Object { $_ })
		if ($included.Count) {
			$lines.Add("`tINCLUDE (" + (Format-IaRuleSqlList -Items @($included | ForEach-Object { Format-IaRuleQuotedName $_ })) + ')')
		}
		$with = Format-IaRuleIndexOptionsSql -Index $Index -DropExisting $DropExisting -Online $Online
	}
	if ($Index['hasFilter'] -and $Index['filterDefinition']) {
		$lines.Add("`tWHERE $($Index['filterDefinition'])")
	}
	if ($with) {
		$lines.Add("`t$with")
	}
	$lines.Add("`tON $DataSpace;")
	return ($lines -join "`r`n")
}

function Format-IaRuleConstraintSql {
	<# ALTER TABLE ... ADD CONSTRAINT PRIMARY KEY/UNIQUE за визначенням індексу-обмеження. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Index,
		[Parameter(Mandatory)][string]$Schema,
		[Parameter(Mandatory)][string]$Table,
		[Parameter(Mandatory)][object[]]$Keys,
		[Parameter(Mandatory)][string]$DataSpace,
		[bool]$Online
	)
	$kind = if ($Index['isPrimaryKey']) { 'PRIMARY KEY' } else { 'UNIQUE' }
	$clustered = if ($Index['typeDesc'] -eq 'CLUSTERED') { 'CLUSTERED' } else { 'NONCLUSTERED' }
	$lines = [System.Collections.Generic.List[string]]::new()
	$lines.Add(('ALTER TABLE {0}.{1} ADD CONSTRAINT {2} {3} {4} ({5})' -f (Format-IaRuleQuotedName $Schema), (Format-IaRuleQuotedName $Table), (Format-IaRuleQuotedName $Index['name']), $kind, $clustered, (Format-IaRuleKeyListSql -Keys $Keys)))
	$with = Format-IaRuleIndexOptionsSql -Index $Index -DropExisting $false -Online $Online
	if ($with) {
		$lines.Add("`t$with")
	}
	$lines.Add("`tON $DataSpace;")
	return ($lines -join "`r`n")
}

function Format-IaRuleBoundaryLiteral {
	<# Літерал межі секціонування: для дат 'yyyyMMdd' або 'yyyy-MM-ddTHH:mm:ss.fff', якщо є час (не залежать від DATEFORMAT);
	   для цілих — число у форматі колонки. #>
	param([Parameter(Mandatory)][datetime]$Date, [Parameter(Mandatory)][string]$Format)
	switch ($Format) {
		'yyyyMMdd' { return $Date.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture) }
		'yyyyMM' { return $Date.ToString('yyyyMM', [cultureinfo]::InvariantCulture) }
		'yyyy' { return $Date.ToString('yyyy', [cultureinfo]::InvariantCulture) }
	}
	if ($Date.TimeOfDay.Ticks -ne 0) {
		return "'" + $Date.ToString("yyyy-MM-dd'T'HH:mm:ss.fff", [cultureinfo]::InvariantCulture) + "'"
	}
	return "'" + $Date.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture) + "'"
}

function Get-IaRulePeriodColumnFormat {
	<# Формат меж для стовпця дати чи періоду: 'Date' для типів дат; для цілих — yyyyMMdd/yyyyMM/yyyy за назвою; $null — не стовпець періоду. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Column)
	$type = ([string]$Column['typeName']).ToLowerInvariant()
	if ($script:IaRuleDateTypes -contains $type) {
		return 'Date'
	}
	if ($script:IaRuleIntegerTypes -contains $type) {
		$name = [string]$Column['name']
		if ($name -match '(?i)(date|day)') { return 'yyyyMMdd' }
		if ($name -match '(?i)(month|period)') { return 'yyyyMM' }
		if ($name -match '(?i)year') { return 'yyyy' }
	}
	return $null
}

function ConvertFrom-IaRuleBoundaryValue {
	<# Значення межі зі snapshot -> [datetime] UTC або $null. #>
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return $null
	}
	if ($Value -is [datetime] -or $Value -is [System.DateTimeOffset]) {
		return ConvertTo-IaRuleUtcDate $Value
	}
	$text = ([string]$Value).Trim().Trim("'").Trim()
	if ($text -match '^\d{8}$') {
		return [datetime]::ParseExact($text, 'yyyyMMdd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
	}
	if ($text -match '^\d{6}$') {
		return [datetime]::ParseExact($text, 'yyyyMM', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
	}
	if ($text -match '^\d{4}$') {
		return [datetime]::new([int]$text, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
	}
	return ConvertTo-IaRuleUtcDate $text
}

function Add-IaRulePeriodStep {
	<# Наступна межа за кроком секціонування. Межі на кінець місяця (типово для RANGE LEFT) лишаються на кінці місяця. #>
	param([Parameter(Mandatory)][datetime]$Date, [Parameter(Mandatory)][string]$Step, [double]$Days = 1)
	if ($Step -in @('Month', 'Quarter')) {
		$months = if ($Step -eq 'Month') { 1 } else { 3 }
		if ($Date.Day -eq [datetime]::DaysInMonth($Date.Year, $Date.Month)) {
			$target = [datetime]::new($Date.Year, $Date.Month, 1, 0, 0, 0, $Date.Kind).AddMonths($months)
			return [datetime]::new($target.Year, $target.Month, [datetime]::DaysInMonth($target.Year, $target.Month), 0, 0, 0, $Date.Kind).Add($Date.TimeOfDay)
		}
		return $Date.AddMonths($months)
	}
	switch ($Step) {
		'Day' { return $Date.AddDays(1) }
		'Year' { return $Date.AddYears(1) }
	}
	return $Date.AddDays([math]::Max(1, [math]::Round($Days)))
}

function Get-IaRuleTableWorkload {
	<# Навантаження Query Store на таблицю: запити, вага (логічні читання або кількість виконань), предикати за стовпцями, partition elimination. #>
	param([Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table)
	$digest = Get-IaRuleQueryStoreDigest -Logical $Logical
	$items = [System.Collections.Generic.List[object]]::new()
	foreach ($entry in @($digest.tables[("$Schema.$Table").ToLowerInvariant()] | Where-Object { $null -ne $_ })) {
		$items.Add([ordered]@{ queryId = $entry.queryId; reads = $entry.reads; executions = $entry.executions; columns = @($entry.columns); elimination = @($entry.elimination); weight = 0 })
	}
	$totalReads = [double]($items | ForEach-Object { $_.reads } | Measure-Object -Sum).Sum
	$useReads = $totalReads -gt 0
	foreach ($item in $items) {
		$item.weight = if ($useReads) { $item.reads } else { $item.executions }
	}
	return [ordered]@{ queries = $items.ToArray(); totalWeight = [double]($items | ForEach-Object { $_.weight } | Measure-Object -Sum).Sum; weightBasis = $(if ($useReads) { 'логічні читання' } else { 'кількість виконань' }) }
}

function Get-IaRuleColumnShare {
	<# Частка навантаження (за вагою), що фільтрує за стовпцем. #>
	param([Parameter(Mandatory)]$Workload, [string]$Column)
	if ($Workload.totalWeight -le 0) {
		return 0
	}
	$weight = ($Workload.queries | Where-Object { $_.columns -contains $Column } | ForEach-Object { $_.weight } | Measure-Object -Sum).Sum
	return [double]$weight / $Workload.totalWeight
}

function Get-IaRuleForeignKeyStatements {
	<# Видалення й відновлення FK інших таблиць, що посилаються на ціль (для зміни PK). #>
	param([Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table, [string]$IndexName)
	$drops = [System.Collections.Generic.List[string]]::new()
	$adds = [System.Collections.Generic.List[string]]::new()
	$names = [System.Collections.Generic.List[string]]::new()
	foreach ($child in @($Logical.primary.database['tables'])) {
		foreach ($fk in @($child['foreignKeys'])) {
			if ($fk -isnot [System.Collections.IDictionary] -or $fk['referencedSchema'] -ne $Schema -or $fk['referencedTable'] -ne $Table -or $fk['referencedIndexName'] -ne $IndexName) {
				continue
			}
			$childSql = '{0}.{1}' -f (Format-IaRuleQuotedName $child['schema']), (Format-IaRuleQuotedName $child['name'])
			$names.Add("$($fk['name']) ($($child['schema']).$($child['name']))")
			$drops.Add("ALTER TABLE $childSql DROP CONSTRAINT $(Format-IaRuleQuotedName $fk['name']);")
			$addHead = 'ALTER TABLE {0} WITH CHECK ADD CONSTRAINT {1} FOREIGN KEY ({2})' -f $childSql, (Format-IaRuleQuotedName $fk['name']), (Format-IaRuleSqlList -Items @($fk['columns'] | ForEach-Object { Format-IaRuleQuotedName $_ }))
			$addTail = "`r`n`tREFERENCES {0}.{1} ({2});" -f (Format-IaRuleQuotedName $Schema), (Format-IaRuleQuotedName $Table), (Format-IaRuleSqlList -Items @($fk['referencedColumns'] | ForEach-Object { Format-IaRuleQuotedName $_ }))
			$adds.Add($addHead + $addTail)
		}
	}
	return [ordered]@{ drops = @($drops); adds = @($adds); names = @($names) }
}

function New-IaRulePartitionTableDraft {
	<# Чернетка PartitionTable для несекціонованої таблиці-кандидата. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)]$Logical,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Table,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Column,
		[Parameter(Mandatory)]$Workload,
		[double]$Share,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$culture = [cultureinfo]::InvariantCulture
	$schema = [string]$Table['schema']
	$tableName = [string]$Table['name']
	$columnName = [string]$Column['name']
	$tableSql = '{0}.{1}' -f (Format-IaRuleQuotedName $schema), (Format-IaRuleQuotedName $tableName)
	$online = [bool]$Logical.primary.instance['supportsOnlineIndexOps']
	$typeSql = Format-IaRuleColumnType -Column $Column
	$functionName = Get-IaRulePartitionObjectName -Prefix 'pf' -Schema $schema -TypeSql $typeSql
	$schemeName = Get-IaRulePartitionObjectName -Prefix 'ps' -Schema $schema -TypeSql $typeSql
	$base = Get-IaRuleBaseIndex -Table $Table
	$originalSpace = if ($base -and $base['dataSpaceType'] -eq 'ROWS_FILEGROUP' -and $base['dataSpaceName']) { [string]$base['dataSpaceName'] } else { 'PRIMARY' }
	$originalSpaceSql = Format-IaRuleQuotedName $originalSpace
	$schemeSpaceSql = '{0} ({1})' -f (Format-IaRuleQuotedName $schemeName), (Format-IaRuleQuotedName $columnName)
	$functionExists = @($Logical.primary.database['tables'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['partitionFunction'] -eq $functionName }).Count -gt 0
	$schemeExists = @($Logical.primary.database['tables'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['partitionScheme'] -eq $schemeName }).Count -gt 0

	# Межі: щомісяця за останні 12 місяців і partitioning.minFuturePartitions місяців наперед (діапазон даних треба звірити).
	$collected = ConvertTo-IaRuleUtcDate $Snapshot['collectedAtUtc']
	if ($null -eq $collected) { $collected = [datetime]::UtcNow }
	$monthStart = [datetime]::new($collected.Year, $collected.Month, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
	$format = Get-IaRulePeriodColumnFormat -Column $Column
	$future = [math]::Max(1, [int]$Config.partitioning.minFuturePartitions)
	$boundaries = [System.Collections.Generic.List[string]]::new()
	for ($offset = -11; $offset -le $future; $offset++) {
		$boundaries.Add((Format-IaRuleBoundaryLiteral -Date $monthStart.AddMonths($offset) -Format $format))
	}
	$functionScript = if ($functionExists) {
		"-- Функцію $(Format-IaRuleQuotedName $functionName) уже створено: використовується наявна (межі звірити)."
	}
	else {
		"CREATE PARTITION FUNCTION $(Format-IaRuleQuotedName $functionName) ($typeSql) AS RANGE RIGHT FOR VALUES (`r`n`t" + (Format-IaRuleSqlList -Items @($boundaries) -Indent "`t") + "`r`n);"
	}
	$schemeScript = if ($schemeExists) {
		"-- Схему $(Format-IaRuleQuotedName $schemeName) уже створено: використовується наявна."
	}
	else {
		"CREATE PARTITION SCHEME $(Format-IaRuleQuotedName $schemeName) AS PARTITION $(Format-IaRuleQuotedName $functionName) ALL TO ($originalSpaceSql);"
	}

	$execute = [System.Collections.Generic.List[string]]::new()
	$rollback = [System.Collections.Generic.List[string]]::new()
	$rollbackTail = [System.Collections.Generic.List[string]]::new()
	$migration = [System.Collections.Generic.List[string]]::new()
	$pkChanges = [System.Collections.Generic.List[string]]::new()
	$nonAligned = [System.Collections.Generic.List[string]]::new()
	$foreignKeys = [System.Collections.Generic.List[string]]::new()
	$migration.Add("Перевірити діапазон значень $(Format-IaRuleQuotedName $columnName) (MIN/MAX) і скоригувати межі: запропоновано щомісячні межі $($boundaries[0])..$($boundaries[$boundaries.Count - 1]), RANGE RIGHT.")
	$migration.Add("За потреби створити файлові групи за конвенцією <база>_<схема>_<yyyy>_<MM> і замінити ALL TO ($originalSpaceSql) у схемі секціонування.")
	if (-not $functionExists) { $execute.Add($functionScript) }
	if (-not $schemeExists) { $execute.Add($schemeScript) }
	$migration.Add("Створити функцію $(Format-IaRuleQuotedName $functionName) і схему $(Format-IaRuleQuotedName $schemeName).")

	# Кластерна структура.
	$clusteredText = $null
	$sizeText = '{0} рядків, {1} МБ' -f $Table['rowCount'], (Format-IaRuleNumber $Table['reservedMb'] '0')
	if ($null -eq $base -or $base['typeDesc'] -eq 'HEAP') {
		$ciName = Get-IaRuleIndexName -KeyColumns @($columnName) -IsPartitioned $true -Prefix 'CI'
		$execute.Add(("CREATE CLUSTERED INDEX {0} ON {1} ({2} ASC)`r`n`t{3}`r`n`tON {4};" -f (Format-IaRuleQuotedName $ciName), $tableSql, (Format-IaRuleQuotedName $columnName), $(if ($online) { 'WITH (ONLINE = ON)' } else { 'WITH (DATA_COMPRESSION = NONE)' }), $schemeSpaceSql))
		$rollback.Add(('DROP INDEX {0} ON {1} WITH (MOVE TO {2});' -f (Format-IaRuleQuotedName $ciName), $tableSql, $originalSpaceSql))
		$clusteredText = "Купа ($sizeText) перетворюється на кластерний індекс $(Format-IaRuleQuotedName $ciName) за $(Format-IaRuleQuotedName $columnName) на схемі секціонування; усі некластерні індекси перебудовуються."
		$migration.Add("Створити кластерний індекс $(Format-IaRuleQuotedName $ciName) на схемі секціонування.")
	}
	elseif ($base['isPrimaryKey'] -or $base['isUniqueConstraint']) {
		$keys = @(Get-IaRuleKeyColumns -Index $base)
		$newKeys = @($keys)
		if (@($keys | Where-Object { $_.name -eq $columnName }).Count -eq 0) {
			$newKeys += [ordered]@{ name = $columnName; desc = $false }
			$pkChanges.Add("$($base['name']): ключ ($(@($keys | ForEach-Object { $_.name }) -join ', ')) -> ($(@($newKeys | ForEach-Object { $_.name }) -join ', ')); унікальність перевіряється вже з урахуванням $columnName")
		}
		$fkStatements = Get-IaRuleForeignKeyStatements -Logical $Logical -Schema $schema -Table $tableName -IndexName ([string]$base['name'])
		$supportName = $null
		if (@($fkStatements.drops).Count) {
			foreach ($statement in $fkStatements.drops) { $execute.Add($statement) }
			foreach ($name in $fkStatements.names) { $foreignKeys.Add("$name посилається на $($base['name']): тимчасово видаляється й відновлюється на окремому унікальному невирівняному індексі") }
		}
		$execute.Add("ALTER TABLE $tableSql DROP CONSTRAINT $(Format-IaRuleQuotedName $base['name']);")
		$execute.Add((Format-IaRuleConstraintSql -Index $base -Schema $schema -Table $tableName -Keys $newKeys -DataSpace $schemeSpaceSql -Online $online))
		if (@($fkStatements.drops).Count) {
			$supportName = Get-IaRuleIndexName -KeyColumns @($keys | ForEach-Object { $_.name }) -IsUnique $true
			$execute.Add(('CREATE UNIQUE NONCLUSTERED INDEX {0} ON {1} ({2})' -f (Format-IaRuleQuotedName $supportName), $tableSql, (Format-IaRuleKeyListSql -Keys $keys)) + "`r`n`t" + $(if ($online) { 'WITH (ONLINE = ON)' } else { 'WITH (DATA_COMPRESSION = NONE)' }) + "`r`n`tON $originalSpaceSql;")
			foreach ($statement in $fkStatements.adds) { $execute.Add($statement) }
			$nonAligned.Add("$supportName (унікальний індекс для FK, невирівняний)")
			foreach ($statement in $fkStatements.drops) { $rollback.Add($statement) }
			$rollback.Add("DROP INDEX $(Format-IaRuleQuotedName $supportName) ON $tableSql;")
		}
		$rollback.Add("ALTER TABLE $tableSql DROP CONSTRAINT $(Format-IaRuleQuotedName $base['name']);")
		$rollback.Add((Format-IaRuleConstraintSql -Index $base -Schema $schema -Table $tableName -Keys $keys -DataSpace $originalSpaceSql -Online $online))
		foreach ($statement in $fkStatements.adds) { $rollback.Add($statement) }
		$clusteredText = "Перебудова кластерного $(if ($base['isPrimaryKey']) { 'PK' } else { 'UNIQUE' }) $(Format-IaRuleQuotedName $base['name']) ($sizeText) на схемі секціонування: обмеження видаляється й створюється заново; на час операції таблиця без PK."
		$migration.Add("Перестворити $(Format-IaRuleQuotedName $base['name']) з ключем секціонування на схемі $(Format-IaRuleQuotedName $schemeName).")
	}
	else {
		$execute.Add((Format-IaRuleIndexCreateSql -Index $base -Schema $schema -Table $tableName -DataSpace $schemeSpaceSql -DropExisting $true -Online $online))
		$rollback.Add((Format-IaRuleIndexCreateSql -Index $base -Schema $schema -Table $tableName -DataSpace $originalSpaceSql -DropExisting $true -Online $online))
		if ($base['isUnique'] -and @(Get-IaRuleKeyColumns -Index $base | Where-Object { $_.name -eq $columnName }).Count -eq 0) {
			$pkChanges.Add("$($base['name']): унікальний кластерний індекс має містити $columnName у ключі — потрібна зміна визначення")
		}
		$clusteredText = "Перебудова кластерного індексу $(Format-IaRuleQuotedName $base['name']) ($sizeText) на схемі секціонування з DROP_EXISTING = ON."
		$migration.Add("Перебудувати $(Format-IaRuleQuotedName $base['name']) на схемі секціонування.")
	}

	# Некластерні індекси: вирівнювання.
	$aligned = [System.Collections.Generic.List[string]]::new()
	foreach ($index in @(Get-IaRuleActiveIndexes -Table $Table)) {
		if ($base -and [object]::ReferenceEquals($index, $base)) {
			continue
		}
		$typeDesc = [string]$index['typeDesc']
		if ($typeDesc -notin @('NONCLUSTERED', 'NONCLUSTERED COLUMNSTORE')) {
			$nonAligned.Add("$($index['name']) ($typeDesc)")
			continue
		}
		$isUnique = $index['isUnique'] -or $index['isUniqueConstraint']
		$hasColumn = @(Get-IaRuleKeyColumns -Index $index | Where-Object { $_.name -eq $columnName }).Count -gt 0
		if ($isUnique -and -not $hasColumn) {
			$nonAligned.Add("$($index['name']) (унікальний без $columnName)")
			$pkChanges.Add("$($index['name']): залишається невирівняним; щоб вирівняти, ключ має містити $columnName")
			continue
		}
		if ($index['isUniqueConstraint']) {
			$nonAligned.Add("$($index['name']) (обмеження UNIQUE)")
			continue
		}
		$originalIndexSpace = if ($index['dataSpaceName']) { Format-IaRuleQuotedName $index['dataSpaceName'] } else { $originalSpaceSql }
		$execute.Add((Format-IaRuleIndexCreateSql -Index $index -Schema $schema -Table $tableName -DataSpace $schemeSpaceSql -DropExisting $true -Online $online))
		$rollback.Insert(0, (Format-IaRuleIndexCreateSql -Index $index -Schema $schema -Table $tableName -DataSpace $originalIndexSpace -DropExisting $true -Online $online))
		$aligned.Add([string]$index['name'])
	}
	if ($aligned.Count) {
		$migration.Add("Перебудувати з вирівнюванням некластерні індекси: $($aligned -join ', ').")
	}
	if ($nonAligned.Count) {
		$migration.Add("Залишаються невирівняними (блокують SWITCH): $($nonAligned -join ', ').")
	}
	if (-not $schemeExists) { $rollbackTail.Add("DROP PARTITION SCHEME $(Format-IaRuleQuotedName $schemeName);") }
	if (-not $functionExists) { $rollbackTail.Add("DROP PARTITION FUNCTION $(Format-IaRuleQuotedName $functionName);") }

	foreach ($fk in @($Table['foreignKeys'])) {
		if ($fk -is [System.Collections.IDictionary]) {
			$foreignKeys.Add("$($fk['name']) ($schema.$tableName -> $($fk['referencedSchema']).$($fk['referencedTable'])): не змінюється; перевірки FK виконуються як раніше")
		}
	}
	$replication = if ($Table['isReplicated'] -eq $true -or @($Table['indexes'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['usedByReplication'] -eq $true }).Count) {
		'Таблиця бере участь у реплікації: зміна PK і перебудова потребують узгодження з публікацією (можлива повторна ініціалізація).'
	}
	elseif ($null -eq $Table['isReplicated']) {
		'Дані про реплікацію не зібрано: перевірити участь таблиці в публікаціях.'
	}
	else {
		'Таблиця не бере участі в реплікації.'
	}
	$filtered = @($Workload.queries | Where-Object { $_.columns -contains $columnName } | ForEach-Object { $_.queryId })
	$withoutFilter = @($Workload.queries | Where-Object { $_.columns -notcontains $columnName } | ForEach-Object { $_.queryId })
	$sharePercent = Format-IaRuleNumber (100 * $Share)
	$elimination = "Запити $(if ($filtered.Count) { $filtered -join ', ' } else { '-' }) фільтрують за $(Format-IaRuleQuotedName $columnName) ($sharePercent% навантаження, $($Workload.weightBasis)): очікується partition elimination."
	if ($withoutFilter.Count) {
		$elimination += " Без фільтра за ключем секціонування: $($withoutFilter -join ', ') — читатимуть усі секції."
	}
	$migration.Add('Оновити статистику й перевірити плани запитів після міграції, зокрема запитів без фільтра за ключем секціонування.')
	$migration.Add('Налаштувати обслуговування: щомісячне додавання меж (ALTER PARTITION SCHEME ... NEXT USED, ALTER PARTITION FUNCTION ... SPLIT RANGE) до появи даних.')
	foreach ($statement in $rollbackTail) { $rollback.Add($statement) }

	$estimate = Get-IaIndexCreateEstimate -Table $Table -KeyColumns @($columnName)
	return [ordered]@{
		action = 'PartitionTable'
		target = [ordered]@{ server = $Logical.server; database = $Logical.database; schema = $schema; table = $tableName; index = $null }
		title = "Секціонування $tableSql за $(Format-IaRuleQuotedName $columnName) (щомісячні секції)"
		rationale = "Таблиця $tableSql велика ($sizeText); $sharePercent% навантаження Query Store ($($Workload.weightBasis)) фільтрує за $(Format-IaRuleQuotedName $columnName). Секціонування дасть partition elimination і обслуговування по секціях."
		risk = [ordered]@{
			level = 'High'
			description = "Перебудова всієї таблиці ($sizeText, орієнтовно від $(Format-IaRuleNumber $estimate.estimatedBuildMinutes '0') хв і більше), зміна ключа PK/UNIQUE, вплив на FK і запити без фільтра за $columnName; потрібні вікно обслуговування, місце в журналі транзакцій і tempdb."
		}
		executeScript = ($execute -join "`r`n")
		rollbackScript = ($rollback -join "`r`n")
		affectedQueryIds = @($Workload.queries | ForEach-Object { [long]$_.queryId })
		replacesIndexes = @()
		confidence = 'Medium'
		partitioning = [ordered]@{
			partitionColumn = $columnName
			functionName = $functionName
			schemeName = $schemeName
			functionScript = $functionScript
			schemeScript = $schemeScript
			boundaries = @($boundaries)
			migrationPlan = @($migration)
			impact = [ordered]@{
				clusteredIndexRebuild = $clusteredText
				nonAlignedIndexes = @($nonAligned)
				primaryKeyAndUniqueChanges = @($pkChanges)
				foreignKeys = @($foreignKeys)
				replication = $replication
				queriesWithoutPartitionFilter = @($withoutFilter | ForEach-Object { [long]$_ })
			}
			maintenanceBenefits = "Sliding window: ALTER TABLE ... SWITCH PARTITION старих секцій в архівну таблицю й TRUNCATE TABLE $tableSql WITH (PARTITIONS (...)) замість масового DELETE; архівування старих секцій на окремі файлові групи з DATA_COMPRESSION = PAGE; ALTER INDEX ... REBUILD PARTITION = N лише для активних секцій; інкрементальна статистика (STATISTICS_INCREMENTAL = ON) і UPDATE STATISTICS ... WITH RESAMPLE ON PARTITIONS (...). SWITCH можливий лише за вирівняних індексів."
			eliminationAssessment = $elimination
		}
	}
}

function New-IaRuleFutureBoundariesDraft {
	<# Чернетка AlterPartitioning для функції секціонування: SPLIT RANGE на майбутні періоди — одна операція для всіх таблиць функції
	   (Tables — таблиці бази на цій функції; ціль — найбільша з них). NEXT USED задається для кожної схеми, що використовує функцію. #>
	param(
		[Parameter(Mandatory)]$Logical,
		[Parameter(Mandatory)][System.Collections.IDictionary[]]$Tables,
		[Parameter(Mandatory)][string[]]$NewBoundaries,
		[string[]]$Notes = @(),
		[bool]$LastPartitionFilled
	)
	$Table = @($Tables | Sort-Object { if ($null -ne $_['reservedMb']) { [double]$_['reservedMb'] } else { 0 } } -Descending)[0]
	$rangeRight = $Table['partitionRangeRight']
	$schema = [string]$Table['schema']
	$tableName = [string]$Table['name']
	$functionName = [string]$Table['partitionFunction']
	# Усі схеми бази на цій функції: без NEXT USED на кожній SPLIT RANGE завершиться помилкою.
	$schemeNames = @($Logical.primary.database['tables'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['partitionFunction'] -eq $functionName -and $_['partitionScheme'] } |
			ForEach-Object { [string]$_['partitionScheme'] } | Sort-Object -Unique)
	if ($schemeNames.Count -eq 0) {
		$schemeNames = @([string]$Table['partitionScheme'])
	}
	$tableNames = @($Logical.primary.database['tables'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['partitionFunction'] -eq $functionName } |
			ForEach-Object { "[$($_['schema'])].[$($_['name'])]" } | Sort-Object -Unique)
	$schemeLines = [System.Collections.Generic.List[string]]::new()
	$functionLines = [System.Collections.Generic.List[string]]::new()
	$execute = [System.Collections.Generic.List[string]]::new()
	$rollback = [System.Collections.Generic.List[string]]::new()
	foreach ($boundary in $NewBoundaries) {
		foreach ($schemeName in $schemeNames) {
			$schemeLine = "ALTER PARTITION SCHEME $(Format-IaRuleQuotedName $schemeName) NEXT USED [PRIMARY];"
			$schemeLines.Add($schemeLine)
			$execute.Add($schemeLine)
		}
		$functionLine = "ALTER PARTITION FUNCTION $(Format-IaRuleQuotedName $functionName) () SPLIT RANGE ($boundary);"
		$functionLines.Add($functionLine)
		$execute.Add($functionLine)
		$rollback.Insert(0, "ALTER PARTITION FUNCTION $(Format-IaRuleQuotedName $functionName) () MERGE RANGE ($boundary);")
	}
	$schemeName = $schemeNames[0]
	$riskText = "SPLIT RANGE — одна операція над функцією $(Format-IaRuleQuotedName $functionName) для всіх таблиць на ній ($($tableNames.Count): $(@($tableNames | Select-Object -First 10) -join ', ')$(if ($tableNames.Count -gt 10) { ', …' }))"
	if ($LastPartitionFilled) { $riskText += '; остання секція не порожня — SPLIT читає її під блокуванням Sch-M на всіх таблицях функції і переміщує рядки, новіші за межу' }
	return [ordered]@{
		action = 'AlterPartitioning'
		target = [ordered]@{ server = $Logical.server; database = $Logical.database; schema = $schema; table = $tableName; index = $null }
		title = "Межі на майбутні періоди для функції $(Format-IaRuleQuotedName $functionName) ($($tableNames.Count) табл.)"
		rationale = ('Попереду замало порожніх секцій: ' + ($Notes -join '; ') + '. Нові дані потраплятимуть в останню секцію, і подальший SPLIT стане дорогим.')
		risk = [ordered]@{ level = $(if ($LastPartitionFilled) { 'Medium' } else { 'Low' }); description = $riskText }
		executeScript = ($execute -join "`r`n")
		rollbackScript = ($rollback -join "`r`n")
		affectedQueryIds = @()
		replacesIndexes = @()
		confidence = $(if ($null -eq $rangeRight) { 'Low' } else { 'High' })
		partitioning = [ordered]@{
			partitionColumn = [string]$Table['partitionColumn']
			functionName = $functionName
			schemeName = $schemeName
			functionScript = ($functionLines -join "`r`n")
			schemeScript = ($schemeLines -join "`r`n")
			boundaries = @($NewBoundaries)
			migrationPlan = @(
				$(if ($null -eq $rangeRight) {
						"Тип функції $(Format-IaRuleQuotedName $functionName) (RANGE LEFT чи RIGHT) не зібрано: перевірити sys.partition_functions.boundary_value_on_right і значення меж перед SPLIT."
					}
					elseif ($rangeRight) {
						"Функція RANGE RIGHT: кожна нова межа — початок секції нового періоду."
					}
					else {
						"Функція RANGE LEFT: кожна нова межа — кінець (включно) секції нового періоду."
					})
				"Перевірити файлову групу для нових секцій (NEXT USED): за конвенцією <база>_<схема>_<yyyy>_<MM>; у чернетці — [PRIMARY]."
				"Перевірити, що NEXT USED задано для кожної схеми на функції (sys.partition_schemes за function_id), зокрема для таблиць поза межами аналізу."
				"Виконати SPLIT RANGE для кожної нової межі до появи даних відповідного періоду."
				'Додати додавання меж у регулярне обслуговування (наприклад, щомісячне завдання SQL Agent).'
			)
			impact = [ordered]@{
				clusteredIndexRebuild = $(if ($LastPartitionFilled) { 'Перебудова не потрібна, але SPLIT непорожньої останньої секції переміщує її дані.' } else { 'Перебудова не потрібна: SPLIT порожньої секції — лише зміна метаданих.' })
				nonAlignedIndexes = @()
				primaryKeyAndUniqueChanges = @()
				foreignKeys = @()
				replication = $(if ($Table['isReplicated'] -eq $true) { 'Таблиця реплікується: перевірити вплив на публікацію.' } else { 'Не впливає.' })
				queriesWithoutPartitionFilter = @()
			}
			maintenanceBenefits = 'Порожні секції попереду дозволяють додавати межі без переміщення даних і підтримувати sliding window (SWITCH, TRUNCATE ... WITH PARTITIONS).'
			eliminationAssessment = $null
		}
	}
}

function Invoke-IaPartitionAnalysis {
	<# Модуль партиціонування (розділ 4.6), незалежний від аналізу індексів. Нічого не виконує.
	   Повертає @{ findings = @(New-IaFinding); drafts = @(чернетки у форматі llm-response recommendations з partitioning) }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$settings = $Config.partitioning
	$findings = [System.Collections.Generic.List[object]]::new()
	$drafts = [System.Collections.Generic.List[object]]::new()
	$functionGroups = [ordered]@{}
	$collected = ConvertTo-IaRuleUtcDate $Snapshot['collectedAtUtc']
	if ($null -eq $collected) { $collected = [datetime]::UtcNow }
	foreach ($logical in @(Get-IaRuleLogicalDatabases -Snapshot $Snapshot)) {
		foreach ($table in @($logical.primary.database['tables'])) {
			if ($table -isnot [System.Collections.IDictionary] -or $table['type'] -ne 'USER_TABLE' -or $table['isMemoryOptimized']) {
				continue
			}
			$schema = [string]$table['schema']
			$tableName = [string]$table['name']
			$tableSql = "[$schema].[$tableName]"
			$target = New-IaTarget -Server $logical.server -Database $logical.database -Schema $schema -Table $tableName -Index $null
			$workload = Get-IaRuleTableWorkload -Logical $logical -Schema $schema -Table $tableName
			$periodColumns = @($table['columns'] | Where-Object { $_ -is [System.Collections.IDictionary] -and (Get-IaRulePeriodColumnFormat -Column $_) })
			if (-not $table['isPartitioned']) {
				if ($null -eq $table['rowCount'] -or $null -eq $table['reservedMb']) {
					continue
				}
				$sizeGb = [double]$table['reservedMb'] / 1024
				if ($sizeGb -lt [double]$settings.minSizeGb -or [long]$table['rowCount'] -lt [long]$settings.minRowCount) {
					continue
				}
				$best = $null
				$bestShare = 0
				foreach ($column in $periodColumns) {
					$share = Get-IaRuleColumnShare -Workload $workload -Column ([string]$column['name'])
					if ($share -gt $bestShare) {
						$best = $column
						$bestShare = $share
					}
				}
				$details = [ordered]@{
					rowCount = [long]$table['rowCount']
					sizeGb = [math]::Round($sizeGb, 2)
					partitionColumn = $(if ($best) { [string]$best['name'] } else { $null })
					dateFilterShare = [math]::Round($bestShare, 4)
					weightBasis = $workload.weightBasis
					queryIds = @($workload.queries | ForEach-Object { $_.queryId })
				}
				if ($best -and $bestShare -ge [double]$settings.minDateFilterShare -and $workload.totalWeight -gt 0) {
					$message = "Таблиця $tableSql ($([long]$table['rowCount']) рядків, $(Format-IaRuleNumber $sizeGb) ГБ) — кандидат на секціонування за [$($best['name'])]: $(Format-IaRuleNumber (100 * $bestShare))% навантаження фільтрує за цим стовпцем"
					$findings.Add((New-IaFinding -RuleId 'PartitionCandidate' -Severity 'Medium' -Target $target -Message $message -SuggestedAction 'PartitionTable' -Details $details))
					$drafts.Add((New-IaRulePartitionTableDraft -Snapshot $Snapshot -Logical $logical -Table $table -Column $best -Workload $workload -Share $bestShare -Config $Config))
				}
				else {
					$reason = if ($workload.totalWeight -le 0) { 'у Query Store немає запитів до таблиці' } else { "найбільша частка запитів з фільтром за датою чи періодом $(Format-IaRuleNumber (100 * $bestShare))% менша за поріг $(Format-IaRuleNumber (100 * [double]$settings.minDateFilterShare))%" }
					$findings.Add((New-IaFinding -RuleId 'PartitionNotBeneficial' -Severity 'Info' -Target $target -Message "Таблиця $tableSql велика, але секціонування не рекомендовано: $reason" -Details $details))
				}
				continue
			}

			# Секціонована таблиця: partition elimination, перекіс, порожні й переповнені секції, межі на майбутні періоди.
			$partitionColumn = [string]$table['partitionColumn']
			$noElimination = @($workload.queries | Where-Object { $_.elimination -contains 'No' })
			$withoutFilter = @($workload.queries | Where-Object { $partitionColumn -and $_.columns -notcontains $partitionColumn })
			if ($noElimination.Count -or $withoutFilter.Count) {
				$affected = @{}
				foreach ($item in @($noElimination) + @($withoutFilter)) { $affected[$item.queryId] = $item.weight }
				$weight = ($affected.Values | Measure-Object -Sum).Sum
				$share = if ($workload.totalWeight -gt 0) { [double]$weight / $workload.totalWeight } else { 0 }
				$message = "Partition elimination на $tableSql не працює для частини запитів ($(Format-IaRuleNumber (100 * $share))% навантаження): без elimination — $(@($noElimination | ForEach-Object { $_.queryId }) -join ', '); без фільтра за [$partitionColumn] — $(@($withoutFilter | ForEach-Object { $_.queryId }) -join ', ')"
				$findings.Add((New-IaFinding -RuleId 'PartitionElimination' -Severity $(if ($share -ge 0.2) { 'Medium' } else { 'Low' }) -Target $target -Message $message -Details ([ordered]@{
								queriesWithoutElimination = @($noElimination | ForEach-Object { $_.queryId })
								queriesWithoutPartitionFilter = @($withoutFilter | ForEach-Object { $_.queryId })
								share = [math]::Round($share, 4)
								weightBasis = $workload.weightBasis
							})))
			}
			$base = Get-IaRuleBaseIndex -Table $table
			$partitions = @()
			if ($base -and $base['partitions']) {
				$partitions = @($base['partitions'] | Where-Object { $_ -is [System.Collections.IDictionary] } | Sort-Object { [int]$_['partitionNumber'] })
			}
			if ($partitions.Count -lt 2) {
				continue
			}
			$rows = @($partitions | ForEach-Object { [long]$_['rowCount'] })
			$nonEmpty = @($rows | Where-Object { $_ -gt 0 } | Sort-Object)
			if ($nonEmpty.Count -ge 2) {
				$median = if ($nonEmpty.Count % 2) { [double]$nonEmpty[[int][math]::Floor($nonEmpty.Count / 2)] } else { ([double]$nonEmpty[$nonEmpty.Count / 2 - 1] + [double]$nonEmpty[$nonEmpty.Count / 2]) / 2 }
				$max = [double]$nonEmpty[-1]
				if ($median -gt 0 -and $max / $median -gt [double]$settings.maxPartitionSkewRatio) {
					$largest = $partitions | Sort-Object { [long]$_['rowCount'] } -Descending | Select-Object -First 1
					$findings.Add((New-IaFinding -RuleId 'PartitionSkew' -Severity 'Low' -Target $target -Message "Перекіс секцій $tableSql`: найбільша секція $($largest['partitionNumber']) ($([long]$largest['rowCount']) рядків) у $(Format-IaRuleNumber ($max / $median)) раза більша за медіану" -Details ([ordered]@{
									largestPartition = [int]$largest['partitionNumber']
									largestRows = [long]$largest['rowCount']
									medianRows = $median
									threshold = [double]$settings.maxPartitionSkewRatio
								})))
				}
			}
			$firstFilled = [array]::FindIndex([long[]]$rows, [Predicate[long]] { param($value) $value -gt 0 })
			$lastFilled = [array]::FindLastIndex([long[]]$rows, [Predicate[long]] { param($value) $value -gt 0 })
			$gaps = @()
			if ($firstFilled -ge 0) {
				for ($i = $firstFilled + 1; $i -lt $lastFilled; $i++) {
					if ($rows[$i] -eq 0) { $gaps += [int]$partitions[$i]['partitionNumber'] }
				}
			}
			if ($gaps.Count) {
				$findings.Add((New-IaFinding -RuleId 'EmptyPartitions' -Severity 'Low' -Target $target -Message "Порожні секції між заповненими на ${tableSql}: $($gaps -join ', ') — перевірити межі функції $($table['partitionFunction'])" -Details ([ordered]@{ emptyPartitions = @($gaps) })))
			}
			$lastPartition = $partitions[-1]
			$lastIsFilled = [long]$lastPartition['rowCount'] -gt 0
			if ($lastIsFilled) {
				$findings.Add((New-IaFinding -RuleId 'PartitionOverflow' -Severity 'Medium' -Target $target -Message "Остання секція $($lastPartition['partitionNumber']) на $tableSql містить $([long]$lastPartition['rowCount']) рядків: немає порожньої секції попереду, SPLIT переміщуватиме дані" -SuggestedAction 'AlterPartitioning' -Details ([ordered]@{
								partitionNumber = [int]$lastPartition['partitionNumber']
								rowCount = [long]$lastPartition['rowCount']
							})))
			}
			# Межі на майбутні періоди (лише для стовпців дати чи періоду з розпізнаними межами).
			$column = Find-IaRuleColumn -Table $table -Name $partitionColumn
			$format = if ($column) { Get-IaRulePeriodColumnFormat -Column $column } else { $null }
			$boundaries = @($partitions | ForEach-Object { ConvertFrom-IaRuleBoundaryValue $_['boundaryValue'] } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
			if ($null -eq $format -or $boundaries.Count -lt 2) {
				continue
			}
			$futureCount = @($boundaries | Where-Object { $_ -gt $collected }).Count
			$required = [int]$settings.minFuturePartitions
			if ($futureCount -ge $required) {
				continue
			}
			$days = ($boundaries[-1] - $boundaries[-2]).TotalDays
			$step = if ($days -le 1.5) { 'Day' } elseif ($days -ge 27 -and $days -le 32) { 'Month' } elseif ($days -ge 88 -and $days -le 93) { 'Quarter' } elseif ($days -ge 364 -and $days -le 367) { 'Year' } else { 'Days' }
			# Межі минулих періодів не пропонуються: якщо останню межу давно не додавали, SPLIT за минулий період переміщував би дані
			# накопиченої останньої секції під Sch-M на всіх таблицях функції. Сітка меж продовжується до поточного моменту без SPLIT.
			$next = $boundaries[-1]
			$skippedPast = 0
			while ($skippedPast -lt 100000) {
				$candidate = Add-IaRulePeriodStep -Date $next -Step $step -Days $days
				if ($candidate -gt $collected) {
					break
				}
				$next = $candidate
				$skippedPast++
			}
			$newBoundaries = [System.Collections.Generic.List[string]]::new()
			while ($newBoundaries.Count -lt $required - $futureCount -and $newBoundaries.Count -lt 120) {
				$next = Add-IaRulePeriodStep -Date $next -Step $step -Days $days
				$newBoundaries.Add((Format-IaRuleBoundaryLiteral -Date $next -Format $format))
			}
			# Кількість повністю майбутніх секцій дорівнює кількості меж після поточного моменту і для RANGE RIGHT (межа — початок секції),
			# і для RANGE LEFT (межа — кінець секції, плюс остання відкрита секція); partitionRangeRight уточнює тлумачення в повідомленнях.
			$rangeRight = $table['partitionRangeRight']
			$rangeText = if ($null -eq $rangeRight) { 'тип RANGE невідомий' } elseif ($rangeRight) { 'RANGE RIGHT: межа — початок секції' } else { 'RANGE LEFT: межа — кінець секції' }
			$notes = @("майбутніх секцій $futureCount, потрібно не менше $required (partitioning.minFuturePartitions)", "остання межа $($boundaries[-1].ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture))", $rangeText)
			if ($skippedPast -gt 0) {
				$notes += "останню межу не додавали $skippedPast період(ів): остання секція накопичує дані за них; межі минулих періодів не пропонуються (SPLIT переміщував би ці дані), перерозподіл історії — окремим етапом через SWITCH і staging-таблицю"
			}
			$findings.Add((New-IaFinding -RuleId 'PartitionFutureBoundaries' -Severity 'Medium' -Target $target -Message "На $tableSql замало меж на майбутні періоди: $($notes -join '; ')" -SuggestedAction 'AlterPartitioning' -Details ([ordered]@{
							futureBoundaries = $futureCount
							required = $required
							step = $step
							rangeRight = $rangeRight
							skippedPastPeriods = $skippedPast
							proposedBoundaries = @($newBoundaries)
						})))
			# Межі змінюються на рівні функції: одна чернетка на функцію бази, а не на кожну таблицю (інакше SPLIT дублювався б).
			$functionKey = ('{0}|{1}|{2}' -f $logical.server, $logical.database, $table['partitionFunction']).ToLowerInvariant()
			if (-not $functionGroups.Contains($functionKey)) {
				$functionGroups[$functionKey] = @{ logical = $logical; tables = [System.Collections.Generic.List[System.Collections.IDictionary]]::new(); boundaries = @($newBoundaries); notes = $notes; lastFilled = $false }
			}
			$functionGroups[$functionKey].tables.Add($table)
			$functionGroups[$functionKey].lastFilled = $functionGroups[$functionKey].lastFilled -or $lastIsFilled
		}
	}
	foreach ($group in $functionGroups.Values) {
		$drafts.Add((New-IaRuleFutureBoundariesDraft -Logical $group.logical -Tables $group.tables.ToArray() -NewBoundaries $group.boundaries -Notes $group.notes -LastPartitionFilled $group.lastFilled))
	}
	return [ordered]@{ findings = @($findings); drafts = @($drafts) }
}
