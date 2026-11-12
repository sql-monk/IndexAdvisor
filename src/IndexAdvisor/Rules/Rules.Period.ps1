# Вікно аналізу й період даних (розділи 4.3, 4.4 ТЗ; CONTRACTS.md, розділи 3.5, 5.3).

function Get-IaAnalysisWindow {
	<# Вікно аналізу: analysisWindow.days або (monthStartRule і перші monthStartDays днів місяця) весь попередній місяць.
	   Повертає @{ fromUtc; toUtc; mode = 'Days'|'PreviousMonth'; reason }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[datetime]$NowUtc = [datetime]::UtcNow
	)
	$now = ConvertTo-IaRuleUtcDate $NowUtc
	$days = [int]$Config.analysisWindow.days
	$from = $now.AddDays(-$days)
	$monthStartDays = [int]$Config.analysisWindow.monthStartDays
	if ($Config.analysisWindow.monthStartRule -and $now.Day -le $monthStartDays) {
		# Початок місяця: вікно охоплює весь попередній місяць разом з його кінцем (і перші дні поточного),
		# а якщо analysisWindow.days довше — то й більше.
		$monthStart = [datetime]::new($now.Year, $now.Month, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
		$previousMonthStart = $monthStart.AddMonths(-1)
		$windowFrom = if ($from -lt $previousMonthStart) { $from } else { $previousMonthStart }
		$reason = 'Початок місяця (день {0} з перших analysisWindow.monthStartDays = {1}): вікно охоплює весь попередній місяць {2} разом із його кінцем' -f
			$now.Day, $monthStartDays, $previousMonthStart.ToString('yyyy-MM', [cultureinfo]::InvariantCulture)
		return [ordered]@{
			fromUtc = ConvertTo-IaUtcString -Date $windowFrom
			toUtc = ConvertTo-IaUtcString -Date $now
			mode = 'PreviousMonth'
			reason = $reason
		}
	}
	return [ordered]@{
		fromUtc = ConvertTo-IaUtcString -Date $from
		toUtc = ConvertTo-IaUtcString -Date $now
		mode = 'Days'
		reason = "analysisWindow.days = $days"
	}
}

function New-IaRuleDataPeriod {
	<# Об'єкт DataPeriod (recommendation.schema.json $defs.dataPeriod) з попередженнями. #>
	param(
		[Parameter(Mandatory)][string]$Server,
		[AllowNull()][string]$Database,
		[Parameter(Mandatory)]$Period,
		[AllowNull()]$QueryStore,
		[int]$MinRequiredDays,
		[bool]$CheckQueryStore
	)
	$warnings = [System.Collections.Generic.List[string]]::new()
	$isSufficient = $Period.days -ge $MinRequiredDays
	$fromText = if ($Period.fromUtc) { $Period.fromUtc.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) } else { '?' }
	$scope = if ($Database) { "бази $Server/$Database" } else { "інстансу $Server" }
	if (-not $isSufficient) {
		$warnings.Add(('Період даних {0} {1} дн. (з {2}) коротший за мінімальний {3} дн.: аналіз не зараховується до серії рекомендацій на видалення' -f
				$scope, (Format-IaRuleNumber $Period.days), $fromText, $MinRequiredDays))
	}
	$qsFrom = $null
	$qsTo = $null
	$qsDays = $null
	if ($QueryStore -is [System.Collections.IDictionary]) {
		$qsFrom = ConvertTo-IaRuleUtcDate $QueryStore['firstIntervalStartUtc']
		$qsTo = ConvertTo-IaRuleUtcDate $QueryStore['lastIntervalEndUtc']
		$qsDays = if ($null -ne $QueryStore['periodDays']) { [double]$QueryStore['periodDays'] } elseif ($qsFrom -and $qsTo) { [math]::Round(($qsTo - $qsFrom).TotalDays, 2) } else { $null }
		$state = [string]$QueryStore['actualState']
		if ($state -in @('OFF', 'ERROR')) {
			$warnings.Add("Query Store бази $Database у стані ${state}: дані про плани недоступні")
		}
		elseif ($state -eq 'READ_ONLY') {
			$warnings.Add("Query Store бази $Database у стані READ_ONLY: нові дані не збираються")
		}
		if ($null -ne $qsDays -and $qsDays -lt $MinRequiredDays) {
			$warnings.Add(('Query Store бази {0} містить дані лише за {1} дн. (менше за мінімальні {2} дн.)' -f $Database, (Format-IaRuleNumber $qsDays), $MinRequiredDays))
		}
		$maxMb = [double]$QueryStore['maxStorageSizeMb']
		if ($maxMb -gt 0 -and [double]$QueryStore['currentStorageSizeMb'] / $maxMb -ge 0.9) {
			$warnings.Add(('Query Store бази {0} заповнено на {1}%: старі дані можуть витіснятися' -f $Database, (Format-IaRuleNumber (100 * [double]$QueryStore['currentStorageSizeMb'] / $maxMb) '0')))
		}
		if ($null -ne $QueryStore['staleQueryThresholdDays'] -and [int]$QueryStore['staleQueryThresholdDays'] -lt $MinRequiredDays) {
			$warnings.Add("Термін зберігання Query Store бази $Database ($($QueryStore['staleQueryThresholdDays']) дн.) менший за мінімальний період ($MinRequiredDays дн.)")
		}
	}
	elseif ($CheckQueryStore) {
		$warnings.Add("Query Store бази $Database не зібрано: невикористання індексів підтверджується лише DMV за період роботи сервера")
	}
	return [ordered]@{
		server = $Server
		database = $(if ($Database) { $Database } else { $null })
		sqlserverStartTimeUtc = ConvertTo-IaUtcString -Date $Period.start
		lastFailoverUtc = ConvertTo-IaUtcString -Date $Period.failover
		lastRebuildUtc = $null
		statsFromUtc = ConvertTo-IaUtcString -Date $Period.fromUtc
		statsToUtc = ConvertTo-IaUtcString -Date $Period.toUtc
		uptimeDays = [double]$Period.days
		queryStoreFromUtc = ConvertTo-IaUtcString -Date $qsFrom
		queryStoreToUtc = ConvertTo-IaUtcString -Date $qsTo
		queryStoreDays = $qsDays
		minRequiredDays = [int]$MinRequiredDays
		isSufficient = [bool]$isSufficient
		warnings = @($warnings)
	}
}

function Get-IaDataPeriod {
	<# Період даних для кожного інстансу (database = $null) і кожної бази: DataPeriod (CONTRACTS.md, розділ 5.3),
	   з урахуванням observationOverrides і попередженням, якщо період коротший за мінімальний. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$periods = [System.Collections.Generic.List[object]]::new()
	foreach ($instance in @($Snapshot['instances'])) {
		if ($instance -isnot [System.Collections.IDictionary]) {
			continue
		}
		$server = [string]$instance['serverName']
		$minDays = Get-IaRuleMinUptimeDays -Config $Config -ServerNames @($server, [string]$instance['connectedTo'], [string]$Snapshot['requestedServer'])
		$period = Get-IaRuleInstancePeriod -Instance $instance
		$periods.Add((New-IaRuleDataPeriod -Server $server -Database $null -Period $period -QueryStore $null -MinRequiredDays $minDays -CheckQueryStore $false))
	}
	foreach ($logical in @(Get-IaRuleLogicalDatabases -Snapshot $Snapshot)) {
		# Для бази в AG — найкоротший період серед зібраних реплік.
		$shortest = $null
		foreach ($replica in $logical.replicas) {
			$period = Get-IaRuleInstancePeriod -Instance $replica.instance
			if ($null -eq $shortest -or $period.days -lt $shortest.days) {
				$shortest = $period
			}
		}
		$aliases = @(Get-IaRuleServerAliases -Snapshot $Snapshot -Logical $logical)
		$minDays = Get-IaRuleMinUptimeDays -Config $Config -ServerNames $aliases -Database $logical.database
		$queryStore = Get-IaRuleQueryStoreInfo -Logical $logical
		$periods.Add((New-IaRuleDataPeriod -Server $logical.server -Database $logical.database -Period $shortest -QueryStore $queryStore -MinRequiredDays $minDays -CheckQueryStore $true))
	}
	return $periods.ToArray()
}

function Find-IaRuleDataPeriod {
	<# DataPeriod бази з масиву (server — ім'я AG або інстансу); $null, якщо не знайдено. #>
	param([object[]]$DataPeriods, [string[]]$ServerNames, [string]$Database)
	foreach ($period in @($DataPeriods)) {
		if ($period -is [System.Collections.IDictionary] -and $period['database'] -eq $Database -and @($ServerNames) -contains [string]$period['server']) {
			return $period
		}
	}
	return $null
}
