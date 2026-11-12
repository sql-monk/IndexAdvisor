# Обслуговування індексів через dbo.usp_AdaptiveIndexDefrag (Microsoft Tiger Toolbox, перевірено з версією 1.7.5).
# План за зібраними даними (snapshot і рекомендації запуску), скрипт виклику процедури, скрипт завдання SQL Server Agent і скрипти відкату.
# Програма нічого не виконує на серверах: скрипти перевіряє й запускає DBA.

$script:IaMntProcedureUrl = 'https://github.com/microsoft/tigertoolbox/tree/master/AdaptiveIndexDefrag'
$script:IaMntProcedureVersion = '1.7.5'
# Біти днів як у msdb.dbo.sysschedules і в exclusionMask AdaptiveIndexDefrag (за @@DATEFIRST = 7).
$script:IaMntDayMasks = [ordered]@{ Sunday = 1; Monday = 2; Tuesday = 4; Wednesday = 8; Thursday = 16; Friday = 32; Saturday = 64 }
$script:IaMntDayNames = @{ Sunday = 'нд'; Monday = 'пн'; Tuesday = 'вт'; Wednesday = 'ср'; Thursday = 'чт'; Friday = 'пт'; Saturday = 'сб' }
$script:IaMntMaxLineLength = 160

function ConvertTo-IaMntLiteral {
	<# Рядковий літерал T-SQL N'...' з подвоєними апострофами. #>
	param([AllowNull()][AllowEmptyString()][string]$Value)
	return "N'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-IaMntNumber {
	<# Число для T-SQL в інваріантній культурі. #>
	param([Parameter(Mandatory)]$Value)
	return ([double]$Value).ToString('0.##', [cultureinfo]::InvariantCulture)
}

function Get-IaMntDayMask {
	<# Сума бітів днів тижня: Sunday = 1 … Saturday = 64. #>
	param([AllowEmptyCollection()][string[]]$Days = @())
	$mask = 0
	foreach ($day in @($Days | Where-Object { $_ } | Select-Object -Unique)) {
		if (-not $script:IaMntDayMasks.Contains($day)) {
			throw "Невідомий день тижня '$day'. Допустимі: $($script:IaMntDayMasks.Keys -join ', ')."
		}
		$mask = $mask -bor $script:IaMntDayMasks[$day]
	}
	return $mask
}

function Format-IaMntDays {
	<# Короткі назви днів у порядку тижня (пн … нд). #>
	param([AllowEmptyCollection()][string[]]$Days = @())
	$order = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
	$selected = @($order | Where-Object { $_ -in $Days })
	if ($selected.Count -eq 7) {
		return 'щодня'
	}
	return (($selected | ForEach-Object { $script:IaMntDayNames[$_] }) -join ', ')
}

function ConvertTo-IaMntStartTime {
	<# 'HH:mm' -> HHMMSS (ціле для @active_start_time у sp_add_jobschedule). #>
	param([AllowNull()][AllowEmptyString()][string]$Value)
	$match = [regex]::Match(([string]$Value).Trim(), '^(?<h>[01]?\d|2[0-3]):(?<m>[0-5]\d)$')
	if (-not $match.Success) {
		throw "maintenance.startTime '$Value' має бути у форматі HH:mm (наприклад, 01:30)."
	}
	return [int]$match.Groups['h'].Value * 10000 + [int]$match.Groups['m'].Value * 100
}

function Get-IaMntMajorVersion {
	<# Основна версія SQL Server з productVersion ('16.0.4135.4' -> 16); невідомо — 0. #>
	param([AllowNull()][AllowEmptyString()][string]$ProductVersion)
	$major = 0
	if ($ProductVersion -and [int]::TryParse((([string]$ProductVersion) -split '\.')[0], [ref]$major)) {
		return $major
	}
	return 0
}

function Split-IaMntCommentText {
	<# Розбиває текст на рядки коментаря T-SQL, щоб рядок з відступом не перевищив 160 символів. #>
	param([AllowNull()][AllowEmptyString()][string]$Text, [string]$Indent = '')
	$limit = $script:IaMntMaxLineLength - $Indent.Length - 4
	$lines = [System.Collections.Generic.List[string]]::new()
	foreach ($paragraph in (([string]$Text) -split "`r?`n")) {
		$current = ''
		foreach ($word in ($paragraph -split ' ')) {
			if ($current.Length -gt 0 -and ($current.Length + 1 + $word.Length) -gt $limit) {
				$lines.Add("$Indent-- $current".TrimEnd())
				$current = $word
			}
			else {
				$current = if ($current.Length -gt 0) { "$current $word" } else { $word }
			}
		}
		$lines.Add("$Indent-- $current".TrimEnd())
	}
	return , @($lines.ToArray())
}

function Get-IaMntDropTargets {
	<# Ключі db|schema|table|index індексів, які запуск рекомендує видалити (не відхилені перевіркою), з назвою рекомендації. #>
	param([AllowEmptyCollection()][object[]]$Recommendations = @())
	$targets = @{}
	foreach ($rec in @($Recommendations | Where-Object { $null -ne $_ })) {
		if ([string]$rec.action -ne 'DropIndex' -or $null -eq $rec.target -or -not $rec.target.index) {
			continue
		}
		if ($rec.validation -and [string]$rec.validation.status -eq 'Failed') {
			continue
		}
		$key = ('{0}|{1}|{2}|{3}' -f $rec.target.database, $rec.target.schema, $rec.target.table, $rec.target.index).ToLowerInvariant()
		$targets[$key] = [string]$rec.title
	}
	return $targets
}

function Select-IaMntDatabaseSources {
	<# Для кожної бази — інстанс, з якого брати фізичну статистику: primary-репліка AG або єдиний інстанс бази. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)
	$sources = [ordered]@{}
	foreach ($instance in @($Snapshot.instances | Where-Object { $null -ne $_ })) {
		foreach ($database in @($instance.databases | Where-Object { $null -ne $_ })) {
			$key = ([string]$database.name).ToLowerInvariant()
			$isPreferred = (-not $database.availabilityGroup) -or [string]$database.replicaRole -eq 'PRIMARY'
			if (-not $sources.Contains($key) -or ($isPreferred -and -not $sources[$key].isPreferred)) {
				$sources[$key] = @{ instance = $instance; database = $database; isPreferred = $isPreferred }
			}
		}
	}
	return , @($sources.Values)
}

function Get-IaMaintenancePlan {
	<# План обслуговування індексів для usp_AdaptiveIndexDefrag за snapshot: кандидати на REORGANIZE і REBUILD за фізичною статистикою;
	   винятки (індекси, рекомендовані до видалення, — exclusionMask = -1, тобто ніколи); обмеження великих індексів днями largeIndexDays
	   (у інші дні — @maxPageCount); параметри процедури для кожної бази (ONLINE і RESUMABLE за редакцією й версією, порядок за range scans)
	   і застереження. Нічого не виконує на сервері. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[AllowEmptyCollection()][object[]]$Recommendations = @(),
		[AllowNull()][AllowEmptyString()][string]$RunId
	)
	$mnt = $Config.maintenance
	$fragmentation = $Config.rules.fragmentation
	$warnings = [System.Collections.Generic.List[string]]::new()
	$startTime = ConvertTo-IaMntStartTime -Value ([string]$mnt.startTime)
	$scheduleDays = @($mnt.scheduleDays | Where-Object { $_ } | ForEach-Object { [string]$_ })
	if ($scheduleDays.Count -eq 0) {
		throw 'maintenance.scheduleDays порожній: завдання SQL Agent ніколи не запуститься.'
	}
	$scheduleMask = Get-IaMntDayMask -Days $scheduleDays
	$largeIndexMb = [double]$mnt.largeIndexMb
	$largeDays = @($mnt.largeIndexDays | Where-Object { $_ } | ForEach-Object { [string]$_ })
	$largeDayMask = Get-IaMntDayMask -Days $largeDays
	# Великі індекси обмежуються, лише якщо їм відведено не всі дні розкладу.
	$limitLarge = $largeIndexMb -gt 0 -and $largeDays.Count -gt 0 -and ($scheduleMask -band (-bnot $largeDayMask) -band 127) -ne 0
	$largeMaxPageCount = if ($limitLarge) { [int][math]::Min([double][int]::MaxValue, [math]::Floor($largeIndexMb * 128)) } else { $null }
	if ($largeIndexMb -gt 0 -and $largeDays.Count -gt 0 -and ($scheduleMask -band $largeDayMask) -eq 0) {
		$warnings.Add("Дні для великих індексів ($(Format-IaMntDays $largeDays)) не збігаються з розкладом завдання ($(Format-IaMntDays $scheduleDays)): індекси, більші за $(ConvertTo-IaMntNumber $largeIndexMb) МБ, завдання не обслуговуватиме.")
	}
	$dropTargets = if ($mnt.excludeDropCandidates) { Get-IaMntDropTargets -Recommendations $Recommendations } else { @{} }
	$minPages = [long]$fragmentation.minPageCount
	$reorganizePercent = [double]$fragmentation.reorganizePercent
	$rebuildPercent = [double]$fragmentation.rebuildPercent

	$databases = [System.Collections.Generic.List[object]]::new()
	foreach ($source in (Select-IaMntDatabaseSources -Snapshot $Snapshot)) {
		$instance = $source.instance
		$database = $source.database
		if ([string]$database.stateDesc -ne 'ONLINE' -or $database.isReadOnly) {
			continue
		}
		$major = Get-IaMntMajorVersion -ProductVersion ([string]$instance.productVersion)
		$online = [bool]$instance.supportsOnlineIndexOps
		$resumable = $online -and $major -ge 14 -and [bool]$mnt.resumableRebuild
		$usageCollected = 'usageStats' -in @($database.collectedDatasets)
		$candidates = [System.Collections.Generic.List[object]]::new()
		$exclusions = [System.Collections.Generic.List[object]]::new()
		$notes = [System.Collections.Generic.List[string]]::new()
		$notScanned = 0
		$columnstore = 0
		foreach ($table in @($database.tables | Where-Object { $null -ne $_ })) {
			foreach ($index in @($table.indexes | Where-Object { $null -ne $_ })) {
				$typeDesc = [string]$index.typeDesc
				if ($typeDesc -eq 'HEAP' -or -not $index.name -or $index.isDisabled -or $index.isHypothetical) {
					continue
				}
				$key = ('{0}|{1}|{2}|{3}' -f $database.name, $table.schema, $table.name, $index.name).ToLowerInvariant()
				if ($dropTargets.ContainsKey($key)) {
					$exclusions.Add([ordered]@{
							schema = [string]$table.schema
							table = [string]$table.name
							index = [string]$index.name
							objectId = [long]$table.objectId
							indexId = [long]$index.indexId
							exclusionMask = -1
							reason = "Рекомендовано до видалення: $($dropTargets[$key])"
						})
					continue
				}
				if ($typeDesc -like '*COLUMNSTORE*') {
					$columnstore++
					continue
				}
				$physical = $index.physical
				if ($null -eq $physical -or $physical.skipped -or $null -eq $physical.avgFragmentationPercent -or $null -eq $physical.pageCount) {
					$notScanned++
					continue
				}
				$percent = [double]$physical.avgFragmentationPercent
				$pages = [long]$physical.pageCount
				if ($pages -lt $minPages -or $percent -lt $reorganizePercent) {
					continue
				}
				$sizeMb = if ($null -ne $index.usedMb) { [double]$index.usedMb } else { [math]::Round($pages / 128.0, 1) }
				$operation = if ($percent -ge $rebuildPercent) { 'Rebuild' } else { 'Reorganize' }
				$isLarge = $limitLarge -and $pages -gt $largeMaxPageCount
				$advice = $null
				$op = $index.operational
				if ($operation -eq 'Rebuild' -and $op -and [long]$op.leafInsertCount -gt 0 -and ([int]$index.fillFactor -eq 0 -or [int]$index.fillFactor -eq 100)) {
					$ratio = [double]$op.leafPageSplitCount / [double]$op.leafInsertCount
					if ($ratio -ge 0.02) {
						$advice = "Багато виділень сторінок ($($op.leafPageSplitCount) на $($op.leafInsertCount) вставок) при FILLFACTOR 100: розгляньте FILLFACTOR = 90."
					}
				}
				$candidates.Add([ordered]@{
						schema = [string]$table.schema
						table = [string]$table.name
						index = [string]$index.name
						typeDesc = $typeDesc
						fragmentationPercent = [math]::Round($percent, 1)
						pageCount = $pages
						sizeMb = [math]::Round($sizeMb, 1)
						operation = $operation
						isLarge = $isLarge
						isPartitioned = [bool]$table.isPartitioned
						userScans = $(if ($index.usage) { [long]$index.usage.userScans } else { $null })
						advice = $advice
					})
			}
		}
		$ordered = @($candidates | Sort-Object -Property @{ Expression = { $_.operation -eq 'Rebuild' }; Descending = $true }, @{ Expression = { $_.sizeMb }; Descending = $true })
		$rebuild = @($ordered | Where-Object { $_.operation -eq 'Rebuild' })
		$reorganize = @($ordered | Where-Object { $_.operation -eq 'Reorganize' })
		$large = @($ordered | Where-Object { $_.isLarge })
		if ($notScanned -gt 0) {
			$notes.Add("Фрагментацію $notScanned індексів не зібрано (вторинна репліка, ліміт часу physical_stats або вимкнений набір): процедура оцінить їх сама під час запуску.")
		}
		if ($columnstore -gt 0) {
			$notes.Add("Columnstore-індексів: $columnstore. Процедура оцінює їх за часткою видалених рядків (@rebuildThreshold_cs = $(ConvertTo-IaMntNumber $mnt.columnstoreRebuildPercent)%).")
		}
		if ($large.Count -gt 0) {
			$notes.Add("Великих індексів (понад $(ConvertTo-IaMntNumber $largeIndexMb) МБ) серед кандидатів: $($large.Count). Вони обслуговуються лише в дні: $(Format-IaMntDays $largeDays); в інші дні — @maxPageCount = $largeMaxPageCount.")
		}
		if (-not $online -and $rebuild.Count -gt 0) {
			$notes.Add("Редакція $($instance.edition) не підтримує ONLINE: REBUILD блокує таблицю на час перебудови. Плануйте вікно обслуговування.")
		}
		if ($database.availabilityGroup) {
			$notes.Add("База в групі доступності $($database.availabilityGroup): обслуговування виконується лише на primary-репліці; REBUILD генерує великий обсяг журналу для вторинних реплік.")
		}
		if ([string]$database.recoveryModel -eq 'FULL' -and $rebuild.Count -gt 0) {
			$notes.Add('Модель відновлення FULL: REBUILD повністю журналюється — стежте за розміром журналу й частотою резервних копій журналу.')
		}
		$parameters = [ordered]@{
			'@defragOrderColumn' = $(if ($usageCollected) { 'range_scan_count' } else { 'fragmentation' })
			'@defragSortOrder' = 'DESC'
			'@minFragmentation' = $reorganizePercent
			'@rebuildThreshold' = $rebuildPercent
			'@rebuildThreshold_cs' = [double]$mnt.columnstoreRebuildPercent
			'@minPageCount' = $minPages
			'@scanMode' = 'LIMITED'
			'@onlineRebuild' = [int]$online
			'@resumableRebuild' = [int]$resumable
			# SORT_IN_TEMPDB несумісний з RESUMABLE = ON.
			'@sortInTempDB' = [int]([bool]$mnt.sortInTempDb -and -not $resumable)
			'@maxDopRestriction' = $(if ([int]$mnt.maxDop -gt 0) { [int]$mnt.maxDop } else { $null })
			'@updateStats' = [int][bool]$mnt.updateStatistics
			'@updateStatsWhere' = 0
			'@dealMaxPartition' = $null
			'@ignoreDropObj' = 1
		}
		$databases.Add([ordered]@{
				name = [string]$database.name
				server = [string]$instance.serverName
				availabilityGroup = $(if ($database.availabilityGroup) { [string]$database.availabilityGroup } else { $null })
				edition = [string]$instance.edition
				productVersion = [string]$instance.productVersion
				onlineRebuild = $online
				resumableRebuild = $resumable
				parameters = $parameters
				candidates = $ordered
				exclusions = @($exclusions.ToArray())
				summary = [ordered]@{
					candidates = $ordered.Count
					rebuild = $rebuild.Count
					reorganize = $reorganize.Count
					rebuildMb = [math]::Round([double](@($rebuild | ForEach-Object { [double]$_.sizeMb }) | Measure-Object -Sum).Sum, 1)
					reorganizeMb = [math]::Round([double](@($reorganize | ForEach-Object { [double]$_.sizeMb }) | Measure-Object -Sum).Sum, 1)
					large = $large.Count
					notScanned = $notScanned
					columnstore = $columnstore
					excluded = $exclusions.Count
				}
				notes = @($notes.ToArray())
			})
	}
	if ($databases.Count -eq 0) {
		$warnings.Add('У зібраних даних немає жодної доступної для запису бази ONLINE: скрипти обслуговування не містять викликів процедури.')
	}
	return [ordered]@{
		tool = 'AdaptiveIndexDefrag'
		procedureVersion = $script:IaMntProcedureVersion
		procedureUrl = $script:IaMntProcedureUrl
		procedureDatabase = [string]$mnt.procedureDatabase
		requestedServer = [string]$Snapshot.requestedServer
		runId = $(if ($RunId) { $RunId } else { $null })
		generatedAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
		jobName = [string]$mnt.jobName
		jobOwner = [string]$mnt.jobOwner
		scheduleDays = $scheduleDays
		scheduleMask = $scheduleMask
		startTime = [string]$mnt.startTime
		startTimeValue = $startTime
		timeLimitMinutes = [int]$mnt.timeLimitMinutes
		largeIndexMb = $largeIndexMb
		largeIndexDays = $largeDays
		largeIndexDayMask = $largeDayMask
		largeIndexMaxPageCount = $largeMaxPageCount
		purgeLogs = [bool]$mnt.purgeLogs
		databases = @($databases.ToArray())
		warnings = @($warnings.ToArray())
	}
}

function ConvertTo-IaMntParameterValue {
	<# Значення параметра процедури: NULL, число, рядок N'...' або змінна @name. #>
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return 'NULL'
	}
	if ($Value -is [string]) {
		if ($Value.StartsWith('@')) {
			return $Value
		}
		return ConvertTo-IaMntLiteral $Value
	}
	if ($Value -is [bool]) {
		return [string][int]$Value
	}
	return ConvertTo-IaMntNumber $Value
}

function New-IaMntHeaderLines {
	<# Заголовок-коментар файлу обслуговування. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan, [Parameter(Mandatory)][string]$Title, [string[]]$Extra = @())
	$lines = [System.Collections.Generic.List[string]]::new()
	$lines.Add('-- ' + ('=' * 100))
	foreach ($text in @(
			"IndexAdvisor. $Title"
			"Сервер: $($Plan.requestedServer); runId: $(if ($Plan.runId) { $Plan.runId } else { '—' }); згенеровано: $($Plan.generatedAtUtc) UTC."
			"Процедура: dbo.usp_AdaptiveIndexDefrag (Microsoft Tiger Toolbox, перевірено з версією $($Plan.procedureVersion)) у базі [$($Plan.procedureDatabase)]; встановлення: $($Plan.procedureUrl)"
		) + @($Extra) + @('Програма нічого не виконує автоматично: скрипт перевіряє й виконує DBA вручну.')) {
		foreach ($line in (Split-IaMntCommentText -Text $text)) {
			$lines.Add($line)
		}
	}
	$lines.Add('-- ' + ('=' * 100))
	return , @($lines.ToArray())
}

function New-IaMntRunBodyLines {
	<# Тіло запуску процедури для кожної бази (спільне для ручного скрипту й кроку завдання): спільний дедлайн за maintenance.timeLimitMinutes,
	   обмеження великих індексів днями тижня, лише primary-репліка для баз AG. Mode = Script — @execPrint задає DBA (0 — лише друк команд). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan, [Parameter(Mandatory)][ValidateSet('Script', 'Job')][string]$Mode)
	$lines = [System.Collections.Generic.List[string]]::new()
	if ($Mode -eq 'Script') {
		$lines.Add('-- 0 — лише надрукувати команди процедури (попередній перегляд); 1 — виконати обслуговування.')
		$lines.Add('DECLARE @execPrint BIT = 0;')
		$lines.Add('DECLARE @printCmds BIT = CASE WHEN @execPrint = 1 THEN 0 ELSE 1 END;')
	}
	else {
		$lines.Add('DECLARE @execPrint BIT = 1;')
		$lines.Add('DECLARE @printCmds BIT = 0;')
	}
	$lines.Add("DECLARE @deadline DATETIME2(0) = DATEADD(MINUTE, $($Plan.timeLimitMinutes), SYSDATETIME());")
	$lines.Add('DECLARE @minutesLeft INT;')
	$limitLarge = $null -ne $Plan.largeIndexMaxPageCount
	if ($limitLarge) {
		foreach ($line in (Split-IaMntCommentText -Text "Індекси, більші за $(ConvertTo-IaMntNumber $Plan.largeIndexMb) МБ ($($Plan.largeIndexMaxPageCount) сторінок), обслуговуються лише в дні: $(Format-IaMntDays $Plan.largeIndexDays). Біт дня не залежить від @@DATEFIRST.")) {
			$lines.Add($line)
		}
		$lines.Add('DECLARE @dayBit INT = POWER(2, ((DATEPART(WEEKDAY, SYSDATETIME()) + @@DATEFIRST) % 7 + 6) % 7);')
		$lines.Add("DECLARE @maxPageCount INT = CASE WHEN @dayBit & $($Plan.largeIndexDayMask) <> 0 THEN NULL ELSE $($Plan.largeIndexMaxPageCount) END;")
	}
	foreach ($database in @($Plan.databases)) {
		$lines.Add('')
		$summary = $database.summary
		$header = "База $($database.name)$(if ($database.availabilityGroup) { " (AG $($database.availabilityGroup), лише primary-репліка)" }): кандидатів за зібраними даними $($summary.candidates) " +
			"(REBUILD $($summary.rebuild) — $(ConvertTo-IaMntNumber $summary.rebuildMb) МБ; REORGANIZE $($summary.reorganize) — $(ConvertTo-IaMntNumber $summary.reorganizeMb) МБ); винятків $($summary.excluded)."
		foreach ($line in (Split-IaMntCommentText -Text $header)) {
			$lines.Add($line)
		}
		$guard = if ($database.availabilityGroup) {
			"sys.fn_hadr_is_primary_replica($(ConvertTo-IaMntLiteral $database.name)) = 1"
		}
		else {
			"DB_ID($(ConvertTo-IaMntLiteral $database.name)) IS NOT NULL"
		}
		$lines.Add('SET @minutesLeft = DATEDIFF(MINUTE, SYSDATETIME(), @deadline);')
		$lines.Add("IF @minutesLeft > 0 AND $guard")
		$lines.Add('BEGIN')
		$lines.Add("`tEXEC dbo.usp_AdaptiveIndexDefrag")
		$arguments = [System.Collections.Generic.List[string]]::new()
		$arguments.Add('@Exec_Print = @execPrint')
		$arguments.Add('@printCmds = @printCmds')
		$arguments.Add('@timeLimit = @minutesLeft')
		$arguments.Add("@dbScope = $(ConvertTo-IaMntLiteral $database.name)")
		foreach ($name in $database.parameters.Keys) {
			$arguments.Add("$name = $(ConvertTo-IaMntParameterValue $database.parameters[$name])")
		}
		if ($limitLarge) {
			$arguments.Add('@maxPageCount = @maxPageCount')
		}
		for ($i = 0; $i -lt $arguments.Count; $i++) {
			$lines.Add("`t`t$($arguments[$i])$(if ($i -lt $arguments.Count - 1) { ',' } else { ';' })")
		}
		$lines.Add('END;')
	}
	return , @($lines.ToArray())
}

function New-IaMntExclusionValuesLines {
	<# Рядки INSERT INTO @exclusions … VALUES (не більше 900 рядків в одному VALUES). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)
	$rows = @(foreach ($database in @($Plan.databases)) {
			foreach ($exclusion in @($database.exclusions)) {
				@{ database = $database.name; exclusion = $exclusion }
			}
		})
	$lines = [System.Collections.Generic.List[string]]::new()
	for ($offset = 0; $offset -lt $rows.Count; $offset += 900) {
		$chunk = @($rows[$offset..([math]::Min($rows.Count, $offset + 900) - 1)])
		$lines.Add('INSERT INTO @exclusions (dbName, objectId, indexId, objectName, indexName, exclusionMask)')
		$lines.Add('VALUES')
		for ($i = 0; $i -lt $chunk.Count; $i++) {
			$row = $chunk[$i]
			$e = $row.exclusion
			foreach ($line in (Split-IaMntCommentText -Text "$($e.schema).$($e.table).$($e.index): $($e.reason)" -Indent "`t")) {
				$lines.Add($line)
			}
			$values = '{0}, {1}, {2}, {3}, {4}, {5}' -f (ConvertTo-IaMntLiteral $row.database), $e.objectId, $e.indexId, (ConvertTo-IaMntLiteral "$($e.schema).$($e.table)"),
				(ConvertTo-IaMntLiteral $e.index), $e.exclusionMask
			$lines.Add("`t($values)$(if ($i -lt $chunk.Count - 1) { ',' } else { ';' })")
		}
	}
	return , @($lines.ToArray())
}

function New-IaMntExclusionTableLines {
	<# Оголошення табличної змінної @exclusions. #>
	return , @(
		'DECLARE @exclusions TABLE ('
		"`tdbName SYSNAME NOT NULL,"
		"`tobjectId INT NOT NULL,"
		"`tindexId INT NOT NULL,"
		"`tobjectName NVARCHAR(256) NOT NULL,"
		"`tindexName NVARCHAR(256) NOT NULL,"
		"`texclusionMask INT NOT NULL"
		');'
	)
}

function ConvertTo-IaMaintenanceSql {
	<# Ручний скрипт обслуговування: перевірка наявності процедури, винятки в dbo.tbl_AdaptiveIndexDefrag_Exceptions (за object_id та index_id
	   зі зібраних даних і DB_ID поточного інстансу — працює й на вторинній репліці) і запуск процедури для кожної бази (@execPrint = 0 — лише друк). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)
	$hasExclusions = @($Plan.databases | ForEach-Object { @($_.exclusions) } | Where-Object { $_ }).Count -gt 0
	$extra = @(
		'Порядок: 1) встановіть процедуру; 2) виконайте скрипт з @execPrint = 0 і перегляньте надруковані команди; 3) встановіть @execPrint = 1 або створіть завдання index_maintenance_job.sql.'
		'Винятки записуються за object_id та index_id зі зібраних даних: якщо індекси перестворено, згенеруйте скрипт заново. Для AG виконайте розділ винятків на кожній репліці.'
	)
	$lines = [System.Collections.Generic.List[string]]::new()
	foreach ($line in (New-IaMntHeaderLines -Plan $Plan -Title 'Обслуговування індексів (AdaptiveIndexDefrag): винятки й запуск' -Extra $extra)) {
		$lines.Add($line)
	}
	foreach ($warning in @($Plan.warnings)) {
		foreach ($line in (Split-IaMntCommentText -Text "УВАГА: $warning")) {
			$lines.Add($line)
		}
	}
	$lines.Add('')
	$lines.Add("USE $('[' + ([string]$Plan.procedureDatabase).Replace(']', ']]') + ']');")
	$lines.Add('GO')
	$lines.Add('')
	$lines.Add("IF OBJECT_ID(N'dbo.usp_AdaptiveIndexDefrag', N'P') IS NULL OR OBJECT_ID(N'dbo.tbl_AdaptiveIndexDefrag_Exceptions', N'U') IS NULL")
	$lines.Add('BEGIN')
	$message = "Процедуру dbo.usp_AdaptiveIndexDefrag не встановлено в базі $($Plan.procedureDatabase): див. посилання в заголовку скрипту."
	$lines.Add("`tTHROW 50000, $(ConvertTo-IaMntLiteral $message), 1;")
	$lines.Add('END;')
	$lines.Add('')
	if ($hasExclusions) {
		$lines.Add('-- Винятки: індекси, рекомендовані до видалення, не обслуговуються (exclusionMask = -1 — ніколи).')
		foreach ($line in (New-IaMntExclusionTableLines)) { $lines.Add($line) }
		foreach ($line in (New-IaMntExclusionValuesLines -Plan $Plan)) { $lines.Add($line) }
		$lines.Add('')
		$lines.Add('BEGIN TRY')
		$lines.Add("`tBEGIN TRANSACTION;")
		$lines.Add("`tUPDATE e")
		$lines.Add("`tSET e.exclusionMask = x.exclusionMask")
		$lines.Add("`tFROM dbo.tbl_AdaptiveIndexDefrag_Exceptions AS e")
		$lines.Add("`tINNER JOIN @exclusions AS x ON e.dbID = DB_ID(x.dbName) AND e.objectID = x.objectId AND e.indexID = x.indexId;")
		$lines.Add("`tINSERT INTO dbo.tbl_AdaptiveIndexDefrag_Exceptions (dbID, objectID, indexID, dbName, objectName, indexName, exclusionMask)")
		$lines.Add("`tSELECT DB_ID(x.dbName), x.objectId, x.indexId, x.dbName, x.objectName, x.indexName, x.exclusionMask")
		$lines.Add("`tFROM @exclusions AS x")
		$lines.Add("`tWHERE DB_ID(x.dbName) IS NOT NULL")
		$lines.Add("`t`tAND NOT EXISTS (")
		$lines.Add("`t`t`tSELECT 1")
		$lines.Add("`t`t`tFROM dbo.tbl_AdaptiveIndexDefrag_Exceptions AS e")
		$lines.Add("`t`t`tWHERE e.dbID = DB_ID(x.dbName) AND e.objectID = x.objectId AND e.indexID = x.indexId")
		$lines.Add("`t`t);")
		$lines.Add("`tCOMMIT TRANSACTION;")
		$lines.Add('END TRY')
		$lines.Add('BEGIN CATCH')
		$lines.Add("`tIF @@TRANCOUNT > 0")
		$lines.Add("`t`tROLLBACK TRANSACTION;")
		$lines.Add("`tTHROW;")
		$lines.Add('END CATCH;')
		$lines.Add('')
	}
	# Один батч: THROW вище зупиняє і запуск процедури.
	$lines.Add('-- Запуск процедури для кожної бази в межах спільного ліміту часу.')
	foreach ($line in (New-IaMntRunBodyLines -Plan $Plan -Mode Script)) { $lines.Add($line) }
	$lines.Add('GO')
	return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

function ConvertTo-IaMaintenanceRollbackSql {
	<# Відкат винятків, доданих ConvertTo-IaMaintenanceSql (попередні значення exclusionMask не відновлюються); $null — винятків немає. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)
	if (@($Plan.databases | ForEach-Object { @($_.exclusions) } | Where-Object { $_ }).Count -eq 0) {
		return $null
	}
	$lines = [System.Collections.Generic.List[string]]::new()
	foreach ($line in (New-IaMntHeaderLines -Plan $Plan -Title 'Відкат винятків обслуговування індексів (AdaptiveIndexDefrag)' -Extra @(
				'Видаляє з dbo.tbl_AdaptiveIndexDefrag_Exceptions лише рядки для індексів цього плану; попередні значення exclusionMask не відновлюються.'))) {
		$lines.Add($line)
	}
	$lines.Add('')
	$lines.Add("USE $('[' + ([string]$Plan.procedureDatabase).Replace(']', ']]') + ']');")
	$lines.Add('GO')
	$lines.Add('')
	foreach ($line in (New-IaMntExclusionTableLines)) { $lines.Add($line) }
	foreach ($line in (New-IaMntExclusionValuesLines -Plan $Plan)) { $lines.Add($line) }
	$lines.Add('')
	$lines.Add('DELETE e')
	$lines.Add('FROM dbo.tbl_AdaptiveIndexDefrag_Exceptions AS e')
	$lines.Add('INNER JOIN @exclusions AS x ON e.dbID = DB_ID(x.dbName) AND e.objectID = x.objectId AND e.indexID = x.indexId;')
	$lines.Add('GO')
	return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

function ConvertTo-IaMaintenanceJobSql {
	<# Скрипт завдання SQL Server Agent: крок запуску процедури (лише primary для баз AG), крок очищення журналів процедури,
	   розклад maintenance.scheduleDays о maintenance.startTime. Наявне завдання з такою назвою замінюється лише за @replaceExisting = 1. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)
	$stepLines = [System.Collections.Generic.List[string]]::new()
	$stepLines.Add("-- IndexAdvisor: обслуговування індексів через dbo.usp_AdaptiveIndexDefrag (згенеровано $($Plan.generatedAtUtc) UTC).")
	foreach ($line in (New-IaMntRunBodyLines -Plan $Plan -Mode Job)) {
		$stepLines.Add($line)
	}
	$stepCommand = ($stepLines -join "`r`n")
	$isDaily = $Plan.scheduleMask -eq 127
	$extra = @(
		"Розклад: $(Format-IaMntDays $Plan.scheduleDays) о $($Plan.startTime) (час сервера); ліміт $($Plan.timeLimitMinutes) хв на всі бази."
		'Виконайте на кожній репліці AG: крок сам пропускає бази, для яких репліка не primary. Спершу виконайте index_maintenance.sql (винятки).'
	)
	$lines = [System.Collections.Generic.List[string]]::new()
	foreach ($line in (New-IaMntHeaderLines -Plan $Plan -Title 'Завдання SQL Server Agent для обслуговування індексів (AdaptiveIndexDefrag)' -Extra $extra)) {
		$lines.Add($line)
	}
	$lines.Add('')
	$lines.Add('USE [msdb];')
	$lines.Add('GO')
	$lines.Add('')
	$lines.Add("DECLARE @jobName SYSNAME = $(ConvertTo-IaMntLiteral $Plan.jobName);")
	$lines.Add('-- 1 — видалити наявне завдання з такою назвою (разом з історією) і створити заново; 0 — зупинитися з помилкою.')
	$lines.Add('DECLARE @replaceExisting BIT = 0;')
	$lines.Add("DECLARE @procedureDatabase SYSNAME = $(ConvertTo-IaMntLiteral $Plan.procedureDatabase);")
	$lines.Add('DECLARE @jobId UNIQUEIDENTIFIER;')
	$lines.Add('DECLARE @command NVARCHAR(MAX);')
	$lines.Add('')
	$lines.Add('IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs AS j WHERE j.name = @jobName)')
	$lines.Add('BEGIN')
	$lines.Add("`tIF @replaceExisting = 0")
	$lines.Add("`tBEGIN")
	$lines.Add("`t`tTHROW 50000, N'Завдання з такою назвою вже існує: встановіть @replaceExisting = 1, щоб замінити його.', 1;")
	$lines.Add("`tEND;")
	$lines.Add("`tEXEC msdb.dbo.sp_delete_job @job_name = @jobName, @delete_unused_schedule = 1;")
	$lines.Add('END;')
	$lines.Add('')
	$lines.Add('BEGIN TRY')
	$lines.Add("`tBEGIN TRANSACTION;")
	$lines.Add("`tIF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories AS c WHERE c.name = N'Database Maintenance' AND c.category_class = 1)")
	$lines.Add("`tBEGIN")
	$lines.Add("`t`tEXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'Database Maintenance';")
	$lines.Add("`tEND;")
	$lines.Add("`tEXEC msdb.dbo.sp_add_job")
	$lines.Add("`t`t@job_name = @jobName,")
	$lines.Add("`t`t@enabled = 1,")
	$databaseList = @($Plan.databases | ForEach-Object { $_.name }) -join ', '
	if ($databaseList.Length -gt 80) {
		$databaseList = "$(@($Plan.databases).Count) баз"
	}
	$lines.Add("`t`t@description = $(ConvertTo-IaMntLiteral "IndexAdvisor: dbo.usp_AdaptiveIndexDefrag для $databaseList."),")
	$lines.Add("`t`t@category_name = N'Database Maintenance',")
	if ($Plan.jobOwner) {
		$lines.Add("`t`t@owner_login_name = $(ConvertTo-IaMntLiteral $Plan.jobOwner),")
	}
	$lines.Add("`t`t@job_id = @jobId OUTPUT;")
	$lines.Add('')
	$lines.Add("`tSET @command = $(ConvertTo-IaMntLiteral $stepCommand);")
	$lines.Add("`tEXEC msdb.dbo.sp_add_jobstep")
	$lines.Add("`t`t@job_id = @jobId,")
	$lines.Add("`t`t@step_name = N'AdaptiveIndexDefrag',")
	$lines.Add("`t`t@subsystem = N'TSQL',")
	$lines.Add("`t`t@database_name = @procedureDatabase,")
	$lines.Add("`t`t@command = @command,")
	$lines.Add("`t`t@on_success_action = $(if ($Plan.purgeLogs) { 3 } else { 1 }),")
	$lines.Add("`t`t@on_fail_action = 2;")
	if ($Plan.purgeLogs) {
		$lines.Add('')
		$lines.Add("`t-- Очищення журналів процедури (за замовчуванням старіших за 90 днів).")
		$lines.Add("`tEXEC msdb.dbo.sp_add_jobstep")
		$lines.Add("`t`t@job_id = @jobId,")
		$lines.Add("`t`t@step_name = N'AdaptiveIndexDefrag_PurgeLogs',")
		$lines.Add("`t`t@subsystem = N'TSQL',")
		$lines.Add("`t`t@database_name = @procedureDatabase,")
		$lines.Add("`t`t@command = N'EXEC dbo.usp_AdaptiveIndexDefrag_PurgeLogs;',")
		$lines.Add("`t`t@on_success_action = 1,")
		$lines.Add("`t`t@on_fail_action = 2;")
	}
	$lines.Add('')
	$lines.Add("`tEXEC msdb.dbo.sp_add_jobschedule")
	$lines.Add("`t`t@job_id = @jobId,")
	$lines.Add("`t`t@name = $(ConvertTo-IaMntLiteral "$($Plan.jobName) ($(Format-IaMntDays $Plan.scheduleDays) $($Plan.startTime))"),")
	$lines.Add("`t`t@enabled = 1,")
	if ($isDaily) {
		$lines.Add("`t`t@freq_type = 4,")
		$lines.Add("`t`t@freq_interval = 1,")
	}
	else {
		$lines.Add("`t`t@freq_type = 8,")
		$lines.Add("`t`t@freq_interval = $($Plan.scheduleMask),")
		$lines.Add("`t`t@freq_recurrence_factor = 1,")
	}
	$lines.Add("`t`t@freq_subday_type = 1,")
	$lines.Add("`t`t@active_start_time = $($Plan.startTimeValue);")
	$lines.Add("`tEXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';")
	$lines.Add("`tCOMMIT TRANSACTION;")
	$lines.Add('END TRY')
	$lines.Add('BEGIN CATCH')
	$lines.Add("`tIF @@TRANCOUNT > 0")
	$lines.Add("`t`tROLLBACK TRANSACTION;")
	$lines.Add("`tTHROW;")
	$lines.Add('END CATCH;')
	$lines.Add('GO')
	return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

function ConvertTo-IaMaintenanceJobRollbackSql {
	<# Видалення завдання SQL Agent, створеного ConvertTo-IaMaintenanceJobSql (разом з історією і розкладом). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)
	$lines = [System.Collections.Generic.List[string]]::new()
	foreach ($line in (New-IaMntHeaderLines -Plan $Plan -Title 'Відкат: видалення завдання SQL Server Agent обслуговування індексів')) {
		$lines.Add($line)
	}
	$lines.Add('')
	$lines.Add('USE [msdb];')
	$lines.Add('GO')
	$lines.Add('')
	$lines.Add("DECLARE @jobName SYSNAME = $(ConvertTo-IaMntLiteral $Plan.jobName);")
	$lines.Add('IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs AS j WHERE j.name = @jobName)')
	$lines.Add('BEGIN')
	$lines.Add("`tEXEC msdb.dbo.sp_delete_job @job_name = @jobName, @delete_unused_schedule = 1;")
	$lines.Add('END;')
	$lines.Add('GO')
	return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

function New-IaMaintenanceReportBlocks {
	<# Розділ звіту «Обслуговування індексів»: параметри, кандидати (до 30 найбільших), винятки, примітки. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan, [int]$Top = 30)
	$blocks = [System.Collections.Generic.List[object]]::new()
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Обслуговування індексів (AdaptiveIndexDefrag)' })
	$blocks.Add(@{ t = 'alert'; level = 'info'; text = "Скрипти в каталозі maintenance/ викликають dbo.usp_AdaptiveIndexDefrag (Microsoft Tiger Toolbox, перевірено з версією $($Plan.procedureVersion)) у базі [$($Plan.procedureDatabase)]. Процедуру встановлюють окремо: $($Plan.procedureUrl). Процедура сама сканує фрагментацію під час запуску; план нижче — оцінка за зібраними даними." })
	$large = if ($null -ne $Plan.largeIndexMaxPageCount) { "понад $(ConvertTo-IaMntNumber $Plan.largeIndexMb) МБ — лише $(Format-IaMntDays $Plan.largeIndexDays)" } else { 'без обмеження' }
	$blocks.Add(@{ t = 'kv'; rows = @(
				, @('Завдання SQL Agent', [string]$Plan.jobName)
				, @('Розклад', "$(Format-IaMntDays $Plan.scheduleDays) о $($Plan.startTime); ліміт $($Plan.timeLimitMinutes) хв")
				, @('Великі індекси', $large)
				, @('Очищення журналів процедури', $(if ($Plan.purgeLogs) { 'так' } else { 'ні' }))
			)
		})
	foreach ($warning in @($Plan.warnings)) {
		$blocks.Add(@{ t = 'alert'; level = 'warn'; text = [string]$warning })
	}
	foreach ($database in @($Plan.databases)) {
		$summary = $database.summary
		$blocks.Add(@{ t = 'h'; level = 3; text = "База $($database.name) ($($database.server))" })
		$parameters = @($database.parameters.Keys | ForEach-Object { "$_ = $(ConvertTo-IaMntParameterValue $database.parameters[$_])" }) -join ', '
		$blocks.Add(@{ t = 'kv'; rows = @(
					, @('Кандидатів', "$($summary.candidates): REBUILD $($summary.rebuild) ($(ConvertTo-IaMntNumber $summary.rebuildMb) МБ), REORGANIZE $($summary.reorganize) ($(ConvertTo-IaMntNumber $summary.reorganizeMb) МБ)")
					, @('Великих серед кандидатів', [string]$summary.large)
					, @('Без зібраної фрагментації', [string]$summary.notScanned)
					, @('Columnstore', [string]$summary.columnstore)
					, @('Винятків', [string]$summary.excluded)
					, @('ONLINE / RESUMABLE', "$(if ($database.onlineRebuild) { 'так' } else { 'ні' }) / $(if ($database.resumableRebuild) { 'так' } else { 'ні' }) ($($database.edition), $($database.productVersion))")
					, @('Параметри процедури', $parameters)
				)
			})
		if (@($database.candidates).Count -gt 0) {
			$shown = @($database.candidates | Select-Object -First $Top)
			$blocks.Add(@{ t = 'table'; headers = @('Таблиця', 'Індекс', 'Фрагментація, %', 'Сторінок', 'МБ', 'Операція', 'Великий', 'Порада'); rows = @(foreach ($c in $shown) {
							, @("$($c.schema).$($c.table)", [string]$c.index, (ConvertTo-IaMntNumber $c.fragmentationPercent), [string]$c.pageCount, (ConvertTo-IaMntNumber $c.sizeMb),
								$(if ($c.operation -eq 'Rebuild') { 'REBUILD' } else { 'REORGANIZE' }), $(if ($c.isLarge) { 'так' } else { '' }), [string]$c.advice)
						})
				})
			if (@($database.candidates).Count -gt $Top) {
				$blocks.Add(@{ t = 'p'; text = "Показано $Top найбільших з $(@($database.candidates).Count) кандидатів." })
			}
		}
		if (@($database.exclusions).Count -gt 0) {
			$blocks.Add(@{ t = 'table'; headers = @('Таблиця', 'Індекс', 'exclusionMask', 'Причина'); rows = @(foreach ($e in @($database.exclusions)) {
							, @("$($e.schema).$($e.table)", [string]$e.index, [string]$e.exclusionMask, [string]$e.reason)
						})
				})
		}
		if (@($database.notes).Count -gt 0) {
			$blocks.Add(@{ t = 'ul'; items = @($database.notes) })
		}
	}
	return , @($blocks.ToArray())
}

function Export-IaMaintenanceFiles {
	<# Записує скрипти плану в <Directory>/maintenance: index_maintenance.sql (+ _rollback, якщо є винятки), index_maintenance_job.sql (+ _rollback).
	   Повертає шляхи файлів. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan, [Parameter(Mandatory)][string]$Directory)
	$folder = Join-Path $Directory 'maintenance'
	New-Item -ItemType Directory -Path $folder -Force | Out-Null
	$files = [System.Collections.Generic.List[string]]::new()
	$files.Add((Write-IaOutFile -Path (Join-Path $folder 'index_maintenance.sql') -Text (ConvertTo-IaMaintenanceSql -Plan $Plan)))
	$rollback = ConvertTo-IaMaintenanceRollbackSql -Plan $Plan
	if ($rollback) {
		$files.Add((Write-IaOutFile -Path (Join-Path $folder 'index_maintenance_rollback.sql') -Text $rollback))
	}
	$files.Add((Write-IaOutFile -Path (Join-Path $folder 'index_maintenance_job.sql') -Text (ConvertTo-IaMaintenanceJobSql -Plan $Plan)))
	$files.Add((Write-IaOutFile -Path (Join-Path $folder 'index_maintenance_job_rollback.sql') -Text (ConvertTo-IaMaintenanceJobRollbackSql -Plan $Plan)))
	return , @($files.ToArray())
}

function New-IaIndexMaintenance {
	<# Скрипти обслуговування індексів (AdaptiveIndexDefrag) з архіву зібраних даних без нового збору й без LLM.
	   -ResultPath — result.json попереднього запуску: індекси, рекомендовані ним до видалення, стають винятками.
	   Результат: каталог <output.path>/<час>_<сервер>_maintenance з maintenance/*.sql і maintenance_plan.md. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$FromArchive,
		[string]$Config,
		[string]$ResultPath,
		[string]$OutputPath,
		[switch]$PassThru
	)
	$overrides = [ordered]@{}
	if ($OutputPath) {
		$overrides.output = [ordered]@{ path = $OutputPath }
	}
	$cfg = Get-IaConfig -Path $Config -Overrides $overrides
	$archive = Read-IaSnapshotArchive -Path $FromArchive
	$snapshot = $archive.snapshot
	if ($archive.maskingMap) {
		$snapshot = ConvertFrom-IaMaskedObject -InputObject $snapshot -Map $archive.maskingMap
	}
	elseif ($archive.manifest -and $archive.manifest.namesMasked) {
		Write-Warning 'Мапи маскування поруч з архівом немає: скрипти міститимуть масковані імена баз і об''єктів.'
	}
	$recommendations = @()
	$runId = $null
	if ($ResultPath) {
		$result = Get-Content -LiteralPath $ResultPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
		$recommendations = @($result['recommendations'] | Where-Object { $null -ne $_ })
		$runId = [string]$result['runId']
	}
	$plan = Get-IaMaintenancePlan -Snapshot $snapshot -Config $cfg -Recommendations $recommendations -RunId $runId
	$serverPart = [regex]::Replace([string]$plan.requestedServer, '[^\p{L}\p{Nd}_.-]', '_')
	if ([string]::IsNullOrEmpty($serverPart)) {
		$serverPart = 'server'
	}
	$root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$cfg.output.path)
	$directory = Join-Path $root ('{0}_{1}_maintenance' -f [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss', [cultureinfo]::InvariantCulture), $serverPart)
	New-Item -ItemType Directory -Path $directory -Force | Out-Null
	$files = [System.Collections.Generic.List[string]]::new()
	foreach ($file in (Export-IaMaintenanceFiles -Plan $plan -Directory $directory)) {
		$files.Add($file)
	}
	$blocks = [System.Collections.Generic.List[object]]::new()
	$blocks.Add(@{ t = 'h'; level = 1; text = "План обслуговування індексів: $($plan.requestedServer)" })
	foreach ($block in (New-IaMaintenanceReportBlocks -Plan $plan)) {
		$blocks.Add($block)
	}
	$files.Add((Write-IaOutFile -Path (Join-Path $directory 'maintenance_plan.md') -Text (ConvertTo-IaOutMarkdown -Blocks $blocks.ToArray())))
	Write-Host "IndexAdvisor: скрипти обслуговування індексів — $directory"
	foreach ($database in @($plan.databases)) {
		Write-Host "  $($database.name): кандидатів $($database.summary.candidates) (REBUILD $($database.summary.rebuild), REORGANIZE $($database.summary.reorganize)); винятків $($database.summary.excluded)"
	}
	foreach ($warning in @($plan.warnings)) {
		Write-Warning $warning
	}
	if ($PassThru) {
		return [ordered]@{ directory = $directory; files = @($files.ToArray()); plan = $plan }
	}
}
