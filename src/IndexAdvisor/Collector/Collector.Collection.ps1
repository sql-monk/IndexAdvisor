# Повний збір snapshot для одного запитаного сервера (ТЗ 4.1, 4.3.1, 4.7; CONTRACTS.md 3.2, 5.1).
# Лише SELECT із системних каталогів, DMV і Query Store через Invoke-IaSqlQuery; цільові бази не змінюються.

function ConvertTo-IaColPlainObject {
	<# Рекурсивно перетворює List/HashSet на масиви й копіює словники в [ordered] (спільні посилання стають окремими копіями). #>
	param($Value)
	if ($null -eq $Value) {
		return $null
	}
	if ($Value -is [System.Collections.IDictionary]) {
		$copy = [ordered]@{}
		foreach ($key in $Value.Keys) {
			$copy[$key] = ConvertTo-IaColPlainObject $Value[$key]
		}
		return $copy
	}
	if ($Value -is [string]) {
		return $Value
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		$items = [System.Collections.Generic.List[object]]::new()
		foreach ($item in $Value) {
			$items.Add((ConvertTo-IaColPlainObject $item))
		}
		return , $items.ToArray()
	}
	return $Value
}

function Get-IaColInstanceTargets {
	<# Інстанси для прямого підключення: для AG — кожна репліка (вторинна з ALLOW_CONNECTIONS = NO пропускається з skipReason),
	   для Standalone і FCI — вказаний інстанс. #>
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Topology,
		[Parameter(Mandatory)][string]$RequestedServer,
		[Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Warnings
	)
	if ($Topology.type -ne 'AG') {
		return , @(@{ server = $RequestedServer; replicas = @() })
	}
	$targets = [ordered]@{}
	foreach ($group in $Topology.availabilityGroups) {
		foreach ($replica in $group.replicas) {
			if ($replica.role -eq 'SECONDARY' -and $replica.secondaryAllowConnections -eq 'NO') {
				$replica.collected = $false
				$replica.skipReason = 'Вторинна репліка з ALLOW_CONNECTIONS = NO: бази AG недоступні для читання, репліку пропущено'
				Add-IaColWarning -List $Warnings -Code 'ReplicaSkipped' -Server $replica.replicaServerName -Show -Message (
					"Репліку '{0}' групи '{1}' пропущено: {2}." -f $replica.replicaServerName, $group.name, $replica.skipReason)
				continue
			}
			$key = $replica.replicaServerName.ToLowerInvariant()
			if (-not $targets.Contains($key)) {
				# Підключення за повним іменем (connectAddress), якщо його визначено: коротке ім'я репліки поза доменом не резолвиться.
				$address = if ($replica.connectAddress) { [string]$replica.connectAddress } else { $replica.replicaServerName }
				$targets[$key] = @{ server = $address; replicas = [System.Collections.Generic.List[object]]::new() }
			}
			$targets[$key].replicas.Add(@{ ag = $group.name; replica = $replica })
		}
	}
	return , @($targets.Values)
}

function Update-IaColReplicaState {
	<# Після збору інстансу уточнює роль репліки (UNKNOWN, якщо топологію бачили з вторинної) і позначає collected. #>
	param([Parameter(Mandatory)][hashtable]$Target, [Parameter(Mandatory)][hashtable]$AgRoles, [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Warnings)
	foreach ($entry in $Target.replicas) {
		$replica = $entry.replica
		$local = $AgRoles[$entry.ag]
		if ($local -and $local.role -in @('PRIMARY', 'SECONDARY', 'RESOLVING') -and $replica.role -eq 'UNKNOWN') {
			$replica.role = $local.role
		}
		if ($local -and $local.role -eq 'SECONDARY' -and $local.allow -eq 'NO') {
			$replica.collected = $false
			$replica.skipReason = 'Вторинна репліка з ALLOW_CONNECTIONS = NO: бази AG недоступні для читання, репліку пропущено'
			Add-IaColWarning -List $Warnings -Code 'ReplicaSkipped' -Server $replica.replicaServerName -Message (
				"Бази групи '{0}' на репліці '{1}' не зібрано: {2}." -f $entry.ag, $replica.replicaServerName, $replica.skipReason)
		}
		else {
			$replica.collected = $true
			$replica.skipReason = $null
		}
	}
}

function Get-IaColLastFailover {
	<# Час останньої зміни ролі репліки (failover) з AlwaysOn_health лише SELECT-ом; недоступно — $null з попередженням. #>
	param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Warnings)
	$result = Invoke-IaColQuery -Name 'last_failover' -Server $Server -Database 'master' -Config $Config -PageSize 200 -SinglePage
	if (-not $result.success) {
		Add-IaColWarning -List $Warnings -Code 'LastFailoverUnknown' -Server $Server -Dataset 'instanceStartTime' -Message (
			"Час останнього failover невідомий (сесія AlwaysOn_health недоступна: {0}); період рахується від запуску інстансу." -f $result.error.message)
		return $null
	}
	$roleOf = {
		param([string]$Data, [string]$Name)
		$match = [regex]::Match($Data, ('(?is)<data name="{0}">.*?<text>(?:<!\[CDATA\[)?\s*(?<v>[A-Z_]+)' -f $Name))
		if ($match.Success) { return ($match.Groups['v'].Value -split '_')[0] }
		return $null
	}
	foreach ($row in $result.rows) {
		$data = [string](Get-IaColValue $row 'eventData')
		$previous = & $roleOf $data 'previous_state'
		$current = & $roleOf $data 'current_state'
		if ($current -in @('PRIMARY', 'SECONDARY') -and $previous -and $previous -ne $current) {
			return ConvertTo-IaColUtc (Get-IaColValue $row 'eventTimeUtc')
		}
	}
	return $null
}

function Invoke-IaColDatabase {
	<# Збір вибраних наборів однієї бази. Помилка обов'язкової структури — виняток (база пропускається з попередженням). #>
	param(
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][string]$ServerName,
		[Parameter(Mandatory)]$DbRow,
		[string]$Intent,
		[Parameter(Mandatory)][hashtable]$Context,
		[Parameter(Mandatory)][hashtable]$QsUsage
	)
	$name = [string](Get-IaColValue $DbRow 'databaseName')
	$role = [string](Get-IaColValue $DbRow 'replicaRole')
	$agName = Get-IaColValue $DbRow 'availabilityGroup'
	$database = [ordered]@{
		name = $name
		databaseId = ConvertTo-IaColLong (Get-IaColValue $DbRow 'databaseId')
		compatibilityLevel = ConvertTo-IaColLong (Get-IaColValue $DbRow 'compatibilityLevel') -Default 0
		stateDesc = [string](Get-IaColValue $DbRow 'stateDesc')
		isReadOnly = ConvertTo-IaColBool (Get-IaColValue $DbRow 'isReadOnly')
		recoveryModel = Get-IaColValue $DbRow 'recoveryModel'
		availabilityGroup = $(if ($agName) { [string]$agName } else { $null })
		replicaRole = $(if ($agName -and $role -in @('PRIMARY', 'SECONDARY')) { $role } else { $null })
		replication = $null
		queryStore = $null
		collectedDatasets = [System.Collections.Generic.List[string]]::new()
		tables = [System.Collections.Generic.List[object]]::new()
		missingIndexes = [System.Collections.Generic.List[object]]::new()
		queryStoreQueries = [System.Collections.Generic.List[object]]::new()
		moduleHints = [System.Collections.Generic.List[object]]::new()
		warnings = [System.Collections.Generic.List[object]]::new()
	}
	$dbCtx = @{
		Server = $Server
		ServerName = $ServerName
		Name = $name
		Intent = $Intent
		Config = $Context.Config
		Context = $Context
		Database = $database
		DbRow = $DbRow
		Tables = [ordered]@{}
		TableFlags = @{}
		IndexMap = @{}
		IndexEntries = [System.Collections.Generic.List[object]]::new()
		IndexesByName = @{}
		QsUsage = $QsUsage
		QsCollected = $false
		ConstraintsCollected = $false
	}
	Add-IaColStructure -DbCtx $dbCtx
	$collected = [System.Collections.Generic.HashSet[string]]::new()
	[void]$collected.Add('indexStructure')
	[void]$collected.Add('instanceStartTime')
	$enabled = $Context.Enabled
	if ($enabled.Contains('usageStats') -and (Add-IaColUsage -DbCtx $dbCtx)) {
		[void]$collected.Add('usageStats')
	}
	if ($enabled.Contains('operationalStats') -and (Add-IaColOperational -DbCtx $dbCtx)) {
		[void]$collected.Add('operationalStats')
	}
	if ($enabled.Contains('sizeAndFragmentation') -and (Add-IaColSize -DbCtx $dbCtx)) {
		[void]$collected.Add('sizeAndFragmentation')
	}
	if ($enabled.Contains('missingIndexes') -and (Add-IaColMissingIndexes -DbCtx $dbCtx)) {
		[void]$collected.Add('missingIndexes')
	}
	if ($enabled.Contains('constraintsAndReplication') -and (Add-IaColConstraints -DbCtx $dbCtx)) {
		$dbCtx.ConstraintsCollected = $true
		[void]$collected.Add('constraintsAndReplication')
	}
	if ($enabled.Contains('queryStore') -and (Add-IaColQueryStore -DbCtx $dbCtx)) {
		$dbCtx.QsCollected = $true
		[void]$collected.Add('queryStore')
	}
	foreach ($datasetName in $script:IaDatasetNames) {
		if ($collected.Contains($datasetName)) {
			$database.collectedDatasets.Add($datasetName)
		}
	}
	return $dbCtx
}

function Invoke-IaColInstance {
	<# Збір одного інстансу (репліки) напряму: відомості, час запуску, failover (AG), бази в межах scope. #>
	param([Parameter(Mandatory)][hashtable]$Target, [Parameter(Mandatory)][hashtable]$Context)
	$server = $Target.server
	$config = $Context.Config
	$info = Invoke-IaColQuery -Name 'instance_info' -Server $server -Database 'master' -Config $config -SinglePage
	if (-not $info.success -or @($info.rows).Count -eq 0) {
		$message = if ($info.success) { 'запит не повернув рядків' } else { $info.error.message }
		throw ("Відомості про інстанс не зібрано: {0}" -f $message)
	}
	$row = @($info.rows)[0]
	$startTime = ConvertTo-IaColUtc (Get-IaColValue $row 'sqlserverStartTimeUtc')
	if (-not $startTime) {
		throw 'Час запуску інстансу (sqlserver_start_time) не отримано'
	}
	$engineEdition = ConvertTo-IaColLong (Get-IaColValue $row 'engineEdition') -Default 0
	$serverName = [string](Get-IaColValue $row 'serverName')
	if ([string]::IsNullOrEmpty($serverName)) {
		$serverName = $server
	}
	$collectedAt = ConvertTo-IaColUtc (Get-IaColValue $row 'collectedAtUtc')
	$instance = [ordered]@{
		serverName = $serverName
		connectedTo = $server
		productVersion = [string](Get-IaColValue $row 'productVersion')
		edition = [string](Get-IaColValue $row 'productEdition')
		engineEdition = $engineEdition
		supportsOnlineIndexOps = $engineEdition -in @(3, 5, 8)
		sqlserverStartTimeUtc = $startTime
		lastFailoverUtc = $null
		collectedAtUtc = $(if ($collectedAt) { $collectedAt } else { ConvertTo-IaUtcString -Date ([datetime]::UtcNow) })
		agRole = $null
		isClustered = ConvertTo-IaColBool (Get-IaColValue $row 'isClustered')
		databases = [System.Collections.Generic.List[object]]::new()
		warnings = [System.Collections.Generic.List[object]]::new()
	}
	if ($Context.Topology.type -eq 'AG') {
		$instance.lastFailoverUtc = Get-IaColLastFailover -Server $server -Config $config -Warnings $instance.warnings
	}
	$databases = Invoke-IaColQuery -Name 'databases' -Server $server -Database 'master' -Config $config
	if (-not $databases.success) {
		throw ("Перелік баз не зібрано: {0}" -f $databases.error.message)
	}
	$agRoles = @{}
	foreach ($dbRow in $databases.rows) {
		$agName = [string](Get-IaColValue $dbRow 'availabilityGroup')
		if ($agName -and -not $agRoles.ContainsKey($agName)) {
			$agRoles[$agName] = @{ role = [string](Get-IaColValue $dbRow 'replicaRole'); allow = [string](Get-IaColValue $dbRow 'secondaryAllowConnections') }
		}
	}
	foreach ($agName in ($agRoles.Keys | Sort-Object)) {
		if ($agRoles[$agName].role -in @('PRIMARY', 'SECONDARY')) {
			$instance.agRole = $agRoles[$agName].role
			break
		}
	}
	$scope = $Context.Scope
	$usage = @{}
	$dbContexts = [System.Collections.Generic.List[object]]::new()
	foreach ($dbRow in $databases.rows) {
		$name = [string](Get-IaColValue $dbRow 'databaseName')
		if (-not (Test-IaColScopeMatch -Value $name -Include @($scope.databases.include) -Exclude @($scope.databases.exclude))) {
			continue
		}
		$state = [string](Get-IaColValue $dbRow 'stateDesc')
		if ($state -ne 'ONLINE') {
			Add-IaColWarning -List $instance.warnings -Code 'DatabaseNotOnline' -Server $serverName -Database $name -Message (
				"Базу '{0}' пропущено: стан {1}." -f $name, $state)
			continue
		}
		$agName = [string](Get-IaColValue $dbRow 'availabilityGroup')
		$role = [string](Get-IaColValue $dbRow 'replicaRole')
		$allow = [string](Get-IaColValue $dbRow 'secondaryAllowConnections')
		$intent = $null
		if ($agName) {
			if ($role -eq 'SECONDARY') {
				if ($allow -eq 'NO') {
					Add-IaColWarning -List $instance.warnings -Code 'DatabaseSkipped' -Server $serverName -Database $name -Message (
						"Базу '{0}' пропущено: вторинна репліка групи '{1}' з ALLOW_CONNECTIONS = NO." -f $name, $agName)
					continue
				}
				if ($allow -eq 'READ_ONLY') {
					$intent = 'ReadOnly'
				}
			}
			elseif ($role -ne 'PRIMARY') {
				Add-IaColWarning -List $instance.warnings -Code 'DatabaseSkipped' -Server $serverName -Database $name -Message (
					"Базу '{0}' пропущено: роль репліки групи '{1}' — {2}." -f $name, $agName, $(if ($role) { $role } else { 'невідома' }))
				continue
			}
		}
		if ($role -ne 'SECONDARY' -and -not (ConvertTo-IaColBool (Get-IaColValue $dbRow 'hasDbAccess') -Default $true)) {
			Add-IaColWarning -List $instance.warnings -Code 'NoDatabaseAccess' -Server $serverName -Database $name -Message (
				"Базу '{0}' пропущено: штатний логін не має доступу до бази (немає користувача з роллю db_index_advisor)." -f $name)
			continue
		}
		try {
			$dbCtx = Invoke-IaColDatabase -Server $server -ServerName $serverName -DbRow $dbRow -Intent $intent -Context $Context -QsUsage $usage
			$instance.databases.Add($dbCtx.Database)
			$dbContexts.Add($dbCtx)
		}
		catch {
			if ($_.FullyQualifiedErrorId -like 'IaLoginRefused*') {
				throw
			}
			Add-IaColWarning -List $instance.warnings -Code 'DatabaseFailed' -Server $serverName -Database $name -Show -Message (
				"Базу '{0}' на '{1}' не зібрано: {2}" -f $name, $serverName, $_.Exception.Message)
		}
	}
	Set-IaColQueryStoreUsage -DbContexts $dbContexts -Usage $usage
	return @{ instance = $instance; agRoles = $agRoles }
}

function Invoke-IaCollection {
	<# Повний збір для одного запитаного сервера: топологія, підключення до кожної репліки AG напряму, вибрані набори даних
	   у межах scope. AnalysisWindow — результат Get-IaAnalysisWindow (вікно Query Store). Повертає snapshot (contracts/snapshot.schema.json). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[Parameter(Mandatory)][System.Collections.IDictionary]$AnalysisWindow
	)
	$selection = Get-IaDatasetSelection -Config $Config
	$warnings = [System.Collections.Generic.List[object]]::new()
	$windowFrom = ConvertTo-IaColDateTime $AnalysisWindow.fromUtc
	$windowTo = ConvertTo-IaColDateTime $AnalysisWindow.toUtc
	if ($null -eq $windowFrom -or $null -eq $windowTo -or $windowTo -le $windowFrom) {
		throw [System.ArgumentException]::new('AnalysisWindow: fromUtc і toUtc обов''язкові, toUtc має бути пізніше за fromUtc')
	}
	$snapshot = [ordered]@{
		schemaVersion = '1.0'
		snapshotId = [guid]::NewGuid().ToString()
		toolVersion = [string]$script:IaToolVersion
		collectedAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
		requestedServer = $Server
		analysisWindow = [ordered]@{
			fromUtc = ConvertTo-IaUtcString -Date $windowFrom
			toUtc = ConvertTo-IaUtcString -Date $windowTo
			mode = $(if ($AnalysisWindow.mode -in @('Days', 'PreviousMonth')) { [string]$AnalysisWindow.mode } else { 'Days' })
			reason = $(if ($null -ne $AnalysisWindow.reason) { [string]$AnalysisWindow.reason } else { $null })
		}
		topology = $null
		datasets = [ordered]@{
			enabled = @($selection.enabled)
			disabled = @($selection.disabled)
			warnings = @(
				foreach ($item in $selection.warnings) {
					New-IaColWarning -Code $item.code -Message $item.message -Dataset $item.dataset -Server $Server
				}
			)
		}
		masking = [ordered]@{ namesMasked = $false; literalsMasked = $false }
		instances = @()
		warnings = $warnings
	}
	$topology = Get-IaTopology -Server $Server -Config $Config
	$snapshot.topology = $topology
	$enabled = [System.Collections.Generic.HashSet[string]]::new()
	foreach ($name in $selection.enabled) {
		[void]$enabled.Add($name)
	}
	$context = @{
		Config = $Config
		Enabled = $enabled
		Scope = $Config.scope
		Topology = $topology
		WindowFrom = $windowFrom
		WindowTo = $windowTo
		WindowDays = ($windowTo - $windowFrom).TotalDays
	}
	$instances = [System.Collections.Generic.List[object]]::new()
	foreach ($target in (Get-IaColInstanceTargets -Topology $topology -RequestedServer $Server -Warnings $warnings)) {
		try {
			$collected = Invoke-IaColInstance -Target $target -Context $context
			$instances.Add($collected.instance)
			Update-IaColReplicaState -Target $target -AgRoles $collected.agRoles -Warnings $warnings
		}
		catch {
			if ($_.FullyQualifiedErrorId -like 'IaLoginRefused*') {
				throw
			}
			$message = "Збір з інстансу '{0}' не виконано: {1}" -f $target.server, $_.Exception.Message
			Add-IaColWarning -List $warnings -Code 'InstanceFailed' -Server $target.server -Message $message -Show
			foreach ($entry in $target.replicas) {
				$entry.replica.collected = $false
				$entry.replica.skipReason = $message
			}
		}
	}
	if ($instances.Count -eq 0) {
		Stop-IaColWithError -ErrorId 'IaCollectionFailed' -Message ("Для сервера '{0}' не зібрано жодного інстансу. {1}" -f $Server, (@($warnings | ForEach-Object { $_.message }) -join ' '))
	}
	$snapshot.instances = $instances
	return ConvertTo-IaColPlainObject $snapshot
}
