# Внутрішні помічники потоку Rules (CONTRACTS.md, розділ 3.5): навігація snapshot, агрегація по репліках AG,
# порівняння ключів індексів, дати, періоди й структурні умови розділу 4.4. Без SQL-запитів і без LLM.

$script:IaRuleUsageFields = @('userSeeks', 'userScans', 'userLookups', 'userUpdates')
$script:IaRuleOperationalFields = @(
	'leafInsertCount', 'leafUpdateCount', 'leafDeleteCount', 'leafPageSplitCount', 'nonleafPageSplitCount',
	'rowLockWaitCount', 'rowLockWaitMs', 'pageLockWaitCount', 'pageLockWaitMs', 'pageLatchWaitCount', 'pageLatchWaitMs',
	'pageIoLatchWaitCount', 'pageIoLatchWaitMs', 'lockEscalationCount'
)
$script:IaRuleDateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
$script:IaRuleIntegerTypes = @('int', 'bigint', 'smallint')
$script:IaRuleVariableTypes = @('varchar', 'nvarchar', 'varbinary', 'sql_variant')
$script:IaRuleNonKeyTypes = @('text', 'ntext', 'image', 'xml', 'geography', 'geometry')

function ConvertTo-IaRuleUtcDate {
	<# Значення дати зі snapshot (рядок ISO 8601, DateTime, DateTimeOffset) -> [datetime] UTC або $null. #>
	param([AllowNull()]$Value)
	if ($null -eq $Value -or $Value -is [System.DBNull]) {
		return $null
	}
	if ($Value -is [System.DateTimeOffset]) {
		return $Value.UtcDateTime
	}
	if ($Value -is [datetime]) {
		if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
			return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
		}
		return $Value.ToUniversalTime()
	}
	$text = [string]$Value
	if ([string]::IsNullOrWhiteSpace($text)) {
		return $null
	}
	$parsed = [System.DateTimeOffset]::MinValue
	$styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
	if ([System.DateTimeOffset]::TryParse($text, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) {
		return $parsed.UtcDateTime
	}
	return $null
}

function Format-IaRuleNumber {
	<# Число для повідомлень (інваріантна культура, до однієї цифри після коми). #>
	param([AllowNull()]$Value, [string]$Format = '0.#')
	if ($null -eq $Value) {
		return '?'
	}
	return ([double]$Value).ToString($Format, [cultureinfo]::InvariantCulture)
}

function Get-IaRulePluralConfirmations {
	<# «бракує N підтвердження/підтверджень» (родовий відмінок). #>
	param([int]$Count)
	if ($Count % 10 -eq 1 -and $Count % 100 -ne 11) {
		return 'підтвердження'
	}
	return 'підтверджень'
}

function New-IaRuleCondition {
	<# Умова DropEligibility: met = $true | $false | $null (невідомо, вважається невиконаною). #>
	param([Parameter(Mandatory)][string]$Id, [AllowNull()]$Met, [string]$Details = '')
	return [ordered]@{ id = $Id; met = $Met; details = $Details }
}

function New-IaRuleCheck {
	<# Перевірка Validation (розділ 4.8). #>
	param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][ValidateSet('Passed', 'Failed', 'Warning', 'Skipped')][string]$Status, [string]$Message = '')
	return [ordered]@{ id = $Id; status = $Status; message = $Message }
}

function Get-IaRuleLogicalDatabases {
	<# Логічні бази snapshot: для бази в AG — одна на AG і базу (усі зібрані репліки разом), інакше — на інстанс і базу.
	   Повертає масив @{ server; database; primary = @{ instance; database }; replicas = @(@{ instance; database }) }. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)
	$map = [ordered]@{}
	foreach ($instance in @($Snapshot['instances'])) {
		if ($null -eq $instance) {
			continue
		}
		foreach ($database in @($instance['databases'])) {
			if ($null -eq $database) {
				continue
			}
			$server = if ($database['availabilityGroup']) { [string]$database['availabilityGroup'] } else { [string]$instance['serverName'] }
			$key = ('{0}|{1}' -f $server, $database['name']).ToLowerInvariant()
			if (-not $map.Contains($key)) {
				$map[$key] = [ordered]@{
					server = $server
					database = [string]$database['name']
					primary = $null
					replicas = [System.Collections.Generic.List[object]]::new()
				}
			}
			$map[$key].replicas.Add([ordered]@{ instance = $instance; database = $database })
		}
	}
	foreach ($entry in $map.Values) {
		$primary = $entry.replicas | Where-Object { $_.database['replicaRole'] -eq 'PRIMARY' } | Select-Object -First 1
		if (-not $primary) {
			$primary = $entry.replicas | Where-Object { $_.instance['agRole'] -eq 'PRIMARY' } | Select-Object -First 1
		}
		if (-not $primary) {
			$primary = $entry.replicas[0]
		}
		$entry.primary = $primary
		$entry.replicas = $entry.replicas.ToArray()
	}
	return @($map.Values)
}

function Get-IaRuleServerAliases {
	<# Імена, під якими може фігурувати сервер логічної бази: AG, репліки, listener, requestedServer. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot, [Parameter(Mandatory)]$Logical)
	$names = [System.Collections.Generic.List[string]]::new()
	$names.Add([string]$Logical.server)
	foreach ($replica in $Logical.replicas) {
		$names.Add([string]$replica.instance['serverName'])
		$names.Add([string]$replica.instance['connectedTo'])
	}
	$topology = $Snapshot['topology']
	if ($topology -is [System.Collections.IDictionary]) {
		foreach ($ag in @($topology['availabilityGroups'])) {
			if ($ag -is [System.Collections.IDictionary] -and $ag['name'] -eq $Logical.server) {
				$names.Add([string]$ag['listenerName'])
			}
		}
	}
	$names.Add([string]$Snapshot['requestedServer'])
	return @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Find-IaRuleLogicalDatabase {
	<# Логічна база за сервером (AG, репліка, listener) і назвою бази. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot, [string]$Server, [string]$Database)
	$candidates = @(Get-IaRuleLogicalDatabases -Snapshot $Snapshot | Where-Object { $_.database -eq $Database })
	foreach ($candidate in $candidates) {
		if ($candidate.server -eq $Server) {
			return $candidate
		}
	}
	foreach ($candidate in $candidates) {
		if (@(Get-IaRuleServerAliases -Snapshot $Snapshot -Logical $candidate) -contains $Server) {
			return $candidate
		}
	}
	return $null
}

$script:IaRuleCache = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Get-IaRuleCacheEntry {
	<# Похідна структура для об'єкта snapshot (кеш за посиланням, щоб не переглядати всі таблиці й запити для кожного індексу).
	   Перебудовується, якщо змінився вихідний масив Source. Build отримує Source першим аргументом. #>
	param([Parameter(Mandatory)]$Owner, [Parameter(Mandatory)][string]$Name, [AllowNull()]$Source, [Parameter(Mandatory)][scriptblock]$Build)
	$entries = $null
	if (-not $script:IaRuleCache.TryGetValue($Owner, [ref]$entries)) {
		$entries = @{}
		$script:IaRuleCache.Add($Owner, $entries)
	}
	$entry = $entries[$Name]
	if ($null -eq $entry -or -not [object]::ReferenceEquals($entry.source, $Source)) {
		$entry = @{ source = $Source; value = (& $Build $Source) }
		$entries[$Name] = $entry
	}
	return $entry.value
}

function Find-IaRuleTable {
	<# Таблиця бази за схемою й іменем (без урахування регістру). #>
	param([AllowNull()]$Database, [string]$Schema, [string]$Table)
	if ($null -eq $Database -or $null -eq $Database['tables']) {
		return $null
	}
	$lookup = Get-IaRuleCacheEntry -Owner $Database -Name 'tables' -Source $Database['tables'] -Build {
		param($Tables)
		$map = @{}
		foreach ($candidate in @($Tables)) {
			if ($candidate -is [System.Collections.IDictionary]) {
				$key = ('{0}.{1}' -f $candidate['schema'], $candidate['name']).ToLowerInvariant()
				if (-not $map.ContainsKey($key)) { $map[$key] = $candidate }
			}
		}
		return $map
	}
	return $lookup[('{0}.{1}' -f $Schema, $Table).ToLowerInvariant()]
}

function Get-IaRuleReferencingForeignKeys {
	<# FK бази за індексом, на який вони посилаються: 'schema.table.index' -> @(@{ name; schema; table }). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Database)
	return Get-IaRuleCacheEntry -Owner $Database -Name 'referencingForeignKeys' -Source $Database['tables'] -Build {
		param($Tables)
		$map = @{}
		foreach ($child in @($Tables)) {
			foreach ($fk in @($child['foreignKeys'])) {
				if ($fk -isnot [System.Collections.IDictionary]) {
					continue
				}
				$key = ('{0}.{1}.{2}' -f $fk['referencedSchema'], $fk['referencedTable'], $fk['referencedIndexName']).ToLowerInvariant()
				if (-not $map.ContainsKey($key)) { $map[$key] = [System.Collections.Generic.List[object]]::new() }
				$map[$key].Add(@{ name = [string]$fk['name']; schema = [string]$child['schema']; table = [string]$child['name'] })
			}
		}
		return $map
	}
}

function Get-IaRuleQueryStoreDigest {
	<# Зведення Query Store логічної бази (кеш): operations — 'schema.table.index' -> @(@{ queryId; operation; isHinted; database });
	   textHints — ім'я індексу -> queryId з хінтами INDEX(...)/INDEX = .../FORCESEEK(...) у тексті запиту;
	   tables — 'schema.table' -> @(@{ queryId; reads; executions; columns (предикати Eq/Range/In); elimination }). #>
	param([Parameter(Mandatory)]$Logical)
	$owner = $Logical.primary.database
	return Get-IaRuleCacheEntry -Owner $owner -Name 'queryStoreDigest' -Source $owner['queryStoreQueries'] -Build {
		param($Source)
		$queries = @(Get-IaRuleQueryStoreQueries -Logical $Logical)
		$operations = @{}
		$textHints = @{}
		$tables = @{}
		$hintPattern = '(?i)\bINDEX\s*(?:\(\s*([^\)]*)\)|=\s*(\[[^\]]+\]|[\w$#@]+))|\bFORCESEEK\s*\(\s*(\[[^\]]+\]|[\w$#@]+)\s*\('
		foreach ($query in $queries) {
			$queryId = [long]$query['queryId']
			$perTable = @{}
			foreach ($plan in @($query['plans'])) {
				if ($plan -isnot [System.Collections.IDictionary]) {
					continue
				}
				$planTables = [System.Collections.Generic.HashSet[string]]::new()
				foreach ($operation in @($plan['indexOperations'])) {
					if ($operation -isnot [System.Collections.IDictionary] -or ($operation['database'] -and $operation['database'] -ne $Logical.database)) {
						continue
					}
					$tableKey = ('{0}.{1}' -f $operation['schema'], $operation['table']).ToLowerInvariant()
					[void]$planTables.Add($tableKey)
					if ($operation['index']) {
						$key = "$tableKey.$($operation['index'])".ToLowerInvariant()
						if (-not $operations.ContainsKey($key)) { $operations[$key] = [System.Collections.Generic.List[object]]::new() }
						$operations[$key].Add(@{ queryId = $queryId; operation = [string]$operation['operation']; isHinted = [bool]$operation['isHinted'] })
					}
				}
				foreach ($predicate in @($plan['predicates'])) {
					if ($predicate -isnot [System.Collections.IDictionary]) {
						continue
					}
					$tableKey = ('{0}.{1}' -f $predicate['schema'], $predicate['table']).ToLowerInvariant()
					[void]$planTables.Add($tableKey)
					if (-not $perTable.ContainsKey($tableKey)) { $perTable[$tableKey] = @{ columns = [System.Collections.Generic.List[string]]::new(); elimination = [System.Collections.Generic.List[string]]::new() } }
					if ($predicate['operator'] -in @('Eq', 'Range', 'In') -and $perTable[$tableKey].columns -notcontains [string]$predicate['column']) {
						$perTable[$tableKey].columns.Add([string]$predicate['column'])
					}
				}
				foreach ($tableKey in $planTables) {
					if (-not $perTable.ContainsKey($tableKey)) { $perTable[$tableKey] = @{ columns = [System.Collections.Generic.List[string]]::new(); elimination = [System.Collections.Generic.List[string]]::new() } }
					if ($plan['partitionElimination']) { $perTable[$tableKey].elimination.Add([string]$plan['partitionElimination']) }
				}
			}
			foreach ($tableKey in $perTable.Keys) {
				if (-not $tables.ContainsKey($tableKey)) { $tables[$tableKey] = [System.Collections.Generic.List[object]]::new() }
				$tables[$tableKey].Add(@{
						queryId = $queryId
						reads = [double]$query['totalLogicalReads']
						executions = [double]$query['executionCount']
						columns = $perTable[$tableKey].columns.ToArray()
						elimination = $perTable[$tableKey].elimination.ToArray()
					})
			}
			foreach ($match in [regex]::Matches([string]$query['queryText'], $hintPattern)) {
				$names = if ($match.Groups[1].Success) { $match.Groups[1].Value -split ',' } elseif ($match.Groups[2].Success) { @($match.Groups[2].Value) } else { @($match.Groups[3].Value) }
				foreach ($name in $names) {
					$clean = $name.Trim().Trim([char[]]'[]" ')
					if (-not $clean -or $clean -match '^\d+$') {
						continue
					}
					$key = $clean.ToLowerInvariant()
					if (-not $textHints.ContainsKey($key)) { $textHints[$key] = [System.Collections.Generic.List[long]]::new() }
					if (-not $textHints[$key].Contains($queryId)) { $textHints[$key].Add($queryId) }
				}
			}
		}
		return @{ queries = $queries; operations = $operations; textHints = $textHints; tables = $tables }
	}
}

function Find-IaRuleIndex {
	<# Індекс таблиці за іменем (без урахування регістру). #>
	param([AllowNull()]$Table, [AllowNull()][string]$Name)
	if ($null -eq $Table -or [string]::IsNullOrEmpty($Name)) {
		return $null
	}
	foreach ($candidate in @($Table['indexes'])) {
		if ($candidate -is [System.Collections.IDictionary] -and $candidate['name'] -eq $Name) {
			return $candidate
		}
	}
	return $null
}

function Find-IaRuleColumn {
	<# Колонка таблиці за іменем. #>
	param([AllowNull()]$Table, [string]$Name)
	if ($null -eq $Table) {
		return $null
	}
	foreach ($column in @($Table['columns'])) {
		if ($column -is [System.Collections.IDictionary] -and $column['name'] -eq $Name) {
			return $column
		}
	}
	return $null
}

function Get-IaRuleIndexReplicas {
	<# Копії індексу на всіх зібраних репліках логічної бази: @(@{ instance; database; table; index }) (index = $null, якщо не знайдено). #>
	param([Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table, [string]$Index)
	$result = [System.Collections.Generic.List[object]]::new()
	foreach ($replica in $Logical.replicas) {
		$replicaTable = Find-IaRuleTable -Database $replica.database -Schema $Schema -Table $Table
		$result.Add([ordered]@{
				instance = $replica.instance
				database = $replica.database
				table = $replicaTable
				index = Find-IaRuleIndex -Table $replicaTable -Name $Index
			})
	}
	return $result.ToArray()
}

function Get-IaRuleAggregatedIndex {
	<# Копія індексу primary з usage й operational, підсумованими по всіх репліках AG.
	   replicaCoverage.withoutUsage — репліки, де статистики використання індексу немає. #>
	param([Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table, [Parameter(Mandatory)][System.Collections.IDictionary]$Index)
	$aggregate = [ordered]@{}
	foreach ($key in $Index.Keys) {
		$aggregate[$key] = $Index[$key]
	}
	$usage = $null
	$operational = $null
	$servers = [System.Collections.Generic.List[string]]::new()
	$withoutUsage = [System.Collections.Generic.List[string]]::new()
	foreach ($copy in @(Get-IaRuleIndexReplicas -Logical $Logical -Schema $Schema -Table $Table -Index $Index['name'])) {
		$server = [string]$copy.instance['serverName']
		$servers.Add($server)
		$copyUsage = if ($copy.index) { $copy.index['usage'] } else { $null }
		$copyOperational = if ($copy.index) { $copy.index['operational'] } else { $null }
		if ($copyUsage -is [System.Collections.IDictionary]) {
			if ($null -eq $usage) {
				$usage = [ordered]@{}
				foreach ($field in $script:IaRuleUsageFields) { $usage[$field] = [long]0 }
			}
			foreach ($field in $script:IaRuleUsageFields) { $usage[$field] += [long]$copyUsage[$field] }
		}
		else {
			$withoutUsage.Add($server)
		}
		if ($copyOperational -is [System.Collections.IDictionary]) {
			if ($null -eq $operational) {
				$operational = [ordered]@{}
				foreach ($field in $script:IaRuleOperationalFields) { $operational[$field] = [long]0 }
			}
			foreach ($field in $script:IaRuleOperationalFields) { $operational[$field] += [long]$copyOperational[$field] }
		}
	}
	$aggregate['usage'] = $usage
	$aggregate['operational'] = $operational
	$aggregate['replicaCoverage'] = [ordered]@{ replicas = @($servers); withoutUsage = @($withoutUsage) }
	return $aggregate
}

function Get-IaRuleReads {
	<# Читання індексу: seeks + scans + lookups ($null, якщо usage не зібрано). #>
	param([AllowNull()]$Usage)
	if ($Usage -isnot [System.Collections.IDictionary]) {
		return $null
	}
	return [long]$Usage['userSeeks'] + [long]$Usage['userScans'] + [long]$Usage['userLookups']
}

function Get-IaRuleKeyColumns {
	<# Ключові колонки індексу за keyOrdinal: @(@{ name; desc }). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Index)
	$keys = @($Index['keyColumns'] | Where-Object { $_ -is [System.Collections.IDictionary] } | Sort-Object { [int]$_['keyOrdinal'] })
	return @($keys | ForEach-Object { [ordered]@{ name = [string]$_['name']; desc = [bool]$_['isDescending'] } })
}

function Test-IaRuleKeyPrefix {
	<# Чи є ключ Short лівим префіксом ключа Long (імена й напрямок, без урахування регістру). -Strict — Short коротший. #>
	param([AllowNull()][object[]]$Short, [AllowNull()][object[]]$Long, [switch]$Strict)
	$shortKeys = @($Short | Where-Object { $null -ne $_ })
	$longKeys = @($Long | Where-Object { $null -ne $_ })
	if ($shortKeys.Count -eq 0 -or $shortKeys.Count -gt $longKeys.Count) {
		return $false
	}
	if ($Strict -and $shortKeys.Count -eq $longKeys.Count) {
		return $false
	}
	for ($i = 0; $i -lt $shortKeys.Count; $i++) {
		if ($shortKeys[$i].name -ne $longKeys[$i].name -or [bool]$shortKeys[$i].desc -ne [bool]$longKeys[$i].desc) {
			return $false
		}
	}
	return $true
}

function Test-IaRuleSameKeys {
	<# Однакові ключі в тому самому порядку й напрямку. #>
	param([AllowNull()][object[]]$First, [AllowNull()][object[]]$Second)
	$a = @($First | Where-Object { $null -ne $_ })
	$b = @($Second | Where-Object { $null -ne $_ })
	return ($a.Count -eq $b.Count -and (Test-IaRuleKeyPrefix -Short $a -Long $b))
}

function Test-IaRuleSubset {
	<# Чи всі елементи Subset є в Superset (рядки без урахування регістру). #>
	param([AllowNull()][object[]]$Subset, [AllowNull()][object[]]$Superset)
	$super = @($Superset | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
	foreach ($item in @($Subset | Where-Object { $null -ne $_ })) {
		if ($super -notcontains [string]$item) {
			return $false
		}
	}
	return $true
}

function Test-IaRuleSameSet {
	<# Однакові множини рядків без урахування регістру й порядку. #>
	param([AllowNull()][object[]]$First, [AllowNull()][object[]]$Second)
	return ((Test-IaRuleSubset -Subset $First -Superset $Second) -and (Test-IaRuleSubset -Subset $Second -Superset $First))
}

function ConvertTo-IaRuleFilterKey {
	<# Нормалізований текст фільтра для порівняння: без пробілів, дужок, лапок, префікса N у рядках, у нижньому регістрі. #>
	param([AllowNull()][string]$Filter)
	if ([string]::IsNullOrWhiteSpace($Filter)) {
		return ''
	}
	$text = $Filter.Trim()
	if ($text -match '^(?i)WHERE\s+') {
		$text = $text -replace '^(?i)WHERE\s+', ''
	}
	$text = $text.ToLowerInvariant() -replace '\s+', '' -replace '[\[\]\(\)"]', ''
	return ($text -replace "(?<![a-z0-9_])n'", "'")
}

function Test-IaRuleRowstore {
	<# Рядковий B-tree індекс (кластерний або некластерний). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Index)
	return ($Index['typeDesc'] -eq 'CLUSTERED' -or $Index['typeDesc'] -eq 'NONCLUSTERED')
}

function Test-IaRuleClusteredIndex {
	<# Кластерний індекс (рядковий або columnstore) — базова структура таблиці. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Index)
	return ($Index['typeDesc'] -eq 'CLUSTERED' -or $Index['typeDesc'] -eq 'CLUSTERED COLUMNSTORE' -or $Index['typeDesc'] -eq 'HEAP')
}

function Get-IaRuleActiveIndexes {
	<# Реальні індекси таблиці: без купи, гіпотетичних і вимкнених. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Table, [switch]$IncludeDisabled)
	return @($Table['indexes'] | Where-Object {
			$_ -is [System.Collections.IDictionary] -and $_['name'] -and $_['typeDesc'] -ne 'HEAP' -and -not $_['isHypothetical'] -and
			($IncludeDisabled -or -not $_['isDisabled'])
		})
}

function Get-IaRuleBaseIndex {
	<# Базова структура таблиці: купа або кластерний індекс. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Table)
	foreach ($index in @($Table['indexes'])) {
		if ($index -is [System.Collections.IDictionary] -and ([int]$index['indexId'] -le 1 -or (Test-IaRuleClusteredIndex -Index $index))) {
			return $index
		}
	}
	return $null
}

function Get-IaRuleInstancePeriod {
	<# Період статистики інстансу: від max(запуск, failover) до моменту збору. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Instance)
	$start = ConvertTo-IaRuleUtcDate $Instance['sqlserverStartTimeUtc']
	$failover = ConvertTo-IaRuleUtcDate $Instance['lastFailoverUtc']
	$to = ConvertTo-IaRuleUtcDate $Instance['collectedAtUtc']
	if ($null -eq $to) {
		$to = [datetime]::UtcNow
	}
	$from = $start
	if ($null -ne $failover -and ($null -eq $from -or $failover -gt $from)) {
		$from = $failover
	}
	$days = if ($null -ne $from) { [math]::Max([double]0, [math]::Round(($to - $from).TotalDays, 2)) } else { 0 }
	return [ordered]@{ start = $start; failover = $failover; fromUtc = $from; toUtc = $to; days = [double]$days }
}

function Get-IaRuleMinUptimeDays {
	<# Мінімальний період з rules.drop.minUptimeDays або найточнішого rules.observationOverrides
	   (сервер < сервер+база < сервер+таблиця < сервер+база+таблиця). #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[string[]]$ServerNames = @(),
		[string]$Database,
		[string]$SchemaTable
	)
	$result = [int]$Config.rules.drop.minUptimeDays
	$bestRank = -1
	foreach ($override in @($Config.rules.observationOverrides)) {
		if ($override -isnot [System.Collections.IDictionary]) {
			continue
		}
		if (@($ServerNames) -notcontains [string]$override['server']) {
			continue
		}
		$overrideDb = [string]$override['database']
		$overrideTable = ([string]$override['table']) -replace '[\[\]]', ''
		$rank = 0
		if ($overrideDb) {
			if (-not $Database -or $overrideDb -ne $Database) {
				continue
			}
			$rank += 1
		}
		if ($overrideTable) {
			if (-not $SchemaTable) {
				continue
			}
			$tableName = ($SchemaTable -split '\.')[-1]
			$isMatch = if ($overrideTable.Contains('.')) { $overrideTable -eq $SchemaTable } else { $overrideTable -eq $tableName }
			if (-not $isMatch) {
				continue
			}
			$rank += 2
		}
		if ($rank -gt $bestRank) {
			$bestRank = $rank
			$result = [int]$override['minUptimeDays']
		}
	}
	return $result
}

function Get-IaRuleQueryStoreInfo {
	<# Налаштування Query Store логічної бази: з primary або першої репліки, де вони зібрані. #>
	param([Parameter(Mandatory)]$Logical)
	if ($Logical.primary.database['queryStore'] -is [System.Collections.IDictionary]) {
		return $Logical.primary.database['queryStore']
	}
	foreach ($replica in $Logical.replicas) {
		if ($replica.database['queryStore'] -is [System.Collections.IDictionary]) {
			return $replica.database['queryStore']
		}
	}
	return $null
}

function Get-IaRuleQueryStoreQueries {
	<# Запити Query Store логічної бази з усіх реплік без дублікатів за queryId. #>
	param([Parameter(Mandatory)]$Logical)
	$seen = [System.Collections.Generic.HashSet[long]]::new()
	$result = [System.Collections.Generic.List[object]]::new()
	foreach ($replica in @($Logical.primary) + @($Logical.replicas)) {
		foreach ($query in @($replica.database['queryStoreQueries'])) {
			if ($query -is [System.Collections.IDictionary] -and $seen.Add([long]$query['queryId'])) {
				$result.Add($query)
			}
		}
	}
	return $result.ToArray()
}

function Get-IaRuleStructuralConditions {
	<# Структурні умови 4.4, що не пом'якшуються: NotPrimaryKey, NotUnique, NoForeignKeySupport, NotReplicated, NoHintReferences.
	   Дані беруться з усіх реплік; met = $null — дані не зібрано (умова вважається невиконаною). #>
	param([Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table, [string]$Index)
	$conditions = [System.Collections.Generic.List[object]]::new()
	$primaryTable = Find-IaRuleTable -Database $Logical.primary.database -Schema $Schema -Table $Table
	$primaryIndex = Find-IaRuleIndex -Table $primaryTable -Name $Index
	if ($null -eq $primaryIndex) {
		foreach ($id in 'NotPrimaryKey', 'NotUnique', 'NoForeignKeySupport', 'NotReplicated', 'NoHintReferences') {
			$conditions.Add((New-IaRuleCondition -Id $id -Met $null -Details "Індекс [$Schema].[$Table].[$Index] не знайдено у snapshot"))
		}
		return $conditions.ToArray()
	}
	$copies = @(Get-IaRuleIndexReplicas -Logical $Logical -Schema $Schema -Table $Table -Index $Index | Where-Object { $_.index })

	$isPrimaryKey = @($copies | Where-Object { $_.index['isPrimaryKey'] }).Count -gt 0
	$conditions.Add((New-IaRuleCondition -Id 'NotPrimaryKey' -Met (-not $isPrimaryKey) -Details $(if ($isPrimaryKey) { 'Індекс є первинним ключем' } else { 'Індекс не є первинним ключем' })))

	$isUnique = @($copies | Where-Object { $_.index['isUnique'] -or $_.index['isUniqueConstraint'] }).Count -gt 0
	$uniqueDetails = if ($isUnique) { 'Індекс унікальний (UNIQUE): забезпечує унікальність даних' } else { 'Індекс не унікальний' }
	$conditions.Add((New-IaRuleCondition -Id 'NotUnique' -Met (-not $isUnique) -Details $uniqueDetails))

	# FK з обох боків: FK інших таблиць спираються на індекс, або індекс покриває колонки FK своєї таблиці.
	$referenced = [System.Collections.Generic.List[string]]::new()
	$covers = [System.Collections.Generic.List[string]]::new()
	$fkUnknown = $false
	foreach ($copy in $copies) {
		$isPrimaryCopy = [object]::ReferenceEquals($copy.database, $Logical.primary.database)
		if ($isPrimaryCopy -and ($null -eq $copy.index['referencedByForeignKeys'] -or $null -eq $copy.index['coversForeignKeys'])) {
			$fkUnknown = $true
		}
		foreach ($name in @($copy.index['referencedByForeignKeys'])) {
			if ($name -and $referenced -notcontains $name) { $referenced.Add([string]$name) }
		}
		foreach ($name in @($copy.index['coversForeignKeys'])) {
			if ($name -and $covers -notcontains $name) { $covers.Add([string]$name) }
		}
	}
	$referencing = (Get-IaRuleReferencingForeignKeys -Database $Logical.primary.database)[("$Schema.$Table.$Index").ToLowerInvariant()]
	foreach ($fk in @($referencing | Where-Object { $null -ne $_ })) {
		if ($referenced -notcontains $fk.name) { $referenced.Add($fk.name) }
	}
	$keyNames = @(Get-IaRuleKeyColumns -Index $primaryIndex | ForEach-Object { $_.name })
	foreach ($fk in @($primaryTable['foreignKeys'])) {
		if ($fk -isnot [System.Collections.IDictionary]) {
			continue
		}
		$fkColumns = @($fk['columns'] | Where-Object { $_ })
		if ($fkColumns.Count -gt 0 -and $fkColumns.Count -le $keyNames.Count -and
			(Test-IaRuleSameSet -First $fkColumns -Second $keyNames[0..($fkColumns.Count - 1)]) -and $covers -notcontains $fk['name']) {
			$covers.Add([string]$fk['name'])
		}
	}
	if ($referenced.Count -gt 0 -or $covers.Count -gt 0) {
		$parts = @()
		if ($referenced.Count -gt 0) { $parts += 'на індекс спираються FK: ' + ($referenced -join ', ') }
		if ($covers.Count -gt 0) { $parts += 'індекс підтримує FK таблиці: ' + ($covers -join ', ') }
		$conditions.Add((New-IaRuleCondition -Id 'NoForeignKeySupport' -Met $false -Details (($parts -join '; ') + '.')))
	}
	elseif ($fkUnknown) {
		$conditions.Add((New-IaRuleCondition -Id 'NoForeignKeySupport' -Met $null -Details 'Дані про FK не зібрано (набір constraintsAndReplication)'))
	}
	else {
		$conditions.Add((New-IaRuleCondition -Id 'NoForeignKeySupport' -Met $true -Details 'Індекс не підтримує FK'))
	}

	# Реплікація.
	$usedByReplication = @($copies | Where-Object { $_.index['usedByReplication'] -eq $true }).Count -gt 0
	$tableReplicated = @($copies | Where-Object { $_.table['isReplicated'] -eq $true }).Count -gt 0
	if ($usedByReplication) {
		$conditions.Add((New-IaRuleCondition -Id 'NotReplicated' -Met $false -Details 'Індекс використовується реплікацією'))
	}
	elseif ($tableReplicated) {
		$conditions.Add((New-IaRuleCondition -Id 'NotReplicated' -Met $false -Details 'Таблиця бере участь у реплікації: видалення індексу потребує узгодження з публікацією'))
	}
	elseif ($null -eq $primaryIndex['usedByReplication']) {
		$conditions.Add((New-IaRuleCondition -Id 'NotReplicated' -Met $null -Details 'Дані про реплікацію не зібрано (набір constraintsAndReplication)'))
	}
	else {
		$conditions.Add((New-IaRuleCondition -Id 'NotReplicated' -Met $true -Details 'Індекс не використовується реплікацією'))
	}

	# Хінти: sys.sql_modules і Query Store (дані колектора, moduleHints, плани з ForcedIndex, тексти запитів).
	$hints = [System.Collections.Generic.List[string]]::new()
	$hintsUnknown = $null -eq $primaryIndex['hintReferences']
	foreach ($copy in $copies) {
		foreach ($reference in @($copy.index['hintReferences'])) {
			if ($reference -isnot [System.Collections.IDictionary]) {
				continue
			}
			$text = if ($reference['source'] -eq 'QueryStore') { "Query Store: запит $($reference['queryId'])" } else { "модуль $($reference['objectName'])" }
			if ($hints -notcontains $text) { $hints.Add($text) }
		}
	}
	foreach ($replica in $Logical.replicas) {
		foreach ($moduleHint in @($replica.database['moduleHints'])) {
			if ($moduleHint -isnot [System.Collections.IDictionary] -or $moduleHint['indexName'] -ne $Index) {
				continue
			}
			$tableName = [string]$moduleHint['tableName']
			if ($tableName -and ($tableName -replace '[\[\]]', '') -ne "$Schema.$Table" -and ($tableName -replace '[\[\]]', '') -ne $Table) {
				continue
			}
			$text = "модуль $($moduleHint['moduleName'])"
			if ($hints -notcontains $text) { $hints.Add($text) }
		}
	}
	# Плани з ForcedIndex/FORCESEEK і хінти в текстах запитів Query Store (за іменем індексу — консервативно).
	$digest = Get-IaRuleQueryStoreDigest -Logical $Logical
	$hintedQueries = [System.Collections.Generic.List[long]]::new()
	foreach ($operation in @($digest.operations[("$Schema.$Table.$Index").ToLowerInvariant()] | Where-Object { $null -ne $_ -and $_.isHinted })) {
		if (-not $hintedQueries.Contains($operation.queryId)) { $hintedQueries.Add($operation.queryId) }
	}
	foreach ($queryId in @($digest.textHints[$Index.ToLowerInvariant()] | Where-Object { $null -ne $_ })) {
		if (-not $hintedQueries.Contains($queryId)) { $hintedQueries.Add($queryId) }
	}
	foreach ($queryId in $hintedQueries) {
		$text = "Query Store: запит $queryId"
		if ($hints -notcontains $text) { $hints.Add($text) }
	}
	if ($hints.Count -gt 0) {
		$conditions.Add((New-IaRuleCondition -Id 'NoHintReferences' -Met $false -Details ('Індекс згадується в хінтах: ' + ($hints -join ', '))))
	}
	elseif ($hintsUnknown) {
		$conditions.Add((New-IaRuleCondition -Id 'NoHintReferences' -Met $null -Details 'Пошук хінтів у sys.sql_modules і Query Store не виконано'))
	}
	else {
		$conditions.Add((New-IaRuleCondition -Id 'NoHintReferences' -Met $true -Details 'Хінтів з індексом у sys.sql_modules і Query Store не знайдено'))
	}
	return $conditions.ToArray()
}

function Get-IaRuleQueryStoreCondition {
	<# Умова NotUsedInQueryStore: жоден план Query Store не використовує індекс (Seek, Scan, Lookup) за весь період Query Store
	   (колектор сканує плани без обмеження вікном аналізу). #>
	param([Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table, [string]$Index)
	$queryIds = [System.Collections.Generic.List[string]]::new()
	$digest = Get-IaRuleQueryStoreDigest -Logical $Logical
	foreach ($operation in @($digest.operations[("$Schema.$Table.$Index").ToLowerInvariant()] | Where-Object { $null -ne $_ -and $_.operation -ne 'Update' })) {
		if ($queryIds -notcontains [string]$operation.queryId) { $queryIds.Add([string]$operation.queryId) }
	}
	$usages = @(Get-IaRuleIndexReplicas -Logical $Logical -Schema $Schema -Table $Table -Index $Index |
			Where-Object { $_.index -and $_.index['queryStoreUsage'] -is [System.Collections.IDictionary] } |
			ForEach-Object { $_.index['queryStoreUsage'] })
	$usedByCollector = $false
	foreach ($usage in $usages) {
		if ([long]$usage['planCount'] -gt 0 -or [long]$usage['seekCount'] + [long]$usage['scanCount'] + [long]$usage['lookupCount'] -gt 0) {
			$usedByCollector = $true
			foreach ($id in @($usage['queryIds'])) {
				if ($null -ne $id -and $queryIds -notcontains [string]$id) { $queryIds.Add([string]$id) }
			}
		}
	}
	$info = Get-IaRuleQueryStoreInfo -Logical $Logical
	if ($queryIds.Count -gt 0 -or $usedByCollector) {
		return New-IaRuleCondition -Id 'NotUsedInQueryStore' -Met $false -Details ('Індекс використовують плани Query Store: запити ' + ($queryIds -join ', '))
	}
	if ($null -eq $info -and $usages.Count -eq 0) {
		return New-IaRuleCondition -Id 'NotUsedInQueryStore' -Met $null -Details 'Query Store не зібрано: невикористання в планах не підтверджено'
	}
	if ($info -and $info['actualState'] -in @('OFF', 'ERROR')) {
		return New-IaRuleCondition -Id 'NotUsedInQueryStore' -Met $null -Details "Query Store у стані $($info['actualState']): невикористання в планах не підтверджено"
	}
	if ($usages.Count -eq 0) {
		return New-IaRuleCondition -Id 'NotUsedInQueryStore' -Met $null -Details 'Використання індексу в планах Query Store не визначено'
	}
	return New-IaRuleCondition -Id 'NotUsedInQueryStore' -Met $true -Details 'Жоден план Query Store не використовує індекс за весь період, що зберігає Query Store'
}

function Get-IaRuleReplicaCondition {
	<# Умова CheckedOnAllReplicas: статистику використання індексу зібрано на всіх репліках AG.
	   Вторинні репліки без доступу на читання (ALLOW_CONNECTIONS = NO, не зібрані) пропускаються: читань там бути не може. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot, [Parameter(Mandatory)]$Logical, [string]$Schema, [string]$Table, [string]$Index)
	$agName = [string]$Logical.primary.database['availabilityGroup']
	$copies = @(Get-IaRuleIndexReplicas -Logical $Logical -Schema $Schema -Table $Table -Index $Index)
	if (-not $agName) {
		$copy = $copies | Select-Object -First 1
		if ($null -eq $copy -or $null -eq $copy.index -or $null -eq $copy.index['usage']) {
			return New-IaRuleCondition -Id 'CheckedOnAllReplicas' -Met $null -Details 'Статистику використання індексу не зібрано'
		}
		return New-IaRuleCondition -Id 'CheckedOnAllReplicas' -Met $true -Details "Не AG: перевірено на інстансі $($copy.instance['serverName'])"
	}
	$ag = $null
	if ($Snapshot['topology'] -is [System.Collections.IDictionary]) {
		$ag = @($Snapshot['topology']['availabilityGroups']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -eq $agName } | Select-Object -First 1
	}
	if ($null -eq $ag) {
		return New-IaRuleCondition -Id 'CheckedOnAllReplicas' -Met $null -Details "AG $agName відсутня в топології snapshot"
	}
	$checked = [System.Collections.Generic.List[string]]::new()
	$failed = [System.Collections.Generic.List[string]]::new()
	$unknown = [System.Collections.Generic.List[string]]::new()
	$skipped = [System.Collections.Generic.List[string]]::new()
	foreach ($replica in @($ag['replicas'])) {
		if ($replica -isnot [System.Collections.IDictionary]) {
			continue
		}
		$name = [string]$replica['replicaServerName']
		if (-not $replica['collected']) {
			if ($replica['role'] -ne 'PRIMARY' -and $replica['secondaryAllowConnections'] -eq 'NO') {
				$skipped.Add("$name (читання заборонено)")
			}
			else {
				$failed.Add("$name не зібрано: $($replica['skipReason'])")
			}
			continue
		}
		$copy = $copies | Where-Object { $_.instance['serverName'] -eq $name } | Select-Object -First 1
		if ($null -eq $copy) {
			$unknown.Add("$name (база не зібрана)")
		}
		elseif ($null -eq $copy.index -or $null -eq $copy.index['usage']) {
			$unknown.Add("$name (немає статистики використання індексу)")
		}
		else {
			$checked.Add($name)
		}
	}
	$details = "Перевірено: $(if ($checked.Count) { $checked -join ', ' } else { 'жодної репліки' })"
	if ($skipped.Count) { $details += "; пропущено: $($skipped -join ', ')" }
	if ($failed.Count) {
		return New-IaRuleCondition -Id 'CheckedOnAllReplicas' -Met $false -Details "$details; $($failed -join '; ')"
	}
	if ($unknown.Count -or $checked.Count -eq 0) {
		return New-IaRuleCondition -Id 'CheckedOnAllReplicas' -Met $null -Details "$details; невідомо: $($unknown -join ', ')"
	}
	return New-IaRuleCondition -Id 'CheckedOnAllReplicas' -Met $true -Details $details
}
