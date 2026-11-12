# Юніт-тести Invoke-IaCollection і Get-IaTopology (потік Collector). SQL мокається через Invoke-IaSqlQuery.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Collector.TestData.ps1')
	Initialize-ColTestQueries
	$script:Module = Get-Module IndexAdvisor
	function Invoke-ColTestCollection {
		param([string]$Server = 'SQL01', [System.Collections.IDictionary]$Config)
		& $script:Module { param($s, $c, $w) Invoke-IaCollection -Server $s -Config $c -AnalysisWindow $w -WarningAction SilentlyContinue } $Server $Config (Get-ColTestAnalysisWindow)
	}
}

Describe 'Get-IaTopology' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery {
			Invoke-ColTestSql -Server $Server -Database $Database -Query $Query -Parameters $Parameters -Fetch $Fetch -Skip $Skip -Purpose $Purpose -ApplicationIntent $ApplicationIntent
		}
		Mock -ModuleName IndexAdvisor Write-IaLog {}
	}

	It 'визначає <Type> одним запитом з Purpose Topology' -ForEach @(
		@{ Type = 'Standalone'; Groups = 0 }
		@{ Type = 'FCI'; Groups = 0 }
		@{ Type = 'AG'; Groups = 1 }
	) {
		Reset-ColTestState -Handlers (Get-ColTestHandlers -Type $Type)
		$config = Get-IaTestConfig
		$topology = & $script:Module { param($c) Get-IaTopology -Server 'AGL-SALES' -Config $c } $config
		$topology.type | Should -Be $Type
		@($topology.availabilityGroups).Count | Should -Be $Groups
		$script:ColCalls.Count | Should -Be 1
		$script:ColCalls[0].Name | Should -Be 'topology'
		$script:ColCalls[0].Purpose | Should -Be 'Topology'
		$script:ColCalls[0].Database | Should -Be 'master'
	}

	It 'для AG повертає listener, ролі, режим доступу й стан підключення реплік' {
		Reset-ColTestState -Handlers (Get-ColTestHandlers -Type AG)
		$topology = & $script:Module { param($c) Get-IaTopology -Server 'AGL-SALES' -Config $c } (Get-IaTestConfig)
		$group = $topology.availabilityGroups[0]
		$group.name | Should -Be 'AG1'
		$group.listenerName | Should -Be 'AGL-SALES'
		@($group.replicas).Count | Should -Be 3
		$group.replicas[1].role | Should -Be 'SECONDARY'
		$group.replicas[1].secondaryAllowConnections | Should -Be 'READ_ONLY'
		$group.replicas[1].isConnected | Should -BeTrue
		$topology.isHadrEnabled | Should -BeTrue
	}

	It 'кидає IaCollectionFailed, якщо сервер недоступний' {
		Reset-ColTestState -Handlers @{ topology = { New-ColTestControl -Fail 'Login timeout expired' -Code 'ConnectionFailed' } }
		{ & $script:Module { param($c) Get-IaTopology -Server 'BAD' -Config $c } (Get-IaTestConfig) } | Should -Throw -ErrorId 'IaCollectionFailed'
	}

	It 'визначає адресу підключення реплік: FQDN з endpoint_url, інакше домен запитаного сервера' {
		$rows = Get-ColTestTopologyRows -Type AG
		$rows[0]['endpointUrl'] = 'TCP://SQL01.corp.local:5022'
		$rows[1]['endpointUrl'] = 'TCP://10.0.0.2:5022'
		Reset-ColTestState -Handlers @{ topology = { $rows }.GetNewClosure() }
		$topology = & $script:Module { param($c) Get-IaTopology -Server 'agl-sales.contoso.local,1433' -Config $c } (Get-IaTestConfig)
		@($topology.availabilityGroups[0].replicas.connectAddress) | Should -Be @('SQL01.corp.local', 'SQL02.contoso.local', 'SQL03.contoso.local')
		@($topology.availabilityGroups[0].replicas.replicaServerName) | Should -Be @('SQL01', 'SQL02', 'SQL03')
	}

	It 'Resolve-IaColReplicaAddress: <Case>' -ForEach @(
		@{ Case = 'FQDN з endpoint_url'; Replica = 'SQL01'; Routing = $null; Endpoint = 'TCP://SQL01.corp.local:5022'; Requested = 'AGL'; Listener = 'AGL'; Expected = 'SQL01.corp.local' }
		@{ Case = 'read_only_routing_url має пріоритет'; Replica = 'SQL01'; Routing = 'tcp://sql01.ro.corp.local:1433'; Endpoint = 'TCP://SQL01.corp.local:5022'
			Requested = 'AGL'; Listener = $null; Expected = 'sql01.ro.corp.local' }
		@{ Case = 'іменований інстанс'; Replica = 'SQL01\INST'; Routing = $null; Endpoint = 'TCP://SQL01.corp.local:5022'; Requested = 'AGL'; Listener = $null
			Expected = 'SQL01.corp.local\INST' }
		@{ Case = 'домен запитаного сервера'; Replica = 'sql-node1'; Routing = $null; Endpoint = 'TCP://sql-node1:5022'; Requested = 'tcp:agl-dwh.contoso.local,1433'
			Listener = 'agl-dwh'; Expected = 'sql-node1.contoso.local' }
		@{ Case = 'IP-адреса — домен listener'; Replica = 'SQL02'; Routing = $null; Endpoint = 'TCP://10.0.0.2:5022'; Requested = '192.0.2.10'; Listener = 'AGL.corp.local'
			Expected = 'SQL02.corp.local' }
		@{ Case = 'URL іншого хоста не використовується'; Replica = 'SQL02'; Routing = $null; Endpoint = 'TCP://SQL020.corp.local:5022'; Requested = 'AGL'; Listener = 'AGL'
			Expected = $null }
		@{ Case = 'домену немає'; Replica = 'SQL02'; Routing = $null; Endpoint = $null; Requested = '10.0.0.10'; Listener = 'AGL'; Expected = $null }
		@{ Case = 'ім''я репліки вже повне'; Replica = 'SQL02.corp.local'; Routing = $null; Endpoint = $null; Requested = 'AGL.contoso.local'; Listener = $null; Expected = $null }
	) {
		$address = & $script:Module {
			param($r, $ro, $e, $q, $l)
			Resolve-IaColReplicaAddress -ReplicaName $r -ReadOnlyRoutingUrl $ro -EndpointUrl $e -RequestedServer $q -ListenerName $l
		} $Replica $Routing $Endpoint $Requested $Listener
		$address | Should -Be $Expected
	}

	It 'Get-IaColInstanceTargets підключається за connectAddress, а без нього — за replicaServerName' {
		$topology = [ordered]@{
			type = 'AG'
			availabilityGroups = @([ordered]@{ name = 'AG1'; replicas = @(
						[ordered]@{ replicaServerName = 'SQL01'; connectAddress = 'SQL01.contoso.local'; role = 'PRIMARY'; secondaryAllowConnections = 'ALL'; collected = $false; skipReason = $null }
						[ordered]@{ replicaServerName = 'SQL02'; connectAddress = $null; role = 'SECONDARY'; secondaryAllowConnections = 'READ_ONLY'; collected = $false; skipReason = $null }
					) })
		}
		$targets = & $script:Module {
			param($t)
			Get-IaColInstanceTargets -Topology $t -RequestedServer 'AGL' -Warnings ([System.Collections.Generic.List[object]]::new())
		} $topology
		@($targets | ForEach-Object { $_.server }) | Should -Be @('SQL01.contoso.local', 'SQL02')
	}
}

Describe 'Invoke-IaCollection' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery {
			Invoke-ColTestSql -Server $Server -Database $Database -Query $Query -Parameters $Parameters -Fetch $Fetch -Skip $Skip -Purpose $Purpose -ApplicationIntent $ApplicationIntent
		}
		Mock -ModuleName IndexAdvisor Write-IaLog {}
	}

	Context 'Standalone, усі набори' {
		BeforeAll {
			Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery {
				Invoke-ColTestSql -Server $Server -Database $Database -Query $Query -Parameters $Parameters -Fetch $Fetch -Skip $Skip -Purpose $Purpose -ApplicationIntent $ApplicationIntent
			}
			Mock -ModuleName IndexAdvisor Write-IaLog {}
			Reset-ColTestState -Handlers (Get-ColTestHandlers -Type Standalone)
			$script:Config = Get-IaTestConfig
			$script:Snapshot = Invoke-ColTestCollection -Config $script:Config
			$script:Calls = @($script:ColCalls)
		}

		It 'повертає snapshot, що відповідає contracts/snapshot.schema.json' {
			Test-ColSnapshotSchema -Snapshot $script:Snapshot | Should -BeTrue
		}

		It 'заповнює заголовок, топологію і набори даних' {
			$script:Snapshot.schemaVersion | Should -Be '1.0'
			$script:Snapshot.requestedServer | Should -Be 'SQL01'
			$script:Snapshot.topology.type | Should -Be 'Standalone'
			$script:Snapshot.analysisWindow.fromUtc | Should -Be '2026-10-11T08:00:00.000Z'
			$script:Snapshot.masking.namesMasked | Should -BeFalse
			$script:Snapshot.masking.literalsMasked | Should -BeFalse
			@($script:Snapshot.datasets.disabled).Count | Should -Be 0
			@($script:Snapshot.instances).Count | Should -Be 1
			$script:Snapshot.instances[0].sqlserverStartTimeUtc | Should -Be '2026-09-01T03:00:00.000Z'
			$script:Snapshot.instances[0].supportsOnlineIndexOps | Should -BeTrue
			$script:Snapshot.instances[0].lastFailoverUtc | Should -BeNullOrEmpty
		}

		It 'виконує лише запити колектора з файлів Queries, без ApplicationIntent' {
			$script:Calls | ForEach-Object { $_.Name | Should -Not -BeNullOrEmpty }
			@($script:Calls | Where-Object { $_.Name -ne 'topology' } | ForEach-Object Purpose | Sort-Object -Unique) | Should -Be @('Collector')
			@($script:Calls | Where-Object { $_.ApplicationIntent }).Count | Should -Be 0
			@($script:Calls | Where-Object { $_.Name -eq 'last_failover' }).Count | Should -Be 0
		}

		It 'пропускає базу не ONLINE з попередженням' {
			@($script:Snapshot.instances[0].databases.name) | Should -Not -Contain 'Offline'
			@($script:Snapshot.instances[0].warnings.code) | Should -Contain 'DatabaseNotOnline'
		}

		It 'збирає структуру: PK, UNIQUE, included-колонки, компресію MIXED, columnstore' {
			$pk = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'PK_Orders'
			$pk.isPrimaryKey | Should -BeTrue
			$pk.compression | Should -Be 'MIXED'
			$status = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'IX_Status'
			@($status.keyColumns.name) | Should -Be @('Status')
			@($status.includedColumns) | Should -Be @('OrderDate')
			$ncci = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'NCCI_Orders'
			@($ncci.includedColumns) | Should -Be @('OrderDate', 'Status')
			$uq = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Customers' 'UQ_Customers_Email'
			$uq.isUniqueConstraint | Should -BeTrue
		}

		It 'usage: рядок DMV або нулі, якщо рядка немає' {
			(Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'IX_CustomerId').usage.userSeeks | Should -Be 50000
			$status = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'IX_Status'
			$status.usage.userSeeks | Should -Be 0
			$status.usage.lastUserSeekUtc | Should -BeNullOrEmpty
			$status.operational.leafPageSplitCount | Should -Be 6000
		}

		It 'розмір: секції, рядки таблиці лише з купи чи кластерного індексу' {
			$sales = $script:Snapshot.instances[0].databases | Where-Object name -EQ 'Sales'
			$orders = $sales.tables | Where-Object name -EQ 'Orders'
			$orders.rowCount | Should -Be 5000000
			$orders.reservedMb | Should -Be 1994
			$pk = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'PK_Orders'
			@($pk.partitions).Count | Should -Be 1
			$pk.physical.mode | Should -Be 'LIMITED'
			$pk.physical.skipped | Should -BeFalse
			$pk.physical.avgFragmentationPercent | Should -Be 12.35
		}

		It 'physical_stats виконується по одному індексу в LIMITED, columnstore пропускається' {
			$physicalCalls = @($script:Calls | Where-Object Name -EQ 'physical_stats')
			$physicalCalls.Count | Should -Be 7
			$physicalCalls[0].Parameters['objectId'] | Should -Be 201
			$physicalCalls[0].Parameters['indexId'] | Should -Be 1
			$ncci = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'NCCI_Orders'
			$ncci.physical.skipped | Should -BeTrue
			$ncci.physical.skipReason | Should -Match 'Columnstore'
		}

		It 'missing index: розбір колонок і хешів запитів без дублікатів' {
			$sales = $script:Snapshot.instances[0].databases | Where-Object name -EQ 'Sales'
			$missing = @($sales.missingIndexes | Where-Object table -EQ 'Orders')[0]
			@($missing.equalityColumns).Count | Should -Be 0
			@($missing.inequalityColumns) | Should -Be @('OrderDate')
			@($missing.includedColumns) | Should -Be @('Amount', 'Status')
			@($missing.queryHashes) | Should -Be @('0x1A2B3C4D5E6F7081')
		}

		It 'обмеження: FK з обох боків, реплікація, хінти з модулів і Query Store' {
			$sales = $script:Snapshot.instances[0].databases | Where-Object name -EQ 'Sales'
			$sales.replication.isPublished | Should -BeFalse
			@((Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Customers' 'PK_Customers').referencedByForeignKeys) | Should -Be @('FK_Orders_Customers')
			$ixCustomer = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'IX_CustomerId'
			@($ixCustomer.coversForeignKeys) | Should -Be @('FK_Orders_Customers')
			$ixCustomer.usedByReplication | Should -BeFalse
			@($ixCustomer.hintReferences.source) | Should -Be @('SqlModule', 'QueryStore')
			$ixCustomer.hintReferences[1].queryId | Should -Be 1003
			@((Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'PK_Orders').coversForeignKeys).Count | Should -Be 0
			$sales.moduleHints[0].moduleName | Should -Be 'dbo.usp_GetOrdersByCustomer'
			$sales.moduleHints[0].tableName | Should -Be 'dbo.Orders'
			($sales.tables | Where-Object name -EQ 'Orders').foreignKeys[0].referencedIndexName | Should -Be 'PK_Customers'
		}

		It 'Query Store: налаштування, топ-запити, профіль по годинах і днях, категорії навантаження' {
			$sales = $script:Snapshot.instances[0].databases | Where-Object name -EQ 'Sales'
			$sales.queryStore.actualState | Should -Be 'READ_WRITE'
			$sales.queryStore.periodDays | Should -Be 90.33
			@($sales.queryStore.warnings).Count | Should -Be 0
			@($sales.queryStoreQueries).Count | Should -Be 3
			$q1001 = $sales.queryStoreQueries | Where-Object queryId -EQ 1001
			@($q1001.topBy) | Should -Be @('Cpu', 'Executions')
			@($q1001.byHour.hour) | Should -Be @(9, 10)
			($q1001.byHour | Where-Object hour -EQ 9).executionCount | Should -Be 150000
			@($q1001.byDayOfWeek.dayOfWeek) | Should -Be @(1, 2)
			$q1001.workloadCategory | Should -Be 'Oltp'
			($sales.queryStoreQueries | Where-Object queryId -EQ 1002).workloadCategory | Should -Be 'Report'
			$q1001.avgCpuMs | Should -Be 0.2
		}

		It 'Query Store: плани розібрано, кеш за query_plan_hash, регресія при кількох планах' {
			$sales = $script:Snapshot.instances[0].databases | Where-Object name -EQ 'Sales'
			$q1001 = $sales.queryStoreQueries | Where-Object queryId -EQ 1001
			$plan = $q1001.plans[0]
			$plan.hasKeyLookup | Should -BeTrue
			@($plan.indexOperations.index) | Should -Contain 'IX_CustomerId'
			$q1003 = $sales.queryStoreQueries | Where-Object queryId -EQ 1003
			@($q1003.plans[0].indexOperations.index) | Should -Contain 'IX_CustomerId'
			$q1002 = $sales.queryStoreQueries | Where-Object queryId -EQ 1002
			@($q1002.plans).Count | Should -Be 2
			$q1002.hasRegression | Should -BeTrue
			$q1002.plans[0].scansWholeTable | Should -BeTrue
			$q1001.hasRegression | Should -BeFalse
		}

		It 'index.queryStoreUsage рахує читання з усіх планів вікна, але не оновлення' {
			$ix = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'IX_CustomerId'
			$ix.queryStoreUsage.planCount | Should -Be 2
			@($ix.queryStoreUsage.queryIds) | Should -Be @(1001, 1003)
			$ix.queryStoreUsage.seekCount | Should -Be 2
			$ix.queryStoreUsage.lastUsedUtc | Should -Be '2026-11-10T07:59:00.000Z'
			$pk = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'PK_Orders'
			$pk.queryStoreUsage.lookupCount | Should -Be 2
			$pk.queryStoreUsage.scanCount | Should -Be 2
			@($pk.queryStoreUsage.queryIds) | Should -Not -Contain 9999
			(Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Customers' 'UQ_Customers_Email').queryStoreUsage.queryIds | Should -Be @(9998)
			$status = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'IX_Status'
			$status.queryStoreUsage.planCount | Should -Be 0
		}

		It 'Query Store OFF: queryStore з попередженням, queryStoreUsage = null, набір не позначено зібраним' {
			$archive = $script:Snapshot.instances[0].databases | Where-Object name -EQ 'Archive'
			$archive.queryStore.actualState | Should -Be 'OFF'
			@($archive.queryStore.warnings.code) | Should -Contain 'QueryStoreOff'
			@($archive.collectedDatasets) | Should -Not -Contain 'queryStore'
			$archive.tables[0].indexes[0].queryStoreUsage | Should -BeNullOrEmpty
			@($archive.collectedDatasets) | Should -Contain 'constraintsAndReplication'
		}

		It 'сирий XML планів не потрапляє в snapshot' {
			($script:Snapshot | ConvertTo-Json -Depth 50) | Should -Not -Match 'ShowPlanXML'
		}

		It 'часи — рядки ISO 8601 UTC' {
			$ix = Get-ColTestIndex $script:Snapshot 'SQL01' 'Sales' 'Orders' 'IX_CustomerId'
			$ix.usage.lastUserSeekUtc | Should -Be '2026-11-10T07:30:00.000Z'
			$ix.statsLastUpdatedUtc | Should -Be '2026-11-01T01:00:00.000Z'
		}
	}

	Context 'FCI' {
		It 'працює з одним вказаним інстансом' {
			Reset-ColTestState -Handlers (Get-ColTestHandlers -Type FCI)
			$snapshot = Invoke-ColTestCollection -Server 'FCI01\SQL' -Config (Get-IaTestConfig)
			$snapshot.topology.type | Should -Be 'FCI'
			@($snapshot.instances).Count | Should -Be 1
			$snapshot.instances[0].connectedTo | Should -Be 'FCI01\SQL'
			$snapshot.instances[0].isClustered | Should -BeTrue
			@($script:ColCalls | Where-Object { $_.Server -ne 'FCI01\SQL' }).Count | Should -Be 0
			Test-ColSnapshotSchema -Snapshot $snapshot | Should -BeTrue
		}
	}

	Context 'Always On AG' {
		BeforeAll {
			Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery {
				Invoke-ColTestSql -Server $Server -Database $Database -Query $Query -Parameters $Parameters -Fetch $Fetch -Skip $Skip -Purpose $Purpose -ApplicationIntent $ApplicationIntent
			}
			Mock -ModuleName IndexAdvisor Write-IaLog {}
			Reset-ColTestState -Handlers (Get-ColTestHandlers -Type AG)
			$script:AgSnapshot = Invoke-ColTestCollection -Server 'AGL-SALES' -Config (Get-IaTestConfig)
			$script:AgCalls = @($script:ColCalls)
		}

		It 'відповідає схемі snapshot' {
			Test-ColSnapshotSchema -Snapshot $script:AgSnapshot | Should -BeTrue
		}

		It 'підключається до кожної репліки напряму, пропускає SECONDARY з ALLOW_CONNECTIONS = NO' {
			@($script:AgSnapshot.instances.serverName) | Should -Be @('SQL01', 'SQL02')
			@($script:AgCalls | Where-Object Server -EQ 'SQL03').Count | Should -Be 0
			$replicas = $script:AgSnapshot.topology.availabilityGroups[0].replicas
			($replicas | Where-Object replicaServerName -EQ 'SQL03').collected | Should -BeFalse
			($replicas | Where-Object replicaServerName -EQ 'SQL03').skipReason | Should -Match 'ALLOW_CONNECTIONS = NO'
			($replicas | Where-Object replicaServerName -EQ 'SQL01').collected | Should -BeTrue
			($replicas | Where-Object replicaServerName -EQ 'SQL02').collected | Should -BeTrue
			@($script:AgSnapshot.warnings.code) | Should -Contain 'ReplicaSkipped'
		}

		It 'ApplicationIntent = ReadOnly лише для баз AG на вторинній з READ_ONLY' {
			$withIntent = @($script:AgCalls | Where-Object ApplicationIntent)
			$withIntent.Count | Should -BeGreaterThan 0
			@($withIntent | ForEach-Object { "$($_.Server)|$($_.Database)" } | Sort-Object -Unique) | Should -Be @('SQL02|Sales')
			@($script:AgCalls | Where-Object { $_.Server -eq 'SQL02' -and $_.Database -eq 'Archive' -and $_.ApplicationIntent }).Count | Should -Be 0
			@($script:AgCalls | Where-Object { $_.Database -eq 'master' -and $_.ApplicationIntent }).Count | Should -Be 0
		}

		It 'визначає роль репліки, час останнього failover і читає Query Store лише з primary' {
			$primary = $script:AgSnapshot.instances | Where-Object serverName -EQ 'SQL01'
			$secondary = $script:AgSnapshot.instances | Where-Object serverName -EQ 'SQL02'
			$primary.agRole | Should -Be 'PRIMARY'
			$secondary.agRole | Should -Be 'SECONDARY'
			$primary.lastFailoverUtc | Should -Be '2026-10-20T01:00:05.000Z'
			$secondarySales = $secondary.databases | Where-Object name -EQ 'Sales'
			$secondarySales.replicaRole | Should -Be 'SECONDARY'
			$secondarySales.availabilityGroup | Should -Be 'AG1'
			$secondarySales.queryStore | Should -BeNullOrEmpty
			@($secondarySales.warnings.code) | Should -Contain 'QueryStoreOnPrimaryOnly'
			@($script:AgCalls | Where-Object { $_.Server -eq 'SQL02' -and $_.Database -eq 'Sales' -and $_.Name -like 'query_store*' }).Count | Should -Be 0
			(Get-ColTestIndex $script:AgSnapshot 'SQL02' 'Sales' 'Orders' 'IX_Status').queryStoreUsage | Should -BeNullOrEmpty
		}

		It 'на вторинній фрагментація не збирається (physical skipped)' {
			$ix = Get-ColTestIndex $script:AgSnapshot 'SQL02' 'Sales' 'Orders' 'PK_Orders'
			$ix.physical.skipped | Should -BeTrue
			$ix.physical.skipReason | Should -Match 'Вторинна'
			@($script:AgCalls | Where-Object { $_.Server -eq 'SQL02' -and $_.Database -eq 'Sales' -and $_.Name -eq 'physical_stats' }).Count | Should -Be 0
		}

		It 'помилка репліки — попередження, collected = false і продовження' {
			$handlers = Get-ColTestHandlers -Type AG
			$base = $handlers.instance_info
			$fail = New-ColTestControl -Fail 'A network-related error' -Code 'ConnectionFailed'
			$handlers.instance_info = {
				param($call)
				if ($call.Server -eq 'SQL02') { return $fail }
				& $base $call
			}.GetNewClosure()
			Reset-ColTestState -Handlers $handlers
			$snapshot = Invoke-ColTestCollection -Server 'AGL-SALES' -Config (Get-IaTestConfig)
			@($snapshot.instances.serverName) | Should -Be @('SQL01')
			$replica = $snapshot.topology.availabilityGroups[0].replicas | Where-Object replicaServerName -EQ 'SQL02'
			$replica.collected | Should -BeFalse
			$replica.skipReason | Should -Match 'network-related'
			@($snapshot.warnings.code) | Should -Contain 'InstanceFailed'
			Test-ColSnapshotSchema -Snapshot $snapshot | Should -BeTrue
		}
	}

	Context 'помилки' {
		It 'помилка однієї бази — попередження і продовження з іншими' {
			$handlers = Get-ColTestHandlers -Type Standalone
			$base = $handlers.tables
			$fail = New-ColTestControl -Fail 'The server principal is not able to access the database'
			$handlers.tables = {
				param($call)
				if ($call.Database -eq 'Archive') { return $fail }
				& $base $call
			}.GetNewClosure()
			Reset-ColTestState -Handlers $handlers
			$snapshot = Invoke-ColTestCollection -Config (Get-IaTestConfig)
			@($snapshot.instances[0].databases.name) | Should -Be @('Sales')
			$warning = $snapshot.instances[0].warnings | Where-Object code -EQ 'DatabaseFailed'
			$warning.database | Should -Be 'Archive'
			$warning.message | Should -Match 'not able to access'
		}

		It 'помилка необов''язкового набору — попередження, поля null, набір не в collectedDatasets' {
			$handlers = Get-ColTestHandlers -Type Standalone
			$handlers.index_usage = { New-ColTestControl -Fail 'Lock request time out period exceeded' -Code 'Timeout' }
			Reset-ColTestState -Handlers $handlers
			$snapshot = Invoke-ColTestCollection -Config (Get-IaTestConfig)
			$sales = $snapshot.instances[0].databases | Where-Object name -EQ 'Sales'
			@($sales.collectedDatasets) | Should -Not -Contain 'usageStats'
			(Get-ColTestIndex $snapshot 'SQL01' 'Sales' 'Orders' 'PK_Orders').usage | Should -BeNullOrEmpty
			@($sales.warnings | Where-Object dataset -EQ 'usageStats').Count | Should -Be 1
		}

		It 'жодного інстансу не зібрано — IaCollectionFailed' {
			$handlers = Get-ColTestHandlers -Type Standalone
			$handlers.instance_info = { New-ColTestControl -Fail 'Cannot open server' -Code 'ConnectionFailed' }
			Reset-ColTestState -Handlers $handlers
			{ Invoke-ColTestCollection -Config (Get-IaTestConfig) } | Should -Throw -ErrorId 'IaCollectionFailed'
		}

		It 'відмова штатного логіна не ковтається — IaLoginRefused' {
			$handlers = Get-ColTestHandlers -Type Standalone
			$handlers.databases = { New-ColTestControl -Fail 'Логін не штатний' -Code 'LoginRefused' }
			Reset-ColTestState -Handlers $handlers
			{ Invoke-ColTestCollection -Config (Get-IaTestConfig) } | Should -Throw -ErrorId 'IaLoginRefused'
		}
	}

	Context 'вибір наборів даних' {
		It 'вимкнені набори дають null у полях, попередження і не запитуються' {
			Reset-ColTestState -Handlers (Get-ColTestHandlers -Type Standalone)
			$config = Get-IaTestConfig
			foreach ($name in @('usageStats', 'operationalStats', 'sizeAndFragmentation', 'missingIndexes', 'queryStore', 'constraintsAndReplication')) {
				$config.collector.datasets[$name] = $false
			}
			$config.collector.datasets.indexStructure = $false
			$snapshot = Invoke-ColTestCollection -Config $config
			Test-ColSnapshotSchema -Snapshot $snapshot | Should -BeTrue
			@($snapshot.datasets.enabled) | Should -Be @('indexStructure', 'instanceStartTime')
			@($snapshot.datasets.disabled).Count | Should -Be 6
			@($snapshot.datasets.warnings.code | Sort-Object -Unique) | Should -Be @('DatasetDisabled', 'MandatoryDatasetForced')
			($snapshot.datasets.warnings | Where-Object dataset -EQ 'queryStore').message | Should -Match 'не використовувався за період'
			$sales = $snapshot.instances[0].databases | Where-Object name -EQ 'Sales'
			@($sales.collectedDatasets) | Should -Be @('indexStructure', 'instanceStartTime')
			$sales.queryStore | Should -BeNullOrEmpty
			$sales.replication | Should -BeNullOrEmpty
			@($sales.missingIndexes).Count | Should -Be 0
			@($sales.queryStoreQueries).Count | Should -Be 0
			$orders = $sales.tables | Where-Object name -EQ 'Orders'
			$orders.rowCount | Should -BeNullOrEmpty
			$orders.isReplicated | Should -BeNullOrEmpty
			$ix = Get-ColTestIndex $snapshot 'SQL01' 'Sales' 'Orders' 'IX_CustomerId'
			foreach ($field in @('usage', 'operational', 'physical', 'partitions', 'rowCount', 'referencedByForeignKeys', 'coversForeignKeys', 'usedByReplication', 'hintReferences', 'queryStoreUsage')) {
				$ix[$field] | Should -BeNullOrEmpty -Because $field
			}
			$names = @($script:ColCalls.Name | Sort-Object -Unique)
			$names | Should -Be @(@('columns', 'databases', 'index_columns', 'indexes', 'instance_info', 'tables', 'topology') | Sort-Object)
		}
	}

	Context 'scope' {
		It 'фільтрує бази, схеми й таблиці за include/exclude з шаблонами * і ?' {
			Reset-ColTestState -Handlers (Get-ColTestHandlers -Type Standalone)
			$config = Get-IaTestConfig
			$config.scope.databases.include = @('Sal*', 'Arch?ve')
			$config.scope.databases.exclude = @('Arch*')
			$config.scope.schemas.exclude = @('etl')
			$config.scope.tables.exclude = @('dbo.Cust?mers')
			$snapshot = Invoke-ColTestCollection -Config $config
			@($snapshot.instances[0].databases.name) | Should -Be @('Sales')
			$sales = $snapshot.instances[0].databases[0]
			@($sales.tables.name) | Should -Be @('Orders')
			@($sales.missingIndexes.table) | Should -Be @('Orders')
			@($script:ColCalls | Where-Object Database -EQ 'Archive').Count | Should -Be 0
			@($script:ColCalls | Where-Object { $_.Name -eq 'physical_stats' -and $_.Parameters['objectId'] -ne 201 }).Count | Should -Be 0
			(Get-ColTestIndex $snapshot 'SQL01' 'Sales' 'Orders' 'IX_CustomerId').coversForeignKeys | Should -Be @('FK_Orders_Customers')
		}

		It 'шаблон таблиці без крапки зіставляється з іменем таблиці' {
			Reset-ColTestState -Handlers (Get-ColTestHandlers -Type Standalone)
			$config = Get-IaTestConfig
			$config.scope.databases.include = @('Sales')
			$config.scope.tables.include = @('Ord*')
			$snapshot = Invoke-ColTestCollection -Config $config
			@($snapshot.instances[0].databases[0].tables.name) | Should -Be @('Orders')
		}
	}

	Context 'пагінація' {
		It 'читає великі набори сторінками Fetch = limits.maxRows зі зсувом Skip до truncated = false' {
			Reset-ColTestState -Handlers (Get-ColTestHandlers -Type Standalone)
			$config = Get-IaTestConfig
			$config.limits.maxRows = 2
			$config.scope.databases.include = @('Sales')
			$snapshot = Invoke-ColTestCollection -Config $config
			$indexCalls = @($script:ColCalls | Where-Object Name -EQ 'indexes')
			@($indexCalls.Skip) | Should -Be @(0, 2, 4, 6)
			@($indexCalls.Fetch | Sort-Object -Unique) | Should -Be @(2)
			$sales = $snapshot.instances[0].databases[0]
			@($sales.tables.indexes).Count | Should -Be 7
			@($sales.tables.columns).Count | Should -Be 8
			@(($sales.tables | Where-Object name -EQ 'Orders').indexes.name) | Should -Be @('PK_Orders', 'IX_CustomerId', 'IX_Status', 'NCCI_Orders')
			@($script:ColCalls | Where-Object Name -EQ 'query_store_plans').Count | Should -Be 3
			(Get-ColTestIndex $snapshot 'SQL01' 'Sales' 'Orders' 'IX_CustomerId').queryStoreUsage.planCount | Should -Be 2
			Test-ColSnapshotSchema -Snapshot $snapshot | Should -BeTrue
		}
	}

	Context 'бюджет часу physical_stats' {
		It 'після вичерпання collector.physicalStatsTimeBudgetSeconds решта індексів позначається skipped' {
			$handlers = Get-ColTestHandlers -Type Standalone
			$handlers.physical_stats = {
				param($call)
				New-ColTestControl -DurationMs 600 -Rows @(New-ColTestRow @{ avgFragmentationPercent = 5.0; pageCount = 100; fragmentCount = 5 })
			}
			Reset-ColTestState -Handlers $handlers
			$config = Get-IaTestConfig
			$config.scope.databases.include = @('Sales')
			$config.collector.physicalStatsTimeBudgetSeconds = 1
			$snapshot = Invoke-ColTestCollection -Config $config
			$calls = @($script:ColCalls | Where-Object Name -EQ 'physical_stats')
			$calls.Count | Should -Be 2
			$calls[0].Parameters['indexId'] | Should -Be 1
			(Get-ColTestIndex $snapshot 'SQL01' 'Sales' 'Orders' 'PK_Orders').physical.skipped | Should -BeFalse
			$skipped = Get-ColTestIndex $snapshot 'SQL01' 'Sales' 'Orders' 'IX_Status'
			$skipped.physical.skipped | Should -BeTrue
			$skipped.physical.skipReason | Should -Match 'physicalStatsTimeBudgetSeconds'
			$skipped.physical.avgFragmentationPercent | Should -BeNullOrEmpty
			$sales = $snapshot.instances[0].databases[0]
			@($sales.warnings.code) | Should -Contain 'PhysicalStatsBudgetExceeded'
			Test-ColSnapshotSchema -Snapshot $snapshot | Should -BeTrue
		}
	}
}
