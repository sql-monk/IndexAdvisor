BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'LlmTestHelpers.ps1')
	Register-IaLlmScriptDomMock

	function Invoke-TestContext {
		param(
			[System.Collections.IDictionary]$Snapshot,
			[object[]]$Findings = @(),
			[string]$Module = 'Indexes',
			[int]$MaxContextTokens = 100000,
			[System.Collections.IDictionary]$Config = (Get-IaTestConfig)
		)
		$provider = [ordered]@{ name = 'test'; type = 'OpenAI'; model = 'm'; maxContextTokens = $MaxContextTokens }
		return InModuleScope IndexAdvisor -Parameters @{ Snapshot = $Snapshot; Findings = $Findings; Module = $Module; Provider = $provider; Config = $Config } {
			param($Snapshot, $Findings, $Module, $Provider, $Config)
			New-IaLlmContext -Snapshot $Snapshot -Findings $Findings -Module $Module -ProviderConfig $Provider -Config $Config
		}
	}

	function New-TestFinding {
		param([string]$Table, [string]$Index, [string]$Severity = 'High')
		return InModuleScope IndexAdvisor -Parameters @{ Table = $Table; Index = $Index; Severity = $Severity } {
			param($Table, $Index, $Severity)
			New-IaFinding -RuleId 'UnusedIndex' -Severity $Severity -Target (New-IaTarget -Server 'AG1' -Database 'Sales' -Schema 'dbo' -Table $Table -Index $Index) -Message "Індекс $Index не використовується"
		}
	}
}

Describe 'New-IaLlmContext (модуль Indexes)' {
	BeforeAll {
		$script:Snapshot = Get-IaTestSnapshot
		$script:Context = Invoke-TestContext -Snapshot $script:Snapshot -Findings @(New-TestFinding -Table 'Orders' -Index 'IX_Status' -Severity 'Medium')
		$script:Database = $script:Context.payload.databases[0]
		$script:Orders = $script:Database.tables | Where-Object { $_.name -eq 'Orders' }
	}

	It 'повертає контрактні поля' {
		@($script:Context.Keys) | Should -Be @('payload', 'includedObjectKeys', 'truncatedObjects', 'estimatedTokens', 'module')
		$script:Context.module | Should -Be 'Indexes'
		$script:Context.estimatedTokens | Should -BeGreaterThan 0
		$script:Context.truncatedObjects.Count | Should -Be 0
	}

	It 'includedObjectKeys побудовано через Get-IaObjectKey; для бази в AG server — ім''я AG' {
		$keys = $script:Context.includedObjectKeys
		$keys | Should -Contain 'ag1|sales|dbo.orders|'
		$keys | Should -Contain 'ag1|sales|dbo.orders|ix_status'
		$keys | Should -Contain 'ag1|sales|dbo.orders|pk_orders'
		$keys | Should -Contain 'ag1|sales|dbo.customers|'
		$keys | Should -Contain 'ag1|sales|dbo.customers|uq_customers_email'
		$keys | Where-Object { $_ -like 'sql0*' } | Should -BeNullOrEmpty
		$keys.Count | Should -Be 10
	}

	It 'об''єднує репліки AG: структура з primary, статистика використання з кожної репліки' {
		$script:Context.payload.databases.Count | Should -Be 1
		$script:Database.server | Should -Be 'AG1'
		$script:Database.database | Should -Be 'Sales'
		@($script:Database.replicas | ForEach-Object { $_.server }) | Should -Be @('SQL01', 'SQL02')
		$status = $script:Orders.indexes | Where-Object { $_.name -eq 'IX_Status' }
		@($status.replicaStats | ForEach-Object { $_.server }) | Should -Be @('SQL01', 'SQL02')
		$status.replicaStats[1].usage | Should -Not -BeNullOrEmpty
	}

	It 'містить структуру, індекси, статистику, топ-запити, знахідки, періоди даних, набори й supportsOnlineIndexOps' {
		$script:Database.supportsOnlineIndexOps | Should -BeTrue
		$script:Database.dataPeriod.queryStorePeriodDays | Should -Be 90.33
		$script:Database.dataPeriod.uptimeDays | Should -BeGreaterThan 0
		$script:Context.payload.datasets.enabled | Should -Contain 'queryStore'
		$script:Context.payload.instances.Count | Should -Be 2
		$script:Context.payload.instances[0].uptimeDays | Should -BeGreaterThan 0
		$script:Orders.columns.Count | Should -BeGreaterThan 0
		$script:Orders.indexes.Count | Should -Be 6
		$script:Orders.missingIndexes.Count | Should -BeGreaterThan 0
		$script:Orders.moduleHints[0].indexName | Should -Be 'IX_CustomerId'
		$script:Orders.findings[0].ruleId | Should -Be 'UnusedIndex'
		$script:Orders.findings[0].index | Should -Be 'IX_Status'
		@($script:Database.queries | ForEach-Object { $_.queryId }) | Should -Be @(1002, 1001, 1003)
		$script:Context.payload.masking.namesMasked | Should -BeFalse
	}

	It 'тексти запитів — без літералів, а планів — лише стиснений розбір' {
		$query = $script:Database.queries | Where-Object { $_.queryId -eq 1001 }
		$query.queryText | Should -Be 'SELECT o.OrderId, o.Amount FROM dbo.Orders AS o WHERE o.CustomerId = @customerId AND o.OrderDate >= {date}'
		$json = ConvertTo-Json -InputObject $script:Context.payload -Depth 50 -Compress
		$json | Should -Not -Match '2026-10-01'''
		$json | Should -Not -Match 'ShowPlanXML'
	}

	It 'дотримується maxContextTokens: пріоритет — таблиці зі знахідками, решта у truncatedObjects' {
		$full = Invoke-TestContext -Snapshot $script:Snapshot
		$empty = Get-IaTestSnapshot
		foreach ($instance in $empty.instances) {
			foreach ($database in $instance.databases) {
				$database.tables = @()
			}
		}
		$base = Invoke-TestContext -Snapshot $empty
		$limit = [int][Math]::Ceiling((($base.estimatedTokens + $full.estimatedTokens) / 2) / 0.8)
		$limited = Invoke-TestContext -Snapshot $script:Snapshot -Findings @(New-TestFinding -Table 'Customers' -Index 'UQ_Customers_Email') -MaxContextTokens $limit
		$limited.estimatedTokens | Should -BeLessOrEqual $limit
		$limited.estimatedTokens | Should -BeLessThan $full.estimatedTokens
		$limited.includedObjectKeys | Should -Contain 'ag1|sales|dbo.customers|'
		$limited.includedObjectKeys | Should -Not -Contain 'ag1|sales|dbo.orders|'
		@($limited.truncatedObjects | ForEach-Object { $_.objectKey }) | Should -Contain 'ag1|sales|dbo.orders|'
		$limited.truncatedObjects[0].reason | Should -BeIn @('Omitted', 'Reduced')
		$limited.payload.truncatedObjects | Should -Not -BeNullOrEmpty
	}

	It 'для standalone-інстансу server — ім''я інстансу' {
		$snapshot = Get-IaTestSnapshot
		$snapshot.instances = @($snapshot.instances[0])
		$snapshot.instances[0].databases[0].availabilityGroup = $null
		$context = Invoke-TestContext -Snapshot $snapshot
		$context.includedObjectKeys | Should -Contain 'sql01|sales|dbo.orders|ix_status'
		$context.payload.databases[0].server | Should -Be 'SQL01'
	}
}

Describe 'New-IaLlmContext (модуль Partitioning)' {
	It 'без кандидатів за порогами таблиці не потрапляють у контекст' {
		$context = Invoke-TestContext -Snapshot (Get-IaTestSnapshot) -Module 'Partitioning'
		$context.module | Should -Be 'Partitioning'
		$context.payload.databases[0].tables.Count | Should -Be 0
		$context.includedObjectKeys.Count | Should -Be 0
		$context.payload.partitioningThresholds.minSizeGb | Should -Be 50
	}

	It 'кандидати мають секції індексів і зведення предикатів' {
		$config = Get-IaTestConfig
		$config.partitioning.minRowCount = 1000
		$context = Invoke-TestContext -Snapshot (Get-IaTestSnapshot) -Module 'Partitioning' -Config $config
		$orders = $context.payload.databases[0].tables | Where-Object { $_.name -eq 'Orders' }
		$orders | Should -Not -BeNullOrEmpty
		$orders.indexes[0].partitions | Should -Not -BeNullOrEmpty
		$orderDate = $orders.predicateSummary | Where-Object { $_.column -eq 'OrderDate' }
		$orderDate.operator | Should -Be 'Range'
		$orderDate.queryCount | Should -BeGreaterThan 0
		$context.includedObjectKeys | Should -Contain 'ag1|sales|dbo.orders|'
	}
}
