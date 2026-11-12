# Звіти IndexAdvisor (CONTRACTS.md, розділ 9): recommendations.md, SQL-скрипти виконання й відкату, report.html, result.json, підсумок у консоль.
# Зміст MD і HTML будується з однієї моделі блоків, тож обидва звіти показують те саме. Усі дані в HTML екрануються.

$script:IaOutActionOrder = @('CreateIndex', 'AlterIndex', 'DropIndex', 'PartitionTable', 'AlterPartitioning')
$script:IaOutConditionNames = [ordered]@{
	ConsecutiveSeries = 'Рекомендація видалення в N аналізах поспіль'
	MinUptimePeriod = 'Мінімальний період роботи сервера'
	MinInterval = 'Мінімальний інтервал між аналізами серії'
	AnalysisWindow = 'Вікно аналізу (на початку місяця — весь попередній місяць)'
	NotPrimaryKey = 'Індекс не є PK'
	NotUnique = 'Індекс не є UNIQUE'
	NoForeignKeySupport = 'Індекс не підтримує FK'
	NotReplicated = 'Індекс не використовується реплікацією'
	NoHintReferences = 'Індекс не згадується в хінтах (sys.sql_modules, Query Store)'
	NotUsedInQueryStore = 'Індекс не використовує жоден план Query Store'
	CheckedOnAllReplicas = 'Перевірено на всіх репліках AG'
}
$script:IaOutCheckNames = [ordered]@{
	ObjectsExist = "Об'єкти існують"
	NotDuplicate = 'Не дублює й не перекриває наявний індекс'
	DropAllowed = 'Видалення дозволене (PK, UNIQUE, FK, реплікація, хінти)'
	SyntaxValid = 'Синтаксис T-SQL коректний'
	RollbackMatches = 'Скрипт відкату відповідає скрипту виконання'
	PlatformLimits = 'Ліміти платформи (ключ, кількість колонок)'
	EditionFeatures = 'Можливості редакції (ONLINE, RESUMABLE)'
	PartitionAlignment = 'Секціонування й вирівнювання'
	SafeScript = 'Скрипт не містить небезпечних інструкцій'
}

function Format-IaOutNumber {
	<# Число в інваріантній культурі (до Decimals знаків після коми). #>
	param([AllowNull()]$Value, [int]$Decimals = 2)
	if ($null -eq $Value -or ($Value -is [string] -and $Value -eq '')) {
		return '—'
	}
	return ([math]::Round([double]$Value, $Decimals)).ToString([cultureinfo]::InvariantCulture)
}

function Format-IaOutText {
	<# Порожнє значення -> '—'. #>
	param([AllowNull()]$Value)
	if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
		return '—'
	}
	return [string]$Value
}

function Format-IaOutBool {
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return 'невідомо'
	}
	return $(if ($Value) { 'так' } else { 'ні' })
}

function Get-IaOutConditionStatus {
	<# Стан умови 4.4: виконано / не виконано / невідомо. #>
	param([AllowNull()]$Met)
	if ($null -eq $Met) {
		return 'невідомо'
	}
	return $(if ($Met) { 'виконано' } else { 'не виконано' })
}

function Get-IaOutObjectName {
	<# schema.table[.index] цілі. #>
	param([AllowNull()][System.Collections.IDictionary]$Target)
	if ($null -eq $Target) {
		return '—'
	}
	$name = "$($Target.schema).$($Target.table)"
	if ($Target.index) {
		$name += ".$($Target.index)"
	}
	return $name
}

function Get-IaOutReportItems {
	<# Впорядковані рекомендації з номерами: прийняті (Passed -> Warning -> інші; за дією), потім відхилені перевіркою (Failed). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$RunResult)
	$statusRank = @{ Passed = 0; Warning = 1; NotValidated = 2 }
	$all = @($RunResult.recommendations | Where-Object { $null -ne $_ })
	$accepted = @($all | Where-Object { -not ($_.validation -and $_.validation.status -eq 'Failed') } | Sort-Object -Stable -Property @(
			@{ Expression = { $status = if ($_.validation) { [string]$_.validation.status } else { 'NotValidated' }; if ($statusRank.ContainsKey($status)) { $statusRank[$status] } else { 3 } } }
			@{ Expression = { $index = [array]::IndexOf($script:IaOutActionOrder, [string]$_.action); if ($index -lt 0) { 99 } else { $index } } }
		))
	$rejected = @($all | Where-Object { $_.validation -and $_.validation.status -eq 'Failed' } | Sort-Object -Stable -Property @(
			@{ Expression = { $index = [array]::IndexOf($script:IaOutActionOrder, [string]$_.action); if ($index -lt 0) { 99 } else { $index } } }
		))
	$number = 0
	$items = foreach ($rec in @($accepted) + @($rejected)) {
		$number++
		$isRejected = [bool]($rec.validation -and $rec.validation.status -eq 'Failed')
		$parts = @(('{0:000}' -f $number), [string]$rec.action, [string]$rec.target.table)
		if ($rec.target.index) {
			$parts += [string]$rec.target.index
		}
		$fileBase = (($parts | ForEach-Object { [regex]::Replace($_, '[^\p{L}\p{Nd}_.-]', '_') }) -join '_')
		if ($fileBase.Length -gt 120) {
			$fileBase = $fileBase.Substring(0, 120)
		}
		[ordered]@{
			number = ('{0:000}' -f $number)
			recommendation = $rec
			rejected = $isRejected
			fileBase = $fileBase
			commentedExecute = ($rec.action -eq 'DropIndex' -and -not ($rec.dropEligibility -and $rec.dropEligibility.isEligible -eq $true))
		}
	}
	return , @($items)
}

function Get-IaOutDropSummary {
	<# «На скількох аналізах ґрунтується і скільки підтверджень бракує». #>
	param([AllowNull()][System.Collections.IDictionary]$Eligibility)
	if ($null -eq $Eligibility) {
		return 'Умови безпечного видалення (розділ 4.4) не перевірено: видалення не рекомендоване до виконання.'
	}
	$text = "Ґрунтується на $($Eligibility.consecutiveCount) з $($Eligibility.requiredConsecutive) потрібних аналізів поспіль; бракує підтверджень: $($Eligibility.missingConfirmations)."
	if ($Eligibility.countsTowardSeries -eq $false) {
		$text += " Поточний аналіз не зараховано до серії: $(Format-IaOutText $Eligibility.notCountedReason)."
	}
	$text += $(if ($Eligibility.isEligible) { ' Усі умови виконано.' } else { ' Умови виконано не всі: видалення поки не рекомендоване до виконання.' })
	return $text
}

function Get-IaOutRulesProfileText {
	param([AllowNull()][System.Collections.IDictionary]$Eligibility)
	if ($null -eq $Eligibility) {
		return '—'
	}
	if ($Eligibility.rulesProfile -eq 'Relaxed') {
		return "пом'якшений (причина: $(Format-IaOutText $Eligibility.relaxedReason)); мінімум аналізів $($Eligibility.requiredConsecutive), мінімальний період $($Eligibility.minUptimeDays) дн."
	}
	return "стандартний; мінімум аналізів $($Eligibility.requiredConsecutive), мінімальний період $($Eligibility.minUptimeDays) дн., інтервал $($Eligibility.minIntervalDays) дн."
}

function Get-IaOutPeriodText {
	<# Однорядковий опис періоду даних. #>
	param([AllowNull()][System.Collections.IDictionary]$Period)
	if ($null -eq $Period) {
		return 'Період даних не визначено.'
	}
	$text = "Статистика з $(Format-IaOutText $Period.statsFromUtc) по $(Format-IaOutText $Period.statsToUtc) ($(Format-IaOutNumber $Period.uptimeDays 1) дн.; мінімум $($Period.minRequiredDays) дн.)"
	$text += "; запуск інстансу $(Format-IaOutText $Period.sqlserverStartTimeUtc); failover $(Format-IaOutText $Period.lastFailoverUtc)"
	if ($Period.Contains('lastRebuildUtc')) {
		$text += "; rebuild $(Format-IaOutText $Period.lastRebuildUtc)"
	}
	$text += "; Query Store з $(Format-IaOutText $Period.queryStoreFromUtc) по $(Format-IaOutText $Period.queryStoreToUtc) ($(Format-IaOutNumber $Period.queryStoreDays 1) дн.)"
	$text += $(if ($Period.isSufficient) { '. Період достатній.' } else { '. УВАГА: період коротший за мінімальний, аналіз не зараховується до серії рекомендацій на видалення.' })
	return $text
}

function Get-IaOutTopologyText {
	param([AllowNull()][System.Collections.IDictionary]$Topology)
	if ($null -eq $Topology) {
		return '—'
	}
	$text = Format-IaOutText $Topology.type
	foreach ($group in @($Topology.availabilityGroups | Where-Object { $_ })) {
		$replicas = @($group.replicas | Where-Object { $_ } | ForEach-Object {
				$state = if ($_.collected -eq $false) { "не зібрано: $($_.skipReason)" } else { 'зібрано' }
				"$($_.replicaServerName) $($_.role), $state"
			})
		$text += "; $($group.name) (listener $(Format-IaOutText $group.listenerName)): $($replicas -join '; ')"
	}
	return $text
}

function New-IaOutRecommendationBlocks {
	<# Блоки опису однієї рекомендації (розділ 9). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Item)
	$rec = $Item.recommendation
	$blocks = [System.Collections.Generic.List[object]]::new()
	$blocks.Add(@{ t = 'h'; level = 3; text = "$($Item.number). $($rec.action) $(Get-IaOutObjectName $rec.target)" })
	$validationStatus = if ($rec.validation) { [string]$rec.validation.status } else { 'NotValidated' }
	$blocks.Add(@{ t = 'kv'; rows = @(
				, @('Назва', (Format-IaOutText $rec.title))
				, @('Сервер / база', "$($rec.target.server) / $($rec.target.database)")
				, @('Модуль / джерело', "$($rec.module) / $($rec.source)")
				, @('Ризик', "$($rec.risk.level): $(Format-IaOutText $rec.risk.description)")
				, @('Впевненість моделі', (Format-IaOutText $rec.confidence))
				, @('Перевірка 4.8', $validationStatus)
				, @('Модель', $(if ($rec.llm) { "$($rec.llm.provider) / $($rec.llm.model) (шаблон $($rec.llm.promptTemplateId) v$($rec.llm.promptTemplateVersion))" } else { '—' }))
				, @('objectKey', (Format-IaOutText $rec.target.objectKey))
			)
		})
	$blocks.Add(@{ t = 'h'; level = 4; text = 'Обґрунтування' })
	$blocks.Add(@{ t = 'p'; text = (Format-IaOutText $rec.rationale) })
	$impact = $rec.impact
	if ($impact) {
		$blocks.Add(@{ t = 'h'; level = 4; text = 'Вплив' })
		$queryIds = @($impact.affectedQueryIds | Where-Object { $null -ne $_ })
		$blocks.Add(@{ t = 'ul'; items = @(
					"Оцінка розміру, МБ: $(Format-IaOutNumber $impact.estimatedSizeMb 1)"
					"Оцінка часу побудови, хв: $(Format-IaOutNumber $impact.estimatedBuildMinutes 1)"
					"Записів у таблицю за добу: $(Format-IaOutNumber $impact.tableWritesPerDay 0)"
					"Запити Query Store: $(if ($queryIds.Count) { $queryIds -join ', ' } else { '—' })"
					"Примітки: $(Format-IaOutText $impact.notes)"
				)
			})
	}
	if (@($rec.replacesIndexes).Count -gt 0) {
		$blocks.Add(@{ t = 'p'; text = "Замінює індекси: $(@($rec.replacesIndexes) -join ', ')" })
	}
	$blocks.Add(@{ t = 'h'; level = 4; text = 'Період даних' })
	$periodText = Get-IaOutPeriodText -Period $rec.dataPeriod
	if ($rec.dataPeriod -and -not $rec.dataPeriod.isSufficient) {
		$blocks.Add(@{ t = 'alert'; level = 'warn'; text = $periodText })
	}
	else {
		$blocks.Add(@{ t = 'p'; text = $periodText })
	}
	$blocks.Add(@{ t = 'h'; level = 4; text = 'Перевірка правилами (розділ 4.8)' })
	$checks = @($rec.validation.checks | Where-Object { $_ })
	if ($checks.Count -gt 0) {
		$blocks.Add(@{ t = 'table'; headers = @('Перевірка', 'Результат', 'Пояснення'); rows = @(foreach ($check in $checks) {
						$name = if ($script:IaOutCheckNames.Contains([string]$check.id)) { "$($script:IaOutCheckNames[[string]$check.id]) ($($check.id))" } else { [string]$check.id }
						, @($name, [string]$check.status, (Format-IaOutText $check.message))
					})
			})
	}
	else {
		$blocks.Add(@{ t = 'p'; text = "Статус перевірки: $validationStatus; окремих перевірок немає." })
	}
	if ($rec.action -eq 'DropIndex') {
		$eligibility = $rec.dropEligibility
		$blocks.Add(@{ t = 'h'; level = 4; text = 'Умови безпечного видалення (розділ 4.4)' })
		$summary = Get-IaOutDropSummary -Eligibility $eligibility
		$blocks.Add(@{ t = 'alert'; level = $(if ($eligibility -and $eligibility.isEligible) { 'info' } else { 'warn' }); text = $summary })
		if ($eligibility) {
			$blocks.Add(@{ t = 'p'; text = "Профіль правил: $(Get-IaOutRulesProfileText -Eligibility $eligibility)" })
			$blocks.Add(@{ t = 'table'; headers = @('Умова', 'Стан', 'Деталі'); rows = @(foreach ($condition in @($eligibility.conditions | Where-Object { $_ })) {
							$name = if ($script:IaOutConditionNames.Contains([string]$condition.id)) { "$($script:IaOutConditionNames[[string]$condition.id]) ($($condition.id))" } else { [string]$condition.id }
							, @($name, (Get-IaOutConditionStatus -Met $condition.met), (Format-IaOutText $condition.details))
						})
				})
			if ($eligibility.warning) {
				$blocks.Add(@{ t = 'p'; text = [string]$eligibility.warning })
			}
		}
	}
	$blocks.Add(@{ t = 'h'; level = 4; text = 'Cross-check' })
	if ($rec.crossCheck) {
		$blocks.Add(@{ t = 'p'; text = "$($rec.crossCheck.provider) / $($rec.crossCheck.model): $($rec.crossCheck.verdict). $(Format-IaOutText $rec.crossCheck.notes)" })
	}
	else {
		$blocks.Add(@{ t = 'p'; text = 'Не виконувався.' })
	}
	$warnings = @($rec.warnings | Where-Object { $_ })
	if ($warnings.Count -gt 0) {
		$blocks.Add(@{ t = 'h'; level = 4; text = 'Попередження' })
		$blocks.Add(@{ t = 'ul'; items = @($warnings | ForEach-Object { [string]$_ }); warn = $true })
	}
	$blocks.Add(@{ t = 'h'; level = 4; text = 'Скрипт виконання' })
	if ($Item.rejected) {
		$blocks.Add(@{ t = 'alert'; level = 'danger'; text = 'Рекомендацію відхилено перевіркою: скрипт показано лише для довідки, виконувати його не можна.' })
	}
	elseif ($Item.commentedExecute) {
		$blocks.Add(@{ t = 'alert'; level = 'warn'; text = 'Умови розділу 4.4 не виконано: у SQL-файлі інструкції закоментовано. Скрипт показано повністю лише для довідки.' })
	}
	$blocks.Add(@{ t = 'code'; text = [string]$rec.executeScript })
	$blocks.Add(@{ t = 'h'; level = 4; text = 'Скрипт відкату' })
	$blocks.Add(@{ t = 'code'; text = [string]$rec.rollbackScript })
	return , @($blocks.ToArray())
}

function New-IaOutReportBlocks {
	<# Модель звіту для одного запуску (розділ 9). #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$RunResult,
		[AllowEmptyCollection()][object[]]$Items = @()
	)
	$run = $RunResult
	$blocks = [System.Collections.Generic.List[object]]::new()
	$blocks.Add(@{ t = 'h'; level = 1; text = "Звіт IndexAdvisor: $($run.requestedServer)" })
	$blocks.Add(@{ t = 'alert'; level = 'info'; text = 'Програма не вносить жодних змін у цільові бази. Рекомендації та SQL-скрипти виконує DBA або розробник самостійно після перевірки.' })
	$source = if ($run.fromArchive) { "архів $($run.fromArchive)" } else { 'збір з сервера' }
	$window = if ($run.analysisWindow) { "$(Format-IaOutText $run.analysisWindow.fromUtc) — $(Format-IaOutText $run.analysisWindow.toUtc) ($(Format-IaOutText $run.analysisWindow.mode); $(Format-IaOutText $run.analysisWindow.reason))" } else { '—' }
	$blocks.Add(@{ t = 'kv'; rows = @(
				, @('Сервер', [string]$run.requestedServer)
				, @('Топологія', (Get-IaOutTopologyText -Topology $run.topology))
				, @('runId', [string]$run.runId)
				, @('Модуль', [string]$run.module)
				, @('Початок / завершення (UTC)', "$(Format-IaOutText $run.startedAtUtc) / $(Format-IaOutText $run.finishedAtUtc)")
				, @('Хто запустив', "$($run.startedBy) на $($run.hostName)")
				, @('Версія IndexAdvisor', (Format-IaOutText $run.toolVersion))
				, @('Статус', "$($run.status) (код повернення $($run.exitCode))")
				, @('Джерело даних', $source)
				, @('Архів зібраних даних', (Format-IaOutText $run.archivePath))
				, @('Вікно аналізу Query Store', $window)
			)
		})

	# Період даних.
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Період даних' })
	$periods = @($run.dataPeriods | Where-Object { $_ })
	$insufficient = @($periods | Where-Object { -not $_.isSufficient })
	if ($insufficient.Count -gt 0) {
		$blocks.Add(@{ t = 'alert'; level = 'warn'; text = "Період роботи сервера коротший за мінімальний для: $(@($insufficient | ForEach-Object { if ($_.database) { "$($_.server)/$($_.database)" } else { [string]$_.server } }) -join ', '). Такий аналіз не зараховується до серії рекомендацій на видалення." })
	}
	if ($periods.Count -gt 0) {
		$blocks.Add(@{ t = 'table'; headers = @('Сервер', 'База', 'Запуск інстансу', 'Failover', 'Статистика з', 'Статистика по', 'Днів', 'Query Store з', 'Query Store по', 'Днів QS', 'Мінімум, дн.', 'Достатньо'); rows = @(foreach ($period in $periods) {
						, @([string]$period.server, (Format-IaOutText $period.database), (Format-IaOutText $period.sqlserverStartTimeUtc), (Format-IaOutText $period.lastFailoverUtc),
							(Format-IaOutText $period.statsFromUtc), (Format-IaOutText $period.statsToUtc), (Format-IaOutNumber $period.uptimeDays 1), (Format-IaOutText $period.queryStoreFromUtc),
							(Format-IaOutText $period.queryStoreToUtc), (Format-IaOutNumber $period.queryStoreDays 1), [string]$period.minRequiredDays, (Format-IaOutBool $period.isSufficient))
					})
			})
		$periodWarnings = @($periods | ForEach-Object { @($_.warnings) } | Where-Object { $_ } | Select-Object -Unique)
		if ($periodWarnings.Count -gt 0) {
			$blocks.Add(@{ t = 'ul'; items = @($periodWarnings | ForEach-Object { [string]$_ }); warn = $true })
		}
	}
	else {
		$blocks.Add(@{ t = 'alert'; level = 'warn'; text = 'Період даних не визначено.' })
	}

	# Набори даних.
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Зібрані набори даних' })
	if ($run.datasets) {
		$blocks.Add(@{ t = 'ul'; items = @(
					"Зібрано: $(if (@($run.datasets.enabled).Count) { @($run.datasets.enabled) -join ', ' } else { '—' })"
					"Вимкнено: $(if (@($run.datasets.disabled).Count) { @($run.datasets.disabled) -join ', ' } else { '—' })"
				)
			})
		$datasetWarnings = @($run.datasets.warnings | Where-Object { $_ } | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { "$($_.dataset): $($_.message)" } else { [string]$_ } })
		if ($datasetWarnings.Count -gt 0) {
			$blocks.Add(@{ t = 'alert'; level = 'warn'; text = 'Вимкнені набори знижують достовірність рекомендацій:' })
			$blocks.Add(@{ t = 'ul'; items = $datasetWarnings; warn = $true })
		}
	}
	else {
		$blocks.Add(@{ t = 'p'; text = 'Дані не зібрано.' })
	}

	# Маскування.
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Маскування' })
	$namesMasked = [bool]($run.masking -and $run.masking.namesMasked)
	$blocks.Add(@{ t = 'ul'; items = @(
				"Імена об'єктів перед відправкою в модель: $(if ($namesMasked) { 'масковано' } else { 'не масковано' })"
				"Літерали в текстах запитів: $(if ($run.masking -and $run.masking.literalsMasked) { 'очищено' } else { 'не очищено' })"
			)
		})
	if (-not $namesMasked -and $run.archivePath) {
		$blocks.Add(@{ t = 'alert'; level = 'warn'; text = 'Архів містить немасковані тексти запитів і структуру баз; його не можна передавати в зовнішні сервіси без перевірки.' })
	}

	# Небезпечні режими.
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Небезпечні режими' })
	$unsafe = @($run.unsafeFlags | Where-Object { $_ })
	if ($unsafe.Count -gt 0) {
		$blocks.Add(@{ t = 'alert'; level = 'danger'; text = "Увімкнено небезпечні режими: $($unsafe -join ', '). Відповідні обмеження безпеки під час запуску не діяли." })
	}
	else {
		$blocks.Add(@{ t = 'p'; text = 'Не ввімкнено.' })
	}
	if ($run.loginCheck -and $run.loginCheck.isStandard -eq $false) {
		$blocks.Add(@{ t = 'alert'; level = 'danger'; text = "Підключення не під штатним логіном: $($run.loginCheck.login)." })
	}

	# Модель, токени, вартість, дозапити.
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Модель, токени й вартість' })
	$cacheWrite = [long](@($run.llm.calls | Where-Object { $_ } | ForEach-Object { [long]$_.cacheWriteTokens }) | Measure-Object -Sum).Sum
	$cacheRead = [long](@($run.llm.calls | Where-Object { $_ } | ForEach-Object { [long]$_.cacheReadTokens }) | Measure-Object -Sum).Sum
	$blocks.Add(@{ t = 'kv'; rows = @(
				, @('Провайдер', (Format-IaOutText $run.llm.provider))
				, @('Модель', (Format-IaOutText $run.llm.model))
				, @('Cross-check', (Format-IaOutText $run.llm.crossCheckProvider))
				, @('Шаблони промптів', $(if (@($run.promptTemplates).Count) { (@($run.promptTemplates | Where-Object { $_ } | ForEach-Object { "$($_.id) v$($_.version)" }) -join ', ') } else { '—' }))
				, @('Вхідні токени', [string]$run.llm.totalInputTokens)
				, @('З них кеш промптів: запис / читання', "$cacheWrite / $cacheRead")
				, @('Вихідні токени', [string]$run.llm.totalOutputTokens)
				, @('Вартість, USD', (Format-IaOutNumber $run.llm.totalCostUsd 4))
			)
		})
	$calls = @($run.llm.calls | Where-Object { $_ })
	if ($calls.Count -gt 0) {
		$blocks.Add(@{ t = 'h'; level = 3; text = 'Виклики моделі' })
		$blocks.Add(@{ t = 'table'; headers = @('Призначення', 'Провайдер', 'Модель', 'Вхід', 'Кеш: запис / читання', 'Вихід', 'Завершення', 'USD', 'мс', 'Успіх'); rows = @(foreach ($call in $calls) {
						, @((Format-IaOutText $call.purpose), (Format-IaOutText $call.provider), (Format-IaOutText $call.model), [string]$call.inputTokens,
							"$([long]$call.cacheWriteTokens) / $([long]$call.cacheReadTokens)", [string]$call.outputTokens, (Format-IaOutText $call.finishReason),
							(Format-IaOutNumber $call.costUsd 4), [string]$call.durationMs, (Format-IaOutBool $call.success))
					})
			})
	}
	$blocks.Add(@{ t = 'h'; level = 3; text = 'Дозапити моделі' })
	$toolRequests = @($run.toolRequests | Where-Object { $_ })
	if ($toolRequests.Count -gt 0) {
		$blocks.Add(@{ t = 'table'; headers = @('Інструмент', 'Сервер / база', 'Аргументи', 'Причина запиту', 'Рішення', 'Пояснення рішення', 'Рядків', 'Успіх'); rows = @(foreach ($request in $toolRequests) {
						$arguments = if ($request.arguments) { ConvertTo-Json -InputObject $request.arguments -Depth 10 -Compress } else { '{}' }
						, @((Format-IaOutText $request.tool), "$($request.server) / $($request.database)", $arguments, (Format-IaOutText $request.reason), (Format-IaOutText $request.decision),
							(Format-IaOutText $request.decisionReason), $(if ($request.response) { [string]$request.response.rowCount } else { '—' }), $(if ($request.response) { Format-IaOutBool $request.response.success } else { '—' }))
					})
			})
	}
	else {
		$blocks.Add(@{ t = 'p'; text = 'Дозапитів не було.' })
	}
	$llmNotes = @($run.llm.notes | Where-Object { $_ -and $_.text })
	if ($llmNotes.Count -gt 0) {
		$blocks.Add(@{ t = 'h'; level = 3; text = 'Нотатки моделі' })
		foreach ($note in $llmNotes) {
			$blocks.Add(@{ t = 'p'; text = ('{0}: {1}' -f (Format-IaOutText $note.module), [string]$note.text) })
		}
	}

	# Попередження й помилки запуску.
	$runWarnings = @($run.warnings | Where-Object { $_ })
	if ($runWarnings.Count -gt 0) {
		$blocks.Add(@{ t = 'h'; level = 2; text = 'Попередження запуску' })
		$blocks.Add(@{ t = 'ul'; items = @($runWarnings | ForEach-Object { [string]$_ }); warn = $true })
	}
	$runErrors = @($run.errors | Where-Object { $_ })
	if ($runErrors.Count -gt 0) {
		$blocks.Add(@{ t = 'h'; level = 2; text = 'Помилки запуску' })
		$blocks.Add(@{ t = 'ul'; items = @($runErrors | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { "$($_.stage) [$($_.code)]: $($_.message)" } else { [string]$_ } }); danger = $true })
	}

	# Знахідки rules engine.
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Знахідки rules engine' })
	$findings = @($run.findings | Where-Object { $_ })
	if ($findings.Count -gt 0) {
		$blocks.Add(@{ t = 'table'; headers = @('Правило', 'Важливість', "Об'єкт", 'Повідомлення', 'Пропонована дія'); rows = @(foreach ($finding in $findings) {
						, @([string]$finding.ruleId, [string]$finding.severity, "$($finding.target.database): $(Get-IaOutObjectName $finding.target)", (Format-IaOutText $finding.message), [string]$finding.suggestedAction)
					})
			})
	}
	else {
		$blocks.Add(@{ t = 'p'; text = 'Знахідок немає.' })
	}

	# Рекомендації.
	$accepted = @($Items | Where-Object { -not $_.rejected })
	$rejected = @($Items | Where-Object { $_.rejected })
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Рекомендації' })
	if ($accepted.Count -eq 0) {
		$blocks.Add(@{ t = 'p'; text = 'Рекомендацій немає.' })
	}
	foreach ($item in $accepted) {
		foreach ($block in (New-IaOutRecommendationBlocks -Item $item)) {
			$blocks.Add($block)
		}
	}
	$blocks.Add(@{ t = 'h'; level = 2; text = 'Відхилені перевіркою' })
	if ($rejected.Count -eq 0) {
		$blocks.Add(@{ t = 'p'; text = 'Відхилених рекомендацій немає.' })
	}
	else {
		$blocks.Add(@{ t = 'alert'; level = 'danger'; text = 'Ці рекомендації не пройшли автоматичну перевірку (розділ 4.8) і не мають виконуватися. SQL-файли для них не створюються.' })
	}
	foreach ($item in $rejected) {
		foreach ($block in (New-IaOutRecommendationBlocks -Item $item)) {
			$blocks.Add($block)
		}
	}
	if ($run.maintenance) {
		foreach ($block in (New-IaMaintenanceReportBlocks -Plan $run.maintenance)) {
			$blocks.Add($block)
		}
	}
	return , @($blocks.ToArray())
}

function ConvertTo-IaOutMarkdownText {
	<# Текст для Markdown поза блоками коду: кутові дужки екрануються, щоб дані не інтерпретувалися як HTML. #>
	param([AllowNull()][string]$Text)
	if ($null -eq $Text) {
		return ''
	}
	return $Text.Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertTo-IaOutMarkdownCell {
	param([AllowNull()][string]$Text)
	return (ConvertTo-IaOutMarkdownText $Text).Replace('|', '\|').Replace("`r", '').Replace("`n", ' ')
}

function ConvertTo-IaOutMarkdown {
	<# Рендер моделі блоків у Markdown. #>
	param([Parameter(Mandatory)][object[]]$Blocks)
	$sb = [System.Text.StringBuilder]::new()
	foreach ($block in $Blocks) {
		switch ($block.t) {
			'h' {
				[void]$sb.AppendLine(('#' * $block.level) + ' ' + (ConvertTo-IaOutMarkdownText $block.text)).AppendLine()
			}
			'p' {
				[void]$sb.AppendLine((ConvertTo-IaOutMarkdownText $block.text)).AppendLine()
			}
			'alert' {
				$prefix = switch ($block.level) { 'danger' { '**УВАГА:** ' } 'warn' { '**Попередження:** ' } default { '' } }
				foreach ($line in ((ConvertTo-IaOutMarkdownText $block.text) -split "`r?`n")) {
					[void]$sb.AppendLine("> $prefix$line")
					$prefix = ''
				}
				[void]$sb.AppendLine()
			}
			'ul' {
				foreach ($item in $block.items) {
					[void]$sb.AppendLine('- ' + ((ConvertTo-IaOutMarkdownText $item) -replace "`r?`n", ' '))
				}
				[void]$sb.AppendLine()
			}
			'kv' {
				[void]$sb.AppendLine('| Параметр | Значення |').AppendLine('|---|---|')
				foreach ($row in $block.rows) {
					[void]$sb.AppendLine("| $(ConvertTo-IaOutMarkdownCell $row[0]) | $(ConvertTo-IaOutMarkdownCell $row[1]) |")
				}
				[void]$sb.AppendLine()
			}
			'table' {
				[void]$sb.AppendLine('| ' + (($block.headers | ForEach-Object { ConvertTo-IaOutMarkdownCell $_ }) -join ' | ') + ' |')
				[void]$sb.AppendLine('|' + ((@($block.headers) | ForEach-Object { '---' }) -join '|') + '|')
				foreach ($row in $block.rows) {
					[void]$sb.AppendLine('| ' + ((@($row) | ForEach-Object { ConvertTo-IaOutMarkdownCell ([string]$_) }) -join ' | ') + ' |')
				}
				[void]$sb.AppendLine()
			}
			'code' {
				$text = [string]$block.text
				$fence = '```'
				while ($text.Contains($fence)) {
					$fence += '`'
				}
				[void]$sb.AppendLine("${fence}sql").AppendLine($text.TrimEnd()).AppendLine($fence).AppendLine()
			}
		}
	}
	return $sb.ToString()
}

function ConvertTo-IaOutHtmlText {
	<# HTML-екранування будь-яких даних (&, <, >, ", '). #>
	param([AllowNull()][string]$Text)
	if ($null -eq $Text) {
		return ''
	}
	return [System.Net.WebUtility]::HtmlEncode($Text)
}

function ConvertTo-IaOutHtml {
	<# Рендер моделі блоків у самодостатній HTML без зовнішніх ресурсів і скриптів. #>
	param(
		[Parameter(Mandatory)][object[]]$Blocks,
		[Parameter(Mandatory)][string]$Title
	)
	$style = @'
:root { color-scheme: light dark; --fg: #1d1d1f; --bg: #ffffff; --muted: #5f6368; --line: #d0d4da; --head: #f2f4f7; --code: #f6f8fa;
	--info: #e8f1fb; --info-line: #2f6fb5; --warn: #fff6e0; --warn-line: #b7791f; --danger: #fdecec; --danger-line: #c0392b; }
@media (prefers-color-scheme: dark) { :root { --fg: #e6e6e6; --bg: #17181a; --muted: #a0a4aa; --line: #3a3d42; --head: #24262a; --code: #1f2124;
	--info: #182a3d; --info-line: #5b9be0; --warn: #3a2f12; --warn-line: #e0b050; --danger: #3d1a1a; --danger-line: #e06a5b; } }
body { font-family: "Segoe UI", Arial, sans-serif; color: var(--fg); background: var(--bg); margin: 0 auto; padding: 16px 24px 48px; max-width: 1200px; line-height: 1.45; }
h1 { font-size: 1.6em; } h2 { margin-top: 2em; border-bottom: 1px solid var(--line); padding-bottom: .2em; } h3 { margin-top: 1.6em; } h4 { margin-bottom: .3em; }
table { border-collapse: collapse; width: 100%; margin: .5em 0 1em; font-size: .92em; display: block; overflow-x: auto; }
th, td { border: 1px solid var(--line); padding: 4px 8px; text-align: left; vertical-align: top; }
th { background: var(--head); } table.kv th { width: 260px; }
pre { background: var(--code); border: 1px solid var(--line); padding: 10px; overflow-x: auto; white-space: pre; }
.alert { border-left: 4px solid var(--info-line); background: var(--info); padding: 8px 12px; margin: .6em 0; }
.alert.warn, ul.warn { border-left: 4px solid var(--warn-line); background: var(--warn); }
.alert.danger, ul.danger { border-left: 4px solid var(--danger-line); background: var(--danger); font-weight: 600; }
ul.warn, ul.danger { padding: 8px 12px 8px 32px; }
'@
	$sb = [System.Text.StringBuilder]::new()
	[void]$sb.AppendLine('<!DOCTYPE html>')
	[void]$sb.AppendLine('<html lang="uk">')
	[void]$sb.AppendLine('<head>')
	[void]$sb.AppendLine('<meta charset="utf-8">')
	[void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
	[void]$sb.AppendLine("<title>$(ConvertTo-IaOutHtmlText $Title)</title>")
	[void]$sb.AppendLine("<style>`n$style</style>")
	[void]$sb.AppendLine('</head>')
	[void]$sb.AppendLine('<body>')
	foreach ($block in $Blocks) {
		switch ($block.t) {
			'h' {
				[void]$sb.AppendLine("<h$($block.level)>$(ConvertTo-IaOutHtmlText $block.text)</h$($block.level)>")
			}
			'p' {
				[void]$sb.AppendLine("<p>$((ConvertTo-IaOutHtmlText $block.text) -replace "`r?`n", '<br>')</p>")
			}
			'alert' {
				$class = if ($block.level -in @('warn', 'danger')) { "alert $($block.level)" } else { 'alert' }
				[void]$sb.AppendLine("<div class=""$class"">$((ConvertTo-IaOutHtmlText $block.text) -replace "`r?`n", '<br>')</div>")
			}
			'ul' {
				$class = if ($block.danger) { ' class="danger"' } elseif ($block.warn) { ' class="warn"' } else { '' }
				[void]$sb.AppendLine("<ul$class>")
				foreach ($item in $block.items) {
					[void]$sb.AppendLine("<li>$(ConvertTo-IaOutHtmlText $item)</li>")
				}
				[void]$sb.AppendLine('</ul>')
			}
			'kv' {
				[void]$sb.AppendLine('<table class="kv"><tbody>')
				foreach ($row in $block.rows) {
					[void]$sb.AppendLine("<tr><th>$(ConvertTo-IaOutHtmlText $row[0])</th><td>$(ConvertTo-IaOutHtmlText $row[1])</td></tr>")
				}
				[void]$sb.AppendLine('</tbody></table>')
			}
			'table' {
				[void]$sb.AppendLine('<table><thead><tr>' + (($block.headers | ForEach-Object { "<th>$(ConvertTo-IaOutHtmlText $_)</th>" }) -join '') + '</tr></thead><tbody>')
				foreach ($row in $block.rows) {
					[void]$sb.AppendLine('<tr>' + ((@($row) | ForEach-Object { "<td>$(ConvertTo-IaOutHtmlText ([string]$_))</td>" }) -join '') + '</tr>')
				}
				[void]$sb.AppendLine('</tbody></table>')
			}
			'code' {
				[void]$sb.AppendLine("<pre><code class=""language-sql"">$(ConvertTo-IaOutHtmlText ([string]$block.text).TrimEnd())</code></pre>")
			}
		}
	}
	[void]$sb.AppendLine("<p><small>Згенеровано IndexAdvisor $(ConvertTo-IaOutHtmlText $script:IaToolVersion) $(ConvertTo-IaOutHtmlText (ConvertTo-IaUtcString -Date ([datetime]::UtcNow))) UTC.</small></p>")
	[void]$sb.AppendLine('</body>')
	[void]$sb.AppendLine('</html>')
	return $sb.ToString()
}

function ConvertTo-IaOutSqlComment {
	<# Рядки коментаря T-SQL: кожен рядок даних починається з '-- ', тож дані не можуть завершити коментар. #>
	param([AllowNull()][string]$Text, [string]$Indent = '')
	if ([string]::IsNullOrEmpty($Text)) {
		return @("--$Indent")
	}
	return @(($Text -split "`r?`n") | ForEach-Object { "-- $Indent$_".TrimEnd() })
}

function New-IaOutSqlFileText {
	<# Текст SQL-файлу (виконання або відкату) із заголовком-коментарем (розділ 9). #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$RunResult,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Item,
		[Parameter(Mandatory)][ValidateSet('Execute', 'Rollback')][string]$Kind
	)
	$rec = $Item.recommendation
	$lines = [System.Collections.Generic.List[string]]::new()
	$kindText = if ($Kind -eq 'Execute') { 'Скрипт виконання' } else { 'Скрипт відкату' }
	$lines.Add('-- ' + ('=' * 100))
	$lines.Add("-- IndexAdvisor. $kindText рекомендації $($Item.number): $($rec.action) $(Get-IaOutObjectName $rec.target)")
	foreach ($line in (ConvertTo-IaOutSqlComment -Text "Назва: $($rec.title)")) { $lines.Add($line) }
	$lines.Add("-- Сервер: $($rec.target.server); база: $($rec.target.database)")
	$lines.Add("-- runId: $($RunResult.runId); recommendationId: $($rec.recommendationId)")
	$lines.Add("-- Дата: $($rec.createdAtUtc) UTC; запуск $($RunResult.startedAtUtc) UTC; модель: $(if ($rec.llm) { "$($rec.llm.provider) / $($rec.llm.model)" } else { '—' })")
	foreach ($line in (ConvertTo-IaOutSqlComment -Text "Ризик: $($rec.risk.level) — $($rec.risk.description)")) { $lines.Add($line) }
	$lines.Add("-- Перевірка 4.8: $(if ($rec.validation) { $rec.validation.status } else { 'NotValidated' })")
	foreach ($line in (ConvertTo-IaOutSqlComment -Text ("Період даних: " + (Get-IaOutPeriodText -Period $rec.dataPeriod)))) { $lines.Add($line) }
	$warnings = @($rec.warnings | Where-Object { $_ })
	if ($warnings.Count -gt 0) {
		$lines.Add('-- Попередження:')
		foreach ($warning in $warnings) {
			foreach ($line in (ConvertTo-IaOutSqlComment -Text "  - $warning")) { $lines.Add($line) }
		}
	}
	if ($rec.action -eq 'DropIndex') {
		$eligibility = $rec.dropEligibility
		foreach ($line in (ConvertTo-IaOutSqlComment -Text ("Умови 4.4: " + (Get-IaOutDropSummary -Eligibility $eligibility)))) { $lines.Add($line) }
		if ($eligibility) {
			foreach ($condition in @($eligibility.conditions | Where-Object { $_ })) {
				$name = if ($script:IaOutConditionNames.Contains([string]$condition.id)) { $script:IaOutConditionNames[[string]$condition.id] } else { [string]$condition.id }
				foreach ($line in (ConvertTo-IaOutSqlComment -Text "  [$(Get-IaOutConditionStatus -Met $condition.met)] $name ($($condition.id)): $($condition.details)")) { $lines.Add($line) }
			}
		}
	}
	$lines.Add('-- Програма нічого не виконує автоматично: скрипт перевіряє й виконує DBA вручну в зазначеній базі.')
	$lines.Add('-- ' + ('=' * 100))
	$lines.Add('')
	$scriptText = if ($Kind -eq 'Execute') { [string]$rec.executeScript } else { [string]$rec.rollbackScript }
	if ($Kind -eq 'Execute' -and $Item.commentedExecute) {
		$missing = if ($rec.dropEligibility) {
			@($rec.dropEligibility.conditions | Where-Object { $_ -and $_.met -ne $true } | ForEach-Object {
					$name = if ($script:IaOutConditionNames.Contains([string]$_.id)) { $script:IaOutConditionNames[[string]$_.id] } else { [string]$_.id }
					"$name ($(Get-IaOutConditionStatus -Met $_.met))"
				})
		}
		else {
			@('умови 4.4 не перевірено')
		}
		$lines.Add('-- УВАГА: умови безпечного видалення (розділ 4.4) виконано не всі, тому інструкції нижче закоментовано.')
		$lines.Add('-- Бракує умов:')
		foreach ($missingItem in $missing) {
			foreach ($line in (ConvertTo-IaOutSqlComment -Text "  - $missingItem")) { $lines.Add($line) }
		}
		$lines.Add('-- Розкоментуйте інструкції лише після того, як усі умови буде виконано.')
		$lines.Add('')
		foreach ($line in ($scriptText -split "`r?`n")) {
			$lines.Add("-- $line".TrimEnd())
		}
	}
	else {
		foreach ($line in ($scriptText -split "`r?`n")) {
			$lines.Add($line)
		}
	}
	return (($lines -join "`r`n").TrimEnd() + "`r`n")
}

function Write-IaOutFile {
	<# Записує текст у UTF-8 без BOM. #>
	param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
	[System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
	return $Path
}

function Write-IaOutConsoleSummary {
	<# Підсумок запуску в консоль (потік Information / хост). #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$RunResult,
		[AllowEmptyCollection()][object[]]$Items = @(),
		[AllowEmptyString()][string]$Directory
	)
	$run = $RunResult
	$accepted = @($Items | Where-Object { -not $_.rejected })
	$byAction = @($accepted | Group-Object { $_.recommendation.action } | ForEach-Object { "$($_.Name): $($_.Count)" })
	$minPeriod = @($run.dataPeriods | Where-Object { $_ } | Sort-Object { [double]$_.uptimeDays } | Select-Object -First 1)
	Write-Host ''
	Write-Host "IndexAdvisor: сервер $($run.requestedServer) — статус $($run.status), код повернення $($run.exitCode)"
	Write-Host "  runId: $($run.runId)"
	if ($minPeriod.Count -gt 0) {
		$period = $minPeriod[0]
		Write-Host "  Період даних (найкоротший): $(Format-IaOutNumber $period.uptimeDays 1) дн. з $($period.statsFromUtc); мінімум $($period.minRequiredDays) дн.; $(if ($period.isSufficient) { 'достатній' } else { 'НЕДОСТАТНІЙ' })"
	}
	else {
		Write-Host '  Період даних: не визначено'
	}
	Write-Host "  Рекомендацій: $($accepted.Count)$(if ($byAction.Count) { ' (' + ($byAction -join ', ') + ')' }); відхилено перевіркою: $(@($Items | Where-Object { $_.rejected }).Count)"
	$drops = @($accepted | Where-Object { $_.recommendation.action -eq 'DropIndex' })
	if ($drops.Count -gt 0) {
		Write-Host "  Видалення з виконаними умовами 4.4: $(@($drops | Where-Object { -not $_.commentedExecute }).Count) з $($drops.Count)"
	}
	if (@($run.unsafeFlags).Count -gt 0) {
		Write-Host "  УВАГА: небезпечні режими: $(@($run.unsafeFlags) -join ', ')"
	}
	Write-Host "  Модель: $(Format-IaOutText $run.llm.provider) / $(Format-IaOutText $run.llm.model); токени $($run.llm.totalInputTokens) + $($run.llm.totalOutputTokens); вартість $(Format-IaOutNumber $run.llm.totalCostUsd 4) USD; дозапитів: $(@($run.toolRequests).Count)"
	Write-Host "  Попереджень: $(@($run.warnings).Count); помилок: $(@($run.errors).Count)"
	if ($Directory) {
		Write-Host "  Результати: $Directory"
	}
}

function Export-IaReport {
	<# Записує результат запуску у формати output.formats (Markdown, Sql, Html, Json, Console) у output.path/<runId>/.
	   Повертає шляхи створених файлів. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$RunResult,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$formats = @($Config.output.formats | Where-Object { $_ })
	$items = Get-IaOutReportItems -RunResult $RunResult
	$files = [System.Collections.Generic.List[string]]::new()
	$fileFormats = @($formats | Where-Object { $_ -ne 'Console' })
	$directory = ''
	if ($fileFormats.Count -gt 0) {
		$started = try {
			[System.DateTimeOffset]::Parse([string]$RunResult.startedAtUtc, [cultureinfo]::InvariantCulture).UtcDateTime
		}
		catch {
			[datetime]::UtcNow
		}
		$serverPart = [regex]::Replace([string]$RunResult.requestedServer, '[^\p{L}\p{Nd}_.-]', '_')
		if ([string]::IsNullOrEmpty($serverPart)) {
			$serverPart = 'server'
		}
		$runPart = ([string]$RunResult.runId).Replace('-', '')
		$runPart = $runPart.Substring(0, [math]::Min(8, $runPart.Length))
		$folder = '{0}_{1}_{2}' -f $started.ToString('yyyyMMdd_HHmmss', [cultureinfo]::InvariantCulture), $serverPart, $runPart
		$root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Config.output.path)
		$directory = Join-Path $root $folder
		New-Item -ItemType Directory -Path $directory -Force | Out-Null
	}
	if ('Markdown' -in $formats -or 'Html' -in $formats) {
		$blocks = New-IaOutReportBlocks -RunResult $RunResult -Items $items
		if ('Markdown' -in $formats) {
			$files.Add((Write-IaOutFile -Path (Join-Path $directory 'recommendations.md') -Text (ConvertTo-IaOutMarkdown -Blocks $blocks)))
		}
		if ('Html' -in $formats) {
			$title = "IndexAdvisor: $($RunResult.requestedServer) ($($RunResult.runId))"
			$files.Add((Write-IaOutFile -Path (Join-Path $directory 'report.html') -Text (ConvertTo-IaOutHtml -Blocks $blocks -Title $title)))
		}
	}
	if ('Sql' -in $formats) {
		$sqlDirectory = Join-Path $directory 'sql'
		New-Item -ItemType Directory -Path $sqlDirectory -Force | Out-Null
		foreach ($item in @($items | Where-Object { -not $_.rejected })) {
			$files.Add((Write-IaOutFile -Path (Join-Path $sqlDirectory "$($item.fileBase).sql") -Text (New-IaOutSqlFileText -RunResult $RunResult -Item $item -Kind Execute)))
			$files.Add((Write-IaOutFile -Path (Join-Path $sqlDirectory "$($item.fileBase)_rollback.sql") -Text (New-IaOutSqlFileText -RunResult $RunResult -Item $item -Kind Rollback)))
		}
	}
	if ($RunResult.maintenance -and $directory) {
		foreach ($file in (Export-IaMaintenanceFiles -Plan $RunResult.maintenance -Directory $directory)) {
			$files.Add($file)
		}
	}
	if ('Json' -in $formats) {
		$json = ConvertTo-Json -InputObject $RunResult -Depth 50
		$files.Add((Write-IaOutFile -Path (Join-Path $directory 'result.json') -Text $json))
	}
	if ('Console' -in $formats) {
		Write-IaOutConsoleSummary -RunResult $RunResult -Items $items -Directory $directory
	}
	return , @($files.ToArray())
}
