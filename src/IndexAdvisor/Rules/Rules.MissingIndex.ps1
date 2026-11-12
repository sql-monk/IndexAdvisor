# Рекомендації на створення: злиття missing index і оцінка впливу (розділ 4.5 ТЗ; CONTRACTS.md, розділ 3.5).

function Get-IaRuleColumnBytes {
	<# Оцінка середнього розміру значення колонки в байтах (змінна довжина — половина максимуму, MAX — 200 байт). #>
	param([AllowNull()]$Column)
	if ($null -eq $Column) {
		return 8
	}
	$maxLength = [int]$Column['maxLength']
	if ($maxLength -lt 0) {
		return 200
	}
	if ($script:IaRuleVariableTypes -contains [string]$Column['typeName']) {
		return [math]::Ceiling($maxLength / 2) + 2
	}
	return [math]::Max(1, $maxLength)
}

function Get-IaIndexCreateEstimate {
	<# Оцінка впливу нового індексу: @{ estimatedSizeMb; estimatedBuildMinutes; tableWritesPerDay }.
	   Розмір — з кількості рядків і розміру ключа, INCLUDE та локатора рядка; час побудови — грубо з обсягу читання таблиці
	   (~500 МБ/хв) і запису індексу (~100 МБ/хв); записи — user_updates базової структури таблиці за добу роботи сервера. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Table,
		[Parameter(Mandatory)][string[]]$KeyColumns,
		[string[]]$IncludedColumns = @(),
		[double]$UptimeDays = 0
	)
	$columns = @($KeyColumns) + @($IncludedColumns | Where-Object { $_ -and @($KeyColumns) -notcontains $_ })
	$base = Get-IaRuleBaseIndex -Table $Table
	$locatorBytes = 8
	if ($base -and $base['typeDesc'] -eq 'CLUSTERED') {
		$locatorBytes = 0
		foreach ($key in @(Get-IaRuleKeyColumns -Index $base)) {
			if ($columns -notcontains $key.name) {
				$locatorBytes += Get-IaRuleColumnBytes -Column (Find-IaRuleColumn -Table $Table -Name $key.name)
			}
		}
		if (-not ($base['isUnique'] -or $base['isPrimaryKey'] -or $base['isUniqueConstraint'])) {
			$locatorBytes += 4
		}
	}
	$rowBytes = 9 + $locatorBytes + 2
	foreach ($name in $columns) {
		$rowBytes += Get-IaRuleColumnBytes -Column (Find-IaRuleColumn -Table $Table -Name $name)
	}
	$sizeMb = $null
	$buildMinutes = $null
	if ($null -ne $Table['rowCount']) {
		$rowsPerPage = [math]::Max(1, [math]::Floor(8096 / $rowBytes))
		$pages = [math]::Ceiling([double]$Table['rowCount'] / $rowsPerPage)
		$sizeMb = [math]::Round($pages * 1.01 * 8 / 1024, 2)
		$tableMb = if ($null -ne $Table['usedMb']) { [double]$Table['usedMb'] } elseif ($null -ne $Table['reservedMb']) { [double]$Table['reservedMb'] } else { $sizeMb }
		$buildMinutes = [math]::Max(0.01, [math]::Round($tableMb / 500 + $sizeMb / 100, 2))
	}
	$writesPerDay = $null
	$updates = $null
	if ($base -and $base['usage'] -is [System.Collections.IDictionary]) {
		$updates = [long]$base['usage']['userUpdates']
	}
	else {
		foreach ($index in @($Table['indexes'])) {
			if ($index -is [System.Collections.IDictionary] -and $index['usage'] -is [System.Collections.IDictionary]) {
				$updates = [math]::Max([long]$updates, [long]$index['usage']['userUpdates'])
			}
		}
	}
	if ($null -ne $updates -and $UptimeDays -gt 0) {
		$writesPerDay = [math]::Round($updates / $UptimeDays, 2)
	}
	return [ordered]@{
		estimatedSizeMb = $sizeMb
		estimatedBuildMinutes = $buildMinutes
		tableWritesPerDay = $writesPerDay
	}
}

function Get-IaRuleIndexName {
	<# Ім'я нового індексу за конвенцією IX_<Col1>[_D][_<Col2>...][_INC][_FLT][_UQ][_P] (до 128 символів). #>
	param([string[]]$KeyColumns, [bool[]]$Descending = @(), [bool]$HasInclude, [bool]$HasFilter, [bool]$IsUnique, [bool]$IsPartitioned, [string]$Prefix = 'IX')
	$parts = [System.Collections.Generic.List[string]]::new()
	for ($i = 0; $i -lt @($KeyColumns).Count; $i++) {
		$part = ($KeyColumns[$i] -replace '[^\w]', '')
		if ($i -lt @($Descending).Count -and $Descending[$i]) {
			$part += '_D'
		}
		$parts.Add($part)
	}
	$name = $Prefix + '_' + ($parts -join '_')
	if ($name.Length -gt 100) {
		$name = $name.Substring(0, 100).TrimEnd('_') + '_0'
	}
	if ($HasInclude) { $name += '_INC' }
	if ($HasFilter) { $name += '_FLT' }
	if ($IsUnique) { $name += '_UQ' }
	if ($IsPartitioned) { $name += '_P' }
	return $name
}

function Test-IaRuleMissingCompatible {
	<# Чи можна злити пропозицію Short у кандидата Long: однакові equality-колонки (як множина) і inequality Short — префікс Long,
	   або Short без inequality, а її equality-колонки (як множина) — перші equality-колонки Long. #>
	param([Parameter(Mandatory)]$Short, [Parameter(Mandatory)]$Long)
	$shortEq = @($Short.equality)
	$longEq = @($Long.equality)
	$shortIneq = @($Short.inequality)
	$longIneq = @($Long.inequality)
	if ($shortEq.Count -eq $longEq.Count -and (Test-IaRuleSameSet -First $shortEq -Second $longEq)) {
		if ($shortIneq.Count -gt $longIneq.Count) {
			return $false
		}
		for ($i = 0; $i -lt $shortIneq.Count; $i++) {
			if ($shortIneq[$i] -ne $longIneq[$i]) {
				return $false
			}
		}
		return $true
	}
	if ($shortIneq.Count -eq 0 -and $shortEq.Count -gt 0 -and $shortEq.Count -lt $longEq.Count) {
		return (Test-IaRuleSameSet -First $shortEq -Second $longEq[0..($shortEq.Count - 1)])
	}
	return $false
}

function Merge-IaMissingIndexes {
	<# Злиття схожих рекомендацій missing index (однакова таблиця, сумісні ключі) у кандидатів
	   @{ target; keyColumns; includedColumns; sourceIndexHandles; userSeeks; userScans; avgUserImpact; estimate }.
	   Джерела — sys.dm_db_missing_index_* з усіх реплік і missing index у планах Query Store. Кандидати, які вже покриває
	   наявний рядковий індекс без фільтра, пропускаються. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$candidates = [System.Collections.Generic.List[object]]::new()
	foreach ($logical in @(Get-IaRuleLogicalDatabases -Snapshot $Snapshot)) {
		$queries = @(Get-IaRuleQueryStoreQueries -Logical $logical)
		$raw = [System.Collections.Generic.List[object]]::new()
		foreach ($replica in $logical.replicas) {
			foreach ($missing in @($replica.database['missingIndexes'])) {
				if ($missing -isnot [System.Collections.IDictionary]) {
					continue
				}
				$hashes = @($missing['queryHashes'] | Where-Object { $_ })
				$queryIds = @($queries | Where-Object { $hashes -contains [string]$_['queryHash'] } | ForEach-Object { [long]$_['queryId'] })
				$raw.Add([ordered]@{
						schema = [string]$missing['schema']; table = [string]$missing['table']
						equality = @($missing['equalityColumns'] | Where-Object { $_ }); inequality = @($missing['inequalityColumns'] | Where-Object { $_ })
						included = @($missing['includedColumns'] | Where-Object { $_ })
						handles = @([long]$missing['indexHandle']); queryIds = $queryIds
						seeks = [long]$missing['userSeeks']; scans = [long]$missing['userScans']
						impact = [double]$missing['avgUserImpact']; cost = [double]$missing['avgTotalUserCost']
					})
			}
		}
		foreach ($query in $queries) {
			foreach ($plan in @($query['plans'])) {
				foreach ($missing in @($plan['missingIndexes'])) {
					if ($missing -isnot [System.Collections.IDictionary]) {
						continue
					}
					$raw.Add([ordered]@{
							schema = [string]$missing['schema']; table = [string]$missing['table']
							equality = @($missing['equalityColumns'] | Where-Object { $_ }); inequality = @($missing['inequalityColumns'] | Where-Object { $_ })
							included = @($missing['includedColumns'] | Where-Object { $_ })
							handles = @(); queryIds = @([long]$query['queryId'])
							seeks = [long]0; scans = [long]0
							impact = $(if ($null -ne $missing['impact']) { [double]$missing['impact'] } else { 0 }); cost = [double]0
						})
				}
			}
		}
		$byTable = [ordered]@{}
		foreach ($item in $raw) {
			if (@($item.equality).Count + @($item.inequality).Count -eq 0) {
				continue
			}
			$key = ('{0}.{1}' -f $item.schema, $item.table).ToLowerInvariant()
			if (-not $byTable.Contains($key)) {
				$byTable[$key] = [System.Collections.Generic.List[object]]::new()
			}
			$byTable[$key].Add($item)
		}
		foreach ($items in $byTable.Values) {
			$sorted = @($items | Sort-Object -Descending -Property @(
					@{ Expression = { @($_.equality).Count + @($_.inequality).Count } }
					@{ Expression = { $_.seeks + $_.scans } }
				))
			$clusters = [System.Collections.Generic.List[object]]::new()
			foreach ($item in $sorted) {
				$cluster = $null
				foreach ($existing in $clusters) {
					if (Test-IaRuleMissingCompatible -Short $item -Long $existing) {
						$cluster = $existing
						break
					}
				}
				if ($null -eq $cluster) {
					$cluster = [ordered]@{
						schema = $item.schema; table = $item.table
						equality = @($item.equality); inequality = @($item.inequality)
						included = [System.Collections.Generic.List[string]]::new()
						handles = [System.Collections.Generic.List[long]]::new(); queryIds = [System.Collections.Generic.List[long]]::new()
						seeks = [long]0; scans = [long]0; impactWeighted = [double]0; impactWeight = [double]0; impactPlain = [System.Collections.Generic.List[double]]::new()
						costWeighted = [double]0
					}
					$clusters.Add($cluster)
				}
				foreach ($column in @($item.included)) {
					if ($cluster.included -notcontains $column) { $cluster.included.Add([string]$column) }
				}
				foreach ($handle in @($item.handles)) {
					if (-not $cluster.handles.Contains([long]$handle)) { $cluster.handles.Add([long]$handle) }
				}
				foreach ($queryId in @($item.queryIds)) {
					if (-not $cluster.queryIds.Contains([long]$queryId)) { $cluster.queryIds.Add([long]$queryId) }
				}
				$weight = [double]($item.seeks + $item.scans)
				$cluster.seeks += $item.seeks
				$cluster.scans += $item.scans
				$cluster.impactWeighted += $item.impact * $weight
				$cluster.costWeighted += $item.cost * $weight
				$cluster.impactWeight += $weight
				$cluster.impactPlain.Add($item.impact)
			}
			foreach ($cluster in $clusters) {
				$table = Find-IaRuleTable -Database $logical.primary.database -Schema $cluster.schema -Table $cluster.table
				$keyColumns = @($cluster.equality) + @($cluster.inequality)
				$included = @($cluster.included | Where-Object { $keyColumns -notcontains $_ })
				if ($table -and (Test-IaRuleMissingCovered -Table $table -Cluster $cluster -Included $included)) {
					continue
				}
				$impact = if ($cluster.impactWeight -gt 0) { $cluster.impactWeighted / $cluster.impactWeight } else { ($cluster.impactPlain | Measure-Object -Average).Average }
				$cost = if ($cluster.impactWeight -gt 0) { $cluster.costWeighted / $cluster.impactWeight } else { 0 }
				$name = Get-IaRuleIndexName -KeyColumns $keyColumns -HasInclude ($included.Count -gt 0)
				$estimate = [ordered]@{ estimatedSizeMb = $null; estimatedBuildMinutes = $null; tableWritesPerDay = $null }
				if ($table) {
					$period = Get-IaRuleInstancePeriod -Instance $logical.primary.instance
					$estimate = Get-IaIndexCreateEstimate -Table $table -KeyColumns $keyColumns -IncludedColumns $included -UptimeDays $period.days
				}
				$candidates.Add([ordered]@{
						target = New-IaTarget -Server $logical.server -Database $logical.database -Schema $cluster.schema -Table $cluster.table -Index $name
						keyColumns = @($keyColumns)
						includedColumns = @($included)
						equalityColumns = @($cluster.equality)
						inequalityColumns = @($cluster.inequality)
						sourceIndexHandles = @($cluster.handles)
						queryIds = @($cluster.queryIds)
						userSeeks = $cluster.seeks
						userScans = $cluster.scans
						avgUserImpact = [math]::Round([double]$impact, 2)
						avgTotalUserCost = [math]::Round([double]$cost, 2)
						proposedName = $name
						estimate = $estimate
					})
			}
		}
	}
	return $candidates.ToArray()
}

function Test-IaRuleMissingCovered {
	<# Чи покриває кандидата наявний увімкнений рядковий індекс без фільтра (ключі — префікс, INCLUDE — підмножина). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Table, [Parameter(Mandatory)]$Cluster, [string[]]$Included = @())
	$equality = @($Cluster.equality)
	$inequality = @($Cluster.inequality)
	foreach ($index in @(Get-IaRuleActiveIndexes -Table $Table)) {
		if (-not (Test-IaRuleRowstore -Index $index) -or (ConvertTo-IaRuleFilterKey $index['filterDefinition'])) {
			continue
		}
		$keys = @(Get-IaRuleKeyColumns -Index $index | ForEach-Object { $_.name })
		if ($keys.Count -lt $equality.Count + $inequality.Count) {
			continue
		}
		if ($equality.Count -gt 0 -and -not (Test-IaRuleSameSet -First $equality -Second $keys[0..($equality.Count - 1)])) {
			continue
		}
		$prefixOk = $true
		for ($i = 0; $i -lt $inequality.Count; $i++) {
			if ($keys[$equality.Count + $i] -ne $inequality[$i]) {
				$prefixOk = $false
			}
		}
		if (-not $prefixOk) {
			continue
		}
		if ($index['typeDesc'] -eq 'CLUSTERED' -or (Test-IaRuleSubset -Subset $Included -Superset (@($keys) + @($index['includedColumns'])))) {
			return $true
		}
	}
	return $false
}
