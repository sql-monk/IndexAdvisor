# Query Store: налаштування й попередження, топ-запити з профілем по годинах і днях тижня, розбір планів,
# регресії, категорія навантаження, index.queryStoreUsage і хінти в текстах запитів (ТЗ 4.3.1).

$script:IaColQueryStorePlanListPageSize = 5000
$script:IaColQueryStorePlanXmlBatchSize = 50
$script:IaColHeavyLogicalReads = 10000
$script:IaColAdHocMaxExecutions = 10
$script:IaColOltpMinExecutions = 100
$script:IaColRegressionRatio = 2.0

function Get-IaColQueryStoreState {
	param($Value)
	$state = [string]$Value
	if ($state -in @('OFF', 'READ_ONLY', 'READ_WRITE', 'ERROR')) {
		return $state
	}
	return 'ERROR'
}

function ConvertTo-IaColQueryStoreInfo {
	<# Рядок query_store_options -> queryStoreInfo з попередженнями (вимкнено, READ_ONLY, мало місця, короткий термін зберігання, короткий період). #>
	param([Parameter(Mandatory)][hashtable]$DbCtx, [Parameter(Mandatory)]$Row)
	$config = $DbCtx.Config
	$context = $DbCtx.Context
	$first = ConvertTo-IaColUtc (Get-IaColValue $Row 'firstIntervalStartUtc')
	$last = ConvertTo-IaColUtc (Get-IaColValue $Row 'lastIntervalEndUtc')
	$periodDays = 0.0
	if ($first -and $last) {
		$periodDays = [Math]::Round(((ConvertTo-IaColDateTime $last) - (ConvertTo-IaColDateTime $first)).TotalDays, 2)
	}
	$info = [ordered]@{
		actualState = Get-IaColQueryStoreState (Get-IaColValue $Row 'actualState')
		desiredState = Get-IaColQueryStoreState (Get-IaColValue $Row 'desiredState')
		readOnlyReason = ConvertTo-IaColLong (Get-IaColValue $Row 'readOnlyReason')
		currentStorageSizeMb = ConvertTo-IaColDouble (Get-IaColValue $Row 'currentStorageSizeMb') -Default 0 -Digits 2
		maxStorageSizeMb = ConvertTo-IaColDouble (Get-IaColValue $Row 'maxStorageSizeMb') -Default 0 -Digits 2
		staleQueryThresholdDays = ConvertTo-IaColLong (Get-IaColValue $Row 'staleQueryThresholdDays') -Default 0
		queryCaptureMode = Get-IaColValue $Row 'queryCaptureMode'
		intervalLengthMinutes = ConvertTo-IaColLong (Get-IaColValue $Row 'intervalLengthMinutes')
		firstIntervalStartUtc = $first
		lastIntervalEndUtc = $last
		periodDays = $periodDays
		warnings = [System.Collections.Generic.List[object]]::new()
	}
	$add = {
		param([string]$Code, [string]$Message)
		Add-IaColWarning -List $info.warnings -Code $Code -Message $Message -Dataset 'queryStore' -Server $DbCtx.ServerName -Database $DbCtx.Name
	}
	$minUptimeDays = [int]$config.rules.drop.minUptimeDays
	$requiredRetention = [int][Math]::Max([Math]::Ceiling($context.WindowDays), $minUptimeDays)
	switch ($info.actualState) {
		'OFF' { & $add 'QueryStoreOff' 'Query Store вимкнено: використання індексів у планах і хінти в текстах запитів не перевіряються; рекомендації на видалення ґрунтуються лише на DMV.' }
		'ERROR' { & $add 'QueryStoreError' 'Query Store у стані ERROR: дані Query Store недоступні для аналізу.' }
		'READ_ONLY' {
			& $add 'QueryStoreReadOnly' ("Query Store у режимі READ_ONLY (readonly_reason = {0}): нові дані не збираються, профіль навантаження може бути застарілим." -f $info.readOnlyReason)
		}
	}
	if ($info.desiredState -ne $info.actualState) {
		& $add 'QueryStoreStateMismatch' ("Бажаний стан Query Store {0} не збігається з фактичним {1}." -f $info.desiredState, $info.actualState)
	}
	if ($info.queryCaptureMode -eq 'NONE') {
		& $add 'QueryStoreCaptureNone' 'QUERY_CAPTURE_MODE = NONE: нові запити не потрапляють у Query Store.'
	}
	if ($info.maxStorageSizeMb -gt 0) {
		$freePercent = ($info.maxStorageSizeMb - $info.currentStorageSizeMb) / $info.maxStorageSizeMb * 100
		if ($freePercent -lt [double]$config.collector.queryStoreMinFreeSpacePercent) {
			& $add 'QueryStoreLowSpace' ("Вільного місця Query Store {0:N1}% (менше за {1}%): можливий перехід у READ_ONLY і втрата даних." -f $freePercent, $config.collector.queryStoreMinFreeSpacePercent)
		}
	}
	if ($info.actualState -ne 'OFF' -and $info.staleQueryThresholdDays -lt $requiredRetention) {
		& $add 'QueryStoreShortRetention' ("Термін зберігання Query Store {0} дн. коротший за потрібні {1} дн. (вікно аналізу або мінімальний період rules.drop.minUptimeDays)." -f $info.staleQueryThresholdDays, $requiredRetention)
	}
	if ($info.actualState -in @('READ_WRITE', 'READ_ONLY') -and $periodDays -lt $minUptimeDays) {
		& $add 'QueryStoreShortPeriod' ("Query Store містить дані лише за {0} дн. (менше за {1} дн.): даних недостатньо для рекомендацій на видалення." -f $periodDays, $minUptimeDays)
	}
	return $info
}

function Get-IaColWorkloadCategory {
	<# Евристика категорії навантаження: Etl, Report, AdHoc, Oltp або Unknown. Application Name (SSIS) у Query Store недоступний,
	   тому ETL визначається за текстом (INSERT BULK, MERGE, SELECT INTO, важкий DML) та іменем модуля. #>
	param([AllowNull()][string]$QueryText, [AllowNull()][string]$ObjectName, [long]$ExecutionCount, [double]$AvgLogicalReads, [bool]$IsParameterized)
	$statement = ([string]$QueryText) -replace '^\s*\((@[^)]*)\)', ''
	$object = [string]$ObjectName
	$isDml = $statement -match '(?is)^\s*(INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\b'
	$heavy = $AvgLogicalReads -ge $script:IaColHeavyLogicalReads
	$etlObject = $object -match '(?i)(etl|load|import|export|stag|stg|ssis|extract|transform)'
	$bulk = $statement -match '(?is)^\s*(INSERT\s+BULK|BULK\s+INSERT)\b'
	$merge = $statement -match '(?is)^\s*MERGE\b'
	$selectInto = $statement -match '(?is)^\s*SELECT\b(?:(?!\bFROM\b).)*\bINTO\s+[\[#\w]'
	if ($bulk -or $merge -or $selectInto -or ($isDml -and $heavy) -or $etlObject) {
		return 'Etl'
	}
	$reportObject = $object -match '(?i)(rpt|report|dashboard|analytic)'
	$aggregate = $statement -match '(?is)\bGROUP\s+BY\b|\bOVER\s*\(|\b(SUM|AVG|COUNT|COUNT_BIG|MIN|MAX)\s*\('
	if ($reportObject -or (-not $isDml -and $aggregate -and $heavy)) {
		return 'Report'
	}
	if (-not $IsParameterized -and [string]::IsNullOrEmpty($object) -and $ExecutionCount -le $script:IaColAdHocMaxExecutions) {
		return 'AdHoc'
	}
	if (-not $heavy -and ($IsParameterized -or -not [string]::IsNullOrEmpty($object) -or $ExecutionCount -ge $script:IaColOltpMinExecutions)) {
		return 'Oltp'
	}
	return 'Unknown'
}

function Test-IaColPlanRegression {
	<# Регресія: у запиту кілька планів, і останній за часом виконання план щонайменше вдвічі повільніший за найкращий інший. #>
	param([object[]]$Plans)
	$withStats = @($Plans | Where-Object { $null -ne $_.avgDurationMs -and [long]$_.executionCount -gt 0 })
	if ($withStats.Count -lt 2) {
		return $false
	}
	$latest = @($withStats | Sort-Object -Property @{ Expression = { [string]$_.lastExecutionUtc }; Descending = $true }, @{ Expression = { [long]$_.planId }; Descending = $true })[0]
	$best = $null
	foreach ($plan in $withStats) {
		if ($plan.planId -ne $latest.planId -and ($null -eq $best -or [double]$plan.avgDurationMs -lt $best)) {
			$best = [double]$plan.avgDurationMs
		}
	}
	return ($null -ne $best -and $best -gt 0 -and [double]$latest.avgDurationMs -ge $script:IaColRegressionRatio * $best)
}

function Add-IaColQueryStoreUsageEntry {
	<# Облік використання індексу планом у мапі інстансу (ключ db|schema|table|index у нижньому регістрі). #>
	param([Parameter(Mandatory)][hashtable]$Usage, $Operation, [long]$PlanId, [long]$QueryId, [AllowNull()][string]$LastUsedUtc)
	$key = ('{0}|{1}|{2}|{3}' -f $Operation.database, $Operation.schema, $Operation.table, $Operation.index).ToLowerInvariant()
	$entry = $Usage[$key]
	if ($null -eq $entry) {
		$entry = @{
			planIds = [System.Collections.Generic.HashSet[long]]::new()
			queryIds = [System.Collections.Generic.HashSet[long]]::new()
			seek = [System.Collections.Generic.HashSet[long]]::new()
			scan = [System.Collections.Generic.HashSet[long]]::new()
			lookup = [System.Collections.Generic.HashSet[long]]::new()
			lastUsedUtc = $null
		}
		$Usage[$key] = $entry
	}
	[void]$entry.planIds.Add($PlanId)
	[void]$entry.queryIds.Add($QueryId)
	switch ($Operation.operation) {
		'Seek' { [void]$entry.seek.Add($PlanId) }
		'Scan' { [void]$entry.scan.Add($PlanId) }
		'Lookup' { [void]$entry.lookup.Add($PlanId) }
	}
	if ($LastUsedUtc -and ($null -eq $entry.lastUsedUtc -or [string]::CompareOrdinal($LastUsedUtc, $entry.lastUsedUtc) -gt 0)) {
		$entry.lastUsedUtc = $LastUsedUtc
	}
}

function Add-IaColQueryStorePlanPage {
	<# Обробляє сторінку планів: розбір XML (кеш за query_plan_hash), облік використання індексів, деталі планів топ-запитів. #>
	param([object[]]$Rows, [Parameter(Mandatory)][hashtable]$State)
	foreach ($row in $Rows) {
		$planId = ConvertTo-IaColLong (Get-IaColValue $row 'planId')
		$queryId = ConvertTo-IaColLong (Get-IaColValue $row 'queryId')
		$hash = [string](Get-IaColValue $row 'queryPlanHash')
		$xml = [string](Get-IaColValue $row 'queryPlan')
		$parsed = $null
		if (-not [string]::IsNullOrEmpty($xml)) {
			$parsed = ConvertFrom-IaColShowplan -PlanXml $xml -DefaultDatabase $State.DatabaseName
			if ($hash) {
				$State.Cache[$hash] = $parsed
			}
			if ($parsed.parseError) {
				$State.ParseErrors++
			}
		}
		elseif ($hash -and $State.Cache.ContainsKey($hash)) {
			$parsed = $State.Cache[$hash]
		}
		else {
			$State.Unparsed++
			continue
		}
		$lastUsed = ConvertTo-IaColUtc (Get-IaColValue $row 'lastExecutionUtc')
		foreach ($operation in $parsed.indexOperations) {
			if ($operation.operation -ne 'Update') {
				Add-IaColQueryStoreUsageEntry -Usage $State.Usage -Operation $operation -PlanId $planId -QueryId $queryId -LastUsedUtc $lastUsed
			}
		}
		$query = $State.Queries[[string]$queryId]
		if ($null -eq $query) {
			continue
		}
		$query.plans.Add([ordered]@{
				planId = $planId
				isForced = ConvertTo-IaColBool (Get-IaColValue $row 'isForced')
				executionCount = ConvertTo-IaColLong (Get-IaColValue $row 'executionCount') -Default 0
				avgDurationMs = ConvertTo-IaColDouble (Get-IaColValue $row 'avgDurationMs') -Digits 3
				avgCpuMs = ConvertTo-IaColDouble (Get-IaColValue $row 'avgCpuMs') -Digits 3
				lastExecutionUtc = $lastUsed
				indexOperations = @($parsed.indexOperations | Where-Object { $null -ne $_.operation })
				missingIndexes = @($parsed.missingIndexes)
				predicates = @($parsed.predicates)
				hasKeyLookup = [bool]$parsed.hasKeyLookup
				hasImplicitConversion = [bool]$parsed.hasImplicitConversion
				usesBatchMode = [bool]$parsed.usesBatchMode
				scansWholeTable = $parsed.scansWholeTable
				partitionElimination = $parsed.partitionElimination
				columnstoreSegmentElimination = $parsed.columnstoreSegmentElimination
			})
	}
}

function Get-IaColPlanXmlBatch {
	<# XML showplan для пакета планів. Тайм-аут пакета — поділ навпіл аж до одного плану; один план — повтор з тайм-аутом команди ×4
	   (гігантський план). Повертає @{ success; rows; error }; помилка — для першого плану, який не вдалося отримати. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx, [Parameter(Mandatory)][long[]]$Ids, [System.Collections.IDictionary]$Config)
	$parameters = [ordered]@{
		planIds = ',' + ($Ids -join ',') + ','
		minPlanId = [long]($Ids | Measure-Object -Minimum).Minimum
		maxPlanId = [long]($Ids | Measure-Object -Maximum).Maximum
	}
	$splat = @{ DbCtx = $DbCtx; Name = 'query_store_plan_xml'; Parameters = $parameters; PageSize = $Ids.Count }
	if ($Config) {
		$splat.Config = $Config
	}
	$result = Invoke-IaColDbQuery @splat
	if ($result.success -or $null -eq $result.error -or [string]$result.error.code -ne 'Timeout') {
		return $result
	}
	if ($Ids.Count -gt 1) {
		$half = [int][Math]::Ceiling($Ids.Count / 2)
		$rows = [System.Collections.Generic.List[object]]::new()
		foreach ($part in @(, @($Ids[0..($half - 1)])) + @(, @($Ids[$half..($Ids.Count - 1)]))) {
			$partResult = Get-IaColPlanXmlBatch -DbCtx $DbCtx -Ids ([long[]]$part) -Config $Config
			if (-not $partResult.success) {
				return $partResult
			}
			foreach ($row in @($partResult.rows)) {
				$rows.Add($row)
			}
		}
		return @{ success = $true; rows = $rows.ToArray(); error = $null }
	}
	if ($null -eq $Config) {
		$Config = Copy-IaObject -InputObject $DbCtx.Config
		$Config.connection.commandTimeoutSeconds = [Math]::Min(3600, 4 * [int]$DbCtx.Config.connection.commandTimeoutSeconds)
		$retry = Get-IaColPlanXmlBatch -DbCtx $DbCtx -Ids $Ids -Config $Config
		if (-not $retry.success -and $retry.error) {
			$retry.error.message = "XML плану $($Ids[0]) не отримано навіть з тайм-аутом $($Config.connection.commandTimeoutSeconds) с: $($retry.error.message)"
		}
		return $retry
	}
	return $result
}

function Add-IaColQueryStorePlans {
	<# Плани Query Store у три кроки (перелік, статистика топ-запитів, XML за query_plan_hash пакетами) з обробкою через
	   Add-IaColQueryStorePlanPage. Повертає текст помилки або $null. Бюджет — collector.queryStorePlansTimeBudgetSeconds. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx, [Parameter(Mandatory)][hashtable]$State)
	$config = $DbCtx.Config
	$maxRows = [int]$config.limits.maxRows
	$budgetSeconds = [int]$(if ($config.collector -and $config.collector.queryStorePlansTimeBudgetSeconds) { $config.collector.queryStorePlansTimeBudgetSeconds } else { 900 })
	$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	$overBudget = { $stopwatch.Elapsed.TotalSeconds -gt $budgetSeconds }
	$budgetMessage = "бюджет часу collector.queryStorePlansTimeBudgetSeconds ($budgetSeconds с) вичерпано"

	# 1. Перелік планів без XML, keyset за plan_id.
	$plans = [System.Collections.Generic.List[object]]::new()
	$afterPlanId = [long]0
	$pageSize = [Math]::Min($script:IaColQueryStorePlanListPageSize, $maxRows)
	while ($true) {
		$page = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'query_store_plan_list' -Parameters ([ordered]@{ afterPlanId = $afterPlanId }) -PageSize $pageSize -SinglePage
		if (-not $page.success) {
			return $page.error.message
		}
		$rows = @($page.rows)
		foreach ($row in $rows) {
			$plans.Add($row)
		}
		if ($rows.Count -lt $pageSize) {
			break
		}
		$afterPlanId = ConvertTo-IaColLong (Get-IaColValue $rows[-1] 'planId')
		if (& $overBudget) {
			return $budgetMessage
		}
	}

	# 2. Статистика виконання — лише для планів топ-запитів (для деталей планів у queryStoreQueries).
	$statsByPlan = @{}
	if ($State.Queries.Count -gt 0) {
		$queryIds = ',' + (($State.Queries.Keys | ForEach-Object { [string]$_ }) -join ',') + ','
		$stats = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'query_store_plan_stats' -Parameters ([ordered]@{ queryIds = $queryIds })
		if (-not $stats.success) {
			Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'queryStore' -Message (
				"Статистику виконання планів топ-запитів не зібрано: {0}; кількість виконань і тривалість планів невідомі." -f $stats.error.message)
		}
		else {
			foreach ($row in @($stats.rows)) {
				$statsByPlan[[string](ConvertTo-IaColLong (Get-IaColValue $row 'planId'))] = $row
			}
		}
	}
	$combine = {
		param($Row, $Xml)
		$planKey = [string](ConvertTo-IaColLong (Get-IaColValue $Row 'planId'))
		$stat = $statsByPlan[$planKey]
		[ordered]@{
			planId = Get-IaColValue $Row 'planId'
			queryId = Get-IaColValue $Row 'queryId'
			queryPlanHash = Get-IaColValue $Row 'queryPlanHash'
			isForced = Get-IaColValue $Row 'isForced'
			lastExecutionUtc = Get-IaColValue $Row 'lastExecutionUtc'
			executionCount = $(if ($stat) { Get-IaColValue $stat 'executionCount' } else { $null })
			avgDurationMs = $(if ($stat) { Get-IaColValue $stat 'avgDurationMs' } else { $null })
			avgCpuMs = $(if ($stat) { Get-IaColValue $stat 'avgCpuMs' } else { $null })
			queryPlan = $Xml
		}
	}

	# 3. XML першого плану кожного query_plan_hash (план без хешу — окремо) пакетами; кожен пакет розбирається одразу.
	$firstByHash = @{}
	$xmlPlans = [System.Collections.Generic.List[object]]::new()
	$others = [System.Collections.Generic.List[object]]::new()
	foreach ($row in $plans) {
		$hash = [string](Get-IaColValue $row 'queryPlanHash')
		if ($hash -and $firstByHash.ContainsKey($hash)) {
			$others.Add($row)
			continue
		}
		if ($hash) {
			$firstByHash[$hash] = $true
		}
		$xmlPlans.Add($row)
	}
	$batchSize = [Math]::Max(1, [Math]::Min($script:IaColQueryStorePlanXmlBatchSize, $maxRows))
	for ($offset = 0; $offset -lt $xmlPlans.Count; $offset += $batchSize) {
		$batch = @($xmlPlans[$offset..([Math]::Min($xmlPlans.Count, $offset + $batchSize) - 1)])
		$ids = [long[]]@($batch | ForEach-Object { ConvertTo-IaColLong (Get-IaColValue $_ 'planId') })
		$result = Get-IaColPlanXmlBatch -DbCtx $DbCtx -Ids $ids
		if (-not $result.success) {
			return $result.error.message
		}
		$xmlById = @{}
		foreach ($row in @($result.rows)) {
			$xmlById[[string](ConvertTo-IaColLong (Get-IaColValue $row 'planId'))] = [string](Get-IaColValue $row 'queryPlan')
		}
		Add-IaColQueryStorePlanPage -Rows @(foreach ($row in $batch) { & $combine $row $xmlById[[string](ConvertTo-IaColLong (Get-IaColValue $row 'planId'))] }) -State $State
		if (& $overBudget) {
			return $budgetMessage
		}
	}

	# 4. Решта планів — розібраний план беруть з кешу за query_plan_hash.
	Add-IaColQueryStorePlanPage -Rows @(foreach ($row in $others) { & $combine $row $null }) -State $State
	return $null
}

function Add-IaColQueryStore {
	<# Набір queryStore для бази на primary (або поза AG). Повертає $true, якщо дані запитів і планів зібрано. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$database = $DbCtx.Database
	if ($database.replicaRole -eq 'SECONDARY') {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'QueryStoreOnPrimaryOnly' -Dataset 'queryStore' -Message (
			'Query Store на вторинній репліці не читається окремо: дані Query Store беруться з primary')
		return $false
	}
	$options = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'query_store_options' -SinglePage
	if (-not $options.success -or @($options.rows).Count -eq 0) {
		$message = if ($options.success) { 'налаштування Query Store не повернуто' } else { $options.error.message }
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'queryStore' -Message ("Query Store не зібрано: {0}" -f $message)
		return $false
	}
	$info = ConvertTo-IaColQueryStoreInfo -DbCtx $DbCtx -Row @($options.rows)[0]
	$database.queryStore = $info
	if ($info.actualState -notin @('READ_WRITE', 'READ_ONLY')) {
		return $false
	}
	$context = $DbCtx.Context
	$config = $DbCtx.Config
	$window = [ordered]@{ fromUtc = $context.WindowFrom; toUtc = $context.WindowTo }
	$topParameters = [ordered]@{ fromUtc = $context.WindowFrom; toUtc = $context.WindowTo; topN = [int]$config.collector.queryStoreTopN }
	$top = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'query_store_top_queries' -Parameters $topParameters
	if (-not $top.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'queryStore' -Message ("Топ-запити Query Store не зібрано: {0}" -f $top.error.message)
		return $false
	}
	$queries = [ordered]@{}
	$queryFlags = @{}
	foreach ($row in $top.rows) {
		$queryId = ConvertTo-IaColLong (Get-IaColValue $row 'queryId')
		$executions = ConvertTo-IaColLong (Get-IaColValue $row 'executionCount') -Default 0
		$totalCpu = ConvertTo-IaColDouble (Get-IaColValue $row 'totalCpuMs') -Default 0 -Digits 3
		$totalReads = ConvertTo-IaColDouble (Get-IaColValue $row 'totalLogicalReads') -Default 0 -Digits 0
		$totalDuration = ConvertTo-IaColDouble (Get-IaColValue $row 'totalDurationMs') -Default 0 -Digits 3
		$divisor = [Math]::Max(1, $executions)
		$topBy = [System.Collections.Generic.List[string]]::new()
		foreach ($pair in @(@('isTopCpu', 'Cpu'), @('isTopLogicalReads', 'LogicalReads'), @('isTopDuration', 'Duration'), @('isTopExecutions', 'Executions'))) {
			if (ConvertTo-IaColBool (Get-IaColValue $row $pair[0])) {
				$topBy.Add($pair[1])
			}
		}
		$objectName = Get-IaColValue $row 'objectName'
		$queries[[string]$queryId] = [ordered]@{
			queryId = $queryId
			queryHash = [string](Get-IaColValue $row 'queryHash')
			objectName = $(if ($null -ne $objectName) { [string]$objectName } else { $null })
			queryText = [string](Get-IaColValue $row 'queryText')
			executionCount = $executions
			totalCpuMs = $totalCpu
			totalLogicalReads = $totalReads
			totalDurationMs = $totalDuration
			avgCpuMs = [Math]::Round($totalCpu / $divisor, 3)
			avgLogicalReads = [Math]::Round($totalReads / $divisor, 2)
			avgDurationMs = [Math]::Round($totalDuration / $divisor, 3)
			planCount = ConvertTo-IaColLong (Get-IaColValue $row 'planCount') -Default 0
			firstExecutionUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'firstExecutionUtc')
			lastExecutionUtc = ConvertTo-IaColUtc (Get-IaColValue $row 'lastExecutionUtc')
			topBy = @($topBy.ToArray())
			byHour = @()
			byDayOfWeek = @()
			workloadCategory = 'Unknown'
			hasRegression = $false
			plans = [System.Collections.Generic.List[object]]::new()
		}
		$queryFlags[[string]$queryId] = ConvertTo-IaColBool (Get-IaColValue $row 'isParameterized')
	}
	if ($queries.Count -gt 0) {
		Add-IaColQueryStoreTimeProfile -DbCtx $DbCtx -Queries $queries -Window $window
	}
	$state = @{
		DatabaseName = $DbCtx.Name
		Cache = @{}
		Usage = $DbCtx.QsUsage
		Queries = $queries
		ParseErrors = 0
		Unparsed = 0
	}
	# Плани — усі, що зберігає Query Store (ТЗ 4.3.1: перед видаленням індексу жоден план не використовує його за весь період
	# спостереження), тож вибірка не обрізається топ-запитами. Щоб це не впиралося в тайм-аут на великому Query Store, збір — у три
	# легкі кроки: перелік планів без XML (keyset за plan_id), статистика лише планів топ-запитів, XML лише першого плану кожного
	# query_plan_hash пакетами. Вичерпаний бюджет часу — як збій: використання індексів у планах невідоме.
	$failure = Add-IaColQueryStorePlans -DbCtx $DbCtx -State $state
	if ($failure) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'DatasetFailed' -Dataset 'queryStore' -Message (
			"Плани Query Store не зібрано: {0}; використання індексів у планах невідоме (queryStoreUsage = null)." -f $failure)
		return $false
	}
	if ($state.ParseErrors -gt 0) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'PlanParseFailed' -Dataset 'queryStore' -Message (
			"{0} план(ів) не розібрано як XML; посилання на індекси взято з тексту плану без типу операції." -f $state.ParseErrors)
	}
	if ($state.Unparsed -gt 0) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'PlanNotAvailable' -Dataset 'queryStore' -Message (
			"Для {0} план(ів) Query Store немає XML showplan: використання індексів цими планами не враховано." -f $state.Unparsed)
	}
	foreach ($queryKey in @($queries.Keys)) {
		$query = $queries[$queryKey]
		$query.hasRegression = Test-IaColPlanRegression -Plans @($query.plans)
		$query.workloadCategory = Get-IaColWorkloadCategory -QueryText $query.queryText -ObjectName $query.objectName -ExecutionCount $query.executionCount `
			-AvgLogicalReads $query.avgLogicalReads -IsParameterized ([bool]$queryFlags[$queryKey])
		$database.queryStoreQueries.Add($query)
	}
	if ($DbCtx.Context.Enabled.Contains('constraintsAndReplication') -and $DbCtx.ConstraintsCollected) {
		Add-IaColQueryStoreHints -DbCtx $DbCtx
	}
	return $true
}

function Add-IaColQueryStoreTimeProfile {
	<# byHour і byDayOfWeek для топ-запитів. Помилка — попередження, масиви лишаються порожніми. #>
	param([Parameter(Mandatory)][hashtable]$DbCtx, [Parameter(Mandatory)][System.Collections.IDictionary]$Queries, [Parameter(Mandatory)][System.Collections.IDictionary]$Window)
	$queryIds = ',' + (($Queries.Keys | ForEach-Object { [string]$_ }) -join ',') + ','
	$parameters = [ordered]@{ fromUtc = $Window.fromUtc; toUtc = $Window.toUtc; queryIds = $queryIds }
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'query_store_time_profile' -Parameters $parameters
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'QueryStoreTimeProfileFailed' -Dataset 'queryStore' -Message (
			"Профіль топ-запитів по годинах і днях тижня не зібрано: {0}" -f $result.error.message)
		return
	}
	$buckets = @{}
	foreach ($row in $result.rows) {
		$queryKey = [string](ConvertTo-IaColLong (Get-IaColValue $row 'queryId'))
		if (-not $Queries.Contains($queryKey)) {
			continue
		}
		if (-not $buckets.ContainsKey($queryKey)) {
			$buckets[$queryKey] = @{ hour = @{}; day = @{} }
		}
		$values = @{
			executionCount = ConvertTo-IaColLong (Get-IaColValue $row 'executionCount') -Default 0
			cpuMs = ConvertTo-IaColDouble (Get-IaColValue $row 'cpuMs') -Default 0
			logicalReads = ConvertTo-IaColDouble (Get-IaColValue $row 'logicalReads') -Default 0
			durationMs = ConvertTo-IaColDouble (Get-IaColValue $row 'durationMs') -Default 0
		}
		foreach ($pair in @(@('hour', (ConvertTo-IaColLong (Get-IaColValue $row 'hourUtc'))), @('day', (ConvertTo-IaColLong (Get-IaColValue $row 'isoDayOfWeek'))))) {
			$bucketSet = $buckets[$queryKey][$pair[0]]
			$bucketKey = [long]$pair[1]
			if (-not $bucketSet.ContainsKey($bucketKey)) {
				$bucketSet[$bucketKey] = @{ executionCount = [long]0; cpuMs = 0.0; logicalReads = 0.0; durationMs = 0.0 }
			}
			$bucket = $bucketSet[$bucketKey]
			$bucket.executionCount += $values.executionCount
			$bucket.cpuMs += $values.cpuMs
			$bucket.logicalReads += $values.logicalReads
			$bucket.durationMs += $values.durationMs
		}
	}
	foreach ($queryKey in $buckets.Keys) {
		$query = $Queries[$queryKey]
		$query.byHour = @(
			foreach ($hour in ($buckets[$queryKey].hour.Keys | Sort-Object)) {
				$bucket = $buckets[$queryKey].hour[$hour]
				[ordered]@{ hour = [long]$hour; executionCount = $bucket.executionCount; cpuMs = [Math]::Round($bucket.cpuMs, 3)
					logicalReads = [Math]::Round($bucket.logicalReads, 0); durationMs = [Math]::Round($bucket.durationMs, 3) }
			}
		)
		$query.byDayOfWeek = @(
			foreach ($day in ($buckets[$queryKey].day.Keys | Sort-Object)) {
				$bucket = $buckets[$queryKey].day[$day]
				[ordered]@{ dayOfWeek = [long]$day; executionCount = $bucket.executionCount; cpuMs = [Math]::Round($bucket.cpuMs, 3)
					logicalReads = [Math]::Round($bucket.logicalReads, 0); durationMs = [Math]::Round($bucket.durationMs, 3) }
			}
		)
	}
}

function Add-IaColQueryStoreHints {
	<# Хінти індексів у текстах Query Store за весь період зберігання -> index.hintReferences (QueryStore). #>
	param([Parameter(Mandatory)][hashtable]$DbCtx)
	$result = Invoke-IaColDbQuery -DbCtx $DbCtx -Name 'query_store_hint_texts' -PageSize 500
	if (-not $result.success) {
		Add-IaColDbWarning -DbCtx $DbCtx -Code 'QueryStoreHintsFailed' -Dataset 'queryStore' -Message (
			"Пошук хінтів у текстах Query Store не виконано: {0}; hintReferences невідомі (null)." -f $result.error.message)
		foreach ($entry in $DbCtx.IndexEntries) {
			$entry.index.hintReferences = $null
		}
		return
	}
	$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($row in $result.rows) {
		$queryId = ConvertTo-IaColLong (Get-IaColValue $row 'queryId')
		foreach ($hint in (Get-IaColHintMatches -Text ([string](Get-IaColValue $row 'queryText')))) {
			$targets = $DbCtx.IndexesByName[$hint.name.ToLowerInvariant()]
			if ($null -eq $targets) {
				continue
			}
			foreach ($target in $targets) {
				if ($null -ne $target.index.hintReferences -and $seen.Add("$queryId|$($target.table.objectId)|$($target.index.indexId)")) {
					$target.index.hintReferences.Add([ordered]@{ source = 'QueryStore'; objectName = $null; queryId = $queryId })
				}
			}
		}
	}
}

function Set-IaColQueryStoreUsage {
	<# Після збору всіх баз інстансу: index.queryStoreUsage для баз, де Query Store зібрано (міжбазові плани враховуються). #>
	param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$DbContexts, [Parameter(Mandatory)][hashtable]$Usage)
	foreach ($dbCtx in $DbContexts) {
		if (-not $dbCtx.QsCollected) {
			continue
		}
		foreach ($entry in $dbCtx.IndexEntries) {
			$index = $entry.index
			$key = ('{0}|{1}|{2}|{3}' -f $dbCtx.Name, $entry.table.schema, $entry.table.name, $(if ($null -ne $index.name) { $index.name } else { '' })).ToLowerInvariant()
			$found = $Usage[$key]
			$index.queryStoreUsage = if ($null -eq $found) {
				[ordered]@{ planCount = 0; queryIds = @(); seekCount = 0; scanCount = 0; lookupCount = 0; lastUsedUtc = $null }
			}
			else {
				[ordered]@{
					planCount = $found.planIds.Count
					queryIds = @($found.queryIds | Sort-Object)
					seekCount = $found.seek.Count
					scanCount = $found.scan.Count
					lookupCount = $found.lookup.Count
					lastUsedUtc = $found.lastUsedUtc
				}
			}
		}
	}
}
