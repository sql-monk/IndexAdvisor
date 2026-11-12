# Помічники юніт-тестів потоку Collector: мок Invoke-IaSqlQuery (конверти New-IaResponse з підготовленими рядками)
# і типові набори рядків для сценаріїв Standalone, FCI та AG. Підключається після TestHelpers.ps1.

$script:ColFixturesPath = Join-Path $PSScriptRoot 'Fixtures'

function Initialize-ColTestQueries {
	<# Мапа текст запиту -> ім'я файлу Collector/Queries (тексти беруться тим самим Get-IaColQueryText, що й у колекторі). #>
	$module = Get-Module IndexAdvisor
	$queriesPath = Join-Path $script:IaRepoRoot 'src\IndexAdvisor\Collector\Queries'
	$script:ColQueryNames = @{}
	foreach ($file in Get-ChildItem -LiteralPath $queriesPath -Filter '*.sql') {
		$text = & $module { param($n) Get-IaColQueryText -Name $n } $file.BaseName
		$script:ColQueryNames[$text] = $file.BaseName
	}
}

function New-ColTestRow {
	<# [ordered] рядок конверта з хеш-таблиці. #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
	$row = [ordered]@{}
	foreach ($key in $Values.Keys) {
		$row[$key] = $Values[$key]
	}
	return $row
}

function New-ColTestControl {
	<# Керуючий результат обробника: помилка конверта або тривалість. #>
	param([object[]]$Rows = @(), [string]$Fail, [string]$Code = 'SqlError', [long]$DurationMs = 1)
	return @{ __control = $true; rows = $Rows; fail = $Fail; code = $Code; durationMs = $DurationMs }
}

function Reset-ColTestState {
	<# Обробники: ім'я запиту -> scriptblock param($call) з рядками або New-ColTestControl. #>
	param([hashtable]$Handlers = @{})
	$script:ColHandlers = $Handlers
	$script:ColCalls = [System.Collections.Generic.List[object]]::new()
}

function Invoke-ColTestSql {
	<# Тіло мока Invoke-IaSqlQuery: пагінація Fetch/Skip, truncated, конверт New-IaResponse. #>
	param($Server, $Database, $Query, $Parameters, $Fetch, $Skip, $Purpose, $ApplicationIntent)
	$name = $script:ColQueryNames[$Query]
	$call = [pscustomobject]@{
		Name = $name
		Server = $Server
		Database = $Database
		Parameters = $Parameters
		Fetch = $Fetch
		Skip = $Skip
		Purpose = $Purpose
		ApplicationIntent = $ApplicationIntent
	}
	$script:ColCalls.Add($call)
	$response = & (Get-Module IndexAdvisor) { param($s, $d) New-IaResponse -Server $s -Database $d } $Server $Database
	$handler = $script:ColHandlers[[string]$name]
	$output = if ($handler) { & $handler $call } else { @() }
	$durationMs = 1
	if ($output -is [hashtable] -and $output.ContainsKey('__control')) {
		$durationMs = $output.durationMs
		if ($output.fail) {
			$response.success = $false
			$response.durationMs = $durationMs
			$response.error = & (Get-Module IndexAdvisor) { param($c, $m) New-IaError -Code $c -Message $m } $output.code $output.fail
			return $response
		}
		$output = $output.rows
	}
	$all = @($output | Where-Object { $null -ne $_ })
	$fetchValue = if ($null -ne $Fetch) { [int]$Fetch } else { 300 }
	$skipValue = [int]$Skip
	$page = @($all | Select-Object -Skip $skipValue -First $fetchValue)
	$response.success = $true
	$response.durationMs = $durationMs
	$response.rows = $page
	$response.rowCount = $page.Count
	$response.truncated = $all.Count -gt ($skipValue + $fetchValue)
	return $response
}

function Get-ColTestPlanXml {
	<# Мінімальний showplan з операторами доступу: @(@{ op = 'Index Seek'; table = 'Orders'; index = 'IX_A'; kind = 'NonClustered' }). #>
	param([object[]]$Operations, [string]$Database = 'Sales', [string]$Schema = 'dbo')
	$relOps = foreach ($operation in $Operations) {
		$element = if ($operation.op -like '*Insert*' -or $operation.op -like '*Update*' -or $operation.op -like '*Delete*') { 'Update' } elseif ($operation.op -eq 'Table Scan') { 'TableScan' } else { 'IndexScan' }
		$indexAttribute = if ($operation.index) { " Index=""[$($operation.index)]""" } else { '' }
		"<RelOp NodeId=""1"" PhysicalOp=""$($operation.op)"" LogicalOp=""$($operation.op)"" EstimatedExecutionMode=""Row""><OutputList /><$element><Object Database=""[$Database]"" Schema=""[$Schema]"" Table=""[$($operation.table)]""$indexAttribute IndexKind=""$($operation.kind)"" Storage=""RowStore"" /></$element></RelOp>"
	}
	return '<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564"><BatchSequence><Batch><Statements><StmtSimple><QueryPlan>' +
		'<RelOp NodeId="0" PhysicalOp="Concatenation" LogicalOp="Concatenation" EstimatedExecutionMode="Row"><OutputList /><Concat>' + ($relOps -join '') +
		'</Concat></RelOp></QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>'
}

function Get-ColTestAnalysisWindow {
	return [ordered]@{ fromUtc = '2026-10-11T08:00:00.000Z'; toUtc = '2026-11-10T08:00:00.000Z'; mode = 'Days'; reason = 'analysisWindow.days = 30' }
}

function Get-ColTestTopologyRows {
	<# Рядки запиту topology: Standalone, FCI або AG (SQL01 PRIMARY, SQL02 SECONDARY READ_ONLY, SQL03 SECONDARY NO). #>
	param([ValidateSet('Standalone', 'FCI', 'AG')][string]$Type = 'Standalone')
	switch ($Type) {
		'Standalone' {
			return , @(New-ColTestRow @{ isHadrEnabled = 0; isClustered = 0; serverName = 'SQL01'; agName = $null; listenerName = $null; replicaServerName = $null
					roleDesc = $null; availabilityMode = $null; secondaryAllowConnections = $null; connectedState = $null })
		}
		'FCI' {
			return , @(New-ColTestRow @{ isHadrEnabled = 0; isClustered = 1; serverName = 'FCI01\SQL'; agName = $null; listenerName = $null; replicaServerName = $null
					roleDesc = $null; availabilityMode = $null; secondaryAllowConnections = $null; connectedState = $null })
		}
		'AG' {
			$rows = foreach ($replica in @(
					@('SQL01', 'PRIMARY', 'ALL', 'SYNCHRONOUS_COMMIT'),
					@('SQL02', 'SECONDARY', 'READ_ONLY', 'SYNCHRONOUS_COMMIT'),
					@('SQL03', 'SECONDARY', 'NO', 'ASYNCHRONOUS_COMMIT'))) {
				New-ColTestRow @{ isHadrEnabled = 1; isClustered = 0; serverName = 'SQL01'; agName = 'AG1'; listenerName = 'AGL-SALES'; replicaServerName = $replica[0]
					roleDesc = $replica[1]; availabilityMode = $replica[3]; secondaryAllowConnections = $replica[2]; connectedState = 'CONNECTED' }
			}
			return , @($rows)
		}
	}
}

function Get-ColTestHandlers {
	<# Типовий набір обробників: інстанс(и), бази Sales і Archive, повні набори даних Sales. #>
	param([ValidateSet('Standalone', 'FCI', 'AG')][string]$Type = 'Standalone')
	$script:ColTestPlans = @{
		oltp = Get-Content -LiteralPath (Join-Path $script:ColFixturesPath 'plan_oltp_lookup.xml') -Raw -Encoding utf8
		report = Get-ColTestPlanXml -Operations @(@{ op = 'Clustered Index Scan'; table = 'Orders'; index = 'PK_Orders'; kind = 'Clustered' })
		email = Get-ColTestPlanXml -Operations @(@{ op = 'Index Scan'; table = 'Customers'; index = 'UQ_Customers_Email'; kind = 'NonClustered' })
		insert = Get-Content -LiteralPath (Join-Path $script:ColFixturesPath 'plan_insert.xml') -Raw -Encoding utf8
	}
	$script:ColTestTopologyRows = Get-ColTestTopologyRows -Type $Type
	$script:ColTestIsAg = $Type -eq 'AG'
	$handlers = @{
		topology = { $script:ColTestTopologyRows }
		instance_info = {
			param($call)
			New-ColTestRow @{ serverName = $(if ($call.Server -eq 'AGL-SALES') { 'SQL01' } else { $call.Server }); productVersion = '16.0.4135.4'
				productEdition = 'Enterprise Edition: Core-based Licensing (64-bit)'; engineEdition = 3; isClustered = $(if ($call.Server -like 'FCI*') { 1 } else { 0 })
				sqlserverStartTimeUtc = '2026-09-01T03:00:00.000Z'; collectedAtUtc = '2026-11-10T08:00:00.000Z' }
		}
		last_failover = {
			@(
				New-ColTestRow @{ eventTimeUtc = '2026-10-20T01:00:05.000Z'; eventData = '<event name="availability_replica_state_change"><data name="previous_state"><value>3</value><text>RESOLVING_NORMAL</text></data><data name="current_state"><value>1</value><text>PRIMARY_NORMAL</text></data></event>' }
				New-ColTestRow @{ eventTimeUtc = '2026-10-20T01:00:00.000Z'; eventData = '<event name="availability_replica_state_change"><data name="previous_state"><value>2</value><text>SECONDARY_NORMAL</text></data><data name="current_state"><value>3</value><text>RESOLVING_NORMAL</text></data></event>' }
			)
		}
		databases = {
			param($call)
			$role = $null
			$allow = $null
			$ag = $null
			if ($script:ColTestIsAg) {
				$ag = 'AG1'
				$role = if ($call.Server -eq 'SQL01') { 'PRIMARY' } else { 'SECONDARY' }
				$allow = if ($call.Server -eq 'SQL02') { 'READ_ONLY' } elseif ($call.Server -eq 'SQL03') { 'NO' } else { 'ALL' }
			}
			@(
				New-ColTestRow @{ databaseId = 5; databaseName = 'Sales'; compatibilityLevel = 160; stateDesc = 'ONLINE'; isReadOnly = $false; recoveryModel = 'FULL'
					availabilityGroup = $ag; replicaRole = $role; secondaryAllowConnections = $allow; isPublished = $false; isMergePublished = $false
					isSubscribed = $false; isDistributor = $false; hasDbAccess = $true }
				New-ColTestRow @{ databaseId = 6; databaseName = 'Archive'; compatibilityLevel = 150; stateDesc = 'ONLINE'; isReadOnly = $false; recoveryModel = 'SIMPLE'
					availabilityGroup = $null; replicaRole = $null; secondaryAllowConnections = $null; isPublished = $false; isMergePublished = $false
					isSubscribed = $false; isDistributor = $false; hasDbAccess = $true }
				New-ColTestRow @{ databaseId = 7; databaseName = 'Offline'; compatibilityLevel = 150; stateDesc = 'OFFLINE'; isReadOnly = $false; recoveryModel = 'SIMPLE'
					availabilityGroup = $null; replicaRole = $null; secondaryAllowConnections = $null; isPublished = $false; isMergePublished = $false
					isSubscribed = $false; isDistributor = $false; hasDbAccess = $false }
			)
		}
		tables = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @(New-ColTestRow @{ objectId = 901; schemaName = 'dbo'; tableName = 'History'; objectType = 'USER_TABLE'; isPartitioned = $false; partitionScheme = $null
						partitionFunction = $null; partitionColumn = $null; isReplicated = $false; isMemoryOptimized = $false })
			}
			@(
				New-ColTestRow @{ objectId = 101; schemaName = 'dbo'; tableName = 'Customers'; objectType = 'USER_TABLE'; isPartitioned = $false; partitionScheme = $null
					partitionFunction = $null; partitionColumn = $null; isReplicated = $false; isMemoryOptimized = $false }
				New-ColTestRow @{ objectId = 201; schemaName = 'dbo'; tableName = 'Orders'; objectType = 'USER_TABLE'; isPartitioned = $false; partitionScheme = $null
					partitionFunction = $null; partitionColumn = $null; isReplicated = $false; isMemoryOptimized = $false }
				New-ColTestRow @{ objectId = 301; schemaName = 'etl'; tableName = 'Load'; objectType = 'USER_TABLE'; isPartitioned = $false; partitionScheme = $null
					partitionFunction = $null; partitionColumn = $null; isReplicated = $false; isMemoryOptimized = $false }
			)
		}
		columns = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @(New-ColTestRow @{ objectId = 901; columnId = 1; columnName = 'Id'; typeName = 'int'; maxLength = 4; columnPrecision = 10; columnScale = 0; isNullable = $false
						isComputed = $false; isIdentity = $true; isRowGuidCol = $false })
			}
			foreach ($column in @(
					@(101, 1, 'CustomerId', 'int', 4), @(101, 2, 'Email', 'nvarchar', 512),
					@(201, 1, 'OrderId', 'bigint', 8), @(201, 2, 'CustomerId', 'int', 4), @(201, 3, 'OrderDate', 'datetime2', 8), @(201, 4, 'Status', 'tinyint', 1),
					@(201, 5, 'Comment', 'nvarchar', 800), @(301, 1, 'Payload', 'nvarchar', -1))) {
				New-ColTestRow @{ objectId = $column[0]; columnId = $column[1]; columnName = $column[2]; typeName = $column[3]; maxLength = $column[4]; columnPrecision = 0
					columnScale = 0; isNullable = $false; isComputed = $false; isIdentity = ($column[1] -eq 1); isRowGuidCol = $false }
			}
		}
		indexes = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @(New-ColTestRow @{ objectId = 901; indexId = 0; indexName = $null; typeDesc = 'HEAP'; isPrimaryKey = $false; isUnique = $false; isUniqueConstraint = $false
						isDisabled = $false; isHypothetical = $false; hasFilter = $false; filterDefinition = $null; indexFillFactor = 0; isPadded = $false; allowRowLocks = $true
						allowPageLocks = $true; ignoreDupKey = $false; dataSpaceName = 'PRIMARY'; dataSpaceType = 'ROWS_FILEGROUP'; partitionFunction = $null
						compressionMin = 'NONE'; compressionMax = 'NONE'; statsLastUpdatedUtc = $null })
			}
			foreach ($index in @(
					@(101, 1, 'PK_Customers', 'CLUSTERED', $true, $true, $false, 'PAGE', 'PAGE'),
					@(101, 2, 'UQ_Customers_Email', 'NONCLUSTERED', $false, $true, $true, 'NONE', 'NONE'),
					@(201, 1, 'PK_Orders', 'CLUSTERED', $true, $true, $false, 'PAGE', 'ROW'),
					@(201, 2, 'IX_CustomerId', 'NONCLUSTERED', $false, $false, $false, 'NONE', 'NONE'),
					@(201, 3, 'IX_Status', 'NONCLUSTERED', $false, $false, $false, 'NONE', 'NONE'),
					@(201, 4, 'NCCI_Orders', 'NONCLUSTERED COLUMNSTORE', $false, $false, $false, 'COLUMNSTORE', 'COLUMNSTORE'),
					@(301, 0, $null, 'HEAP', $false, $false, $false, 'NONE', 'NONE'))) {
				New-ColTestRow @{ objectId = $index[0]; indexId = $index[1]; indexName = $index[2]; typeDesc = $index[3]; isPrimaryKey = $index[4]; isUnique = $index[5]
					isUniqueConstraint = $index[6]; isDisabled = $false; isHypothetical = $false; hasFilter = $false; filterDefinition = $null; indexFillFactor = 0
					isPadded = $false; allowRowLocks = $true; allowPageLocks = $true; ignoreDupKey = $false; dataSpaceName = 'PRIMARY'; dataSpaceType = 'ROWS_FILEGROUP'
					partitionFunction = $null; compressionMin = $index[7]; compressionMax = $index[8]; statsLastUpdatedUtc = '2026-11-01T01:00:00.000Z' }
			}
		}
		index_columns = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @()
			}
			foreach ($column in @(
					@(101, 1, 'CustomerId', 1, $false), @(101, 2, 'Email', 1, $false),
					@(201, 1, 'OrderId', 1, $false), @(201, 2, 'CustomerId', 1, $false), @(201, 3, 'Status', 1, $false), @(201, 3, 'OrderDate', 0, $true),
					@(201, 4, 'OrderDate', 0, $false), @(201, 4, 'Status', 0, $false))) {
				New-ColTestRow @{ objectId = $column[0]; indexId = $column[1]; indexColumnId = 1; columnName = $column[2]; keyOrdinal = $column[3]; isDescending = $false
					isIncluded = $column[4]; partitionOrdinal = 0 }
			}
		}
		index_usage = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @()
			}
			@(
				New-ColTestRow @{ objectId = 101; indexId = 1; userSeeks = 1500000; userScans = 40; userLookups = 0; userUpdates = 2000; lastUserSeekUtc = '2026-11-10T07:59:00.000Z'
					lastUserScanUtc = '2026-11-09T23:00:00.000Z'; lastUserLookupUtc = $null; lastUserUpdateUtc = '2026-11-10T07:50:00.000Z' }
				New-ColTestRow @{ objectId = 201; indexId = 2; userSeeks = '50000'; userScans = 0; userLookups = 0; userUpdates = 400000; lastUserSeekUtc = '2026-11-10T07:30:00.000Z'
					lastUserScanUtc = $null; lastUserLookupUtc = $null; lastUserUpdateUtc = '2026-11-10T07:59:30.000Z' }
			)
		}
		index_operational = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @()
			}
			@(New-ColTestRow @{ objectId = 201; indexId = 3; leafInsertCount = 400000; leafUpdateCount = 50000; leafDeleteCount = 0; leafPageSplitCount = 6000
					nonleafPageSplitCount = 15; rowLockWaitCount = 3; rowLockWaitMs = 200; pageLockWaitCount = 0; pageLockWaitMs = 0; pageLatchWaitCount = 150
					pageLatchWaitMs = 1000; pageIoLatchWaitCount = 100; pageIoLatchWaitMs = 800; lockEscalationCount = 0 })
		}
		partition_stats = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @(New-ColTestRow @{ objectId = 901; indexId = 0; partitionNumber = 1; partitionRows = 10; usedMb = 0.1; reservedMb = 0.2; compressionDesc = 'NONE'; boundaryValue = $null })
			}
			foreach ($partition in @(
					@(101, 1, 200000, 55.0, 58.0), @(101, 2, 200000, 9.0, 9.5),
					@(201, 1, 5000000, 1500.0, 1520.0), @(201, 2, 5000000, 90.0, 92.0), @(201, 3, 5000000, 70.0, 72.0), @(201, 4, 5000000, 300.0, 310.0),
					@(301, 0, 1000, 1.0, 1.5))) {
				New-ColTestRow @{ objectId = $partition[0]; indexId = $partition[1]; partitionNumber = 1; partitionRows = $partition[2]; usedMb = $partition[3]
					reservedMb = $partition[4]; compressionDesc = 'NONE'; boundaryValue = $null }
			}
		}
		physical_stats = {
			param($call)
			New-ColTestRow @{ avgFragmentationPercent = 12.3456; pageCount = 1000 + [int]$call.Parameters['indexId']; fragmentCount = 50 }
		}
		missing_indexes = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @()
			}
			@(
				New-ColTestRow @{ indexHandle = 11; groupHandle = 12; objectId = 201; schemaName = 'dbo'; tableName = 'Orders'; equalityColumns = $null
					inequalityColumns = '[OrderDate]'; includedColumns = '[Amount], [Status]'; userSeeks = 4300; userScans = 0; avgTotalUserCost = 85.2
					avgUserImpact = 97.1; lastUserSeekUtc = '2026-11-10T06:00:00.000Z'; uniqueCompiles = 3 }
				New-ColTestRow @{ indexHandle = 13; groupHandle = 14; objectId = 301; schemaName = 'etl'; tableName = 'Load'; equalityColumns = '[Payload]'
					inequalityColumns = $null; includedColumns = $null; userSeeks = 1; userScans = 0; avgTotalUserCost = 1.0; avgUserImpact = 10.0
					lastUserSeekUtc = $null; uniqueCompiles = 1 }
			)
		}
		missing_index_queries = {
			@(
				New-ColTestRow @{ indexHandle = 11; queryHash = '0x1A2B3C4D5E6F7081' }
				New-ColTestRow @{ indexHandle = 11; queryHash = '0x1A2B3C4D5E6F7081' }
			)
		}
		foreign_keys = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @()
			}
			@(New-ColTestRow @{ foreignKeyId = 501; foreignKeyName = 'FK_Orders_Customers'; parentObjectId = 201; referencedObjectId = 101; referencedSchema = 'dbo'
					referencedTable = 'Customers'; keyIndexId = 1; referencedIndexName = 'PK_Customers'; isDisabled = $false; isNotTrusted = $false; columnOrdinal = 1
					columnName = 'CustomerId'; referencedColumnName = 'CustomerId' })
		}
		module_hints = {
			param($call)
			if ($call.Database -eq 'Archive') {
				return @()
			}
			@(New-ColTestRow @{ objectId = 700; schemaName = 'dbo'; moduleName = 'usp_GetOrdersByCustomer'
					moduleDefinition = 'CREATE PROCEDURE dbo.usp_GetOrdersByCustomer @CustomerId INT AS SELECT o.OrderId FROM dbo.Orders AS o WITH (INDEX(IX_CustomerId)) WHERE o.CustomerId = @CustomerId;' })
		}
		query_store_options = {
			param($call)
			$state = if ($call.Database -eq 'Archive') { 'OFF' } else { 'READ_WRITE' }
			New-ColTestRow @{ actualState = $state; desiredState = $state; readOnlyReason = 0; currentStorageSizeMb = 1000.0; maxStorageSizeMb = 2048.0
				staleQueryThresholdDays = 90; queryCaptureMode = 'AUTO'; intervalLengthMinutes = 60; firstIntervalStartUtc = '2026-08-12T00:00:00.000Z'
				lastIntervalEndUtc = '2026-11-10T08:00:00.000Z' }
		}
		query_store_top_queries = {
			@(
				New-ColTestRow @{ queryId = 1001; queryHash = '0x00AA11BB22CC33DD'; objectName = $null
					queryText = '(@CustomerId int)SELECT o.OrderId FROM dbo.Orders AS o WHERE o.CustomerId = @CustomerId'; isParameterized = $true
					executionCount = 1200000; totalCpuMs = 240000.0; totalLogicalReads = 6000000.0; totalDurationMs = 360000.0; planCount = 1
					firstExecutionUtc = '2026-08-12T00:10:00.000Z'; lastExecutionUtc = '2026-11-10T07:59:00.000Z'; isTopCpu = $true; isTopLogicalReads = $false
					isTopDuration = $false; isTopExecutions = $true }
				New-ColTestRow @{ queryId = 1002; queryHash = '0x1A2B3C4D5E6F7081'; objectName = 'dbo.usp_DailyRevenue'
					queryText = 'SELECT CAST(o.OrderDate AS date) AS d, SUM(o.Amount) FROM dbo.Orders AS o GROUP BY CAST(o.OrderDate AS date)'; isParameterized = $false
					executionCount = 90; totalCpuMs = 900000.0; totalLogicalReads = 17280000.0; totalDurationMs = 1200000.0; planCount = 2
					firstExecutionUtc = '2026-08-12T06:00:00.000Z'; lastExecutionUtc = '2026-11-10T06:00:00.000Z'; isTopCpu = $true; isTopLogicalReads = $true
					isTopDuration = $true; isTopExecutions = $false }
				New-ColTestRow @{ queryId = 1003; queryHash = '0x7788990011223344'; objectName = 'dbo.usp_GetOrdersByCustomer'
					queryText = 'SELECT o.OrderId FROM dbo.Orders AS o WITH (INDEX(IX_CustomerId)) WHERE o.CustomerId = @CustomerId'; isParameterized = $false
					executionCount = 50000; totalCpuMs = 5000.0; totalLogicalReads = 400000.0; totalDurationMs = 9000.0; planCount = 1
					firstExecutionUtc = '2026-08-12T00:00:00.000Z'; lastExecutionUtc = '2026-11-10T07:30:00.000Z'; isTopCpu = $false; isTopLogicalReads = $false
					isTopDuration = $false; isTopExecutions = $true }
			)
		}
		query_store_time_profile = {
			@(
				New-ColTestRow @{ queryId = 1001; hourUtc = 9; isoDayOfWeek = 1; executionCount = 100000; cpuMs = 20000.0; logicalReads = 500000.0; durationMs = 30000.0 }
				New-ColTestRow @{ queryId = 1001; hourUtc = 9; isoDayOfWeek = 2; executionCount = 50000; cpuMs = 10000.0; logicalReads = 250000.0; durationMs = 15000.0 }
				New-ColTestRow @{ queryId = 1001; hourUtc = 10; isoDayOfWeek = 1; executionCount = 1000; cpuMs = 200.0; logicalReads = 5000.0; durationMs = 300.0 }
				New-ColTestRow @{ queryId = 1002; hourUtc = 6; isoDayOfWeek = 7; executionCount = 90; cpuMs = 900000.0; logicalReads = 17280000.0; durationMs = 1200000.0 }
			)
		}
		# Плани Query Store: перелік (keyset за afterPlanId), статистика планів топ-запитів (queryIds), XML пакетами (planIds).
		query_store_plan_list = {
			param($call)
			$after = [long]$call.Parameters.afterPlanId
			@(Get-ColTestPlanRows | Where-Object { [long]$_.planId -gt $after } | ForEach-Object {
					New-ColTestRow @{ planId = $_.planId; queryId = $_.queryId; queryPlanHash = $_.queryPlanHash; isForced = $_.isForced; lastExecutionUtc = $_.lastExecutionUtc }
				})
		}
		query_store_plan_stats = {
			param($call)
			$ids = [string]$call.Parameters.queryIds
			@(Get-ColTestPlanRows | Where-Object { $ids.Contains(",$($_.queryId),") } | ForEach-Object {
					New-ColTestRow @{ planId = $_.planId; executionCount = $_.executionCount; avgDurationMs = $_.avgDurationMs; avgCpuMs = $_.avgCpuMs }
				})
		}
		query_store_plan_xml = {
			param($call)
			$ids = [string]$call.Parameters.planIds
			@(Get-ColTestPlanRows | Where-Object { $ids.Contains(",$($_.planId),") -and [long]$_.planId -ge [long]$call.Parameters.minPlanId -and [long]$_.planId -le [long]$call.Parameters.maxPlanId } |
					ForEach-Object { New-ColTestRow @{ planId = $_.planId; queryPlan = $_.queryPlan } })
		}
		query_store_hint_texts = {
			@(New-ColTestRow @{ queryId = 1003; queryText = 'SELECT o.OrderId FROM dbo.Orders AS o WITH (INDEX(IX_CustomerId)) WHERE o.CustomerId = @CustomerId' })
		}
	}
	return $handlers
}

function Get-ColTestPlanRows {
	<# Плани Query Store фікстури (plan 2003 має той самий hash, що й 2001, і без XML — розбір береться з кешу за hash). #>
	@(
		@{ planId = 2001; queryId = 1001; queryPlanHash = '0xAAAA'; isForced = $false; executionCount = 1200000; avgDurationMs = 0.3; avgCpuMs = 0.2
			lastExecutionUtc = '2026-11-10T07:59:00.000Z'; queryPlan = $script:ColTestPlans.oltp }
		@{ planId = 2002; queryId = 1002; queryPlanHash = '0xBBBB'; isForced = $false; executionCount = 60; avgDurationMs = 10000.0; avgCpuMs = 9000.0
			lastExecutionUtc = '2026-10-01T06:00:00.000Z'; queryPlan = $script:ColTestPlans.report }
		@{ planId = 2003; queryId = 1003; queryPlanHash = '0xAAAA'; isForced = $false; executionCount = 50000; avgDurationMs = 0.18; avgCpuMs = 0.1
			lastExecutionUtc = '2026-11-10T07:30:00.000Z'; queryPlan = $null }
		@{ planId = 2004; queryId = 9999; queryPlanHash = '0xCCCC'; isForced = $false; executionCount = 400000; avgDurationMs = 0.1; avgCpuMs = 0.05
			lastExecutionUtc = '2026-11-10T07:59:30.000Z'; queryPlan = $script:ColTestPlans.insert }
		@{ planId = 2005; queryId = 9998; queryPlanHash = '0xDDDD'; isForced = $false; executionCount = 10; avgDurationMs = 5.0; avgCpuMs = 4.0
			lastExecutionUtc = '2026-11-09T10:00:00.000Z'; queryPlan = $script:ColTestPlans.email }
		@{ planId = 2006; queryId = 1002; queryPlanHash = '0xEEEE'; isForced = $false; executionCount = 30; avgDurationMs = 30000.0; avgCpuMs = 25000.0
			lastExecutionUtc = '2026-11-10T06:00:00.000Z'; queryPlan = $script:ColTestPlans.report }
	)
}

function Get-ColTestIndex {
	<# Індекс зі snapshot за сервером, базою, таблицею й іменем. #>
	param($Snapshot, [string]$Server, [string]$Database, [string]$Table, [AllowNull()][string]$Index)
	$instance = @($Snapshot.instances | Where-Object { $_.serverName -eq $Server })[0]
	$db = @($instance.databases | Where-Object { $_.name -eq $Database })[0]
	$tableObject = @($db.tables | Where-Object { $_.name -eq $Table })[0]
	return @($tableObject.indexes | Where-Object { $_.name -eq $Index })[0]
}

function Test-ColSnapshotSchema {
	<# Валідація snapshot за contracts/snapshot.schema.json; повертає $true або текст помилок. #>
	param([Parameter(Mandatory)]$Snapshot)
	$json = $Snapshot | ConvertTo-Json -Depth 50
	$schemaText = Get-Content -LiteralPath (Join-Path $script:IaContractsPath 'snapshot.schema.json') -Raw -Encoding utf8
	$errors = $null
	$valid = Test-Json -Json $json -Schema $schemaText -ErrorVariable errors -ErrorAction SilentlyContinue
	if ($valid) {
		return $true
	}
	return (@($errors | ForEach-Object { $_.ToString() }) -join '; ')
}
