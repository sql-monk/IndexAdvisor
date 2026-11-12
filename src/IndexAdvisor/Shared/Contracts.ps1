# Спільні контракти IndexAdvisor: константи та конструктори канонічних об'єктів.
# Власник — оркестратор. Субагенти НЕ змінюють цей файл; потрібна зміна — зупинитися й повідомити оркестратора.
# Усі об'єкти даних — вкладені [ordered] хеш-таблиці з JSON-сумісними значеннями; дати — рядки ISO 8601 UTC.

$script:IaSchemaVersion = '1.0'
$script:IaDatasetNames = @(
	'indexStructure', 'instanceStartTime', 'usageStats', 'operationalStats',
	'sizeAndFragmentation', 'missingIndexes', 'queryStore', 'constraintsAndReplication'
)
$script:IaMandatoryDatasets = @('indexStructure', 'instanceStartTime')
$script:IaActions = @('CreateIndex', 'DropIndex', 'AlterIndex', 'PartitionTable', 'AlterPartitioning')
$script:IaModules = @('Indexes', 'Partitioning')
$script:IaExitCodes = [ordered]@{
	Success = 0
	SuccessWithWarnings = 1
	ConfigError = 2
	ConnectionRefused = 3
	CollectionFailed = 4
	LlmFailed = 5
	RepositoryFailed = 6
	Unexpected = 9
}
$script:IaErrorCodes = @(
	'ArgumentInvalid', 'CommandTooLong', 'NotSingleSelect', 'ForbiddenSource', 'UnknownParameter',
	'MissingParameter', 'LoginRefused', 'ConnectionFailed', 'SqlError', 'Timeout'
)
$script:IaConfigSchemaCache = $null

function Get-IaConfigSchema {
	<# Повертає схему конфігурації (Shared/ConfigSchema.psd1), кешовану в модулі. #>
	[CmdletBinding()]
	param()
	if ($null -eq $script:IaConfigSchemaCache) {
		$script:IaConfigSchemaCache = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'ConfigSchema.psd1')
	}
	return $script:IaConfigSchemaCache
}

function ConvertTo-IaDefaultValue {
	<# Внутрішня: значення за замовчуванням для вузла схеми. #>
	param([Parameter(Mandatory)][hashtable]$Node)
	switch ($Node.Type) {
		'object' {
			$result = [ordered]@{}
			foreach ($child in $Node.Properties) {
				if ($child.Type -eq 'object' -or $child.ContainsKey('Default')) {
					$result[$child.Name] = ConvertTo-IaDefaultValue -Node $child
				}
			}
			return $result
		}
		'array' {
			return , @($Node.Default)
		}
		'map' {
			return [ordered]@{}
		}
		default {
			return $Node.Default
		}
	}
}

function Get-IaDefaultConfig {
	<# Повертає повну конфігурацію зі значеннями за замовчуванням (вкладені [ordered] хеш-таблиці). #>
	[CmdletBinding()]
	param()
	return ConvertTo-IaDefaultValue -Node (Get-IaConfigSchema)
}

function ConvertTo-IaUtcString {
	<# Дата -> 'yyyy-MM-ddTHH:mm:ss.fffZ' (UTC). $null і DBNull -> $null. Рядок розбирається як дата. #>
	[CmdletBinding()]
	param([Parameter(ValueFromPipeline)][AllowNull()]$Date)
	process {
		if ($null -eq $Date -or $Date -is [System.DBNull]) {
			return $null
		}
		$utc = switch ($Date) {
			{ $_ -is [System.DateTimeOffset] } { $_.UtcDateTime; break }
			{ $_ -is [datetime] } {
				if ($_.Kind -eq [System.DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($_, [System.DateTimeKind]::Utc) } else { $_.ToUniversalTime() }
				break
			}
			default { [System.DateTimeOffset]::Parse([string]$_, [cultureinfo]::InvariantCulture).UtcDateTime }
		}
		return $utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)
	}
}

function Get-IaObjectKey {
	<# Ключ об'єкта для історії: 'server|database|schema.table|index' у нижньому регістрі (index порожній для таблиці).
	   Для AG як server використовується ім'я AG, для standalone/FCI — @@SERVERNAME. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][string]$Database,
		[Parameter(Mandatory)][string]$Schema,
		[Parameter(Mandatory)][string]$Table,
		[AllowEmptyString()][AllowNull()][string]$Index
	)
	return ('{0}|{1}|{2}.{3}|{4}' -f $Server, $Database, $Schema, $Table, $Index).ToLowerInvariant()
}

function New-IaTarget {
	<# Канонічна ціль рекомендації чи знахідки. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][string]$Database,
		[Parameter(Mandatory)][string]$Schema,
		[Parameter(Mandatory)][string]$Table,
		[AllowEmptyString()][AllowNull()][string]$Index
	)
	return [ordered]@{
		server = $Server
		database = $Database
		schema = $Schema
		table = $Table
		index = $(if ([string]::IsNullOrEmpty($Index)) { $null } else { $Index })
		objectKey = Get-IaObjectKey -Server $Server -Database $Database -Schema $Schema -Table $Table -Index $Index
	}
}

function New-IaResponse {
	<# Конверт відповіді конвеєра SQL (розділ 4.7). Заповнює Core. #>
	[CmdletBinding()]
	param(
		[AllowEmptyString()][AllowNull()][string]$Server,
		[AllowEmptyString()][AllowNull()][string]$Database,
		[string]$RequestId = ([guid]::NewGuid().ToString())
	)
	return [ordered]@{
		success = $false
		requestId = $RequestId
		server = $Server
		database = $Database
		durationMs = 0
		rowCount = 0
		truncated = $false
		columns = @()
		rows = @()
		messages = @()
		error = $null
	}
}

function New-IaError {
	<# Об'єкт помилки для конверта: code — один із $script:IaErrorCodes. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Code,
		[Parameter(Mandatory)][string]$Message,
		[Nullable[int]]$Line,
		[Nullable[int]]$Column
	)
	return [ordered]@{ code = $Code; message = $Message; line = $Line; column = $Column }
}

function New-IaFinding {
	<# Канонічна знахідка rules engine. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$RuleId,
		[Parameter(Mandatory)][ValidateSet('Info', 'Low', 'Medium', 'High')][string]$Severity,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Target,
		[Parameter(Mandatory)][string]$Message,
		[System.Collections.IDictionary]$Details = [ordered]@{},
		[string[]]$RelatedIndexes = @(),
		[ValidateSet('CreateIndex', 'DropIndex', 'AlterIndex', 'PartitionTable', 'AlterPartitioning', 'None')][string]$SuggestedAction = 'None'
	)
	return [ordered]@{
		findingId = [guid]::NewGuid().ToString()
		ruleId = $RuleId
		severity = $Severity
		target = $Target
		relatedIndexes = @($RelatedIndexes)
		message = $Message
		details = $Details
		suggestedAction = $SuggestedAction
	}
}

function New-IaRecommendation {
	<# Канонічна рекомендація (contracts/recommendation.schema.json) з чернетки моделі
	   (contracts/llm-response.schema.json -> recommendations[i]) або модуля партиціонування. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Draft,
		[Parameter(Mandatory)][string]$RunId,
		[Parameter(Mandatory)][ValidateSet('Indexes', 'Partitioning')][string]$Module,
		[ValidateSet('Llm', 'Rules')][string]$Source = 'Llm',
		[System.Collections.IDictionary]$Llm
	)
	$draftTarget = $Draft['target']
	$target = New-IaTarget -Server $draftTarget['server'] -Database $draftTarget['database'] -Schema $draftTarget['schema'] -Table $draftTarget['table'] -Index $draftTarget['index']
	$risk = $Draft['risk']
	return [ordered]@{
		recommendationId = [guid]::NewGuid().ToString()
		runId = $RunId
		module = $Module
		action = [string]$Draft['action']
		source = $Source
		target = $target
		title = [string]$Draft['title']
		rationale = [string]$Draft['rationale']
		risk = [ordered]@{
			level = $(if ($risk) { [string]$risk['level'] } else { 'High' })
			description = $(if ($risk) { [string]$risk['description'] } else { '' })
		}
		impact = [ordered]@{
			estimatedSizeMb = $null
			estimatedBuildMinutes = $null
			tableWritesPerDay = $null
			affectedQueryIds = @($Draft['affectedQueryIds'] | Where-Object { $null -ne $_ })
			notes = $null
		}
		executeScript = [string]$Draft['executeScript']
		rollbackScript = [string]$Draft['rollbackScript']
		replacesIndexes = @($Draft['replacesIndexes'] | Where-Object { $null -ne $_ })
		partitioning = $Draft['partitioning']
		confidence = $(if ($Draft['confidence']) { [string]$Draft['confidence'] } else { $null })
		dataPeriod = $null
		dropEligibility = $null
		validation = [ordered]@{ status = 'NotValidated'; checks = @() }
		crossCheck = $null
		llm = $Llm
		warnings = @()
		createdAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
	}
}

function New-IaRunResult {
	<# Канонічний результат запуску (один запуск = один запитаний сервер). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$RequestedServer,
		[Parameter(Mandatory)][ValidateSet('Indexes', 'Partitioning', 'Both')][string]$Module,
		[System.Collections.IDictionary]$Parameters = [ordered]@{}
	)
	return [ordered]@{
		runId = [guid]::NewGuid().ToString()
		module = $Module
		requestedServer = $RequestedServer
		startedAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
		finishedAtUtc = $null
		startedBy = [System.Environment]::UserDomainName + '\' + [System.Environment]::UserName
		hostName = [System.Environment]::MachineName
		toolVersion = $script:IaToolVersion
		parameters = $Parameters
		fromArchive = $null
		archivePath = $null
		analysisWindow = $null
		topology = $null
		datasets = $null
		dataPeriods = @()
		masking = [ordered]@{ namesMasked = $false; literalsMasked = $true }
		unsafeFlags = @()
		loginCheck = $null
		promptTemplates = @()
		llm = [ordered]@{
			provider = $null
			model = $null
			crossCheckProvider = $null
			notes = @()
			calls = @()
			totalInputTokens = 0
			totalOutputTokens = 0
			totalCostUsd = 0
		}
		toolRequests = @()
		findings = @()
		recommendations = @()
		verdicts = @()
		warnings = @()
		errors = @()
		status = 'Succeeded'
		exitCode = 0
	}
}

function Copy-IaObject {
	<# Глибока копія JSON-сумісного об'єкта (через JSON). Повертає [ordered] хеш-таблиці. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][AllowNull()]$InputObject)
	if ($null -eq $InputObject) {
		return $null
	}
	$json = ConvertTo-Json -InputObject $InputObject -Depth 100 -Compress
	return , (ConvertFrom-Json -InputObject $json -AsHashtable -Depth 100)
}
