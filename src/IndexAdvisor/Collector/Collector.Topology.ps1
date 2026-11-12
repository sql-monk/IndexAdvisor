# Визначення топології (Standalone, FCI, AG) і вибір наборів даних (ТЗ 4.1, 4.7; CONTRACTS.md 3.2).

function Get-IaColDnsSuffix {
	<# DNS-суфікс імені сервера ('agl-dwh.contoso.local,1433' → 'contoso.local'); для короткого імені чи IP-адреси — $null. #>
	param([AllowEmptyString()][AllowNull()][string]$Name)
	if ([string]::IsNullOrWhiteSpace($Name)) {
		return $null
	}
	$hostName = ((($Name.Trim() -replace '^tcp:', '') -split '[\\,]')[0]).Trim()
	$address = $null
	if ([System.Net.IPAddress]::TryParse($hostName, [ref]$address)) {
		return $null
	}
	$dot = $hostName.IndexOf('.')
	if ($dot -le 0 -or $dot -eq $hostName.Length - 1) {
		return $null
	}
	return $hostName.Substring($dot + 1)
}

function Resolve-IaColReplicaAddress {
	<# Адреса прямого підключення до репліки AG. replica_server_name зазвичай коротке NetBIOS-ім'я ('SQL01' або 'SQL01\INST'),
	   яке поза доменом не резолвиться. Порядок: FQDN хоста з read_only_routing_url чи endpoint_url, якщо він починається
	   з імені репліки; інакше домен запитаного сервера чи listener. Повертає 'fqdn[\інстанс]' або $null (підключення за replicaServerName). #>
	param(
		[Parameter(Mandatory)][string]$ReplicaName,
		[AllowEmptyString()][AllowNull()][string]$ReadOnlyRoutingUrl,
		[AllowEmptyString()][AllowNull()][string]$EndpointUrl,
		[AllowEmptyString()][AllowNull()][string]$RequestedServer,
		[AllowEmptyString()][AllowNull()][string]$ListenerName
	)
	$parts = $ReplicaName.Split('\', 2)
	$shortHost = $parts[0]
	$instancePart = if ($parts.Count -gt 1) { '\' + $parts[1] } else { '' }
	if ([string]::IsNullOrWhiteSpace($shortHost) -or $shortHost.Contains('.')) {
		return $null
	}
	foreach ($url in @($ReadOnlyRoutingUrl, $EndpointUrl)) {
		$match = [regex]::Match([string]$url, '^\s*tcp://(?<host>[^:/\s]+)', 'IgnoreCase')
		if ($match.Success -and $match.Groups['host'].Value.StartsWith("$shortHost.", [System.StringComparison]::OrdinalIgnoreCase)) {
			return $match.Groups['host'].Value + $instancePart
		}
	}
	foreach ($name in @($RequestedServer, $ListenerName)) {
		$suffix = Get-IaColDnsSuffix -Name $name
		if ($suffix) {
			return "$shortHost.$suffix$instancePart"
		}
	}
	return $null
}

function Get-IaTopology {
	<# Одним SELECT визначає топологію (Standalone, FCI, AG) вказаного інстансу чи listener.
	   Повертає об'єкт topology зі схеми contracts/snapshot.schema.json. Недоступний сервер — виняток IaCollectionFailed. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$result = Invoke-IaColQuery -Name 'topology' -Server $Server -Database 'master' -Config $Config -Purpose Topology
	if (-not $result.success) {
		Stop-IaColWithError -ErrorId 'IaCollectionFailed' -Message ("Не вдалося визначити топологію сервера '{0}': {1}" -f $Server, $result.error.message)
	}
	$rows = @($result.rows)
	if ($rows.Count -eq 0) {
		Stop-IaColWithError -ErrorId 'IaCollectionFailed' -Message ("Запит топології сервера '{0}' не повернув рядків" -f $Server)
	}
	$first = $rows[0]
	$isHadrEnabled = ConvertTo-IaColBool (Get-IaColValue $first 'isHadrEnabled')
	$isClustered = ConvertTo-IaColBool (Get-IaColValue $first 'isClustered')
	$groups = [ordered]@{}
	foreach ($row in $rows) {
		$agName = [string](Get-IaColValue $row 'agName')
		if ([string]::IsNullOrEmpty($agName)) {
			continue
		}
		if (-not $groups.Contains($agName)) {
			$groups[$agName] = [ordered]@{
				name = $agName
				listenerName = $null
				replicas = [System.Collections.Generic.List[object]]::new()
				replicaNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
			}
		}
		$group = $groups[$agName]
		$listener = Get-IaColValue $row 'listenerName'
		if ($null -eq $group.listenerName -and -not [string]::IsNullOrEmpty([string]$listener)) {
			$group.listenerName = [string]$listener
		}
		$replicaName = [string](Get-IaColValue $row 'replicaServerName')
		if ([string]::IsNullOrEmpty($replicaName) -or -not $group.replicaNames.Add($replicaName)) {
			continue
		}
		$role = [string](Get-IaColValue $row 'roleDesc')
		if ($role -notin @('PRIMARY', 'SECONDARY', 'RESOLVING')) {
			$role = 'UNKNOWN'
		}
		$allow = [string](Get-IaColValue $row 'secondaryAllowConnections')
		if ($allow -notin @('NO', 'READ_ONLY', 'ALL')) {
			$allow = 'NO'
		}
		$mode = Get-IaColValue $row 'availabilityMode'
		$connectAddress = Resolve-IaColReplicaAddress -ReplicaName $replicaName -ReadOnlyRoutingUrl (Get-IaColValue $row 'readOnlyRoutingUrl') `
			-EndpointUrl (Get-IaColValue $row 'endpointUrl') -RequestedServer $Server -ListenerName ([string]$listener)
		$group.replicas.Add([ordered]@{
				replicaServerName = $replicaName
				connectAddress = $connectAddress
				role = $role
				availabilityMode = $(if ($null -ne $mode) { [string]$mode } else { $null })
				secondaryAllowConnections = $allow
				isConnected = ([string](Get-IaColValue $row 'connectedState')) -eq 'CONNECTED'
				collected = $false
				skipReason = $null
			})
	}
	$availabilityGroups = @(
		foreach ($group in $groups.Values) {
			[ordered]@{ name = $group.name; listenerName = $group.listenerName; replicas = @($group.replicas.ToArray()) }
		}
	)
	$type = if ($isHadrEnabled -and $availabilityGroups.Count -gt 0) { 'AG' } elseif ($isClustered) { 'FCI' } else { 'Standalone' }
	$serverName = Get-IaColValue $first 'serverName'
	return [ordered]@{
		type = $type
		requestedServer = $Server
		serverName = $(if ($null -ne $serverName) { [string]$serverName } else { $null })
		isHadrEnabled = $isHadrEnabled
		isClustered = $isClustered
		availabilityGroups = $availabilityGroups
	}
}

$script:IaColDatasetWarnings = [ordered]@{
	usageStats = 'Набір usageStats вимкнено: seeks, scans, lookups і updates з sys.dm_db_index_usage_stats не зібрано; невикористовувані та write-only індекси визначаються лише за Query Store, рекомендації на видалення менш достовірні.'
	operationalStats = 'Набір operationalStats вимкнено: блокування, latch і page splits не оцінюються; «дорогі» індекси для пом''якшених правил визначаються лише за співвідношенням записів і читань (usageStats).'
	sizeAndFragmentation = 'Набір sizeAndFragmentation вимкнено: розмір, кількість рядків і фрагментація невідомі; оцінка розміру й часу побудови нових індексів та рекомендації щодо фрагментації неможливі.'
	missingIndexes = 'Набір missingIndexes вимкнено: кандидати на створення визначаються лише з планів Query Store.'
	queryStore = 'Набір queryStore вимкнено: рекомендація на видалення лише позначає, що індекс не використовувався за період роботи сервера за даними DMV; використання в планах, хінти в текстах запитів і профіль навантаження не перевіряються.'
	constraintsAndReplication = 'Набір constraintsAndReplication вимкнено: залежності FK, реплікація та хінти в коді не перевіряються, тому умови безпечного видалення (розділ 4.4) вважаються невиконаними.'
}

function Get-IaDatasetSelection {
	<# Вибір наборів даних з collector.datasets. Обов'язкові набори завжди ввімкнені (з попередженням, якщо їх вимкнули).
	   Повертає @{ enabled = @(); disabled = @(); warnings = @(@{ dataset; code; message }) } — warnings про зниження достовірності. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$datasets = if ($Config.collector -and $Config.collector.datasets) { $Config.collector.datasets } else { @{} }
	$enabled = [System.Collections.Generic.List[string]]::new()
	$disabled = [System.Collections.Generic.List[string]]::new()
	$warnings = [System.Collections.Generic.List[object]]::new()
	foreach ($name in $script:IaDatasetNames) {
		$value = $datasets[$name]
		$isOn = if ($null -eq $value) { $true } else { ConvertTo-IaColBool $value -Default $true }
		if ($name -in $script:IaMandatoryDatasets) {
			$enabled.Add($name)
			if (-not $isOn) {
				$warnings.Add([ordered]@{
						dataset = $name
						code = 'MandatoryDatasetForced'
						message = "Набір $name обов'язковий (без нього аналіз неможливий) і збирається завжди, попри значення false у конфігурації."
					})
			}
			continue
		}
		if ($isOn) {
			$enabled.Add($name)
		}
		else {
			$disabled.Add($name)
			$warnings.Add([ordered]@{ dataset = $name; code = 'DatasetDisabled'; message = $script:IaColDatasetWarnings[$name] })
		}
	}
	return [ordered]@{
		enabled = @($enabled.ToArray())
		disabled = @($disabled.ToArray())
		warnings = @($warnings.ToArray())
	}
}
