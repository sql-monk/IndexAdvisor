# Репозиторій рекомендацій (CONTRACTS.md, розділ 8): запис запусків, історія вердиктів, очищення.
# Запис дозволено лише в базу repository.database і лише параметризованими командами через шов Invoke-IaOutRepositoryCommand.
# Відмова, якщо база-репозиторій збігається з цільовою базою на тому самому сервері. Сирі дані DMV і Query Store сюди не потрапляють.

function Initialize-IaOutSqlClient {
	<# Завантажує Microsoft.Data.SqlClient з dbatools.library, якщо типи ще не завантажені. #>
	[CmdletBinding()]
	param()
	if ('Microsoft.Data.SqlClient.SqlConnection' -as [type]) {
		return
	}
	try {
		Import-Module -Name 'dbatools.library' -ErrorAction Stop | Out-Null
	}
	catch {
		Write-Verbose "dbatools.library не імпортовано: $($_.Exception.Message)"
	}
	if ('Microsoft.Data.SqlClient.SqlConnection' -as [type]) {
		return
	}
	$library = Get-Module -ListAvailable -Name 'dbatools.library' | Sort-Object Version -Descending | Select-Object -First 1
	if (-not $library) {
		throw 'Не знайдено модуль dbatools.library з Microsoft.Data.SqlClient.'
	}
	Add-Type -Path (Join-Path $library.ModuleBase 'core/lib/Microsoft.Data.SqlClient.dll')
}

function New-IaOutRepositoryConnectionString {
	<# Рядок підключення до репозиторію без пароля (пароль передається окремо як SqlCredential). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$repository = $Config.repository
	if ([string]::IsNullOrWhiteSpace($repository.server)) {
		throw 'Не задано сервер репозиторію (repository.server).'
	}
	if ([string]::IsNullOrWhiteSpace($repository.database)) {
		throw 'Не задано базу репозиторію (repository.database).'
	}
	$builder = [System.Data.Common.DbConnectionStringBuilder]::new()
	$builder['Data Source'] = [string]$repository.server
	$builder['Initial Catalog'] = [string]$repository.database
	if ($repository.authentication -eq 'Windows') {
		$builder['Integrated Security'] = 'True'
	}
	$builder['Encrypt'] = [string]$repository.encrypt
	$builder['Trust Server Certificate'] = $(if ($repository.trustServerCertificate) { 'True' } else { 'False' })
	$builder['Application Name'] = "$($Config.connection.applicationName) (repository)"
	$builder['Connect Timeout'] = [string]$Config.connection.connectTimeoutSeconds
	$builder['Pooling'] = 'False'
	return $builder.ConnectionString
}

function New-IaOutParam {
	<# Опис параметра команди: @{ name; value; sqlType; size; precision; scale }. Значення перетворюються на типи драйвера. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Name,
		[AllowNull()]$Value,
		[Parameter(Mandatory)][ValidateSet('UniqueIdentifier', 'NVarChar', 'VarChar', 'DateTime2', 'Int', 'BigInt', 'Decimal', 'Bit')][string]$SqlType,
		[int]$Size = 0,
		[byte]$Precision = 0,
		[byte]$Scale = 0
	)
	$converted = $null
	if ($null -ne $Value -and -not ($Value -is [string] -and $Value -eq '' -and $SqlType -notin @('NVarChar', 'VarChar'))) {
		switch ($SqlType) {
			'UniqueIdentifier' { $converted = [guid]::Parse([string]$Value) }
			'DateTime2' {
				$converted = if ($Value -is [datetime]) {
					if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
				}
				else {
					[System.DateTimeOffset]::Parse([string]$Value, [cultureinfo]::InvariantCulture).UtcDateTime
				}
			}
			'Int' { $converted = [int]$Value }
			'BigInt' { $converted = [long]$Value }
			'Decimal' { $converted = [decimal]$Value }
			'Bit' { $converted = [bool]$Value }
			default { $converted = [string]$Value }
		}
	}
	return [ordered]@{ name = $(if ($Name.StartsWith('@')) { $Name } else { "@$Name" }); value = $converted; sqlType = $SqlType; size = $Size; precision = $Precision; scale = $Scale }
}

function ConvertTo-IaOutGuid {
	<# Рядок GUID або новий GUID, якщо значення відсутнє чи некоректне (для первинних ключів журналів викликів). #>
	param([AllowNull()]$Value)
	$parsed = [guid]::Empty
	if ($null -ne $Value -and [guid]::TryParse([string]$Value, [ref]$parsed)) {
		return $parsed.ToString()
	}
	return [guid]::NewGuid().ToString()
}

function ConvertTo-IaOutJson {
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return $null
	}
	return (ConvertTo-Json -InputObject $Value -Depth 50 -Compress)
}

function ConvertTo-IaOutServerKey {
	<# Нормалізоване ім'я сервера для порівняння: без протоколу й порту, коротке ім'я хоста, локальні аліаси -> ім'я машини. #>
	param([AllowNull()][string]$Name)
	if ([string]::IsNullOrWhiteSpace($Name)) {
		return ''
	}
	$value = $Name.Trim().ToLowerInvariant()
	$value = $value -replace '^(tcp|np|lpc|admin):', ''
	$value = $value -replace ',\s*\d+$', ''
	$parts = $value.Split('\', 2)
	$hostName = $parts[0]
	$instance = if ($parts.Count -gt 1) { $parts[1] } else { '' }
	if ($hostName -in @('.', '(local)', 'localhost', '127.0.0.1', '::1', '(localdb)')) {
		$hostName = [System.Environment]::MachineName.ToLowerInvariant()
	}
	elseif ($hostName -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
		$hostName = $hostName.Split('.')[0]
	}
	if ($instance -eq 'mssqlserver') {
		$instance = ''
	}
	return $(if ($instance) { "$hostName\$instance" } else { $hostName })
}

function Get-IaOutRunTargetServers {
	<# Усі імена цільового сервера запуску: запитаний сервер, інстанс, AG, listener, репліки, сервери періодів. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$RunResult)
	$names = [System.Collections.Generic.List[string]]::new()
	$names.Add([string]$RunResult.requestedServer)
	$topology = $RunResult.topology
	if ($topology) {
		$names.Add([string]$topology.requestedServer)
		$names.Add([string]$topology.serverName)
		foreach ($group in @($topology.availabilityGroups | Where-Object { $_ })) {
			$names.Add([string]$group.name)
			$names.Add([string]$group.listenerName)
			foreach ($replica in @($group.replicas | Where-Object { $_ })) {
				$names.Add([string]$replica.replicaServerName)
			}
		}
	}
	foreach ($period in @($RunResult.dataPeriods | Where-Object { $_ })) {
		$names.Add([string]$period.server)
	}
	foreach ($rec in @($RunResult.recommendations | Where-Object { $_ })) {
		$names.Add([string]$rec.target.server)
	}
	return @($names | Where-Object { $_ } | ForEach-Object { ConvertTo-IaOutServerKey $_ } | Where-Object { $_ } | Select-Object -Unique)
}

function Assert-IaOutRepositoryTarget {
	<# Відмова записувати, якщо база-репозиторій — одна з цільових баз запуску на тому самому сервері. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[System.Collections.IDictionary]$RunResult
	)
	$repository = $Config.repository
	$repositoryServer = ConvertTo-IaOutServerKey ([string]$repository.server)
	$repositoryDatabase = [string]$repository.database
	if ($RunResult) {
		$servers = Get-IaOutRunTargetServers -RunResult $RunResult
		$databases = @(@($RunResult.dataPeriods | Where-Object { $_ -and $_.database } | ForEach-Object { [string]$_.database }) +
			@($RunResult.recommendations | Where-Object { $_ -and $_.target } | ForEach-Object { [string]$_.target.database }))
		if ($repositoryServer -in $servers -and @($databases | Where-Object { $_ -ieq $repositoryDatabase }).Count -gt 0) {
			throw "Відмова: база-репозиторій '$repositoryDatabase' на сервері '$($repository.server)' є цільовою базою аналізу. Програма не змінює цільові бази; виключіть її з аналізу (scope.databases.exclude) або використайте окрему базу-репозиторій."
		}
		return
	}
	# Без RunResult (очищення історії): перевірка за конфігурацією — сервери з servers і область баз scope.databases.
	$servers = @($Config.servers | Where-Object { $_ } | ForEach-Object { ConvertTo-IaOutServerKey $_ })
	if ($repositoryServer -notin $servers) {
		return
	}
	$include = @($Config.scope.databases.include | Where-Object { $_ })
	$exclude = @($Config.scope.databases.exclude | Where-Object { $_ })
	$included = ($include.Count -eq 0) -or (@($include | Where-Object { $repositoryDatabase -like $_ }).Count -gt 0)
	$excluded = @($exclude | Where-Object { $repositoryDatabase -like $_ }).Count -gt 0
	if ($included -and -not $excluded) {
		throw "Відмова: база-репозиторій '$repositoryDatabase' на сервері '$($repository.server)' входить до області аналізу. Виключіть її (scope.databases.exclude) або використайте окрему базу-репозиторій."
	}
}

function Invoke-IaOutRepositoryCommand {
	<# Шов репозиторію: виконує параметризовані команди в базі repository.database в одній транзакції (Microsoft.Data.SqlClient).
	   Commands — масив @{ commandText; parameters = @(New-IaOutParam ...) }. Mode NonQuery повертає кількість змінених рядків,
	   Reader — рядки останньої команди як [ordered] словники. Пароль (repository.passwordRef) читається Get-IaSecret і передається як SqlCredential. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[Parameter(Mandatory)][object[]]$Commands,
		[ValidateSet('NonQuery', 'Reader')][string]$Mode = 'NonQuery'
	)
	Initialize-IaOutSqlClient
	$connection = [Microsoft.Data.SqlClient.SqlConnection]::new((New-IaOutRepositoryConnectionString -Config $Config))
	if ($Config.repository.authentication -eq 'Sql') {
		$password = Get-IaSecret -Reference ([string]$Config.repository.passwordRef)
		$password.MakeReadOnly()
		$connection.Credential = [Microsoft.Data.SqlClient.SqlCredential]::new([string]$Config.repository.login, $password)
	}
	$transaction = $null
	$affected = 0
	$rows = [System.Collections.Generic.List[object]]::new()
	try {
		$connection.Open()
		$transaction = $connection.BeginTransaction()
		foreach ($definition in $Commands) {
			$command = $connection.CreateCommand()
			$command.Transaction = $transaction
			$command.CommandText = [string]$definition.commandText
			$command.CommandTimeout = [int]$Config.connection.commandTimeoutSeconds
			foreach ($parameter in @($definition.parameters | Where-Object { $_ })) {
				$sqlParameter = [Microsoft.Data.SqlClient.SqlParameter]::new([string]$parameter.name, [System.Data.SqlDbType]$parameter.sqlType)
				if ($parameter.size) {
					$sqlParameter.Size = [int]$parameter.size
				}
				if ($parameter.sqlType -eq 'Decimal') {
					$sqlParameter.Precision = [byte]$parameter.precision
					$sqlParameter.Scale = [byte]$parameter.scale
				}
				$sqlParameter.Value = $(if ($null -eq $parameter.value) { [System.DBNull]::Value } else { $parameter.value })
				[void]$command.Parameters.Add($sqlParameter)
			}
			if ($Mode -eq 'Reader') {
				$rows.Clear()
				$reader = $command.ExecuteReader()
				try {
					while ($reader.Read()) {
						$row = [ordered]@{}
						for ($i = 0; $i -lt $reader.FieldCount; $i++) {
							$row[$reader.GetName($i)] = $(if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) })
						}
						$rows.Add($row)
					}
				}
				finally {
					$reader.Dispose()
				}
			}
			else {
				$affected += $command.ExecuteNonQuery()
			}
			$command.Dispose()
		}
		$transaction.Commit()
	}
	catch {
		if ($null -ne $transaction) {
			try {
				$transaction.Rollback()
			}
			catch {
				Write-Verbose "Відкат транзакції репозиторію не вдався: $($_.Exception.Message)"
			}
		}
		throw
	}
	finally {
		$connection.Dispose()
	}
	if ($Mode -eq 'Reader') {
		return , @($rows.ToArray())
	}
	return $affected
}

function New-IaOutRunCommands {
	<# Параметризовані команди запису запуску. Тексти команд — константи; значення лише в параметрах. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$RunResult)
	$run = $RunResult
	$commands = [System.Collections.Generic.List[object]]::new()
	$runIdParam = { New-IaOutParam -Name 'RunId' -Value $run.runId -SqlType UniqueIdentifier }

	# Повторний запис того самого запуску замінює попередній (ON DELETE CASCADE).
	$commands.Add([ordered]@{ commandText = 'DELETE FROM Advisor.AnalysisRun WHERE RunId = @RunId;'; parameters = @(& $runIdParam) })

	$firstPrompt = @($run.promptTemplates | Where-Object { $_ }) | Select-Object -First 1
	$commands.Add([ordered]@{
			commandText = @'
INSERT INTO Advisor.AnalysisRun (RunId, Module, RequestedServer, StartedAtUtc, FinishedAtUtc, StartedBy, HostName, ToolVersion, ParametersJson, FromArchive,
	ArchivePath, NamesMasked, UnsafeFlags, DatasetsJson, Provider, Model, InputTokens, OutputTokens, CostUsd, Status, ExitCode, WarningsJson)
VALUES (@RunId, @Module, @RequestedServer, @StartedAtUtc, @FinishedAtUtc, @StartedBy, @HostName, @ToolVersion, @ParametersJson, @FromArchive,
	@ArchivePath, @NamesMasked, @UnsafeFlags, @DatasetsJson, @Provider, @Model, @InputTokens, @OutputTokens, @CostUsd, @Status, @ExitCode, @WarningsJson);
'@
			parameters = @(
				(& $runIdParam)
				(New-IaOutParam -Name 'Module' -Value $run.module -SqlType VarChar -Size 20)
				(New-IaOutParam -Name 'RequestedServer' -Value $run.requestedServer -SqlType NVarChar -Size 256)
				(New-IaOutParam -Name 'StartedAtUtc' -Value $run.startedAtUtc -SqlType DateTime2)
				(New-IaOutParam -Name 'FinishedAtUtc' -Value $run.finishedAtUtc -SqlType DateTime2)
				(New-IaOutParam -Name 'StartedBy' -Value $run.startedBy -SqlType NVarChar -Size 256)
				(New-IaOutParam -Name 'HostName' -Value $run.hostName -SqlType NVarChar -Size 256)
				(New-IaOutParam -Name 'ToolVersion' -Value $run.toolVersion -SqlType VarChar -Size 32)
				(New-IaOutParam -Name 'ParametersJson' -Value $(if ($run.parameters) { ConvertTo-IaOutJson $run.parameters } else { '{}' }) -SqlType NVarChar -Size -1)
				(New-IaOutParam -Name 'FromArchive' -Value $run.fromArchive -SqlType NVarChar -Size 1024)
				(New-IaOutParam -Name 'ArchivePath' -Value $run.archivePath -SqlType NVarChar -Size 1024)
				(New-IaOutParam -Name 'NamesMasked' -Value ([bool]($run.masking -and $run.masking.namesMasked)) -SqlType Bit)
				(New-IaOutParam -Name 'UnsafeFlags' -Value $(if (@($run.unsafeFlags).Count) { @($run.unsafeFlags) -join ', ' } else { $null }) -SqlType NVarChar -Size 400)
				(New-IaOutParam -Name 'DatasetsJson' -Value $(if ($run.datasets) { ConvertTo-IaOutJson $run.datasets } else { '{}' }) -SqlType NVarChar -Size -1)
				(New-IaOutParam -Name 'Provider' -Value $run.llm.provider -SqlType NVarChar -Size 100)
				(New-IaOutParam -Name 'Model' -Value $run.llm.model -SqlType NVarChar -Size 200)
				(New-IaOutParam -Name 'InputTokens' -Value ([long]$run.llm.totalInputTokens) -SqlType BigInt)
				(New-IaOutParam -Name 'OutputTokens' -Value ([long]$run.llm.totalOutputTokens) -SqlType BigInt)
				(New-IaOutParam -Name 'CostUsd' -Value ([double]$run.llm.totalCostUsd) -SqlType Decimal -Precision 19 -Scale 6)
				(New-IaOutParam -Name 'Status' -Value $run.status -SqlType VarChar -Size 20)
				(New-IaOutParam -Name 'ExitCode' -Value ([int]$run.exitCode) -SqlType Int)
				(New-IaOutParam -Name 'WarningsJson' -Value $(if (@($run.warnings).Count) { ConvertTo-IaOutJson @($run.warnings) } else { $null }) -SqlType NVarChar -Size -1)
			)
		})

	foreach ($period in @($run.dataPeriods | Where-Object { $_ })) {
		$commands.Add([ordered]@{
				commandText = @'
INSERT INTO Advisor.RunDataPeriod (RunId, ServerName, DatabaseName, SqlServerStartTimeUtc, LastFailoverUtc, StatsFromUtc, StatsToUtc, UptimeDays,
	QueryStoreFromUtc, QueryStoreToUtc, QueryStoreDays, MinRequiredDays, IsSufficient)
VALUES (@RunId, @ServerName, @DatabaseName, @SqlServerStartTimeUtc, @LastFailoverUtc, @StatsFromUtc, @StatsToUtc, @UptimeDays,
	@QueryStoreFromUtc, @QueryStoreToUtc, @QueryStoreDays, @MinRequiredDays, @IsSufficient);
'@
				parameters = @(
					(& $runIdParam)
					(New-IaOutParam -Name 'ServerName' -Value $period.server -SqlType NVarChar -Size 256)
					(New-IaOutParam -Name 'DatabaseName' -Value $period.database -SqlType NVarChar -Size 128)
					(New-IaOutParam -Name 'SqlServerStartTimeUtc' -Value $period.sqlserverStartTimeUtc -SqlType DateTime2)
					(New-IaOutParam -Name 'LastFailoverUtc' -Value $period.lastFailoverUtc -SqlType DateTime2)
					(New-IaOutParam -Name 'StatsFromUtc' -Value $period.statsFromUtc -SqlType DateTime2)
					(New-IaOutParam -Name 'StatsToUtc' -Value $period.statsToUtc -SqlType DateTime2)
					(New-IaOutParam -Name 'UptimeDays' -Value $period.uptimeDays -SqlType Decimal -Precision 9 -Scale 2)
					(New-IaOutParam -Name 'QueryStoreFromUtc' -Value $period.queryStoreFromUtc -SqlType DateTime2)
					(New-IaOutParam -Name 'QueryStoreToUtc' -Value $period.queryStoreToUtc -SqlType DateTime2)
					(New-IaOutParam -Name 'QueryStoreDays' -Value $period.queryStoreDays -SqlType Decimal -Precision 9 -Scale 2)
					(New-IaOutParam -Name 'MinRequiredDays' -Value $period.minRequiredDays -SqlType Int)
					(New-IaOutParam -Name 'IsSufficient' -Value ([bool]$period.isSufficient) -SqlType Bit)
				)
			})
	}

	foreach ($call in @($run.llm.calls | Where-Object { $_ })) {
		$commands.Add([ordered]@{
				commandText = @'
INSERT INTO Advisor.LlmCall (LlmCallId, RunId, Purpose, Provider, Model, PromptTemplateId, PromptTemplateVersion, InputTokens, OutputTokens, CostUsd,
	DurationMs, Success, CreatedAtUtc)
VALUES (@LlmCallId, @RunId, @Purpose, @Provider, @Model, @PromptTemplateId, @PromptTemplateVersion, @InputTokens, @OutputTokens, @CostUsd,
	@DurationMs, @Success, @CreatedAtUtc);
'@
				parameters = @(
					(New-IaOutParam -Name 'LlmCallId' -Value (ConvertTo-IaOutGuid $call.llmCallId) -SqlType UniqueIdentifier)
					(& $runIdParam)
					(New-IaOutParam -Name 'Purpose' -Value $(if ($call.purpose) { $call.purpose } else { 'Analysis' }) -SqlType VarChar -Size 20)
					(New-IaOutParam -Name 'Provider' -Value $(if ($call.provider) { $call.provider } else { [string]$run.llm.provider }) -SqlType NVarChar -Size 100)
					(New-IaOutParam -Name 'Model' -Value $(if ($call.model) { $call.model } else { [string]$run.llm.model }) -SqlType NVarChar -Size 200)
					(New-IaOutParam -Name 'PromptTemplateId' -Value $(if ($call.promptTemplateId) { $call.promptTemplateId } elseif ($firstPrompt) { $firstPrompt.id } else { $null }) -SqlType VarChar -Size 100)
					(New-IaOutParam -Name 'PromptTemplateVersion' -Value $(if ($call.promptTemplateVersion) { $call.promptTemplateVersion } elseif ($firstPrompt) { $firstPrompt.version } else { $null }) -SqlType Int)
					(New-IaOutParam -Name 'InputTokens' -Value ([int]$call.inputTokens) -SqlType Int)
					(New-IaOutParam -Name 'OutputTokens' -Value ([int]$call.outputTokens) -SqlType Int)
					(New-IaOutParam -Name 'CostUsd' -Value ([double]$call.costUsd) -SqlType Decimal -Precision 19 -Scale 6)
					(New-IaOutParam -Name 'DurationMs' -Value ([int]$call.durationMs) -SqlType Int)
					(New-IaOutParam -Name 'Success' -Value ([bool]$call.success) -SqlType Bit)
					(New-IaOutParam -Name 'CreatedAtUtc' -Value $(if ($call.createdAtUtc) { $call.createdAtUtc } else { $run.startedAtUtc }) -SqlType DateTime2)
				)
			})
	}

	foreach ($request in @($run.toolRequests | Where-Object { $_ })) {
		$response = $request.response
		$commands.Add([ordered]@{
				commandText = @'
INSERT INTO Advisor.ToolRequest (ToolRequestId, RunId, LlmCallId, ToolName, ServerName, DatabaseName, ArgumentsJson, Decision, [RowCount], Truncated,
	Success, ExecutedAtUtc)
VALUES (@ToolRequestId, @RunId, @LlmCallId, @ToolName, @ServerName, @DatabaseName, @ArgumentsJson, @Decision, @RowCount, @Truncated,
	@Success, @ExecutedAtUtc);
'@
				parameters = @(
					(New-IaOutParam -Name 'ToolRequestId' -Value (ConvertTo-IaOutGuid $request.toolRequestId) -SqlType UniqueIdentifier)
					(& $runIdParam)
					(New-IaOutParam -Name 'LlmCallId' -Value $(if ($request.llmCallId -and [guid]::TryParse([string]$request.llmCallId, [ref][guid]::Empty)) { $request.llmCallId } else { $null }) -SqlType UniqueIdentifier)
					(New-IaOutParam -Name 'ToolName' -Value $request.tool -SqlType NVarChar -Size 128)
					(New-IaOutParam -Name 'ServerName' -Value $request.server -SqlType NVarChar -Size 256)
					(New-IaOutParam -Name 'DatabaseName' -Value $request.database -SqlType NVarChar -Size 128)
					(New-IaOutParam -Name 'ArgumentsJson' -Value $(if ($request.arguments) { ConvertTo-IaOutJson $request.arguments } else { '{}' }) -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'Decision' -Value $request.decision -SqlType VarChar -Size 20)
					(New-IaOutParam -Name 'RowCount' -Value $(if ($response) { $response.rowCount } else { $null }) -SqlType Int)
					(New-IaOutParam -Name 'Truncated' -Value $(if ($response) { [bool]$response.truncated } else { $null }) -SqlType Bit)
					(New-IaOutParam -Name 'Success' -Value $(if ($response) { [bool]$response.success } else { $null }) -SqlType Bit)
					(New-IaOutParam -Name 'ExecutedAtUtc' -Value $request.executedAtUtc -SqlType DateTime2)
				)
			})
	}

	foreach ($rec in @($run.recommendations | Where-Object { $_ })) {
		$eligibility = $rec.dropEligibility
		$period = $rec.dataPeriod
		$commands.Add([ordered]@{
				commandText = @'
INSERT INTO Advisor.Recommendation (RecommendationId, RunId, Module, Action, Source, ObjectKey, ServerName, DatabaseName, SchemaName, TableName, IndexName,
	Title, Rationale, RiskLevel, RiskDescription, ExecuteScript, RollbackScript, ValidationStatus, ValidationJson, DropEligibilityJson, IsDropEligible,
	RulesProfile, CrossCheckJson, Provider, Model, PromptTemplateId, PromptTemplateVersion, PeriodFromUtc, PeriodToUtc, UptimeDays, WarningsJson,
	RecommendationJson, CreatedAtUtc)
VALUES (@RecommendationId, @RunId, @Module, @Action, @Source, @ObjectKey, @ServerName, @DatabaseName, @SchemaName, @TableName, @IndexName,
	@Title, @Rationale, @RiskLevel, @RiskDescription, @ExecuteScript, @RollbackScript, @ValidationStatus, @ValidationJson, @DropEligibilityJson, @IsDropEligible,
	@RulesProfile, @CrossCheckJson, @Provider, @Model, @PromptTemplateId, @PromptTemplateVersion, @PeriodFromUtc, @PeriodToUtc, @UptimeDays, @WarningsJson,
	@RecommendationJson, @CreatedAtUtc);
'@
				parameters = @(
					(New-IaOutParam -Name 'RecommendationId' -Value (ConvertTo-IaOutGuid $rec.recommendationId) -SqlType UniqueIdentifier)
					(& $runIdParam)
					(New-IaOutParam -Name 'Module' -Value $rec.module -SqlType VarChar -Size 20)
					(New-IaOutParam -Name 'Action' -Value $rec.action -SqlType VarChar -Size 30)
					(New-IaOutParam -Name 'Source' -Value $rec.source -SqlType VarChar -Size 10)
					(New-IaOutParam -Name 'ObjectKey' -Value $rec.target.objectKey -SqlType NVarChar -Size 850)
					(New-IaOutParam -Name 'ServerName' -Value $rec.target.server -SqlType NVarChar -Size 256)
					(New-IaOutParam -Name 'DatabaseName' -Value $rec.target.database -SqlType NVarChar -Size 128)
					(New-IaOutParam -Name 'SchemaName' -Value $rec.target.schema -SqlType NVarChar -Size 128)
					(New-IaOutParam -Name 'TableName' -Value $rec.target.table -SqlType NVarChar -Size 128)
					(New-IaOutParam -Name 'IndexName' -Value $rec.target.index -SqlType NVarChar -Size 128)
					(New-IaOutParam -Name 'Title' -Value $rec.title -SqlType NVarChar -Size 400)
					(New-IaOutParam -Name 'Rationale' -Value $rec.rationale -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'RiskLevel' -Value $rec.risk.level -SqlType VarChar -Size 10)
					(New-IaOutParam -Name 'RiskDescription' -Value $rec.risk.description -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'ExecuteScript' -Value $rec.executeScript -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'RollbackScript' -Value $rec.rollbackScript -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'ValidationStatus' -Value $(if ($rec.validation) { $rec.validation.status } else { 'NotValidated' }) -SqlType VarChar -Size 20)
					(New-IaOutParam -Name 'ValidationJson' -Value $(if ($rec.validation) { ConvertTo-IaOutJson $rec.validation } else { '{}' }) -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'DropEligibilityJson' -Value (ConvertTo-IaOutJson $eligibility) -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'IsDropEligible' -Value $(if ($eligibility) { [bool]$eligibility.isEligible } else { $null }) -SqlType Bit)
					(New-IaOutParam -Name 'RulesProfile' -Value $(if ($eligibility) { $eligibility.rulesProfile } else { $null }) -SqlType VarChar -Size 10)
					(New-IaOutParam -Name 'CrossCheckJson' -Value (ConvertTo-IaOutJson $rec.crossCheck) -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'Provider' -Value $(if ($rec.llm) { $rec.llm.provider } else { $null }) -SqlType NVarChar -Size 100)
					(New-IaOutParam -Name 'Model' -Value $(if ($rec.llm) { $rec.llm.model } else { $null }) -SqlType NVarChar -Size 200)
					(New-IaOutParam -Name 'PromptTemplateId' -Value $(if ($rec.llm) { $rec.llm.promptTemplateId } else { $null }) -SqlType VarChar -Size 100)
					(New-IaOutParam -Name 'PromptTemplateVersion' -Value $(if ($rec.llm -and $null -ne $rec.llm.promptTemplateVersion) { $rec.llm.promptTemplateVersion } else { $null }) -SqlType Int)
					(New-IaOutParam -Name 'PeriodFromUtc' -Value $(if ($period) { $period.statsFromUtc } else { $null }) -SqlType DateTime2)
					(New-IaOutParam -Name 'PeriodToUtc' -Value $(if ($period) { $period.statsToUtc } else { $null }) -SqlType DateTime2)
					(New-IaOutParam -Name 'UptimeDays' -Value $(if ($period) { $period.uptimeDays } else { $null }) -SqlType Decimal -Precision 9 -Scale 2)
					(New-IaOutParam -Name 'WarningsJson' -Value $(if (@($rec.warnings).Count) { ConvertTo-IaOutJson @($rec.warnings) } else { $null }) -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'RecommendationJson' -Value (ConvertTo-IaOutJson $rec) -SqlType NVarChar -Size -1)
					(New-IaOutParam -Name 'CreatedAtUtc' -Value $(if ($rec.createdAtUtc) { $rec.createdAtUtc } else { $run.startedAtUtc }) -SqlType DateTime2)
				)
			})
	}

	foreach ($verdict in @($run.verdicts | Where-Object { $_ })) {
		$commands.Add([ordered]@{
				commandText = @'
INSERT INTO Advisor.ObjectVerdict (RunId, ObjectKey, Module, AnalyzedAtUtc, Verdict, CountsTowardSeries, PeriodDays, RulesProfile)
VALUES (@RunId, @ObjectKey, @Module, @AnalyzedAtUtc, @Verdict, @CountsTowardSeries, @PeriodDays, @RulesProfile);
'@
				parameters = @(
					(& $runIdParam)
					(New-IaOutParam -Name 'ObjectKey' -Value $verdict.objectKey -SqlType NVarChar -Size 850)
					(New-IaOutParam -Name 'Module' -Value $verdict.module -SqlType VarChar -Size 20)
					(New-IaOutParam -Name 'AnalyzedAtUtc' -Value $(if ($verdict.analyzedAtUtc) { $verdict.analyzedAtUtc } else { $run.startedAtUtc }) -SqlType DateTime2)
					(New-IaOutParam -Name 'Verdict' -Value $verdict.verdict -SqlType VarChar -Size 20)
					(New-IaOutParam -Name 'CountsTowardSeries' -Value ([bool]$verdict.countsTowardSeries) -SqlType Bit)
					(New-IaOutParam -Name 'PeriodDays' -Value $(if ($null -ne $verdict.periodDays) { $verdict.periodDays } else { 0 }) -SqlType Decimal -Precision 9 -Scale 2)
					(New-IaOutParam -Name 'RulesProfile' -Value $verdict.rulesProfile -SqlType VarChar -Size 10)
				)
			})
	}
	return , @($commands.ToArray())
}

function Save-IaRunToRepository {
	<# Записує запуск, періоди, виклики LLM, дозапити, рекомендації та вердикти в репозиторій (схема Advisor).
	   Нічого не робить, якщо repository.enabled = $false. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$RunResult,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	if (-not $Config.repository.enabled) {
		return
	}
	if ([string]::IsNullOrWhiteSpace($Config.repository.server)) {
		throw 'Не задано сервер репозиторію (repository.server). Для разового аналізу без запису використайте -NoRepository.'
	}
	Assert-IaOutRepositoryTarget -Config $Config -RunResult $RunResult
	$commands = New-IaOutRunCommands -RunResult $RunResult
	Invoke-IaOutRepositoryCommand -Config $Config -Commands $commands -Mode NonQuery | Out-Null
}

function Get-IaRecommendationHistory {
	<# Історія вердиктів (IndexVerdict) для objectKey з репозиторію, відсортована від старих до нових.
	   Якщо repository.enabled = $false — порожній масив. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ObjectKeys,
		[Parameter(Mandatory)][ValidateSet('Indexes', 'Partitioning')][string]$Module,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$keys = @($ObjectKeys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
	if (-not $Config.repository.enabled -or $keys.Count -eq 0) {
		return , @()
	}
	if ([string]::IsNullOrWhiteSpace($Config.repository.server)) {
		throw 'Не задано сервер репозиторію (repository.server). Для разового аналізу без історії використайте -NoRepository.'
	}
	$command = [ordered]@{
		commandText = @'
SELECT v.RunId, v.ObjectKey, v.Module, v.AnalyzedAtUtc, v.Verdict, v.CountsTowardSeries, v.PeriodDays, v.RulesProfile
FROM Advisor.ObjectVerdict AS v
WHERE v.Module = @Module
	AND v.ObjectKey IN (SELECT k.[value] FROM OPENJSON(@ObjectKeys) AS k)
ORDER BY v.AnalyzedAtUtc, v.ObjectKey;
'@
		parameters = @(
			(New-IaOutParam -Name 'Module' -Value $Module -SqlType VarChar -Size 20)
			(New-IaOutParam -Name 'ObjectKeys' -Value (ConvertTo-Json -InputObject @($keys) -Compress) -SqlType NVarChar -Size -1)
		)
	}
	$rows = Invoke-IaOutRepositoryCommand -Config $Config -Commands @($command) -Mode Reader
	$rows = @($rows | Where-Object { $null -ne $_ })
	$verdicts = foreach ($row in $rows | Where-Object { $_ }) {
		[ordered]@{
			runId = ([string]$row.RunId).ToLowerInvariant()
			objectKey = [string]$row.ObjectKey
			module = [string]$row.Module
			analyzedAtUtc = ConvertTo-IaUtcString -Date $row.AnalyzedAtUtc
			verdict = [string]$row.Verdict
			countsTowardSeries = [bool]$row.CountsTowardSeries
			periodDays = $(if ($null -ne $row.PeriodDays) { [double]$row.PeriodDays } else { $null })
			rulesProfile = $(if ($row.RulesProfile) { [string]$row.RulesProfile } else { $null })
		}
	}
	return , @($verdicts | Sort-Object -Stable { [string]$_.analyzedAtUtc })
}

function Remove-IaExpiredHistory {
	<# Видаляє з репозиторію запуски, старші за repository.historyRetentionDays. Повертає кількість видалених запусків. #>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	if (-not $Config.repository.enabled) {
		return 0
	}
	if ([string]::IsNullOrWhiteSpace($Config.repository.server)) {
		throw 'Не задано сервер репозиторію (repository.server).'
	}
	Assert-IaOutRepositoryTarget -Config $Config
	$days = [int]$Config.repository.historyRetentionDays
	$cutoff = [datetime]::UtcNow.AddDays(-$days)
	if (-not $PSCmdlet.ShouldProcess("$($Config.repository.server)/$($Config.repository.database)", "Видалити запуски, старші за $days дн.")) {
		return 0
	}
	$command = [ordered]@{
		commandText = @'
SET NOCOUNT ON;
DECLARE @deletedRuns INT;
DELETE FROM Advisor.AnalysisRun WHERE StartedAtUtc < @CutoffUtc;
SET @deletedRuns = @@ROWCOUNT;
SELECT @deletedRuns AS DeletedRuns;
'@
		parameters = @((New-IaOutParam -Name 'CutoffUtc' -Value $cutoff -SqlType DateTime2))
	}
	$rows = Invoke-IaOutRepositoryCommand -Config $Config -Commands @($command) -Mode Reader
	$rows = @($rows | Where-Object { $null -ne $_ })
	if ($rows.Count -eq 0 -or $null -eq $rows[0]) {
		return 0
	}
	return [int]$rows[0].DeletedRuns
}
