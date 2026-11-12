# Стиснений контекст для моделі (ТЗ 4.3, 4.3.1, 4.6; CONTRACTS.md 3.4).
# У модель іде лише payload: метадані, статистика й тексти запитів без літералів — ніколи значення даних.

$script:IaLlmContextBudgetShare = 0.8      # частка maxContextTokens для payload (решта — шаблон, схеми інструментів, дозапити)
$script:IaLlmMaxQueriesPerTable = 10
$script:IaLlmMaxPlansPerQuery = 3
$script:IaLlmMaxQueryTextLength = 4000
$script:IaLlmSeverityWeights = @{ High = 1000; Medium = 100; Low = 10; Info = 1 }

function Get-IaLlmTableKey {
	<# Внутрішня: 'schema.table' у нижньому регістрі для зіставлення. #>
	param([AllowNull()][AllowEmptyString()][string]$Schema, [AllowNull()][AllowEmptyString()][string]$Table)
	return ('{0}.{1}' -f $Schema, $Table).ToLowerInvariant()
}

function Get-IaLlmUptimeDays {
	<# Внутрішня: днів від max(запуск, failover) до моменту збору. #>
	param([AllowNull()]$StartUtc, [AllowNull()]$FailoverUtc, [AllowNull()]$CollectedUtc)
	$start = ConvertTo-IaLlmUtcDate -Value $StartUtc
	$failover = ConvertTo-IaLlmUtcDate -Value $FailoverUtc
	$collected = ConvertTo-IaLlmUtcDate -Value $CollectedUtc
	if ($null -eq $start -or $null -eq $collected) {
		return $null
	}
	if ($null -ne $failover -and $failover -gt $start) {
		$start = $failover
	}
	return [Math]::Round(($collected - $start).TotalDays, 1)
}

function Get-IaLlmDatabaseGroups {
	<# Внутрішня: бази snapshot, згруповані за (сервер-ключ, база): для AG сервер-ключ — ім'я AG, інакше serverName інстансу.
	   Повертає [ordered] ключ -> @{ server; database; entries = @(@{ instance; database; isPrimary }) }. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)
	$groups = [ordered]@{}
	foreach ($instance in @($Snapshot['instances'])) {
		if ($instance -isnot [System.Collections.IDictionary]) {
			continue
		}
		foreach ($database in @($instance['databases'])) {
			if ($database -isnot [System.Collections.IDictionary]) {
				continue
			}
			$serverKey = if ($database['availabilityGroup']) { [string]$database['availabilityGroup'] } else { [string]$instance['serverName'] }
			$groupKey = ('{0}|{1}' -f $serverKey, $database['name']).ToLowerInvariant()
			if (-not $groups.Contains($groupKey)) {
				$groups[$groupKey] = @{ server = $serverKey; database = [string]$database['name']; entries = [System.Collections.Generic.List[object]]::new() }
			}
			$isPrimary = ([string]$database['replicaRole'] -eq 'PRIMARY') -or (-not $database['availabilityGroup'])
			$groups[$groupKey].entries.Add(@{ instance = $instance; database = $database; isPrimary = $isPrimary })
		}
	}
	foreach ($group in $groups.Values) {
		# Primary — першим (структура, Query Store і хінти беруться з нього).
		$ordered = @($group.entries | Sort-Object -Property @{ Expression = { -not $_.isPrimary } } -Stable)
		$group.entries = $ordered
	}
	return $groups
}

function ConvertTo-IaLlmQueryNode {
	<# Внутрішня: стиснений запит Query Store (текст без літералів, до 3 планів). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Query)
	$text = Remove-IaSqlLiterals -Sql ([string]$Query['queryText'])
	$truncated = $false
	if ($null -ne $text -and $text.Length -gt $script:IaLlmMaxQueryTextLength) {
		$text = $text.Substring(0, $script:IaLlmMaxQueryTextLength)
		$truncated = $true
	}
	$plans = @(@($Query['plans']) | Where-Object { $_ -is [System.Collections.IDictionary] } |
		Sort-Object -Property @{ Expression = { [double]($_['executionCount'] ?? 0) }; Descending = $true } |
		Select-Object -First $script:IaLlmMaxPlansPerQuery |
		ForEach-Object {
			$plan = $_
			$node = [ordered]@{}
			foreach ($name in @('planId', 'isForced', 'executionCount', 'avgDurationMs', 'avgCpuMs', 'lastExecutionUtc', 'indexOperations', 'missingIndexes',
					'predicates', 'hasKeyLookup', 'hasImplicitConversion', 'usesBatchMode', 'scansWholeTable', 'partitionElimination', 'columnstoreSegmentElimination')) {
				if ($plan.Contains($name)) {
					$node[$name] = ConvertTo-IaLlmPlainValue -Value $plan[$name]
				}
			}
			$node
		})
	$node = [ordered]@{
		queryId = $Query['queryId']
		objectName = $Query['objectName']
		queryText = $text
		queryTextTruncated = $truncated
	}
	foreach ($name in @('executionCount', 'totalCpuMs', 'totalLogicalReads', 'totalDurationMs', 'avgCpuMs', 'avgLogicalReads', 'avgDurationMs', 'planCount',
			'firstExecutionUtc', 'lastExecutionUtc', 'topBy', 'workloadCategory', 'hasRegression', 'byHour', 'byDayOfWeek')) {
		if ($Query.Contains($name)) {
			$node[$name] = ConvertTo-IaLlmPlainValue -Value $Query[$name]
		}
	}
	$node['plans'] = $plans
	return $node
}

function Get-IaLlmQueryTables {
	<# Внутрішня: множина 'schema.table' (нижній регістр), до яких звертається запит за планами Query Store. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Query)
	$tables = [System.Collections.Generic.HashSet[string]]::new()
	foreach ($plan in @($Query['plans'])) {
		if ($plan -isnot [System.Collections.IDictionary]) {
			continue
		}
		foreach ($listName in @('indexOperations', 'predicates', 'missingIndexes')) {
			foreach ($item in @($plan[$listName])) {
				if ($item -is [System.Collections.IDictionary] -and $item['table']) {
					$null = $tables.Add((Get-IaLlmTableKey -Schema $item['schema'] -Table $item['table']))
				}
			}
		}
	}
	return , $tables
}

function ConvertTo-IaLlmIndexNode {
	<# Внутрішня: стиснений індекс зі статистикою використання з кожної зібраної репліки. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Index,
		[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ReplicaStats,
		[Parameter(Mandatory)][string]$Module
	)
	$node = [ordered]@{}
	foreach ($name in @('name', 'indexId', 'typeDesc', 'isPrimaryKey', 'isUnique', 'isUniqueConstraint', 'isDisabled', 'hasFilter', 'filterDefinition',
			'fillFactor', 'compression', 'dataSpaceName', 'dataSpaceType', 'partitionColumn', 'isAligned')) {
		if ($Index.Contains($name)) {
			$node[$name] = ConvertTo-IaLlmPlainValue -Value $Index[$name]
		}
	}
	$node['keyColumns'] = @(@($Index['keyColumns']) | Where-Object { $_ -is [System.Collections.IDictionary] } | Sort-Object -Property { [int]($_['keyOrdinal'] ?? 0) } |
		ForEach-Object { [ordered]@{ name = $_['name']; isDescending = [bool]$_['isDescending'] } })
	$node['includedColumns'] = @(@($Index['includedColumns']) | Where-Object { $null -ne $_ })
	foreach ($name in @('rowCount', 'usedMb', 'reservedMb')) {
		$node[$name] = $Index[$name]
	}
	$partitions = @(@($Index['partitions']) | Where-Object { $_ -is [System.Collections.IDictionary] })
	$node['partitionCount'] = $partitions.Count
	if ($Module -eq 'Partitioning' -and $partitions.Count -gt 0) {
		$node['partitions'] = ConvertTo-IaLlmPlainValue -Value $partitions
	}
	$node['statsLastUpdatedUtc'] = ConvertTo-IaLlmPlainValue -Value $Index['statsLastUpdatedUtc']
	$node['lastRebuildUtc'] = ConvertTo-IaLlmPlainValue -Value $Index['lastRebuildUtc']
	$physical = $Index['physical']
	$node['physical'] = if ($physical -is [System.Collections.IDictionary]) {
		[ordered]@{ avgFragmentationPercent = $physical['avgFragmentationPercent']; pageCount = $physical['pageCount']; skipped = $physical['skipped'] }
	}
	else {
		$null
	}
	$node['replicaStats'] = $ReplicaStats
	foreach ($name in @('referencedByForeignKeys', 'coversForeignKeys', 'usedByReplication', 'hintReferences', 'queryStoreUsage')) {
		$node[$name] = ConvertTo-IaLlmPlainValue -Value $Index[$name]
	}
	return $node
}

function Get-IaLlmPredicateSummary {
	<# Внутрішня: (партиціонування) які стовпці таблиці і якими операторами фільтруються в запитах Query Store. #>
	param([Parameter(Mandatory)][string]$TableKey, [object[]]$Queries = @())
	$summary = [ordered]@{}
	foreach ($query in $Queries) {
		foreach ($plan in @($query['plans'])) {
			if ($plan -isnot [System.Collections.IDictionary]) {
				continue
			}
			foreach ($predicate in @($plan['predicates'])) {
				if ($predicate -isnot [System.Collections.IDictionary] -or (Get-IaLlmTableKey -Schema $predicate['schema'] -Table $predicate['table']) -ne $TableKey) {
					continue
				}
				$key = ('{0}|{1}' -f $predicate['column'], $predicate['operator'])
				if (-not $summary.Contains($key)) {
					$summary[$key] = [ordered]@{ column = $predicate['column']; operator = $predicate['operator']; queryCount = 0; executionCount = 0; totalCpuMs = 0; partitionElimination = @() }
				}
				$item = $summary[$key]
				$item.queryCount++
				$item.executionCount += [double]($plan['executionCount'] ?? 0)
				$item.totalCpuMs += [double]($plan['avgCpuMs'] ?? 0) * [double]($plan['executionCount'] ?? 0)
				if ($plan['partitionElimination'] -and $plan['partitionElimination'] -notin $item.partitionElimination) {
					$item.partitionElimination = @($item.partitionElimination) + @([string]$plan['partitionElimination'])
				}
			}
		}
	}
	return , @($summary.Values)
}

function New-IaLlmContext {
	<# Стиснений контекст для моделі з НЕмаскованого snapshot і знахідок rules engine у межах maxContextTokens провайдера.
	   Повертає @{ payload (те, що йде в модель); includedObjectKeys; truncatedObjects; estimatedTokens; module }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[object[]]$Findings = @(),
		[Parameter(Mandatory)][ValidateSet('Indexes', 'Partitioning')][string]$Module,
		[Parameter(Mandatory)][System.Collections.IDictionary]$ProviderConfig,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$maxContextTokens = [int](Get-IaLlmSetting -ProviderConfig $ProviderConfig -Name 'maxContextTokens')
	$budget = [int][Math]::Floor($maxContextTokens * $script:IaLlmContextBudgetShare)
	$partitioningConfig = Get-IaLlmValue -InputObject $Config -Name 'partitioning'

	# Знахідки rules engine за таблицями.
	$findingsByTable = @{}
	foreach ($finding in @($Findings)) {
		if ($finding -isnot [System.Collections.IDictionary]) {
			continue
		}
		$target = $finding['target']
		if ($target -isnot [System.Collections.IDictionary]) {
			continue
		}
		$tableKey = Get-IaObjectKey -Server ([string]$target['server']) -Database ([string]$target['database']) -Schema ([string]$target['schema']) -Table ([string]$target['table']) -Index ''
		if (-not $findingsByTable.ContainsKey($tableKey)) {
			$findingsByTable[$tableKey] = [System.Collections.Generic.List[object]]::new()
		}
		$findingsByTable[$tableKey].Add($finding)
	}

	$topology = $Snapshot['topology']
	$payload = [ordered]@{
		module = $Module
		masking = [ordered]@{ namesMasked = $false; literalsMasked = $false }
		snapshotId = $Snapshot['snapshotId']
		requestedServer = $Snapshot['requestedServer']
		collectedAtUtc = ConvertTo-IaLlmPlainValue -Value $Snapshot['collectedAtUtc']
		analysisWindow = ConvertTo-IaLlmPlainValue -Value $Snapshot['analysisWindow']
		topology = $(if ($topology -is [System.Collections.IDictionary]) {
				[ordered]@{
					type = $topology['type']
					requestedServer = $topology['requestedServer']
					serverName = $topology['serverName']
					availabilityGroups = ConvertTo-IaLlmPlainValue -Value @($topology['availabilityGroups'] | Where-Object { $null -ne $_ })
				}
			}
			else {
				$null
			})
		datasets = ConvertTo-IaLlmPlainValue -Value $Snapshot['datasets']
		instances = @()
		databases = @()
		warnings = ConvertTo-IaLlmPlainValue -Value @($Snapshot['warnings'] | Where-Object { $null -ne $_ })
	}
	if ($Module -eq 'Partitioning' -and $partitioningConfig) {
		$payload['partitioningThresholds'] = ConvertTo-IaLlmPlainValue -Value $partitioningConfig
	}
	$instances = [System.Collections.Generic.List[object]]::new()
	foreach ($instance in @($Snapshot['instances'])) {
		if ($instance -isnot [System.Collections.IDictionary]) {
			continue
		}
		$instances.Add([ordered]@{
			server = $instance['serverName']
			agRole = $instance['agRole']
			edition = $instance['edition']
			engineEdition = $instance['engineEdition']
			productVersion = $instance['productVersion']
			supportsOnlineIndexOps = $instance['supportsOnlineIndexOps']
			isClustered = $instance['isClustered']
			sqlserverStartTimeUtc = ConvertTo-IaLlmPlainValue -Value $instance['sqlserverStartTimeUtc']
			lastFailoverUtc = ConvertTo-IaLlmPlainValue -Value $instance['lastFailoverUtc']
			collectedAtUtc = ConvertTo-IaLlmPlainValue -Value $instance['collectedAtUtc']
			uptimeDays = Get-IaLlmUptimeDays -StartUtc $instance['sqlserverStartTimeUtc'] -FailoverUtc $instance['lastFailoverUtc'] -CollectedUtc $instance['collectedAtUtc']
			warnings = ConvertTo-IaLlmPlainValue -Value @($instance['warnings'] | Where-Object { $null -ne $_ })
		})
	}
	$payload['instances'] = $instances.ToArray()

	# Бази й одиниці контексту (таблиці).
	$databaseNodes = [System.Collections.Generic.List[object]]::new()
	$units = [System.Collections.Generic.List[object]]::new()
	$groups = Get-IaLlmDatabaseGroups -Snapshot $Snapshot
	foreach ($group in $groups.Values) {
		$entries = @($group.entries)
		$primary = $entries[0]
		$primaryDb = $primary.database
		$uptimes = @($entries | ForEach-Object { Get-IaLlmUptimeDays -StartUtc $_.instance['sqlserverStartTimeUtc'] -FailoverUtc $_.instance['lastFailoverUtc'] -CollectedUtc $_.instance['collectedAtUtc'] } | Where-Object { $null -ne $_ })
		$queryStore = $primaryDb['queryStore']
		$databaseNode = [ordered]@{
			server = $group.server
			database = $group.database
			availabilityGroup = $primaryDb['availabilityGroup']
			replicas = @($entries | ForEach-Object { [ordered]@{ server = $_.instance['serverName']; role = $(if ($_.database['replicaRole']) { $_.database['replicaRole'] } else { $_.instance['agRole'] }) } })
			compatibilityLevel = $primaryDb['compatibilityLevel']
			recoveryModel = $primaryDb['recoveryModel']
			stateDesc = $primaryDb['stateDesc']
			isReadOnly = $primaryDb['isReadOnly']
			supportsOnlineIndexOps = [bool](@($entries | Where-Object { -not $_.instance['supportsOnlineIndexOps'] }).Count -eq 0)
			replication = ConvertTo-IaLlmPlainValue -Value $primaryDb['replication']
			queryStore = ConvertTo-IaLlmPlainValue -Value $queryStore
			collectedDatasets = ConvertTo-IaLlmPlainValue -Value @($primaryDb['collectedDatasets'] | Where-Object { $null -ne $_ })
			dataPeriod = [ordered]@{
				uptimeDays = $(if ($uptimes.Count -gt 0) { ($uptimes | Measure-Object -Minimum).Minimum } else { $null })
				queryStorePeriodDays = $(if ($queryStore -is [System.Collections.IDictionary]) { $queryStore['periodDays'] } else { $null })
			}
			warnings = ConvertTo-IaLlmPlainValue -Value @($entries | ForEach-Object { @($_.database['warnings']) } | Where-Object { $null -ne $_ })
			tables = [System.Collections.Generic.List[object]]::new()
			queries = [System.Collections.Generic.List[object]]::new()
		}
		$databaseNodes.Add($databaseNode)

		# Запити Query Store (з primary) і зв'язок таблиця -> запити.
		$queries = @(@($primaryDb['queryStoreQueries']) | Where-Object { $_ -is [System.Collections.IDictionary] })
		$queriesById = @{}
		$queriesByTable = @{}
		foreach ($query in $queries) {
			$queriesById[[string]$query['queryId']] = $query
			foreach ($queryTableKey in (Get-IaLlmQueryTables -Query $query)) {
				if (-not $queriesByTable.ContainsKey($queryTableKey)) {
					$queriesByTable[$queryTableKey] = [System.Collections.Generic.List[object]]::new()
				}
				$queriesByTable[$queryTableKey].Add($query)
			}
		}
		# Таблиці кожної репліки, missing index і хінти — за ключем таблиці.
		$tablesByEntry = @{}
		$missingByTable = @{}
		for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
			$entry = $entries[$entryIndex]
			$byKey = @{}
			foreach ($table in @($entry.database['tables'])) {
				if ($table -is [System.Collections.IDictionary]) {
					$byKey[(Get-IaLlmTableKey -Schema $table['schema'] -Table $table['name'])] = $table
				}
			}
			$tablesByEntry[$entryIndex] = $byKey
			foreach ($missing in @($entry.database['missingIndexes'])) {
				if ($missing -isnot [System.Collections.IDictionary]) {
					continue
				}
				$missingKey = Get-IaLlmTableKey -Schema $missing['schema'] -Table $missing['table']
				if (-not $missingByTable.ContainsKey($missingKey)) {
					$missingByTable[$missingKey] = [System.Collections.Generic.List[object]]::new()
				}
				$copy = ConvertTo-IaLlmPlainValue -Value $missing
				$copy['replica'] = $entry.instance['serverName']
				$missingByTable[$missingKey].Add($copy)
			}
		}
		$hintsByTable = @{}
		foreach ($hint in @($primaryDb['moduleHints'])) {
			if ($hint -isnot [System.Collections.IDictionary]) {
				continue
			}
			$hintKey = ([string]$hint['tableName']).Replace('[', '').Replace(']', '').ToLowerInvariant()
			if (-not $hintsByTable.ContainsKey($hintKey)) {
				$hintsByTable[$hintKey] = [System.Collections.Generic.List[object]]::new()
			}
			$hintsByTable[$hintKey].Add((ConvertTo-IaLlmPlainValue -Value $hint))
		}

		# Таблиці: структура з primary, далі таблиці, які є лише на інших репліках.
		$tableOrder = [System.Collections.Generic.List[string]]::new()
		$tableSource = @{}
		foreach ($entry in $entries) {
			foreach ($table in @($entry.database['tables'])) {
				if ($table -isnot [System.Collections.IDictionary]) {
					continue
				}
				$tableKey = Get-IaLlmTableKey -Schema $table['schema'] -Table $table['name']
				if (-not $tableSource.ContainsKey($tableKey)) {
					$tableSource[$tableKey] = $table
					$tableOrder.Add($tableKey)
				}
			}
		}
		foreach ($tableKey in $tableOrder) {
			$table = $tableSource[$tableKey]
			$objectKey = Get-IaObjectKey -Server $group.server -Database $group.database -Schema ([string]$table['schema']) -Table ([string]$table['name']) -Index ''
			$tableFindings = @()
			if ($findingsByTable.ContainsKey($objectKey)) {
				$tableFindings = $findingsByTable[$objectKey].ToArray()
			}
			$findingsScore = 0
			foreach ($finding in $tableFindings) {
				$findingsScore += [int]($script:IaLlmSeverityWeights[[string]$finding['severity']] ?? 1)
			}
			$sizeMb = [double]($table['reservedMb'] ?? 0)
			$isPartitioned = [bool]$table['isPartitioned']
			if ($Module -eq 'Partitioning') {
				$minSizeGb = [double]((Get-IaLlmValue -InputObject $partitioningConfig -Name 'minSizeGb') ?? 0)
				$minRowCount = [double]((Get-IaLlmValue -InputObject $partitioningConfig -Name 'minRowCount') ?? 0)
				$isCandidate = $tableFindings.Count -gt 0 -or $isPartitioned -or ($sizeMb / 1024 -ge $minSizeGb) -or ([double]($table['rowCount'] ?? 0) -ge $minRowCount)
				if (-not $isCandidate) {
					continue
				}
			}

			# Пов'язані запити: за планами або за queryStoreUsage індексів таблиці.
			$indexQueryIds = [System.Collections.Generic.HashSet[string]]::new()
			foreach ($index in @($table['indexes'])) {
				if ($index -is [System.Collections.IDictionary] -and $index['queryStoreUsage'] -is [System.Collections.IDictionary]) {
					foreach ($queryId in @($index['queryStoreUsage']['queryIds'])) {
						if ($null -ne $queryId) {
							$null = $indexQueryIds.Add([string]$queryId)
						}
					}
				}
			}
			$candidates = @{}
			if ($queriesByTable.ContainsKey($tableKey)) {
				foreach ($query in $queriesByTable[$tableKey]) {
					$candidates[[string]$query['queryId']] = $query
				}
			}
			foreach ($queryId in $indexQueryIds) {
				if ($queriesById.ContainsKey($queryId)) {
					$candidates[$queryId] = $queriesById[$queryId]
				}
			}
			$related = @($candidates.Values |
				Sort-Object -Property @{ Expression = { [double]($_['totalCpuMs'] ?? 0) }; Descending = $true }, @{ Expression = { [double]($_['totalLogicalReads'] ?? 0) }; Descending = $true } |
				Select-Object -First $script:IaLlmMaxQueriesPerTable)
			$queryScore = 0.0
			foreach ($query in $related) {
				$queryScore += [double]($query['totalCpuMs'] ?? 0) + [double]($query['totalDurationMs'] ?? 0)
			}

			# Індекси зі статистикою кожної репліки.
			$indexNodes = [System.Collections.Generic.List[object]]::new()
			$indexKeys = [System.Collections.Generic.List[string]]::new()
			foreach ($index in @($table['indexes'])) {
				if ($index -isnot [System.Collections.IDictionary]) {
					continue
				}
				$replicaStats = [System.Collections.Generic.List[object]]::new()
				for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
					$entry = $entries[$entryIndex]
					$replicaTable = $tablesByEntry[$entryIndex][$tableKey]
					if ($null -eq $replicaTable) {
						continue
					}
					$replicaIndex = @($replicaTable['indexes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['indexId'] -eq $index['indexId'] } | Select-Object -First 1
					if ($null -eq $replicaIndex) {
						continue
					}
					$replicaStats.Add([ordered]@{
						server = $entry.instance['serverName']
						role = $(if ($entry.database['replicaRole']) { $entry.database['replicaRole'] } else { $entry.instance['agRole'] })
						usage = ConvertTo-IaLlmPlainValue -Value $replicaIndex['usage']
						operational = ConvertTo-IaLlmPlainValue -Value $replicaIndex['operational']
					})
				}
				$indexNodes.Add((ConvertTo-IaLlmIndexNode -Index $index -ReplicaStats $replicaStats.ToArray() -Module $Module))
				if ($index['name']) {
					$indexKeys.Add((Get-IaObjectKey -Server $group.server -Database $group.database -Schema ([string]$table['schema']) -Table ([string]$table['name']) -Index ([string]$index['name'])))
				}
			}

			$missingIndexes = @()
			if ($missingByTable.ContainsKey($tableKey)) {
				$missingIndexes = $missingByTable[$tableKey].ToArray()
			}
			$hints = @()
			if ($hintsByTable.ContainsKey($tableKey)) {
				$hints = $hintsByTable[$tableKey].ToArray()
			}

			$tableNode = [ordered]@{}
			foreach ($name in @('schema', 'name', 'type', 'rowCount', 'reservedMb', 'usedMb', 'isPartitioned', 'partitionScheme', 'partitionFunction',
					'partitionColumn', 'isReplicated', 'isMemoryOptimized')) {
				$tableNode[$name] = ConvertTo-IaLlmPlainValue -Value $table[$name]
			}
			$tableNode['columns'] = @(@($table['columns']) | Where-Object { $_ -is [System.Collections.IDictionary] } | ForEach-Object {
					$column = [ordered]@{}
					foreach ($name in @('name', 'typeName', 'maxLength', 'precision', 'scale', 'isNullable', 'isComputed', 'isIdentity')) {
						if ($_.Contains($name)) {
							$column[$name] = $_[$name]
						}
					}
					$column
				})
			$tableNode['indexes'] = $indexNodes.ToArray()
			$tableNode['foreignKeys'] = ConvertTo-IaLlmPlainValue -Value @(@($table['foreignKeys']) | Where-Object { $null -ne $_ })
			$tableNode['missingIndexes'] = $missingIndexes
			$tableNode['moduleHints'] = $hints
			$tableNode['findings'] = @($tableFindings | ForEach-Object {
					[ordered]@{
						ruleId = $_['ruleId']
						severity = $_['severity']
						index = $(if ($_['target'] -is [System.Collections.IDictionary]) { $_['target']['index'] } else { $null })
						relatedIndexes = ConvertTo-IaLlmPlainValue -Value @($_['relatedIndexes'] | Where-Object { $null -ne $_ })
						message = $_['message']
						details = ConvertTo-IaLlmPlainValue -Value $_['details']
						suggestedAction = $_['suggestedAction']
					}
				})
			if ($Module -eq 'Partitioning') {
				$tableNode['predicateSummary'] = Get-IaLlmPredicateSummary -TableKey $tableKey -Queries $related
			}
			$tableNode['relatedQueryIds'] = @($related | ForEach-Object { $_['queryId'] })

			$units.Add(@{
				objectKey = $objectKey
				indexKeys = $indexKeys.ToArray()
				databaseNode = $databaseNode
				table = $tableNode
				related = $related
				hasFindings = $tableFindings.Count -gt 0
				findingsScore = $findingsScore
				queryScore = $queryScore
				isPartitioned = $isPartitioned
				sizeMb = $sizeMb
			})
		}
	}
	$payload['databases'] = $databaseNodes.ToArray()

	# Знахідки без відповідної таблиці в snapshot — окремим списком.
	$knownKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@($units | ForEach-Object { $_.objectKey }))
	$otherFindings = @($findingsByTable.Keys | Where-Object { -not $knownKeys.Contains($_) } | ForEach-Object { @($findingsByTable[$_]) } | ForEach-Object { ConvertTo-IaLlmPlainValue -Value $_ })
	if ($otherFindings.Count -gt 0 -and $Module -eq 'Indexes') {
		$payload['otherFindings'] = $otherFindings
	}

	# Пріоритет: таблиці зі знахідками rules engine, з топ-запитами Query Store (для партиціонування — секціоновані), далі за розміром.
	$sortProperties = if ($Module -eq 'Partitioning') {
		@(
			@{ Expression = { $_.hasFindings }; Descending = $true }
			@{ Expression = { $_.isPartitioned }; Descending = $true }
			@{ Expression = { $_.findingsScore }; Descending = $true }
			@{ Expression = { $_.sizeMb }; Descending = $true }
			@{ Expression = { $_.queryScore }; Descending = $true }
		)
	}
	else {
		@(
			@{ Expression = { $_.hasFindings }; Descending = $true }
			@{ Expression = { $_.queryScore -gt 0 }; Descending = $true }
			@{ Expression = { $_.findingsScore }; Descending = $true }
			@{ Expression = { $_.queryScore }; Descending = $true }
			@{ Expression = { $_.sizeMb }; Descending = $true }
		)
	}
	$orderedUnits = @($units | Sort-Object -Property $sortProperties -Stable)

	$usedTokens = Measure-IaTokens -Text (ConvertTo-IaLlmJson -Value $payload)
	$includedObjectKeys = [System.Collections.Generic.List[string]]::new()
	$truncatedObjects = [System.Collections.Generic.List[object]]::new()
	$addedQueries = @{}
	foreach ($unit in $orderedUnits) {
		$databaseNode = $unit.databaseNode
		$databaseKey = '{0}|{1}' -f $databaseNode['server'], $databaseNode['database']
		if (-not $addedQueries.ContainsKey($databaseKey)) {
			$addedQueries[$databaseKey] = @{}
		}
		$newQueries = @($unit.related | Where-Object { -not $addedQueries[$databaseKey].ContainsKey([string]$_['queryId']) } | ForEach-Object { ConvertTo-IaLlmQueryNode -Query $_ })
		$tableTokens = Measure-IaTokens -Text (ConvertTo-IaLlmJson -Value $unit.table)
		$queryTokens = 0
		if ($newQueries.Count -gt 0) {
			$queryTokens = Measure-IaTokens -Text (ConvertTo-IaLlmJson -Value $newQueries)
		}
		if ($usedTokens + $tableTokens + $queryTokens -le $budget) {
			$databaseNode['tables'].Add($unit.table)
			foreach ($query in $newQueries) {
				$databaseNode['queries'].Add($query)
				$addedQueries[$databaseKey][[string]$query['queryId']] = $true
			}
			$usedTokens += $tableTokens + $queryTokens
		}
		else {
			# Скорочений варіант: таблиця без нових текстів запитів.
			$reduced = [ordered]@{}
			foreach ($key in $unit.table.Keys) {
				$reduced[$key] = $unit.table[$key]
			}
			$reduced['relatedQueryIds'] = @($unit.table['relatedQueryIds'] | Where-Object { $addedQueries[$databaseKey].ContainsKey([string]$_) })
			$reduced['queriesOmitted'] = $true
			$reducedTokens = Measure-IaTokens -Text (ConvertTo-IaLlmJson -Value $reduced)
			if ($usedTokens + $reducedTokens -gt $budget) {
				$truncatedObjects.Add([ordered]@{ objectKey = $unit.objectKey; reason = 'Omitted' })
				continue
			}
			$databaseNode['tables'].Add($reduced)
			$usedTokens += $reducedTokens
			$truncatedObjects.Add([ordered]@{ objectKey = $unit.objectKey; reason = 'Reduced' })
		}
		$includedObjectKeys.Add($unit.objectKey)
		foreach ($indexKey in $unit.indexKeys) {
			$includedObjectKeys.Add($indexKey)
		}
	}
	foreach ($databaseNode in $payload['databases']) {
		$databaseNode['tables'] = $databaseNode['tables'].ToArray()
		$databaseNode['queries'] = $databaseNode['queries'].ToArray()
	}
	if ($truncatedObjects.Count -gt 0) {
		$payload['truncatedObjects'] = $truncatedObjects.ToArray()
	}
	return [ordered]@{
		payload = $payload
		includedObjectKeys = $includedObjectKeys.ToArray()
		truncatedObjects = $truncatedObjects.ToArray()
		estimatedTokens = Measure-IaTokens -Text (ConvertTo-IaLlmJson -Value $payload)
		module = $Module
	}
}
