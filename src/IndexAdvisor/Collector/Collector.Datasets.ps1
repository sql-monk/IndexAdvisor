# Збір наборів даних однієї бази (ТЗ 4.1): структура, usage, operational, розмір і фрагментація, missing index, обмеження й реплікація.
# Кожна функція отримує контекст бази $DbCtx (див. New-IaColDatabaseContext у Collector.Collection.ps1).

function Invoke-IaColDbQuery {
	<# Запит колектора в контексті бази (сервер, база, ApplicationIntent). #>
	param(
		[Parameter(Mandatory)][hashtable]$DbCtx,
		[Parameter(Mandatory)][string]$Name,
		[System.Collections.IDictionary]$Parameters = @{},
		[int]$PageSize = 0,
		[switch]$SinglePage,
		[System.Collections.IDictionary]$Config
	)
	$splat = @{
		Name = $Name
		Server = $DbCtx.Server
		Database = $DbCtx.Name
		Config = $(if ($Config) { $Config } else { $DbCtx.Config })
		Parameters = $Parameters
		PageSize = $PageSize
		SinglePage = $SinglePage
	}
	if ($DbCtx.Intent) {
		$splat.ApplicationIntent = $DbCtx.Intent
	}
	return Invoke-IaColQuery @splat
}

function Add-IaColDbWarning {
	<# Попередження рівня бази. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx, [Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message, [string]$Dataset)
	Add-IaColWarning -List $DbCtx.Database.warnings -Code $Code -Message $Message -Dataset $Dataset -Server $DbCtx.ServerName -Database $DbCtx.Name
}

function Get-IaColIndexKey {
	param($ObjectId, $IndexId)
	return ('{0}|{1}' -f [long]$ObjectId, [long]$IndexId)
}

function Add-IaColStructure {
	<# Обов'язковий набір indexStructure: таблиці, колонки, індекси, ключові й included-колонки. Помилка — виняток (база пропускається). #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$results = [ordered]@{}
	foreach ($name in @('tables', 'columns', 'indexes', 'index_columns')) {
		$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name $name
		if (-not $result.success) {
			throw ("Структуру індексів не зібрано (запит {0}): {1}" -f $name, $result.error.message)
		}
		$results[$name] = $result.rows
	}
	$scope = $DbCtx.Context.Scope
	foreach ($row in $results['tables']) {
		$schema = [string](Get-IaColValue $row 'schemaName')
		$tableName = [string](Get-IaColValue $row 'tableName')
		if (-not (Test-IaColTableInScope -Schema $schema -Table $tableName -Scope $scope)) {
			continue
		}
		$objectId = ConvertTo-IaColLong (Get-IaColValue $row 'objectId')
		$isPartitioned = ConvertTo-IaColBool (Get-IaColValue $row 'isPartitioned')
		$table = [ordered]@{
			objectId = $objectId
			schema = $schema
			name = $tableName
			type = $(if ((Get-IaColValue $row 'objectType') -eq 'VIEW') { 'VIEW' } else { 'USER_TABLE' })
			isPartitioned = $isPartitioned
			partitionScheme = Get-IaColValue $row 'partitionScheme'
			partitionFunction = Get-IaColValue $row 'partitionFunction'
			partitionColumn = Get-IaColValue $row 'partitionColumn'
			partitionRangeRight = $(if ($isPartitioned -and $null -ne (Get-IaColValue $row 'partitionRangeRight')) { ConvertTo-IaColBool (Get-IaColValue $row 'partitionRangeRight') } else { $null })
			rowCount = $null
			reservedMb = $null
			usedMb = $null
			isReplicated = $null
			isMemoryOptimized = ConvertTo-IaColBool (Get-IaColValue $row 'isMemoryOptimized')
			columns = [System.Collections.Generic.List[object]]::new()
			indexes = [System.Collections.Generic.List[object]]::new()
			foreignKeys = [System.Collections.Generic.List[object]]::new()
		}
		$DbCtx.Tables[[string]$objectId] = $table
		$DbCtx.TableFlags[[string]$objectId] = @{ isReplicated = ConvertTo-IaColBool (Get-IaColValue $row 'isReplicated'); rowGuidColumns = @() }
		$DbCtx.Database.tables.Add($table)
	}
	foreach ($row in $results['columns']) {
		$table = $DbCtx.Tables[[string](ConvertTo-IaColLong (Get-IaColValue $row 'objectId'))]
		if ($null -eq $table) {
			continue
		}
		$columnName = [string](Get-IaColValue $row 'columnName')
		$table.columns.Add([ordered]@{
				columnId = ConvertTo-IaColLong (Get-IaColValue $row 'columnId')
				name = $columnName
				typeName = [string](Get-IaColValue $row 'typeName')
				maxLength = ConvertTo-IaColLong (Get-IaColValue $row 'maxLength') -Default 0
				precision = ConvertTo-IaColLong (Get-IaColValue $row 'columnPrecision') -Default 0
				scale = ConvertTo-IaColLong (Get-IaColValue $row 'columnScale') -Default 0
				isNullable = ConvertTo-IaColBool (Get-IaColValue $row 'isNullable')
				isComputed = ConvertTo-IaColBool (Get-IaColValue $row 'isComputed')
				isIdentity = ConvertTo-IaColBool (Get-IaColValue $row 'isIdentity')
			})
		if (ConvertTo-IaColBool (Get-IaColValue $row 'isRowGuidCol')) {
			$flags = $DbCtx.TableFlags[[string]$table.objectId]
			$flags.rowGuidColumns = @($flags.rowGuidColumns) + $columnName
		}
	}
	foreach ($row in $results['indexes']) {
		$objectId = ConvertTo-IaColLong (Get-IaColValue $row 'objectId')
		$table = $DbCtx.Tables[[string]$objectId]
		if ($null -eq $table) {
			continue
		}
		$indexId = ConvertTo-IaColLong (Get-IaColValue $row 'indexId')
		$compressionMin = Get-IaColValue $row 'compressionMin'
		$compressionMax = Get-IaColValue $row 'compressionMax'
		$compression = if ($null -eq $compressionMin) { 'NONE' } elseif ($compressionMin -eq $compressionMax) { [string]$compressionMin } else { 'MIXED' }
		$indexName = Get-IaColValue $row 'indexName'
		$index = [ordered]@{
			indexId = $indexId
			name = $(if ($null -ne $indexName) { [string]$indexName } else { $null })
			typeDesc = [string](Get-IaColValue $row 'typeDesc')
			isPrimaryKey = ConvertTo-IaColBool (Get-IaColValue $row 'isPrimaryKey')
			isUnique = ConvertTo-IaColBool (Get-IaColValue $row 'isUnique')
			isUniqueConstraint = ConvertTo-IaColBool (Get-IaColValue $row 'isUniqueConstraint')
			isDisabled = ConvertTo-IaColBool (Get-IaColValue $row 'isDisabled')
			isHypothetical = ConvertTo-IaColBool (Get-IaColValue $row 'isHypothetical')
			hasFilter = ConvertTo-IaColBool (Get-IaColValue $row 'hasFilter')
			filterDefinition = Get-IaColValue $row 'filterDefinition'
			fillFactor = ConvertTo-IaColLong (Get-IaColValue $row 'indexFillFactor') -Default 0
			isPadded = ConvertTo-IaColBool (Get-IaColValue $row 'isPadded')
			allowRowLocks = ConvertTo-IaColBool (Get-IaColValue $row 'allowRowLocks') -Default $true
			allowPageLocks = ConvertTo-IaColBool (Get-IaColValue $row 'allowPageLocks') -Default $true
			ignoreDupKey = ConvertTo-IaColBool (Get-IaColValue $row 'ignoreDupKey')
			compression = $compression
			dataSpaceName = Get-IaColValue $row 'dataSpaceName'
			dataSpaceType = Get-IaColValue $row 'dataSpaceType'
			partitionColumn = $null
			isAligned = $null
			keyColumns = [System.Collections.Generic.List[object]]::new()
			includedColumns = [System.Collections.Generic.List[object]]::new()
			rowCount = $null
			usedMb = $null
			reservedMb = $null
			partitions = $null
			statsLastUpdatedUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'statsLastUpdatedUtc')
			lastRebuildUtc = $null
			usage = $null
			operational = $null
			physical = $null
			referencedByForeignKeys = $null
			coversForeignKeys = $null
			usedByReplication = $null
			hintReferences = $null
			queryStoreUsage = $null
		}
		$table.indexes.Add($index)
		$key = Get-IaColIndexKey $objectId $indexId
		$DbCtx.IndexMap[$key] = $index
		$DbCtx.IndexEntries.Add(@{ table = $table; index = $index; partitionFunction = Get-IaColValue $row 'partitionFunction' })
		if ($null -ne $index.name) {
			$nameKey = $index.name.ToLowerInvariant()
			if (-not $DbCtx.IndexesByName.ContainsKey($nameKey)) {
				$DbCtx.IndexesByName[$nameKey] = [System.Collections.Generic.List[object]]::new()
			}
			$DbCtx.IndexesByName[$nameKey].Add(@{ table = $table; index = $index })
		}
	}
	foreach ($row in $results['index_columns']) {
		$index = $DbCtx.IndexMap[(Get-IaColIndexKey (Get-IaColValue $row 'objectId') (Get-IaColValue $row 'indexId'))]
		if ($null -eq $index) {
			continue
		}
		$columnName = [string](Get-IaColValue $row 'columnName')
		$keyOrdinal = ConvertTo-IaColLong (Get-IaColValue $row 'keyOrdinal') -Default 0
		if ($keyOrdinal -gt 0) {
			$index.keyColumns.Add([ordered]@{ name = $columnName; keyOrdinal = $keyOrdinal; isDescending = ConvertTo-IaColBool (Get-IaColValue $row 'isDescending') })
		}
		elseif ((ConvertTo-IaColBool (Get-IaColValue $row 'isIncluded')) -or $index.typeDesc -like '*COLUMNSTORE*') {
			$index.includedColumns.Add($columnName)
		}
		if ((ConvertTo-IaColLong (Get-IaColValue $row 'partitionOrdinal') -Default 0) -eq 1) {
			$index.partitionColumn = $columnName
		}
	}
	foreach ($entry in $DbCtx.IndexEntries) {
		$table = $entry.table
		$index = $entry.index
		if ($table.isPartitioned) {
			$index.isAligned = ($index.dataSpaceType -eq 'PARTITION_SCHEME') -and
				([string]$entry.partitionFunction -eq [string]$table.partitionFunction) -and
				([string]$index.partitionColumn -eq [string]$table.partitionColumn)
		}
	}
}

function Add-IaColUsage {
	<# Набір usageStats: відсутній рядок DMV — нулі. Повертає $true, якщо зібрано. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'index_usage'
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'usageStats' -Message ("Usage stats не зібрано: {0}" -f $result.error.message)
		return $false
	}
	$map = @{}
	foreach ($row in $result.rows) {
		$map[(Get-IaColIndexKey (Get-IaColValue $row 'objectId') (Get-IaColValue $row 'indexId'))] = $row
	}
	foreach ($key in $DbCtx.IndexMap.Keys) {
		$row = $map[$key]
		$DbCtx.IndexMap[$key].usage = [ordered]@{
			userSeeks = ConvertTo-IaColLong (Get-IaColValue $row 'userSeeks') -Default 0
			userScans = ConvertTo-IaColLong (Get-IaColValue $row 'userScans') -Default 0
			userLookups = ConvertTo-IaColLong (Get-IaColValue $row 'userLookups') -Default 0
			userUpdates = ConvertTo-IaColLong (Get-IaColValue $row 'userUpdates') -Default 0
			lastUserSeekUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'lastUserSeekUtc')
			lastUserScanUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'lastUserScanUtc')
			lastUserLookupUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'lastUserLookupUtc')
			lastUserUpdateUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'lastUserUpdateUtc')
		}
	}
	return $true
}

function Add-IaColOperational {
	<# Набір operationalStats (сума по секціях; відсутній рядок — нулі). #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'index_operational'
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'operationalStats' -Message ("Operational stats не зібрано: {0}" -f $result.error.message)
		return $false
	}
	$map = @{}
	foreach ($row in $result.rows) {
		$map[(Get-IaColIndexKey (Get-IaColValue $row 'objectId') (Get-IaColValue $row 'indexId'))] = $row
	}
	$fields = @('leafInsertCount', 'leafUpdateCount', 'leafDeleteCount', 'leafPageSplitCount', 'nonleafPageSplitCount', 'rowLockWaitCount', 'rowLockWaitMs',
		'pageLockWaitCount', 'pageLockWaitMs', 'pageLatchWaitCount', 'pageLatchWaitMs', 'pageIoLatchWaitCount', 'pageIoLatchWaitMs', 'lockEscalationCount')
	foreach ($key in $DbCtx.IndexMap.Keys) {
		$row = $map[$key]
		$operational = [ordered]@{}
		foreach ($field in $fields) {
			$operational[$field] = ConvertTo-IaColLong (Get-IaColValue $row $field) -Default 0
		}
		$DbCtx.IndexMap[$key].operational = $operational
	}
	return $true
}

function Add-IaColSize {
	<# Набір sizeAndFragmentation: sys.dm_db_partition_stats по секціях і physical_stats (LIMITED) у межах бюджету часу. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'partition_stats'
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'sizeAndFragmentation' -Message ("Розмір секцій не зібрано: {0}" -f $result.error.message)
		return $false
	}
	foreach ($entry in $DbCtx.IndexEntries) {
		$entry.index.partitions = [System.Collections.Generic.List[object]]::new()
		$entry.index.rowCount = [long]0
		$entry.index.usedMb = [double]0
		$entry.index.reservedMb = [double]0
	}
	foreach ($table in $DbCtx.Tables.Values) {
		$table.rowCount = [long]0
		$table.usedMb = [double]0
		$table.reservedMb = [double]0
	}
	foreach ($row in $result.rows) {
		$objectId = Get-IaColValue $row 'objectId'
		$indexId = ConvertTo-IaColLong (Get-IaColValue $row 'indexId')
		$index = $DbCtx.IndexMap[(Get-IaColIndexKey $objectId $indexId)]
		if ($null -eq $index) {
			continue
		}
		$table = $DbCtx.Tables[[string](ConvertTo-IaColLong $objectId)]
		$rows = ConvertTo-IaColLong (Get-IaColValue $row 'partitionRows') -Default 0
		$usedMb = ConvertTo-IaColDouble (Get-IaColValue $row 'usedMb') -Default 0 -Digits 3
		$reservedMb = ConvertTo-IaColDouble (Get-IaColValue $row 'reservedMb') -Default 0 -Digits 3
		$index.partitions.Add([ordered]@{
				partitionNumber = ConvertTo-IaColLong (Get-IaColValue $row 'partitionNumber')
				rowCount = $rows
				usedMb = [Math]::Round($usedMb, 2)
				reservedMb = [Math]::Round($reservedMb, 2)
				compression = Get-IaColValue $row 'compressionDesc'
				boundaryValue = Get-IaColValue $row 'boundaryValue'
			})
		$index.rowCount += $rows
		$index.usedMb += $usedMb
		$index.reservedMb += $reservedMb
		if ($indexId -le 1) {
			$table.rowCount += $rows
		}
		$table.usedMb += $usedMb
		$table.reservedMb += $reservedMb
	}
	foreach ($entry in $DbCtx.IndexEntries) {
		$entry.index.usedMb = [Math]::Round($entry.index.usedMb, 2)
		$entry.index.reservedMb = [Math]::Round($entry.index.reservedMb, 2)
	}
	foreach ($table in $DbCtx.Tables.Values) {
		$table.usedMb = [Math]::Round($table.usedMb, 2)
		$table.reservedMb = [Math]::Round($table.reservedMb, 2)
	}
	Add-IaColPhysicalStats -DbCtx $DbCtx
	return $true
}

function New-IaColSkippedPhysical {
	param([Parameter(Mandatory)][string]$Reason)
	return [ordered]@{ avgFragmentationPercent = $null; pageCount = $null; fragmentCount = $null; mode = 'LIMITED'; skipped = $true; skipReason = $Reason }
}

function Get-IaColPhysicalNotApplicableReason {
	<# Причина, з якої physical_stats не застосовується до індексу, або $null. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx, $Table, $Index)
	if ($DbCtx.Database.replicaRole -eq 'SECONDARY') {
		return 'Вторинна репліка: фрагментація збирається лише на primary (фізична структура реплік однакова, зайве навантаження не створюється)'
	}
	if ($Table.isMemoryOptimized) {
		return 'Таблиця In-Memory OLTP: sys.dm_db_index_physical_stats не застосовується'
	}
	if ($Index.typeDesc -like '*COLUMNSTORE*') {
		return 'Columnstore: стан оцінюється за сегментами й rowgroup, а не за sys.dm_db_index_physical_stats'
	}
	if ($Index.typeDesc -notin @('HEAP', 'CLUSTERED', 'NONCLUSTERED')) {
		return ("Тип індексу {0}: фрагментація не збирається" -f $Index.typeDesc)
	}
	if ($Index.isDisabled) {
		return 'Індекс вимкнено (DISABLE): даних немає'
	}
	if ($Index.isHypothetical) {
		return 'Гіпотетичний індекс: даних немає'
	}
	return $null
}

function Add-IaColPhysicalStats {
	<# sys.dm_db_index_physical_stats (LIMITED) по одному індексу, від найбільших; після вичерпання collector.physicalStatsTimeBudgetSeconds
	   решта індексів позначається skipped. Таймаут кожного виклику не перевищує залишку бюджету. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$config = $DbCtx.Config
	$budgetSeconds = [int]$config.collector.physicalStatsTimeBudgetSeconds
	$budgetMs = [long]$budgetSeconds * 1000
	$commandTimeout = [int]$config.connection.commandTimeoutSeconds
	$entries = @($DbCtx.IndexEntries | Sort-Object -Property @{ Expression = { if ($null -ne $_.index.usedMb) { [double]$_.index.usedMb } else { 0 } }; Descending = $true },
		@{ Expression = { [long]$_.table.objectId } }, @{ Expression = { [long]$_.index.indexId } })
	$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	$serverDurationMs = [long]0
	$budgetSkipped = 0
	$failed = 0
	foreach ($entry in $entries) {
		$index = $entry.index
		$reason = Get-IaColPhysicalNotApplicableReason -DbCtx $DbCtx -Table $entry.table -Index $index
		if ($reason) {
			$index.physical = New-IaColSkippedPhysical -Reason $reason
			continue
		}
		$spentMs = [Math]::Max($stopwatch.ElapsedMilliseconds, $serverDurationMs)
		if ($spentMs -ge $budgetMs) {
			$index.physical = New-IaColSkippedPhysical -Reason ("Вичерпано бюджет часу collector.physicalStatsTimeBudgetSeconds = {0} с" -f $budgetSeconds)
			$budgetSkipped++
			continue
		}
		$remainingSeconds = [int][Math]::Ceiling(($budgetMs - $spentMs) / 1000.0)
		$callConfig = if ($remainingSeconds -lt $commandTimeout) { Copy-IaColConfigWithTimeout -Config $config -TimeoutSeconds $remainingSeconds } else { $config }
		$parameters = [ordered]@{ objectId = [int]$entry.table.objectId; indexId = [int]$index.indexId }
		$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'physical_stats' -Parameters $parameters -SinglePage -Config $callConfig
		$serverDurationMs += [long]$result.durationMs
		if (-not $result.success) {
			$failed++
			$index.physical = New-IaColSkippedPhysical -Reason ("Помилка sys.dm_db_index_physical_stats: {0}" -f $result.error.message)
			continue
		}
		$row = @($result.rows)[0]
		$index.physical = [ordered]@{
			avgFragmentationPercent = ConvertTo-IaColDouble (Get-IaColValue $row 'avgFragmentationPercent') -Digits 2
			pageCount = ConvertTo-IaColLong (Get-IaColValue $row 'pageCount')
			fragmentCount = ConvertTo-IaColLong (Get-IaColValue $row 'fragmentCount')
			mode = 'LIMITED'
			skipped = $false
			skipReason = $null
		}
	}
	if ($budgetSkipped -gt 0) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'PhysicalStatsBudgetExceeded' -Dataset 'sizeAndFragmentation' -Message (
			"Бюджет часу sys.dm_db_index_physical_stats ({0} с) вичерпано: фрагментацію {1} індекс(ів) не зібрано (skipped)." -f $budgetSeconds, $budgetSkipped)
	}
	if ($failed -gt 0) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'PhysicalStatsFailed' -Dataset 'sizeAndFragmentation' -Message (
			"sys.dm_db_index_physical_stats завершився помилкою для {0} індекс(ів); вони позначені skipped." -f $failed)
	}
}

function Add-IaColMissingIndexes {
	<# Набір missingIndexes: details + groups + group_stats і хеші запитів із group_stats_query (лише таблиці в межах scope). #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'missing_indexes'
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'missingIndexes' -Message ("Missing index DMV не зібрано: {0}" -f $result.error.message)
		return $false
	}
	$hashes = @{}
	$hashResult = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'missing_index_queries'
	if ($hashResult.success) {
		foreach ($row in $hashResult.rows) {
			$handle = [string](ConvertTo-IaColLong (Get-IaColValue $row 'indexHandle'))
			if (-not $hashes.ContainsKey($handle)) {
				$hashes[$handle] = [System.Collections.Generic.List[string]]::new()
			}
			$hash = [string](Get-IaColValue $row 'queryHash')
			if ($hash -and -not $hashes[$handle].Contains($hash)) {
				$hashes[$handle].Add($hash)
			}
		}
	}
	else {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'MissingIndexQueriesFailed' -Dataset 'missingIndexes' -Message (
			"Хеші запитів для missing index не зібрано: {0}" -f $hashResult.error.message)
	}
	foreach ($row in $result.rows) {
		$schema = [string](Get-IaColValue $row 'schemaName')
		$tableName = [string](Get-IaColValue $row 'tableName')
		if ([string]::IsNullOrEmpty($tableName) -or -not (Test-IaColTableInScope -Schema $schema -Table $tableName -Scope $DbCtx.Context.Scope)) {
			continue
		}
		$handle = ConvertTo-IaColLong (Get-IaColValue $row 'indexHandle')
		$DbCtx.Database.missingIndexes.Add([ordered]@{
				indexHandle = $handle
				groupHandle = ConvertTo-IaColLong (Get-IaColValue $row 'groupHandle')
				schema = $schema
				table = $tableName
				objectId = ConvertTo-IaColLong (Get-IaColValue $row 'objectId')
				equalityColumns = Split-IaColBracketList ([string](Get-IaColValue $row 'equalityColumns'))
				inequalityColumns = Split-IaColBracketList ([string](Get-IaColValue $row 'inequalityColumns'))
				includedColumns = Split-IaColBracketList ([string](Get-IaColValue $row 'includedColumns'))
				userSeeks = ConvertTo-IaColLong (Get-IaColValue $row 'userSeeks') -Default 0
				userScans = ConvertTo-IaColLong (Get-IaColValue $row 'userScans') -Default 0
				avgTotalUserCost = ConvertTo-IaColDouble (Get-IaColValue $row 'avgTotalUserCost') -Default 0 -Digits 4
				avgUserImpact = ConvertTo-IaColDouble (Get-IaColValue $row 'avgUserImpact') -Default 0 -Digits 2
				lastUserSeekUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'lastUserSeekUtc')
				uniqueCompiles = ConvertTo-IaColLong (Get-IaColValue $row 'uniqueCompiles')
				queryHashes = [string[]]@($hashes[[string]$handle] | Where-Object { $_ })
			})
	}
	return $true
}

function Get-IaColHintMatches {
	<# Табличні хінти індексів у тексті T-SQL: INDEX(a, b), INDEX = a, FORCESEEK(a(...)). Повертає @(@{ name; text }). #>
	param([AllowNull()][string]$Text)
	$found = [System.Collections.Generic.List[object]]::new()
	if ([string]::IsNullOrEmpty($Text)) {
		return , $found.ToArray()
	}
	$identifier = '\[(?:[^\]]|\]\])+\]|"[^"]+"|[\w@#$]+'
	$add = {
		param([string]$Raw, [string]$Snippet)
		$name = Get-IaColUnquotedName $Raw
		if (-not [string]::IsNullOrWhiteSpace($name) -and $name -notmatch '^\d+$') {
			$found.Add(@{ name = $name; text = $Snippet })
		}
	}
	foreach ($match in [regex]::Matches($Text, '(?is)\bINDEX\s*\(\s*(?<list>[^)]*)\)')) {
		foreach ($item in ($match.Groups['list'].Value -split ',')) {
			& $add $item.Trim() $match.Value
		}
	}
	foreach ($match in [regex]::Matches($Text, "(?is)\bINDEX\s*=\s*(?<one>$identifier)")) {
		& $add $match.Groups['one'].Value $match.Value
	}
	foreach ($match in [regex]::Matches($Text, "(?is)\bFORCESEEK\s*\(\s*(?<one>$identifier)\s*\(")) {
		& $add $match.Groups['one'].Value $match.Value
	}
	return , $found.ToArray()
}

function Add-IaColConstraints {
	<# Набір constraintsAndReplication: прапорці реплікації бази й таблиць, FK з обох боків, usedByReplication, хінти в sys.sql_modules. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'foreign_keys'
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'constraintsAndReplication' -Message ("Обмеження (FK) не зібрано: {0}" -f $result.error.message)
		return $false
	}
	$dbRow = $DbCtx.DbRow
	$replication = [ordered]@{
		isPublished = ConvertTo-IaColBool (Get-IaColValue $dbRow 'isPublished')
		isMergePublished = ConvertTo-IaColBool (Get-IaColValue $dbRow 'isMergePublished')
		isSubscribed = ConvertTo-IaColBool (Get-IaColValue $dbRow 'isSubscribed')
		isDistributor = ConvertTo-IaColBool (Get-IaColValue $dbRow 'isDistributor')
	}
	$DbCtx.Database.replication = $replication
	foreach ($key in @($DbCtx.Tables.Keys)) {
		$DbCtx.Tables[$key].isReplicated = [bool]$DbCtx.TableFlags[$key].isReplicated
	}
	foreach ($entry in $DbCtx.IndexEntries) {
		$entry.index.referencedByForeignKeys = [System.Collections.Generic.List[string]]::new()
		$entry.index.coversForeignKeys = [System.Collections.Generic.List[string]]::new()
		$entry.index.hintReferences = [System.Collections.Generic.List[object]]::new()
	}
	$foreignKeys = [ordered]@{}
	foreach ($row in $result.rows) {
		$id = [string](ConvertTo-IaColLong (Get-IaColValue $row 'foreignKeyId'))
		if (-not $foreignKeys.Contains($id)) {
			$foreignKeys[$id] = @{
				name = [string](Get-IaColValue $row 'foreignKeyName')
				parentObjectId = ConvertTo-IaColLong (Get-IaColValue $row 'parentObjectId')
				referencedObjectId = ConvertTo-IaColLong (Get-IaColValue $row 'referencedObjectId')
				referencedSchema = [string](Get-IaColValue $row 'referencedSchema')
				referencedTable = [string](Get-IaColValue $row 'referencedTable')
				keyIndexId = ConvertTo-IaColLong (Get-IaColValue $row 'keyIndexId')
				referencedIndexName = Get-IaColValue $row 'referencedIndexName'
				isDisabled = ConvertTo-IaColBool (Get-IaColValue $row 'isDisabled')
				isNotTrusted = ConvertTo-IaColBool (Get-IaColValue $row 'isNotTrusted')
				columns = [System.Collections.Generic.List[string]]::new()
				referencedColumns = [System.Collections.Generic.List[string]]::new()
			}
		}
		$foreignKeys[$id].columns.Add([string](Get-IaColValue $row 'columnName'))
		$foreignKeys[$id].referencedColumns.Add([string](Get-IaColValue $row 'referencedColumnName'))
	}
	foreach ($fk in $foreignKeys.Values) {
		if ($null -ne $fk.keyIndexId) {
			$referenced = $DbCtx.IndexMap[(Get-IaColIndexKey $fk.referencedObjectId $fk.keyIndexId)]
			if ($referenced -and -not $referenced.referencedByForeignKeys.Contains($fk.name)) {
				$referenced.referencedByForeignKeys.Add($fk.name)
			}
		}
		$parent = $DbCtx.Tables[[string]$fk.parentObjectId]
		if ($null -eq $parent) {
			continue
		}
		$parent.foreignKeys.Add([ordered]@{
				name = $fk.name
				columns = @($fk.columns.ToArray())
				referencedSchema = $fk.referencedSchema
				referencedTable = $fk.referencedTable
				referencedColumns = @($fk.referencedColumns.ToArray())
				referencedIndexName = $fk.referencedIndexName
				isDisabled = $fk.isDisabled
				isNotTrusted = $fk.isNotTrusted
			})
		$fkColumns = @($fk.columns | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
		foreach ($index in $parent.indexes) {
			$keys = @($index.keyColumns | Sort-Object -Property { [long]$_.keyOrdinal })
			if ($keys.Count -lt $fkColumns.Count -or $fkColumns.Count -eq 0) {
				continue
			}
			$leading = @($keys[0..($fkColumns.Count - 1)] | ForEach-Object { ([string]$_.name).ToLowerInvariant() } | Sort-Object)
			if ((Compare-Object -ReferenceObject $fkColumns -DifferenceObject $leading -SyncWindow 0).Count -eq 0 -and -not $index.coversForeignKeys.Contains($fk.name)) {
				$index.coversForeignKeys.Add($fk.name)
			}
		}
	}
	foreach ($entry in $DbCtx.IndexEntries) {
		$flags = $DbCtx.TableFlags[[string]$entry.table.objectId]
		$index = $entry.index
		$keyNames = @($index.keyColumns | ForEach-Object { ([string]$_.name).ToLowerInvariant() })
		$coversRowGuid = @($flags.rowGuidColumns | Where-Object { $_.ToLowerInvariant() -in $keyNames }).Count -gt 0
		$index.usedByReplication = if ($flags.isReplicated) {
			$index.isPrimaryKey -or ($index.isUnique -and $coversRowGuid)
		}
		elseif ($replication.isSubscribed) {
			$index.isPrimaryKey -or $index.isUnique
		}
		else {
			$false
		}
	}
	Add-IaColModuleHints -DbCtx $DbCtx
	return $true
}

function Add-IaColModuleHints {
	<# Хінти індексів у sys.sql_modules.definition: moduleHints бази і hintReferences (SqlModule) індексів. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'module_hints' -PageSize 200
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'ModuleHintsFailed' -Dataset 'constraintsAndReplication' -Message (
			"Пошук хінтів у sys.sql_modules не виконано: {0}; hintReferences невідомі (null)." -f $result.error.message)
		foreach ($entry in $DbCtx.IndexEntries) {
			$entry.index.hintReferences = $null
		}
		return
	}
	$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($row in $result.rows) {
		$moduleName = '{0}.{1}' -f (Get-IaColValue $row 'schemaName'), (Get-IaColValue $row 'moduleName')
		foreach ($hint in (Get-IaColHintMatches -Text ([string](Get-IaColValue $row 'moduleDefinition')))) {
			$targets = $DbCtx.IndexesByName[$hint.name.ToLowerInvariant()]
			if ($null -eq $targets) {
				continue
			}
			foreach ($target in $targets) {
				$tableName = '{0}.{1}' -f $target.table.schema, $target.table.name
				if ($seen.Add("$moduleName|$tableName|$($target.index.name)")) {
					$DbCtx.Database.moduleHints.Add([ordered]@{ moduleName = $moduleName; indexName = $target.index.name; tableName = $tableName; hintText = $hint.text })
					$target.index.hintReferences.Add([ordered]@{ source = 'SqlModule'; objectName = $moduleName; queryId = $null })
				}
			}
		}
	}
}
