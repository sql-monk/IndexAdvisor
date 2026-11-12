# Основний CLI IndexAdvisor: конвеєр CONTRACTS.md, розділ 4. Функції інших потоків викликаються лише через контрактні сигнатури.
# Програма нічого не змінює в цільових базах: результат — звіти, SQL-скрипти для DBA і запис історії в окрему базу-репозиторій.

function Get-IaCliErrorId {
	<# ErrorId винятку (перша частина FullyQualifiedErrorId). #>
	param([AllowNull()]$ErrorRecord)
	if ($null -eq $ErrorRecord) {
		return ''
	}
	$id = [string]$ErrorRecord.FullyQualifiedErrorId
	return ($id -split ',')[0]
}

function ConvertTo-IaCliList {
	<# Нормалізує результат функції (масив, масив через кому, один об'єкт або $null) до плоского масиву без $null. #>
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return , @()
	}
	if ($Value -is [System.Collections.IDictionary] -or $Value -is [string]) {
		return , @($Value)
	}
	return , @($Value | Where-Object { $null -ne $_ })
}

function Set-IaCliOverride {
	<# Записує значення за шляхом a.b.c у вкладений словник перевизначень. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Overrides,
		[Parameter(Mandatory)][string]$Path,
		[AllowNull()]$Value
	)
	$parts = $Path.Split('.')
	$node = $Overrides
	for ($i = 0; $i -lt $parts.Count - 1; $i++) {
		if (-not $node.Contains($parts[$i]) -or $node[$parts[$i]] -isnot [System.Collections.IDictionary]) {
			$node[$parts[$i]] = [ordered]@{}
		}
		$node = $node[$parts[$i]]
	}
	$node[$parts[-1]] = $Value
}

function ConvertTo-IaCliOverrides {
	<# Параметри CLI -> перевизначення конфігурації (таблиця CONTRACTS.md, розділ 7). Невідомі набори даних — IaConfigInvalid. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters)
	$overrides = [ordered]@{}
	$errors = [System.Collections.Generic.List[object]]::new()
	$simple = [ordered]@{
		Server = 'servers'
		Database = 'scope.databases.include'
		ExcludeDatabase = 'scope.databases.exclude'
		Schema = 'scope.schemas.include'
		ExcludeSchema = 'scope.schemas.exclude'
		Table = 'scope.tables.include'
		ExcludeTable = 'scope.tables.exclude'
		Module = 'module'
		Provider = 'llm.provider'
		Model = 'llm.model'
		CrossCheckProvider = 'llm.crossCheckProvider'
		AnalysisWindowDays = 'analysisWindow.days'
		OutputPath = 'output.path'
		Format = 'output.formats'
	}
	foreach ($name in $simple.Keys) {
		if ($BoundParameters.Contains($name)) {
			$value = $BoundParameters[$name]
			if ($value -is [array]) {
				$value = @($value | ForEach-Object { [string]$_ })
			}
			Set-IaCliOverride -Overrides $overrides -Path $simple[$name] -Value $value
		}
	}
	$switches = [ordered]@{
		NonInteractive = 'run.nonInteractive'
		AutoApprove = 'llm.autoApproveToolRequests'
		LocalOnly = 'llm.localOnly'
		MaskNames = 'llm.maskNames'
		UnsafeDisableSelectCheck = 'unsafe.disableSelectCheck'
		UnsafeDisableMaxdop = 'unsafe.disableMaxdop'
		UnsafeDisableTimeouts = 'unsafe.disableTimeouts'
		UnsafeAllowFreeQuery = 'unsafe.allowFreeQuery'
		AllowNonStandardLogin = 'unsafe.allowNonStandardLogin'
		Maintenance = 'maintenance.enabled'
	}
	foreach ($name in $switches.Keys) {
		if ($BoundParameters.Contains($name)) {
			Set-IaCliOverride -Overrides $overrides -Path $switches[$name] -Value ([bool]$BoundParameters[$name])
		}
	}
	if ($BoundParameters.Contains('NoRepository')) {
		Set-IaCliOverride -Overrides $overrides -Path 'repository.enabled' -Value (-not [bool]$BoundParameters['NoRepository'])
	}
	if ($BoundParameters.Contains('NoArchive')) {
		Set-IaCliOverride -Overrides $overrides -Path 'archive.enabled' -Value (-not [bool]$BoundParameters['NoArchive'])
	}
	$resolveDataset = {
		param([string]$Name, [string]$Parameter)
		$canonical = @($script:IaDatasetNames | Where-Object { $_ -eq $Name.Trim() }) | Select-Object -First 1
		if (-not $canonical) {
			$errors.Add((New-IaCliConfigError -Line $null -Column $null -Path "-$Parameter" -Message ("Невідомий набір даних '{0}'. Допустимі: {1}." -f $Name, ($script:IaDatasetNames -join ', '))))
		}
		return $canonical
	}
	if ($BoundParameters.Contains('Dataset')) {
		$selected = @(foreach ($name in @($BoundParameters['Dataset'])) { & $resolveDataset $name 'Dataset' }) | Where-Object { $_ }
		foreach ($datasetName in $script:IaDatasetNames) {
			$enabled = ($datasetName -in $selected) -or ($datasetName -in $script:IaMandatoryDatasets)
			Set-IaCliOverride -Overrides $overrides -Path "collector.datasets.$datasetName" -Value $enabled
		}
	}
	if ($BoundParameters.Contains('ExcludeDataset')) {
		foreach ($name in @($BoundParameters['ExcludeDataset'])) {
			$canonical = & $resolveDataset $name 'ExcludeDataset'
			if (-not $canonical) {
				continue
			}
			if ($canonical -in $script:IaMandatoryDatasets) {
				$errors.Add((New-IaCliConfigError -Line $null -Column $null -Path '-ExcludeDataset' -Message "Обов'язковий набір даних '$canonical' не можна вимкнути: без нього аналіз неможливий."))
				continue
			}
			Set-IaCliOverride -Overrides $overrides -Path "collector.datasets.$canonical" -Value $false
		}
	}
	if ($errors.Count -gt 0) {
		$PSCmdlet.ThrowTerminatingError((New-IaCliConfigErrorRecord -Errors $errors.ToArray()))
	}
	return $overrides
}

function Format-IaCliCommandLine {
	<# Текст команди для журналу сесії (CLI не приймає секретів; значення лише з параметрів). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters)
	$parts = [System.Collections.Generic.List[string]]::new()
	$parts.Add('Invoke-IndexAdvisor')
	foreach ($key in $BoundParameters.Keys) {
		$value = $BoundParameters[$key]
		if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
			$parts.Add("-${key}:$('$' + ([bool]$value).ToString().ToLowerInvariant())")
		}
		else {
			$text = (@($value) | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ','
			$parts.Add("-$key $text")
		}
	}
	return ($parts -join ' ')
}

function ConvertTo-IaCliParameterMap {
	<# Параметри запуску для RunResult.parameters (JSON-сумісні значення). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters)
	$result = [ordered]@{}
	foreach ($key in $BoundParameters.Keys) {
		$value = $BoundParameters[$key]
		if ($value -is [System.Management.Automation.SwitchParameter]) {
			$result[$key] = $value.IsPresent
		}
		elseif ($value -is [array]) {
			$result[$key] = @($value | ForEach-Object { [string]$_ })
		}
		else {
			$result[$key] = $value
		}
	}
	return $result
}

function Write-IaCliLog {
	<# Запис у журнал сесії; збій журналу не зупиняє запуск, але показується як попередження. #>
	param(
		[Parameter(Mandatory)][string]$Message,
		[ValidateSet('Info', 'Warning', 'Error', 'Security')][string]$Level = 'Info',
		[System.Collections.IDictionary]$Data
	)
	try {
		if ($Data) {
			Write-IaLog -Message $Message -Level $Level -Data $Data
		}
		else {
			Write-IaLog -Message $Message -Level $Level
		}
	}
	catch {
		Write-Warning "Не вдалося записати в журнал: $($_.Exception.Message)"
	}
}

function Write-IaCliError {
	<# Повідомлення про помилку в потік помилок без переривання (для SQL Agent, Rundeck, cron). #>
	param([Parameter(Mandatory)][string]$Message, [string]$ErrorId = 'IaRunError')
	Write-Error -Message $Message -ErrorId $ErrorId -ErrorAction Continue
}

$script:IaCliWarningRunIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Add-IaCliRunWarning {
	<# Попередження рівня запуску. Звичайне попередження дає код SuccessWithWarnings; Informational — лише показується у звіті. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Run,
		[AllowEmptyString()][string]$Message,
		[switch]$Informational
	)
	if ([string]::IsNullOrWhiteSpace($Message)) {
		return
	}
	if ($Message -notin @($Run.warnings)) {
		$Run.warnings = @($Run.warnings) + $Message
	}
	if (-not $Informational) {
		[void]$script:IaCliWarningRunIds.Add([string]$Run.runId)
	}
}

function Add-IaCliRunError {
	<# Помилка етапу запуску з кодом повернення (розділ 11). #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Run,
		[Parameter(Mandatory)][string]$Stage,
		[Parameter(Mandatory)][ValidateSet('ConfigError', 'ConnectionRefused', 'CollectionFailed', 'LlmFailed', 'RepositoryFailed', 'Unexpected')][string]$Code,
		[Parameter(Mandatory)][string]$Message
	)
	$Run.errors = @($Run.errors) + [ordered]@{ stage = $Stage; code = $Code; exitCode = [int]$script:IaExitCodes[$Code]; message = $Message }
	Write-IaCliError -Message "[$($Run.requestedServer)] $Stage`: $Message" -ErrorId "Ia$Code"
	Write-IaCliLog -Message "[$($Run.requestedServer)] $Stage`: $Message" -Level Error
}

function Update-IaCliRunStatus {
	<# Обчислює status і exitCode запуску: найгірший код помилки; без помилок — 1, якщо є попередження
	   (короткий період, частковий збір, рекомендації з Failed/Warning тощо). Неповні умови 4.4 не рахуються. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Run, [switch]$Fatal, [switch]$PartialCollection)
	$code = 0
	foreach ($item in @($Run.errors)) {
		if ([int]$item.exitCode -gt $code) {
			$code = [int]$item.exitCode
		}
	}
	if ($code -eq 0) {
		$hasRecWarnings = @($Run.recommendations | Where-Object { $_.validation -and $_.validation.status -in @('Failed', 'Warning') }).Count -gt 0
		if ($script:IaCliWarningRunIds.Contains([string]$Run.runId) -or $hasRecWarnings) {
			$code = [int]$script:IaExitCodes.SuccessWithWarnings
		}
	}
	$Run.exitCode = $code
	$Run.status = if ($Fatal) { 'Failed' } elseif (@($Run.errors).Count -gt 0 -or $PartialCollection) { 'Partial' } else { 'Succeeded' }
}

function Find-IaCliDataPeriod {
	<# Період даних для цілі рекомендації: спершу база на тому самому сервері, далі база будь-де, далі інстанс. #>
	param([object[]]$Periods = @(), [System.Collections.IDictionary]$Target)
	if ($null -eq $Target) {
		return $null
	}
	$byServerAndDb = @($Periods | Where-Object { $_.database -and $_.database -eq $Target.database -and $_.server -eq $Target.server }) | Select-Object -First 1
	if ($byServerAndDb) {
		return $byServerAndDb
	}
	$byDb = @($Periods | Where-Object { $_.database -and $_.database -eq $Target.database }) | Sort-Object { [double]$_.uptimeDays } | Select-Object -First 1
	if ($byDb) {
		return $byDb
	}
	return @($Periods | Where-Object { -not $_.database }) | Sort-Object { [double]$_.uptimeDays } | Select-Object -First 1
}

function Format-IaCliPeriodWarning {
	<# Текст попередження про недостатній період даних. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Period)
	$scope = if ($Period.database) { "$($Period.server)/$($Period.database)" } else { [string]$Period.server }
	$days = [System.Convert]::ToString([math]::Round([double]$Period.uptimeDays, 1), [cultureinfo]::InvariantCulture)
	return ("Період даних {0}: {1} дн. (з {2}) коротший за мінімальний {3} дн.; аналіз не зараховується до серії рекомендацій на видалення." -f $scope, $days, $Period.statsFromUtc, $Period.minRequiredDays)
}

function Get-IaCliSnapshotWarnings {
	<# Попередження зі snapshot. Частковий збір (загальні попередження, незібрані репліки) — warnings;
	   попередження інстансів і баз (наприклад, Query Store на вторинній репліці) — info. Повертає @{ warnings; info; partial }. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)
	$warnings = [System.Collections.Generic.List[string]]::new()
	$info = [System.Collections.Generic.List[string]]::new()
	$partial = $false
	foreach ($message in @($Snapshot.warnings)) {
		if ($message) {
			$warnings.Add([string]$(if ($message -is [System.Collections.IDictionary]) { $message.message } else { $message }))
			$partial = $true
		}
	}
	if ($Snapshot.topology) {
		foreach ($group in @($Snapshot.topology.availabilityGroups)) {
			foreach ($replica in @($group.replicas)) {
				if ($replica -and $replica.collected -eq $false) {
					$partial = $true
					$warnings.Add(("Репліку {0} групи {1} не зібрано: {2}" -f $replica.replicaServerName, $group.name, $replica.skipReason))
				}
			}
		}
	}
	foreach ($instance in @($Snapshot.instances)) {
		foreach ($message in @($instance.warnings)) {
			if ($message) {
				$info.Add("[$($instance.serverName)] $(if ($message -is [System.Collections.IDictionary]) { $message.message } else { $message })")
			}
		}
		foreach ($database in @($instance.databases)) {
			foreach ($message in @($database.warnings)) {
				if ($message) {
					$info.Add("[$($instance.serverName)/$($database.name)] $(if ($message -is [System.Collections.IDictionary]) { $message.message } else { $message })")
				}
			}
		}
	}
	return @{ warnings = @($warnings.ToArray()); info = @($info.ToArray()); partial = $partial }
}

function Get-IaCliDatasetWarnings {
	<# Тексти попереджень про вимкнені набори даних. #>
	param([AllowNull()][System.Collections.IDictionary]$Datasets)
	if ($null -eq $Datasets) {
		return @()
	}
	return @(foreach ($item in @($Datasets.warnings)) {
			if ($item -is [System.Collections.IDictionary]) { [string]$item.message } elseif ($item) { [string]$item }
		})
}

function ConvertTo-IaCliCompactDraft {
	<# Чернетка модуля партиціонування для промпту: з draftId і без SQL-скриптів (executeScript, rollbackScript, functionScript, schemeScript).
	   Модель не повторює чернетки, а повертає рішення draftDecisions; за Confirm програма бере скрипти з самої чернетки. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Draft, [Parameter(Mandatory)][string]$DraftId)
	$compact = [ordered]@{ draftId = $DraftId }
	foreach ($key in $Draft.Keys) {
		if ($key -in @('executeScript', 'rollbackScript')) {
			continue
		}
		if ($key -eq 'partitioning' -and $Draft[$key] -is [System.Collections.IDictionary]) {
			$partitioning = [ordered]@{}
			foreach ($name in $Draft[$key].Keys) {
				if ($name -notin @('functionScript', 'schemeScript')) {
					$partitioning[$name] = $Draft[$key][$name]
				}
			}
			$compact[$key] = $partitioning
			continue
		}
		$compact[$key] = $Draft[$key]
	}
	return $compact
}

function Merge-IaCliDraftDecisions {
	<# Рекомендації з чернеток модуля за рішеннями моделі: Reject — чернетку відкинуто (інформаційне попередження з причиною);
	   Confirm — рекомендація правил з позначкою підтвердження; без рішення — рекомендація правил з попередженням, що модель її не оцінила. #>
	param(
		[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DraftEntries,
		[AllowEmptyCollection()][object[]]$Decisions = @(),
		[Parameter(Mandatory)][System.Collections.IDictionary]$Run,
		[Parameter(Mandatory)][ValidateSet('Indexes', 'Partitioning')][string]$Module
	)
	$byId = @{}
	foreach ($decision in @($Decisions | Where-Object { $null -ne $_ })) {
		$byId[[string]$decision.draftId] = $decision
	}
	$knownIds = @($DraftEntries | ForEach-Object { [string]$_.id })
	foreach ($id in @($byId.Keys | Where-Object { $_ -notin $knownIds })) {
		Add-IaCliRunWarning -Run $Run -Informational -Message "Модель повернула рішення для невідомої чернетки '$id'; його проігноровано."
	}
	foreach ($entry in $DraftEntries) {
		$decision = $byId[[string]$entry.id]
		if ($decision -and [string]$decision.decision -eq 'Reject') {
			$reason = if ($decision.reason) { [string]$decision.reason } else { 'причину не вказано' }
			Add-IaCliRunWarning -Run $Run -Informational -Message "Модель відхилила чернетку $($entry.id) «$($entry.draft.title)»: $reason"
			continue
		}
		$rec = New-IaRecommendation -Draft $entry.draft -RunId $Run.runId -Module $Module -Source Rules
		$rec.warnings = @(
			if ($decision) {
				"Чернетку детермінованого модуля підтверджено моделлю$(if ($decision.reason) { ": $($decision.reason)" } else { '.' })"
			}
			else {
				'Модель не оцінила цю чернетку детермінованого модуля; рекомендацію сформовано без аналізу моделлю.'
			}
		)
		$rec
	}
}

function Invoke-IaCliServerRun {
	<# Один запуск для одного сервера (CONTRACTS.md, розділ 4, крок 4). Повертає RunResult; винятки перехоплюються. #>
	[CmdletBinding()]
	param(
		[AllowEmptyString()][AllowNull()][string]$Server,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Context
	)
	$cfg = $Config
	$modules = if ($cfg.module -eq 'Both') { @('Indexes', 'Partitioning') } else { @([string]$cfg.module) }
	$fromArchive = $Context.fromArchive
	$archive = $null
	$archiveError = $null
	if ($fromArchive) {
		try {
			$archive = Read-IaSnapshotArchive -Path $fromArchive
			if ($archive.manifest -and $archive.manifest.requestedServer) {
				$Server = [string]$archive.manifest.requestedServer
			}
			elseif ($archive.snapshot -and $archive.snapshot.requestedServer) {
				$Server = [string]$archive.snapshot.requestedServer
			}
		}
		catch {
			$archiveError = $_
		}
		if ([string]::IsNullOrWhiteSpace($Server)) {
			$Server = [System.IO.Path]::GetFileNameWithoutExtension($fromArchive)
		}
	}
	$run = New-IaRunResult -RequestedServer $Server -Module $cfg.module -Parameters $Context.parameters
	$run.unsafeFlags = @($Context.unsafeFlags)
	$run.loginCheck = $Context.loginCheck
	$run.llm.provider = $Context.provider.name
	$run.llm.model = $Context.provider.model
	$run.llm.crossCheckProvider = $(if ($cfg.llm.crossCheckProvider) { [string]$cfg.llm.crossCheckProvider } else { $null })
	$run.masking = [ordered]@{ namesMasked = [bool]$cfg.llm.maskNames; literalsMasked = $true }
	foreach ($flag in @($Context.unsafeFlags)) {
		Add-IaCliRunWarning -Run $run -Message "Увімкнено небезпечний режим: $flag"
	}
	foreach ($message in @($Context.loginCheck.warnings)) {
		Add-IaCliRunWarning -Run $run -Message ([string]$message)
	}
	$partialCollection = $false
	$fatal = $false
	$snapshot = $null
	try {
		# 4.1 Вікно аналізу.
		$window = Get-IaAnalysisWindow -Config $cfg
		$run.analysisWindow = $window

		# 4.2 Дані: архів або збір.
		if ($fromArchive) {
			$run.fromArchive = $fromArchive
			if ($archiveError) {
				Add-IaCliRunError -Run $run -Stage 'Архів' -Code CollectionFailed -Message "Не вдалося прочитати архів '$fromArchive': $($archiveError.Exception.Message)"
				$fatal = $true
				return $run
			}
			$snapshot = $archive.snapshot
			$manifest = $archive.manifest
			if ($archive.maskingMap) {
				$snapshot = ConvertFrom-IaMaskedObject -InputObject $snapshot -Map $archive.maskingMap
			}
			elseif ($manifest -and $manifest.namesMasked) {
				Add-IaCliRunWarning -Run $run -Informational -Message 'Мапи маскування поруч з архівом немає: аналіз виконується з маскованими іменами об''єктів.'
			}
			if ($manifest) {
				$run.masking = [ordered]@{ namesMasked = [bool]$manifest.namesMasked; literalsMasked = [bool]$manifest.literalsMasked }
			}
			if ($snapshot.analysisWindow) {
				$run.analysisWindow = $snapshot.analysisWindow
			}
		}
		else {
			try {
				$snapshot = Invoke-IaCollection -Server $Server -Config $cfg -AnalysisWindow $window
			}
			catch {
				# IaLoginRefused -> ConnectionRefused (3); IaCollectionFailed та інші збої збору -> CollectionFailed (4).
				$code = if ([string]$_.FullyQualifiedErrorId -like 'IaLoginRefused*') { 'ConnectionRefused' } else { 'CollectionFailed' }
				Add-IaCliRunError -Run $run -Stage 'Збір даних' -Code $code -Message $_.Exception.Message
				$fatal = $true
				return $run
			}
		}
		if ($null -eq $snapshot -or @($snapshot.instances).Count -eq 0) {
			Add-IaCliRunError -Run $run -Stage 'Збір даних' -Code CollectionFailed -Message 'Не зібрано даних із жодного інстансу.'
			$fatal = $true
			return $run
		}
		$run.topology = $snapshot.topology
		$run.datasets = $snapshot.datasets
		$snapshotWarnings = Get-IaCliSnapshotWarnings -Snapshot $snapshot
		$partialCollection = $snapshotWarnings.partial
		foreach ($message in $snapshotWarnings.warnings) {
			Add-IaCliRunWarning -Run $run -Message $message
		}
		foreach ($message in $snapshotWarnings.info) {
			Add-IaCliRunWarning -Run $run -Informational -Message $message
		}
		$datasetWarnings = @(Get-IaCliDatasetWarnings -Datasets $snapshot.datasets)
		foreach ($message in $datasetWarnings) {
			Add-IaCliRunWarning -Run $run -Message $message
		}

		# Нештатний логін: фактичні права на кожному інстансі й базі.
		if (-not $fromArchive -and $Context.loginCheck -and $Context.loginCheck.isStandard -eq $false) {
			$permissions = [System.Collections.Generic.List[object]]::new()
			foreach ($instance in @($snapshot.instances)) {
				foreach ($database in @($instance.databases)) {
					try {
						$check = Get-IaLoginPermissions -Server $instance.serverName -Database $database.name -Config $cfg
						$permissions.Add($check)
						foreach ($item in @($check.excessive)) {
							if ($null -eq $item) {
								continue
							}
							$message = "Зайве право логіна $($check.login) на $($instance.serverName)/$($database.name): $($item.permission) ($($item.scope))"
							Write-Warning $message
							Write-IaCliLog -Message $message -Level Security
							Add-IaCliRunWarning -Run $run -Message $message
						}
						foreach ($message in @($check.warnings)) {
							Add-IaCliRunWarning -Run $run -Message ([string]$message)
						}
					}
					catch {
						Add-IaCliRunWarning -Run $run -Message "Не вдалося перевірити права логіна на $($instance.serverName)/$($database.name): $($_.Exception.Message)"
					}
				}
			}
			$loginCheck = [ordered]@{}
			foreach ($key in $Context.loginCheck.Keys) {
				$loginCheck[$key] = $Context.loginCheck[$key]
			}
			$loginCheck.permissions = @($permissions.ToArray())
			$run.loginCheck = $loginCheck
		}

		# 4.3 Період даних.
		$periods = ConvertTo-IaCliList (Get-IaDataPeriod -Snapshot $snapshot -Config $cfg)
		$run.dataPeriods = $periods
		foreach ($period in $periods) {
			if ($period -and -not $period.isSufficient) {
				Add-IaCliRunWarning -Run $run -Message (Format-IaCliPeriodWarning -Period $period)
			}
		}

		# 4.4 Rules engine і модуль партиціонування.
		$findingsByModule = @{ Indexes = @(); Partitioning = @() }
		$partitionDrafts = @()
		if ('Indexes' -in $modules) {
			$findingsByModule.Indexes = ConvertTo-IaCliList (Invoke-IaRulesEngine -Snapshot $snapshot -Config $cfg)
		}
		if ('Partitioning' -in $modules) {
			$partition = Invoke-IaPartitionAnalysis -Snapshot $snapshot -Config $cfg
			$findingsByModule.Partitioning = @($partition.findings)
			$partitionDrafts = @($partition.drafts | Where-Object { $null -ne $_ })
		}
		$run.findings = @($findingsByModule.Indexes) + @($findingsByModule.Partitioning)
		$partitionDraftEntries = @(for ($i = 0; $i -lt $partitionDrafts.Count; $i++) { @{ id = ('D{0:00}' -f ($i + 1)); draft = $partitionDrafts[$i] } })

		# 4.5 Провайдер (перевірено до циклу), інструменти, мапа маскування.
		$provider = $Context.provider
		$tools = $Context.tools
		$map = New-IaMaskingMap

		# 4.6 Контекст і промпт для кожного модуля.
		$moduleState = [ordered]@{}
		foreach ($module in $modules) {
			# Чернетки модуля партиціонування — компактно (без скриптів) і в межах бюджету контексту.
			$compactDrafts = @()
			$reservedTokens = 0
			if ($module -eq 'Partitioning' -and $partitionDraftEntries.Count -gt 0) {
				$compactDrafts = @(foreach ($entry in $partitionDraftEntries) { ConvertTo-IaCliCompactDraft -Draft $entry.draft -DraftId $entry.id })
				$reservedTokens = Measure-IaTokens -Text (ConvertTo-IaLlmJson -Value $compactDrafts)
			}
			$llmContext = New-IaLlmContext -Snapshot $snapshot -Findings $findingsByModule[$module] -Module $module -ProviderConfig $provider -Config $cfg `
				-ReservedTokens $reservedTokens
			$payload = $llmContext.payload
			if ($module -eq 'Partitioning' -and $payload -is [System.Collections.IDictionary]) {
				$payload['drafts'] = $compactDrafts
			}
			$maskedPayload = ConvertTo-IaMaskedObject -InputObject $payload -Map $map -Config $cfg
			$templateName = if ($module -eq 'Partitioning') { 'partition-analysis' } else { 'index-analysis' }
			$prompt = New-IaPrompt -TemplateName $templateName -Payload $maskedPayload -ToolSchemas $Context.toolSchemas -Config $cfg
			$moduleState[$module] = @{ context = $llmContext; payload = $maskedPayload; prompt = $prompt; completed = $false; recommendations = @() }
		}

		# 4.7 Архів (не для -FromArchive).
		if (-not $fromArchive) {
			try {
				$maskedSnapshot = ConvertTo-IaMaskedObject -InputObject (Copy-IaObject -InputObject $snapshot) -Map $map -Config $cfg
				if ($maskedSnapshot -is [System.Collections.IDictionary] -and $maskedSnapshot.masking) {
					$run.masking = [ordered]@{ namesMasked = [bool]$maskedSnapshot.masking.namesMasked; literalsMasked = [bool]$maskedSnapshot.masking.literalsMasked }
				}
				$prompts = [System.Collections.IDictionary[]]@($moduleState.Values | ForEach-Object { $_.prompt })
				$maskingMap = if ($cfg.llm.maskNames) { $map } else { $null }
				$archivePath = Save-IaSnapshotArchive -Snapshot $maskedSnapshot -Prompts $prompts -MaskingMap $maskingMap -RunId $run.runId -Config $cfg
				$run.archivePath = $archivePath
				if ($archivePath -and -not $run.masking.namesMasked) {
					Add-IaCliRunWarning -Run $run -Informational -Message 'Архів містить немасковані тексти запитів і структуру баз; його не можна передавати в зовнішні сервіси без перевірки.'
				}
			}
			catch {
				Add-IaCliRunWarning -Run $run -Message "Архів зібраних даних не збережено: $($_.Exception.Message)"
			}
		}

		# 4.8 Аналіз моделлю.
		$recommendations = [System.Collections.Generic.List[object]]::new()
		$calls = [System.Collections.Generic.List[object]]::new()
		foreach ($module in $modules) {
			$state = $moduleState[$module]
			$analysis = $null
			# Без жодної таблиці в контексті (бази не зібрано чи пропущено через права) модель не викликається: аналізувати нічого.
			if (@($state.context.includedObjectKeys | Where-Object { $_ }).Count -eq 0 -and -not ($module -eq 'Partitioning' -and $partitionDraftEntries.Count -gt 0)) {
				$state.completed = $true
				$reason = if ($module -eq 'Partitioning') {
					'немає секціонованих таблиць і кандидатів за порогами partitioning (minSizeGb, minRowCount)'
				}
				else {
					'у зібраних даних немає жодної таблиці (бази не зібрано або пропущено — див. попередження вище)'
				}
				Add-IaCliRunWarning -Run $run -Informational:($module -eq 'Partitioning') -Message "Аналіз моделлю ($module) пропущено: $reason."
				continue
			}
			try {
				$analysis = Invoke-IaAnalysisLoop -Prompt $state.prompt -Snapshot $snapshot -ProviderConfig $provider -Tools $tools -MaskingMap $map -Config $cfg
			}
			catch {
				$reason = if ([string]$_.FullyQualifiedErrorId -like 'IaBudgetExceeded*') { 'перевищено бюджет' } else { 'помилка' }
				Add-IaCliRunError -Run $run -Stage "Аналіз моделлю ($module)" -Code LlmFailed -Message "$reason`: $($_.Exception.Message)"
			}
			if ($analysis) {
				foreach ($call in @($analysis.calls)) {
					if ($call) {
						$calls.Add($call)
					}
				}
				$run.llm.totalInputTokens = [long]$run.llm.totalInputTokens + [long]$analysis.totalInputTokens
				$run.llm.totalOutputTokens = [long]$run.llm.totalOutputTokens + [long]$analysis.totalOutputTokens
				$run.llm.totalCostUsd = [double]$run.llm.totalCostUsd + [double]$analysis.totalCostUsd
				$run.toolRequests = @($run.toolRequests) + @($analysis.toolRequests | Where-Object { $null -ne $_ })
				if ($analysis.prompt) {
					$run.promptTemplates = @($run.promptTemplates) + [ordered]@{ id = $analysis.prompt.templateId; version = $analysis.prompt.templateVersion }
				}
				if (-not [string]::IsNullOrWhiteSpace([string]$analysis.notes)) {
					$run.llm.notes = @($run.llm.notes) + [ordered]@{ module = $module; text = [string]$analysis.notes }
				}
				switch ([string]$analysis.stoppedReason) {
					'Error' {
						Add-IaCliRunError -Run $run -Stage "Аналіз моделлю ($module)" -Code LlmFailed -Message "Аналіз завершився з помилкою: $($analysis.error)"
					}
					'BudgetExceeded' {
						Add-IaCliRunError -Run $run -Stage "Аналіз моделлю ($module)" -Code LlmFailed -Message "Перевищено бюджет LLM: $($analysis.error)"
					}
					'ToolLimit' {
						$state.completed = $true
						Add-IaCliRunWarning -Run $run -Message "Аналіз ($module): вичерпано ліміт дозапитів моделі (limits.maxToolRequestsPerAnalysis)."
					}
					'TokenLimit' {
						$state.completed = $true
						Add-IaCliRunWarning -Run $run -Message "Аналіз ($module): вичерпано ліміт токенів (limits.maxTokensPerAnalysis)."
					}
					default {
						$state.completed = $true
					}
				}
				$callIds = @($analysis.calls | Where-Object { $_ } | ForEach-Object { [string]$_.llmCallId } | Where-Object { $_ })
				$firstModel = @($analysis.calls | Where-Object { $_ -and $_.model } | ForEach-Object { [string]$_.model }) | Select-Object -First 1
				$llmInfo = [ordered]@{
					provider = [string]$provider.name
					model = $(if ($firstModel) { $firstModel } else { [string]$provider.model })
					promptTemplateId = $(if ($analysis.prompt) { [string]$analysis.prompt.templateId } else { [string]$state.prompt.templateId })
					promptTemplateVersion = $(if ($analysis.prompt) { [int]$analysis.prompt.templateVersion } else { [int]$state.prompt.templateVersion })
					llmCallIds = $callIds
				}
				$moduleRecs = foreach ($draft in @($analysis.recommendations | Where-Object { $null -ne $_ })) {
					New-IaRecommendation -Draft $draft -RunId $run.runId -Module $module -Source Llm -Llm $llmInfo
				}
				$state.recommendations = @($moduleRecs)
				if ($state.completed -and $module -eq 'Partitioning' -and $partitionDraftEntries.Count -gt 0) {
					$state.recommendations = @($moduleRecs) + @(Merge-IaCliDraftDecisions -DraftEntries $partitionDraftEntries `
							-Decisions @($analysis.draftDecisions) -Run $run -Module Partitioning)
				}
			}
			if (-not $state.completed -and $module -eq 'Partitioning' -and $partitionDrafts.Count -gt 0) {
				# Модель не дала відповіді: чернетки модуля партиціонування показуються як рекомендації правил з попередженням.
				$state.recommendations = @(foreach ($draft in $partitionDrafts) {
						$rec = New-IaRecommendation -Draft $draft -RunId $run.runId -Module Partitioning -Source Rules
						$rec.warnings = @('Рекомендацію сформовано детермінованим модулем партиціонування без аналізу моделлю.')
						$rec
					})
			}
		}
		$run.llm.calls = @($calls.ToArray())

		# 4.9 Cross-check критичних рекомендацій.
		if ($cfg.llm.crossCheckProvider) {
			foreach ($module in $modules) {
				$state = $moduleState[$module]
				if (@($state.recommendations).Count -eq 0) {
					continue
				}
				try {
					$crossCheck = Invoke-IaCrossCheck -Recommendations @($state.recommendations) -Payload $state.payload -MaskingMap $map -Config $cfg
					if ($null -ne $crossCheck.recommendations) {
						$state.recommendations = @($crossCheck.recommendations)
					}
					$run.llm.calls = @($run.llm.calls) + @($crossCheck.calls | Where-Object { $null -ne $_ })
					foreach ($call in @($crossCheck.calls | Where-Object { $null -ne $_ })) {
						$run.llm.totalInputTokens = [long]$run.llm.totalInputTokens + [long]$call.inputTokens
						$run.llm.totalOutputTokens = [long]$run.llm.totalOutputTokens + [long]$call.outputTokens
						$run.llm.totalCostUsd = [double]$run.llm.totalCostUsd + [double]$call.costUsd
					}
				}
				catch {
					Add-IaCliRunError -Run $run -Stage "Cross-check ($module)" -Code LlmFailed -Message $_.Exception.Message
				}
			}
		}

		# 4.10 Період, перевірка 4.8, правила 4.4, попередження для кожної рекомендації.
		$history = @{}
		foreach ($module in $modules) {
			$dropKeys = @($moduleState[$module].recommendations | Where-Object { $_.action -eq 'DropIndex' } | ForEach-Object { $_.target.objectKey } | Select-Object -Unique)
			$history[$module] = @()
			if ($dropKeys.Count -eq 0) {
				continue
			}
			try {
				$history[$module] = ConvertTo-IaCliList (Get-IaRecommendationHistory -ObjectKeys $dropKeys -Module $module -Config $cfg)
			}
			catch {
				Add-IaCliRunError -Run $run -Stage 'Історія рекомендацій' -Code RepositoryFailed -Message $_.Exception.Message
			}
		}
		$unsafeWarnings = @($Context.unsafeFlags | ForEach-Object { "Рекомендацію отримано з увімкненим небезпечним режимом: $_" })
		foreach ($module in $modules) {
			foreach ($rec in @($moduleState[$module].recommendations)) {
				$warnings = [System.Collections.Generic.List[string]]::new()
				foreach ($message in @($rec.warnings)) {
					if ($message) {
						$warnings.Add([string]$message)
					}
				}
				$rec.dataPeriod = Find-IaCliDataPeriod -Periods $periods -Target $rec.target
				try {
					$rec.validation = Test-IaRecommendation -Recommendation $rec -Snapshot $snapshot -Config $cfg
				}
				catch {
					$warnings.Add("Перевірку 4.8 не виконано: $($_.Exception.Message)")
					$rec.validation = [ordered]@{ status = 'NotValidated'; checks = @() }
					Add-IaCliRunWarning -Run $run -Message "Перевірку 4.8 рекомендації «$($rec.title)» не виконано: $($_.Exception.Message)"
				}
				if ($rec.action -eq 'DropIndex') {
					$recHistory = @($history[$module] | Where-Object { $_ -and $_.objectKey -eq $rec.target.objectKey })
					try {
						$rec.dropEligibility = Get-IaDropEligibility -Recommendation $rec -Snapshot $snapshot -History $recHistory -DataPeriods $periods -Config $cfg
					}
					catch {
						$rec.dropEligibility = $null
						Add-IaCliRunWarning -Run $run -Message "Умови 4.4 для «$($rec.title)» не перевірено: $($_.Exception.Message)"
					}
					if ($null -eq $rec.dropEligibility) {
						$warnings.Add('Умови безпечного видалення (розділ 4.4) не перевірено: видалення не рекомендоване до виконання.')
					}
					elseif (-not $rec.dropEligibility.isEligible) {
						$warnings.Add($(if ($rec.dropEligibility.warning) { [string]$rec.dropEligibility.warning } else { 'Умови безпечного видалення (розділ 4.4) виконано не повністю.' }))
					}
					if ($rec.dropEligibility -and $rec.dropEligibility.rulesProfile -eq 'Relaxed') {
						$warnings.Add("Застосовано пом'якшені правила видалення: $($rec.dropEligibility.relaxedReason)")
					}
				}
				foreach ($message in $unsafeWarnings) {
					$warnings.Add($message)
				}
				foreach ($message in $datasetWarnings) {
					$warnings.Add($message)
				}
				if ($rec.dataPeriod -and -not $rec.dataPeriod.isSufficient) {
					$warnings.Add((Format-IaCliPeriodWarning -Period $rec.dataPeriod))
				}
				$rec.warnings = @($warnings | Select-Object -Unique)
				$recommendations.Add($rec)
			}
		}
		$run.recommendations = @($recommendations.ToArray())

		# 4.11 Вердикти для історії (лише для модулів з завершеним аналізом).
		$verdicts = [System.Collections.Generic.List[object]]::new()
		foreach ($module in $modules) {
			$state = $moduleState[$module]
			if (-not $state.completed) {
				continue
			}
			$moduleVerdicts = ConvertTo-IaCliList (New-IaObjectVerdicts -RunId $run.runId -Module $module -Recommendations @($state.recommendations) `
				-IncludedObjectKeys @($state.context.includedObjectKeys) -DataPeriods $periods -Config $cfg)
			foreach ($verdict in $moduleVerdicts) {
				if ($verdict) {
					$verdicts.Add($verdict)
				}
			}
		}
		$run.verdicts = @($verdicts.ToArray())

		# Обслуговування індексів (AdaptiveIndexDefrag): план за зібраними даними й рекомендаціями; збій не зупиняє запуск.
		if ($cfg.maintenance -and $cfg.maintenance.enabled) {
			try {
				$run.maintenance = Get-IaMaintenancePlan -Snapshot $snapshot -Config $cfg -Recommendations @($run.recommendations) -RunId $run.runId
			}
			catch {
				Add-IaCliRunWarning -Run $run -Message "План обслуговування індексів не сформовано: $($_.Exception.Message)"
			}
		}
		if (@($moduleState.Values | Where-Object { $_.completed }).Count -eq 0 -and $run.recommendations.Count -eq 0) {
			$fatal = $true
		}
	}
	catch {
		Add-IaCliRunError -Run $run -Stage 'Запуск' -Code Unexpected -Message "$($_.Exception.Message) ($($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber))"
		$fatal = $true
	}
	finally {
		$run.finishedAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
		Update-IaCliRunStatus -Run $run -Fatal:$fatal -PartialCollection:$partialCollection
	}
	return $run
}

function Complete-IaCliRunOutput {
	<# Крок 4.11: звіт, репозиторій, очищення історії й архівів. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Run,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	try {
		Export-IaReport -RunResult $Run -Config $Config | Out-Null
	}
	catch {
		Add-IaCliRunError -Run $Run -Stage 'Звіт' -Code Unexpected -Message $_.Exception.Message
		Update-IaCliRunStatus -Run $Run -Fatal:($Run.status -eq 'Failed')
	}
	if ($Config.repository.enabled) {
		try {
			Save-IaRunToRepository -RunResult $Run -Config $Config
		}
		catch {
			Add-IaCliRunError -Run $Run -Stage 'Репозиторій' -Code RepositoryFailed -Message $_.Exception.Message
			Update-IaCliRunStatus -Run $Run -Fatal:($Run.status -eq 'Failed')
		}
		try {
			$removed = Remove-IaExpiredHistory -Config $Config
			if ($removed) {
				Write-IaCliLog -Message "Видалено застарілих запусків з репозиторію: $removed"
			}
		}
		catch {
			Write-Warning "Не вдалося видалити застарілу історію рекомендацій: $($_.Exception.Message)"
		}
	}
	try {
		Remove-IaExpiredArchives -Config $Config | Out-Null
	}
	catch {
		Write-Warning "Не вдалося видалити застарілі архіви: $($_.Exception.Message)"
	}
}

function Invoke-IndexAdvisor {
	<# Основний CLI: збір, аналіз і рекомендації за один запуск (конвеєр — CONTRACTS.md, розділ 4).
	   Параметри командного рядка мають пріоритет над YAML. Встановлює $global:LASTEXITCODE; з -PassThru повертає RunResult[]. #>
	[CmdletBinding()]
	param(
		[string]$Config,
		[string[]]$Server,
		[string[]]$Database,
		[string[]]$ExcludeDatabase,
		[string[]]$Schema,
		[string[]]$ExcludeSchema,
		[string[]]$Table,
		[string[]]$ExcludeTable,
		[ValidateSet('Indexes', 'Partitioning', 'Both')][string]$Module,
		[string]$Provider,
		[string]$Model,
		[string]$CrossCheckProvider,
		[ValidateRange(1, 3650)][int]$AnalysisWindowDays,
		[string[]]$Dataset,
		[string[]]$ExcludeDataset,
		[string]$OutputPath,
		[ValidateSet('Markdown', 'Sql', 'Html', 'Json', 'Console')][string[]]$Format,
		[switch]$NoRepository,
		[switch]$NoArchive,
		[string]$FromArchive,
		[switch]$NonInteractive,
		[switch]$AutoApprove,
		[switch]$LocalOnly,
		[switch]$MaskNames,
		[switch]$UnsafeDisableSelectCheck,
		[switch]$UnsafeDisableMaxdop,
		[switch]$UnsafeDisableTimeouts,
		[switch]$UnsafeAllowFreeQuery,
		[switch]$AllowNonStandardLogin,
		[switch]$Maintenance,
		[switch]$PassThru
	)
	$exitCodes = $script:IaExitCodes
	$bound = [ordered]@{}
	foreach ($key in $PSBoundParameters.Keys) {
		if ($key -notin @('PassThru', 'Config', 'FromArchive') -and $key -notin [System.Management.Automation.PSCmdlet]::CommonParameters) {
			$bound[$key] = $PSBoundParameters[$key]
		}
	}
	$results = [System.Collections.Generic.List[object]]::new()
	$exitCode = [int]$exitCodes.Success
	$sessionStarted = $false
	try {
		# 1. Конфігурація: YAML + CLI.
		try {
			$overrides = ConvertTo-IaCliOverrides -BoundParameters $bound
			$cfg = Get-IaConfig -Path $Config -Overrides $overrides
		}
		catch {
			Write-IaCliError -Message $_.Exception.Message -ErrorId 'IaConfigInvalid'
			$exitCode = [int]$exitCodes.ConfigError
			return
		}
		$seenServers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		$servers = @(foreach ($item in @($cfg.servers)) {
				if (-not [string]::IsNullOrWhiteSpace($item) -and $seenServers.Add($item.Trim())) {
					$item.Trim()
				}
			})
		if ($FromArchive) {
			if ($servers.Count -gt 0) {
				Write-Warning 'Задано -FromArchive: список серверів ігнорується, аналізується сервер з архіву.'
			}
			$servers = @('')
		}
		elseif ($servers.Count -eq 0) {
			Write-IaCliError -Message 'Не задано жодного сервера: вкажіть -Server або servers у конфігурації.' -ErrorId 'IaConfigInvalid'
			$exitCode = [int]$exitCodes.ConfigError
			return
		}
		if ([string]::IsNullOrWhiteSpace($cfg.llm.provider)) {
			Write-IaCliError -Message 'Не задано провайдера LLM: вкажіть -Provider або llm.provider у конфігурації.' -ErrorId 'IaConfigInvalid'
			$exitCode = [int]$exitCodes.ConfigError
			return
		}

		# 2. Сесія і небезпечні режими.
		$parameters = ConvertTo-IaCliParameterMap -BoundParameters $PSBoundParameters
		$parameters.Remove('PassThru')
		$session = Start-IaSession -Config $cfg -Command (Format-IaCliCommandLine -BoundParameters $PSBoundParameters)
		$sessionStarted = $true
		$unsafeFlags = ConvertTo-IaCliList (Get-IaUnsafeFlags -Config $cfg)
		foreach ($flag in $unsafeFlags) {
			$message = "Увімкнено небезпечний режим '$flag': відповідне обмеження безпеки вимкнено. Це записано в журнал і в кожну рекомендацію."
			Write-Warning $message
			Write-IaCliLog -Message $message -Level Warning
		}

		# 3. Штатний логін.
		try {
			$loginCheck = Assert-IaStandardLogin -Config $cfg
		}
		catch {
			Write-IaCliError -Message $_.Exception.Message -ErrorId 'IaLoginRefused'
			Write-IaCliLog -Message $_.Exception.Message -Level Security
			$exitCode = [int]$exitCodes.ConnectionRefused
			return
		}
		if ($loginCheck -and $loginCheck.isStandard -eq $false) {
			$message = "Підключення не під штатним логіном ($($loginCheck.login)): увімкнено unsafe.allowNonStandardLogin; фактичні права буде перевірено на кожному сервері й базі."
			Write-Warning $message
			Write-IaCliLog -Message $message -Level Security
		}

		# Провайдер LLM та інструменти не залежать від сервера: перевіряються до збору, щоб не навантажувати сервери даремно.
		try {
			$providerConfig = Get-IaLlmProviderConfig -Name $cfg.llm.provider -Config $cfg
			Assert-IaProviderAllowed -ProviderConfig $providerConfig -Config $cfg
			if ($cfg.llm.crossCheckProvider) {
				$crossCheckConfig = Get-IaLlmProviderConfig -Name $cfg.llm.crossCheckProvider -Config $cfg -IgnoreModelOverride
				Assert-IaProviderAllowed -ProviderConfig $crossCheckConfig -Config $cfg
			}
			$toolsPath = if ($cfg.tools.definitionsPath) { [string]$cfg.tools.definitionsPath } else { $null }
			$tools = if ($toolsPath) { Import-IaToolDefinitions -Path $toolsPath -Config $cfg } else { Import-IaToolDefinitions -Config $cfg }
			if ($null -eq $tools) {
				$tools = [ordered]@{}
			}
			$toolSchemas = @(foreach ($tool in $tools.Values) { ConvertTo-IaToolJsonSchema -Tool $tool })
		}
		catch {
			Write-IaCliError -Message $_.Exception.Message -ErrorId (Get-IaCliErrorId $_)
			Write-IaCliLog -Message $_.Exception.Message -Level Error
			$exitCode = [int]$exitCodes.ConfigError
			return
		}

		# 4. Окремий запуск для кожного сервера.
		$context = @{
			loginCheck = $loginCheck
			unsafeFlags = $unsafeFlags
			provider = $providerConfig
			tools = $tools
			toolSchemas = $toolSchemas
			fromArchive = $(if ($FromArchive) { $FromArchive } else { $null })
			parameters = $parameters
		}
		foreach ($serverName in $servers) {
			Write-IaCliLog -Message "Початок аналізу сервера '$serverName'."
			$run = Invoke-IaCliServerRun -Server $serverName -Config $cfg -Context $context
			Complete-IaCliRunOutput -Run $run -Config $cfg
			Write-IaCliLog -Message "Завершено аналіз сервера '$($run.requestedServer)': статус $($run.status), код $($run.exitCode)."
			$results.Add($run)
		}

		# 5. Найгірший код серед запусків.
		foreach ($run in $results) {
			if ([int]$run.exitCode -gt $exitCode) {
				$exitCode = [int]$run.exitCode
			}
		}
	}
	catch {
		Write-IaCliError -Message "Непередбачена помилка: $($_.Exception.Message)" -ErrorId 'IaUnexpected'
		$exitCode = [int]$exitCodes.Unexpected
	}
	finally {
		if ($sessionStarted) {
			try {
				Stop-IaSession | Out-Null
			}
			catch {
				Write-Warning "Не вдалося завершити сесію: $($_.Exception.Message)"
			}
		}
		$global:LASTEXITCODE = $exitCode
	}
	if ($PassThru) {
		return , @($results.ToArray())
	}
}
