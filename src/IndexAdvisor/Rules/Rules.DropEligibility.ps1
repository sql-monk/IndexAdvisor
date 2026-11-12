# Правила безпечного видалення індексу (розділ 4.4 ТЗ; CONTRACTS.md, розділи 3.5, 5.4, 5.7).

function Get-IaRuleWindowCondition {
	<# Умова AnalysisWindow: на початку місяця вікно охоплює весь попередній місяць з його кінцем; Query Store покриває вікно. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot, [Parameter(Mandatory)]$Logical, [Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$window = $Snapshot['analysisWindow']
	if ($window -isnot [System.Collections.IDictionary]) {
		return New-IaRuleCondition -Id 'AnalysisWindow' -Met $null -Details 'Вікно аналізу у snapshot не вказано'
	}
	$from = ConvertTo-IaRuleUtcDate $window['fromUtc']
	$to = ConvertTo-IaRuleUtcDate $window['toUtc']
	if ($null -eq $from -or $null -eq $to) {
		return New-IaRuleCondition -Id 'AnalysisWindow' -Met $null -Details 'Межі вікна аналізу не розпізнано'
	}
	$culture = [cultureinfo]::InvariantCulture
	$details = 'Вікно {0} — {1} ({2})' -f $from.ToString('yyyy-MM-dd HH:mm', $culture), $to.ToString('yyyy-MM-dd HH:mm', $culture), $window['mode']
	if ($Config.analysisWindow.monthStartRule -and $to.Day -le [int]$Config.analysisWindow.monthStartDays) {
		$monthStart = [datetime]::new($to.Year, $to.Month, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
		$previousMonthStart = $monthStart.AddMonths(-1)
		if ($from -gt $previousMonthStart -or $to -lt $monthStart) {
			return New-IaRuleCondition -Id 'AnalysisWindow' -Met $false -Details ('{0}: на початку місяця вікно має охоплювати весь попередній місяць {1} разом із його кінцем' -f
					$details, $previousMonthStart.ToString('yyyy-MM', $culture))
		}
		$details += '; охоплює весь попередній місяць разом із його кінцем'
	}
	$queryStore = Get-IaRuleQueryStoreInfo -Logical $Logical
	if ($null -eq $queryStore) {
		return New-IaRuleCondition -Id 'AnalysisWindow' -Met $null -Details "${details}; Query Store не зібрано: покриття вікна невідоме"
	}
	$qsFrom = ConvertTo-IaRuleUtcDate $queryStore['firstIntervalStartUtc']
	$tolerance = [math]::Max(60, [int]$queryStore['intervalLengthMinutes'])
	if ($null -eq $qsFrom -or $qsFrom -gt $from.AddMinutes($tolerance)) {
		$qsText = if ($qsFrom) { $qsFrom.ToString('yyyy-MM-dd HH:mm', $culture) } else { 'невідомо' }
		return New-IaRuleCondition -Id 'AnalysisWindow' -Met $false -Details "${details}; Query Store зберігає дані лише з ${qsText}: вікно покрите не повністю"
	}
	return New-IaRuleCondition -Id 'AnalysisWindow' -Met $true -Details "${details}; Query Store покриває вікно"
}

function Get-IaDropEligibility {
	<# Умови розділу 4.4 для рекомендації DropIndex з урахуванням історії (масив IndexVerdict за objectKey, від старих до нових).
	   Повертає DropEligibility (CONTRACTS.md, розділ 5.4). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Recommendation,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[object[]]$History = @(),
		[object[]]$DataPeriods = @(),
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[datetime]$NowUtc = [datetime]::UtcNow
	)
	$now = ConvertTo-IaRuleUtcDate $NowUtc
	$culture = [cultureinfo]::InvariantCulture
	$target = $Recommendation['target']
	$schema = [string]$target['schema']
	$tableName = [string]$target['table']
	$indexName = [string]$target['index']
	$logical = Find-IaRuleLogicalDatabase -Snapshot $Snapshot -Server ([string]$target['server']) -Database ([string]$target['database'])
	$primaryIndex = $null
	if ($logical) {
		$primaryIndex = Find-IaRuleIndex -Table (Find-IaRuleTable -Database $logical.primary.database -Schema $schema -Table $tableName) -Name $indexName
	}

	# Профіль правил: пом'якшений для «дорогих» індексів (структурні умови не пом'якшуються).
	$rulesProfile = 'Standard'
	$relaxedReason = $null
	if ($primaryIndex -and $Config.rules.relaxed.enabled) {
		$aggregate = Get-IaRuleAggregatedIndex -Logical $logical -Schema $schema -Table $tableName -Index $primaryIndex
		$expensive = Test-IaExpensiveIndex -Index $aggregate -Config $Config
		if ($expensive.isExpensive) {
			$rulesProfile = 'Relaxed'
			$relaxedReason = 'Індекс «дорогий»: ' + ($expensive.reasons -join '; ') + '. Знижено кількість аналізів поспіль і мінімальний період; структурні умови не пом''якшуються'
		}
	}
	$aliases = if ($logical) { @(Get-IaRuleServerAliases -Snapshot $Snapshot -Logical $logical) } else { @([string]$target['server']) }
	$standardMinDays = Get-IaRuleMinUptimeDays -Config $Config -ServerNames $aliases -Database ([string]$target['database']) -SchemaTable "$schema.$tableName"
	if ($rulesProfile -eq 'Relaxed') {
		$required = [int]$Config.rules.relaxed.requiredConsecutive
		$minUptimeDays = [math]::Min([int]$Config.rules.relaxed.minUptimeDays, $standardMinDays)
	}
	else {
		$required = [int]$Config.rules.drop.requiredConsecutive
		$minUptimeDays = $standardMinDays
	}
	$minIntervalDays = [int]$Config.rules.drop.minIntervalDays

	# Період даних поточного аналізу (з урахуванням rebuild індексу).
	$dataPeriod = Find-IaRuleDataPeriod -DataPeriods $DataPeriods -ServerNames $aliases -Database ([string]$target['database'])
	if ($null -eq $dataPeriod -and $logical) {
		$dataPeriod = Find-IaRuleDataPeriod -DataPeriods @(Get-IaDataPeriod -Snapshot $Snapshot -Config $Config) -ServerNames $aliases -Database ([string]$target['database'])
	}
	$periodDays = $null
	$periodFrom = $null
	if ($dataPeriod) {
		$periodDays = [double]$dataPeriod['uptimeDays']
		$periodFrom = ConvertTo-IaRuleUtcDate $dataPeriod['statsFromUtc']
		$periodTo = ConvertTo-IaRuleUtcDate $dataPeriod['statsToUtc']
		$lastRebuild = $null
		if ($logical) {
			foreach ($copy in @(Get-IaRuleIndexReplicas -Logical $logical -Schema $schema -Table $tableName -Index $indexName)) {
				$rebuild = if ($copy.index) { ConvertTo-IaRuleUtcDate $copy.index['lastRebuildUtc'] } else { $null }
				if ($rebuild -and ($null -eq $lastRebuild -or $rebuild -gt $lastRebuild)) { $lastRebuild = $rebuild }
			}
		}
		if ($lastRebuild -and $periodFrom -and $periodTo -and $lastRebuild -gt $periodFrom) {
			$periodFrom = $lastRebuild
			$periodDays = [math]::Round([math]::Max([double]0, ($periodTo - $lastRebuild).TotalDays), 2)
		}
	}
	$periodOk = $null -ne $periodDays -and $periodDays -ge $minUptimeDays

	# Серія з історії: Keep обнуляє; зараховуються лише DropRecommended з countsTowardSeries.
	$entries = @($History | Where-Object {
			$_ -is [System.Collections.IDictionary] -and $null -ne (ConvertTo-IaRuleUtcDate $_['analyzedAtUtc']) -and
			(-not $_['runId'] -or $_['runId'] -ne $Recommendation['runId']) -and (-not $_['module'] -or $_['module'] -eq 'Indexes')
		} | Sort-Object { ConvertTo-IaRuleUtcDate $_['analyzedAtUtc'] })
	$streak = 0
	$lastCounted = $null
	foreach ($entry in $entries) {
		if ($entry['verdict'] -ne 'DropRecommended') {
			$streak = 0
			$lastCounted = $null
		}
		elseif ($entry['countsTowardSeries']) {
			$streak++
			$lastCounted = ConvertTo-IaRuleUtcDate $entry['analyzedAtUtc']
		}
	}
	$intervalDays = if ($lastCounted) { ($now - $lastCounted).TotalDays } else { $null }
	$intervalOk = $null -eq $lastCounted -or $intervalDays -ge $minIntervalDays
	$counts = [bool]($periodOk -and $intervalOk)
	$consecutive = $streak + [int]$counts
	$missing = [math]::Max(0, $required - $consecutive)

	$notCounted = [System.Collections.Generic.List[string]]::new()
	if ($null -eq $periodDays) {
		$notCounted.Add('період даних бази невідомий')
	}
	elseif (-not $periodOk) {
		$notCounted.Add(('період {0} дн. коротший за мінімальний {1} дн.' -f (Format-IaRuleNumber $periodDays), $minUptimeDays))
	}
	if (-not $intervalOk) {
		$notCounted.Add(('з попереднього зарахованого аналізу ({0}) минуло {1} дн., мінімум {2} дн.' -f $lastCounted.ToString('yyyy-MM-dd', $culture), (Format-IaRuleNumber $intervalDays), $minIntervalDays))
	}

	$conditions = [System.Collections.Generic.List[object]]::new()
	$conditions.Add((New-IaRuleCondition -Id 'ConsecutiveSeries' -Met ($consecutive -ge $required) -Details ('Зараховано {0} з {1} аналізів поспіль з рекомендацією видалення (профіль {2})' -f $consecutive, $required, $rulesProfile)))
	$periodText = if ($null -ne $periodDays) { '{0} дн. (з {1})' -f (Format-IaRuleNumber $periodDays), $(if ($periodFrom) { $periodFrom.ToString('yyyy-MM-dd', $culture) } else { '?' }) } else { 'невідомий' }
	$conditions.Add((New-IaRuleCondition -Id 'MinUptimePeriod' -Met $(if ($null -eq $periodDays) { $null } else { [bool]$periodOk }) -Details "Період даних $periodText, мінімум $minUptimeDays дн."))
	$intervalText = if ($lastCounted) { 'З попереднього зарахованого аналізу ({0}) минуло {1} дн., мінімум {2} дн.' -f $lastCounted.ToString('yyyy-MM-dd', $culture), (Format-IaRuleNumber $intervalDays), $minIntervalDays } else { 'Попередніх зарахованих аналізів у серії немає' }
	$conditions.Add((New-IaRuleCondition -Id 'MinInterval' -Met ([bool]$intervalOk) -Details $intervalText))
	if ($logical) {
		$conditions.Add((Get-IaRuleWindowCondition -Snapshot $Snapshot -Logical $logical -Config $Config))
		foreach ($condition in @(Get-IaRuleStructuralConditions -Logical $logical -Schema $schema -Table $tableName -Index $indexName)) {
			$conditions.Add($condition)
		}
		if ($primaryIndex) {
			$conditions.Add((Get-IaRuleQueryStoreCondition -Logical $logical -Schema $schema -Table $tableName -Index $indexName))
			$conditions.Add((Get-IaRuleReplicaCondition -Snapshot $Snapshot -Logical $logical -Schema $schema -Table $tableName -Index $indexName))
		}
		else {
			$conditions.Add((New-IaRuleCondition -Id 'NotUsedInQueryStore' -Met $null -Details 'Індекс не знайдено у snapshot'))
			$conditions.Add((New-IaRuleCondition -Id 'CheckedOnAllReplicas' -Met $null -Details 'Індекс не знайдено у snapshot'))
		}
	}
	else {
		$details = "Базу $($target['server'])/$($target['database']) не знайдено у snapshot"
		foreach ($id in 'AnalysisWindow', 'NotPrimaryKey', 'NotUnique', 'NoForeignKeySupport', 'NotReplicated', 'NoHintReferences', 'NotUsedInQueryStore', 'CheckedOnAllReplicas') {
			$conditions.Add((New-IaRuleCondition -Id $id -Met $null -Details $details))
		}
	}
	$isEligible = @($conditions | Where-Object { $_.met -ne $true }).Count -eq 0

	$warning = $null
	if (-not $isEligible) {
		$warning = 'Ґрунтується на {0} з {1} аналізів; період {2}; бракує {3} {4}' -f $consecutive, $required, $periodText, $missing, (Get-IaRulePluralConfirmations -Count $missing)
		if ($notCounted.Count) {
			$warning += '; поточний аналіз не зараховано: ' + ($notCounted -join '; ')
		}
		$unmet = @($conditions | Where-Object { $_.met -ne $true -and $_.id -ne 'ConsecutiveSeries' } | ForEach-Object { if ($null -eq $_.met) { "$($_.id) (невідомо)" } else { $_.id } })
		if ($unmet.Count) {
			$warning += '; не виконано умови: ' + ($unmet -join ', ')
		}
		if ($rulesProfile -eq 'Relaxed') {
			$warning += '; застосовано пом''якшені правила для «дорогого» індексу'
		}
	}
	return [ordered]@{
		rulesProfile = $rulesProfile
		relaxedReason = $relaxedReason
		requiredConsecutive = $required
		consecutiveCount = $consecutive
		missingConfirmations = $missing
		minIntervalDays = $minIntervalDays
		minUptimeDays = $minUptimeDays
		countsTowardSeries = $counts
		notCountedReason = $(if ($counts) { $null } else { ($notCounted -join '; ') })
		conditions = @($conditions)
		isEligible = [bool]$isEligible
		warning = $warning
	}
}

function New-IaObjectVerdicts {
	<# Вердикти для історії: для кожного objectKey з IncludedObjectKeys — DropRecommended (є DropIndex, що пройшов валідацію)
	   або Keep; countsTowardSeries береться з dropEligibility. Повертає масив IndexVerdict (CONTRACTS.md, розділ 5.7). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$RunId,
		[Parameter(Mandatory)][ValidateSet('Indexes', 'Partitioning')][string]$Module,
		[object[]]$Recommendations = @(),
		[string[]]$IncludedObjectKeys = @(),
		[object[]]$DataPeriods = @(),
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[datetime]$NowUtc = [datetime]::UtcNow
	)
	$analyzedAt = ConvertTo-IaUtcString -Date (ConvertTo-IaRuleUtcDate $NowUtc)
	$verdicts = [System.Collections.Generic.List[object]]::new()
	$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($objectKey in @($IncludedObjectKeys)) {
		if ([string]::IsNullOrWhiteSpace($objectKey) -or -not $seen.Add($objectKey)) {
			continue
		}
		$key = $objectKey.ToLowerInvariant()
		$drop = $null
		if ($Module -eq 'Indexes') {
			$drop = @($Recommendations) | Where-Object {
				$_ -is [System.Collections.IDictionary] -and $_['action'] -eq 'DropIndex' -and $_['target'] -is [System.Collections.IDictionary] -and
				([string]$_['target']['objectKey']).ToLowerInvariant() -eq $key -and $_['validation'] -is [System.Collections.IDictionary] -and
				$_['validation']['status'] -in @('Passed', 'Warning')
			} | Select-Object -First 1
		}
		# objectKey: server|database|schema.table|index
		$parts = $key.Split('|')
		$period = if ($parts.Count -ge 2) { Find-IaRuleDataPeriod -DataPeriods $DataPeriods -ServerNames @($parts[0]) -Database $parts[1] } else { $null }
		if ($drop) {
			$eligibility = $drop['dropEligibility']
			$periodDays = if ($drop['dataPeriod'] -is [System.Collections.IDictionary]) { [double]$drop['dataPeriod']['uptimeDays'] } elseif ($period) { [double]$period['uptimeDays'] } else { 0 }
			$verdicts.Add([ordered]@{
					runId = $RunId
					objectKey = $key
					module = $Module
					analyzedAtUtc = $analyzedAt
					verdict = 'DropRecommended'
					countsTowardSeries = [bool]($eligibility -is [System.Collections.IDictionary] -and $eligibility['countsTowardSeries'])
					periodDays = $periodDays
					rulesProfile = $(if ($eligibility -is [System.Collections.IDictionary]) { [string]$eligibility['rulesProfile'] } else { $null })
				})
		}
		else {
			$verdicts.Add([ordered]@{
					runId = $RunId
					objectKey = $key
					module = $Module
					analyzedAtUtc = $analyzedAt
					verdict = 'Keep'
					countsTowardSeries = [bool]($period -and $period['isSufficient'])
					periodDays = $(if ($period) { [double]$period['uptimeDays'] } else { 0 })
					rulesProfile = $null
				})
		}
	}
	return $verdicts.ToArray()
}
