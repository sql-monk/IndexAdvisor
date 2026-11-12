# Живий інтеграційний тест: справжній SQL Server, модель замокана (без платних API). Запускається лише явно:
#   Invoke-Pester -Path .\tests\Integration -TagFilter Integration
# Змінні середовища:
#   IA_TEST_SQL_SERVER    інстанс або listener (обов'язкова; без неї тести пропускаються)
#   IA_TEST_SQL_DATABASE  база для аналізу (порожньо — усі користувацькі бази)
#   IA_TEST_SQL_LOGIN     SQL-логін (порожньо — Windows-автентифікація з -AllowNonStandardLogin)
#   IA_TEST_SQL_PASSWORD  пароль SQL-логіна (читається програмою через passwordRef env:, у тексті тесту не з'являється)
#   IA_TEST_SQL_TRUST_CERTIFICATE  1 — TrustServerCertificate = True (LocalDB, тестові сервери із самопідписаним сертифікатом)
#   IA_TEST_OUTPUT_PATH   каталог, де залишити звіти, архів і журнали прогону (порожньо — тимчасовий TestDrive)
# Перевіряє: повний збір усіх наборів даних, rules engine, звіти; кожен із 8 інструментів моделі на живому сервері;
# журнал сесії містить лише SELECT.

BeforeDiscovery {
	$script:IaLiveSkip = [string]::IsNullOrWhiteSpace($env:IA_TEST_SQL_SERVER)
}

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:module = Get-Module IndexAdvisor
	$script:root = if ($env:IA_TEST_OUTPUT_PATH) {
		(New-Item -ItemType Directory -Path $env:IA_TEST_OUTPUT_PATH -Force).FullName
	}
	else {
		(Get-PSDrive TestDrive).Root
	}
	$script:server = $env:IA_TEST_SQL_SERVER
	$script:database = $env:IA_TEST_SQL_DATABASE
	$script:useSqlLogin = -not [string]::IsNullOrWhiteSpace($env:IA_TEST_SQL_LOGIN)
	$env:IA_TEST_OPENAI_KEY = 'sk-test-not-a-real-key'

	function ConvertTo-TestYamlString {
		param([string]$Value)
		return "'" + $Value.Replace("'", "''") + "'"
	}

	$connectionYaml = if ($script:useSqlLogin) {
		@"
  authentication: Sql
  login: $(ConvertTo-TestYamlString $env:IA_TEST_SQL_LOGIN)
  passwordRef: env:IA_TEST_SQL_PASSWORD
"@
	}
	else {
		'  authentication: Windows'
	}
	$trust = if ($env:IA_TEST_SQL_TRUST_CERTIFICATE -eq '1') { 'true' } else { 'false' }
	$databasesYaml = if ($script:database) { "[$(ConvertTo-TestYamlString $script:database)]" } else { '[]' }
	$securityYaml = if ($script:useSqlLogin) { "security:`n  standardLogin: $(ConvertTo-TestYamlString $env:IA_TEST_SQL_LOGIN)" } else { '' }

	$script:yamlPath = Join-Path $script:root 'live.yaml'
	@"
version: 1
servers: [$(ConvertTo-TestYamlString $script:server)]
module: Both
scope:
  databases:
    include: $databasesYaml
connection:
$connectionYaml
  encrypt: Optional
  trustServerCertificate: $trust
$securityYaml
collector:
  datasets:
    usageStats: true
    operationalStats: true
    sizeAndFragmentation: true
    missingIndexes: true
    queryStore: true
    constraintsAndReplication: true
archive:
  path: $(ConvertTo-TestYamlString (Join-Path $script:root 'archive'))
logging:
  path: $(ConvertTo-TestYamlString (Join-Path $script:root 'logs'))
output:
  path: $(ConvertTo-TestYamlString (Join-Path $script:root 'out'))
  formats: [Markdown, Sql, Html, Json]
repository:
  enabled: false
llm:
  provider: openai
  budgetLedgerPath: $(ConvertTo-TestYamlString (Join-Path $script:root 'state\llm-usage.json'))
  providers:
    openai:
      type: OpenAI
      model: gpt-test
      apiKeyRef: env:IA_TEST_OPENAI_KEY
run:
  nonInteractive: true
"@ | Set-Content -LiteralPath $script:yamlPath -Encoding utf8

	# Відповідь моделі без рекомендацій і дозапитів: перевіряється збір і конвеєр, а не якість моделі.
	$script:modelText = '{"recommendations":[],"toolRequests":[],"notes":"live integration test"}'
}

AfterAll {
	Remove-Item Env:\IA_TEST_OPENAI_KEY -ErrorAction SilentlyContinue
}

Describe 'Живий прогін Invoke-IndexAdvisor (SQL справжній, модель замокана)' -Tag 'Integration' -Skip:$script:IaLiveSkip {
	BeforeAll {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			[pscustomobject]@{
				id = 'chatcmpl-live-test'
				model = 'gpt-test'
				choices = @([pscustomobject]@{ index = 0; finish_reason = 'stop'; message = [pscustomobject]@{ role = 'assistant'; content = $script:modelText } })
				usage = [pscustomobject]@{ prompt_tokens = 100; completion_tokens = 10; total_tokens = 110 }
			}
		}
		$extra = @{}
		if (-not $script:useSqlLogin) {
			$extra.AllowNonStandardLogin = $true
		}
		$script:result = @(Invoke-IndexAdvisor -Config $script:yamlPath -NoRepository -PassThru @extra 3>$null 6>$null)[0]
		$script:exitCode = $global:LASTEXITCODE
		$script:logText = (Get-ChildItem -LiteralPath (Join-Path $script:root 'logs') -Filter '*.md' -Recurse |
				ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 }) -join "`n"
	}

	It 'завершується без помилок (код 0 або 1)' {
		$script:result | Should -Not -BeNullOrEmpty
		($script:result.errors | ConvertTo-Json -Depth 5) | Should -BeIn @($null, '', '[]', 'null')
		$script:exitCode | Should -BeIn @(0, 1)
	}

	It 'збирає всі набори даних без збоїв' {
		$all = @('indexStructure', 'instanceStartTime', 'usageStats', 'operationalStats', 'sizeAndFragmentation', 'missingIndexes',
			'queryStore', 'constraintsAndReplication')
		foreach ($name in $all) {
			@($script:result.datasets.enabled) | Should -Contain $name
		}
		$failedCodes = @($script:result.datasets.warnings | Where-Object { [string]$_.code -match 'Failed|SqlError' } |
				ForEach-Object { "$($_.code) [$($_.server)/$($_.database)/$($_.dataset)]: $($_.message)" })
		$failedCodes | Should -BeNullOrEmpty
		$failedRun = @($script:result.warnings | Where-Object { [string]$_ -match 'не зібрано|Failed|SqlError|помилк' })
		$failedRun | Should -BeNullOrEmpty
	}

	It 'показує період даних і створює звіти' {
		@($script:result.dataPeriods).Count | Should -BeGreaterThan 0
		$out = Join-Path $script:root 'out'
		Get-ChildItem -LiteralPath $out -Recurse -Filter 'recommendations.md' | Should -Not -BeNullOrEmpty
		Get-ChildItem -LiteralPath $out -Recurse -Filter 'report.html' | Should -Not -BeNullOrEmpty
		Get-ChildItem -LiteralPath $out -Recurse -Filter 'result.json' | Should -Not -BeNullOrEmpty
	}

	It 'журнал сесії містить лише SELECT і жодної помилки SQL' {
		$script:logText | Should -Not -BeNullOrEmpty
		$script:logText | Should -Not -Match '(?im)^\s*(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE|EXEC|GRANT)\b'
		$script:logText | Should -Not -Match '(?i)SqlError|Msg \d{3,5},'
	}
}

Describe 'Інструменти моделі на живому сервері' -Tag 'Integration' -Skip:$script:IaLiveSkip {
	BeforeAll {
		$overrides = @{ logging = @{ path = (Join-Path $script:root 'tool-logs') } }
		$script:toolRun = & $script:module {
			param($yamlPath, $overrides, $requestedDatabase)
			$cfg = Get-IaConfig -Path $yamlPath -Overrides $overrides
			$null = Start-IaSession -Config $cfg -Command 'LiveRun.Integration.Tests'
			try {
				$server = [string]$cfg.servers[0]
				$databaseName = $requestedDatabase
				if ([string]::IsNullOrWhiteSpace($databaseName)) {
					$dbs = Invoke-IaSqlQuery -Server $server -Database 'master' -Purpose 'Collector' -Config $cfg -Fetch 1 -Query @'
SELECT d.name FROM sys.databases AS d WHERE d.database_id > 4 AND d.state = 0 AND HAS_DBACCESS(d.name) = 1 ORDER BY d.name
'@
					$databaseName = [string]@($dbs.rows)[0].name
				}
				# Таблиця з найбільшою кількістю індексів — щоб інструментам було що повернути.
				$tables = Invoke-IaSqlQuery -Server $server -Database $databaseName -Purpose 'Collector' -Config $cfg -Fetch 1 -Query @'
SELECT s.name AS schemaName, t.name AS tableName, MIN(i.name) AS indexName
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN sys.indexes AS i ON i.object_id = t.object_id AND i.index_id > 0
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name
ORDER BY COUNT(*) DESC, s.name, t.name
'@
				$table = @($tables.rows)[0]
				$tools = Import-IaToolDefinitions -Config $cfg
				$results = [ordered]@{}
				$argumentsByTool = @{
					index_operational_stats = @{ SchemaName = $table.schemaName; TableName = $table.tableName }
					index_usage_stats = @{ SchemaName = $table.schemaName; TableName = $table.tableName }
					missing_indexes = @{}
					query_store_plans = @{ IndexName = $table.indexName }
					query_store_predicates = @{ SchemaName = $table.schemaName; TableName = $table.tableName }
					query_store_top_queries = @{ OrderBy = 'logicalReads' }
					size_and_partitions = @{ SchemaName = $table.schemaName; TableName = $table.tableName }
					table_structure = @{ SchemaName = $table.schemaName; TableName = $table.tableName }
				}
				foreach ($name in @($tools.Keys)) {
					$arguments = if ($argumentsByTool.ContainsKey($name)) { $argumentsByTool[$name] } else { @{} }
					$results[$name] = Invoke-IaTool -Tool $tools[$name] -Arguments $arguments -Server $server -Database $databaseName -Config $cfg
				}
				return @{ database = $databaseName; table = $table; results = $results; toolNames = @($tools.Keys) }
			}
			finally {
				Stop-IaSession
			}
		} $script:yamlPath $overrides $script:database 3>$null 6>$null
	}

	It 'знаходить таблицю з індексами для перевірки' {
		$script:toolRun.table | Should -Not -BeNullOrEmpty
	}

	It 'завантажує всі 8 інструментів' {
		$script:toolRun.toolNames.Count | Should -Be 8
	}

	It 'кожен інструмент виконується без помилки' {
		foreach ($name in $script:toolRun.toolNames) {
			$response = $script:toolRun.results[$name]
			$message = if ($response.error) { "$($response.error.code): $($response.error.message)" } else { '' }
			$message | Should -BeNullOrEmpty -Because "інструмент $name"
		}
	}
}
