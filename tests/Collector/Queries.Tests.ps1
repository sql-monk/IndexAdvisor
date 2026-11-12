# Перевірка запитів колектора Collector/Queries/*.sql: рівно одна інструкція SELECT із системних джерел (потік Collector).
BeforeDiscovery {
	$queriesPath = Join-Path $PSScriptRoot '..\..\src\IndexAdvisor\Collector\Queries'
	$script:QueryCases = @(Get-ChildItem -LiteralPath $queriesPath -Filter '*.sql' | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } })
	Import-Module (Join-Path $PSScriptRoot '..\..\src\IndexAdvisor\IndexAdvisor.psd1') -Force -ErrorAction Stop
	$script:CoreReady = $true
	try {
		$null = & (Get-Module IndexAdvisor) { Test-IaSelectOnly -Sql 'SELECT 1;'; Test-IaSystemSourcesOnly -Sql 'SELECT 1;' }
	}
	catch [System.NotImplementedException] {
		$script:CoreReady = $false
	}
	catch {
		if ($_.Exception -is [System.NotImplementedException] -or $_.Exception.InnerException -is [System.NotImplementedException]) {
			$script:CoreReady = $false
		}
	}
	$library = Get-Module dbatools.library -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
	$script:ScriptDomPath = if ($library) { Join-Path $library.ModuleBase 'core\lib\Microsoft.SqlServer.TransactSql.ScriptDom.dll' } else { $null }
	$script:ScriptDomReady = [bool]($script:ScriptDomPath -and (Test-Path -LiteralPath $script:ScriptDomPath))
	foreach ($case in $script:QueryCases) {
		$case.ScriptDomPath = $script:ScriptDomPath
	}
}

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:Module = Get-Module IndexAdvisor
	function Get-ColTestSqlCode {
		<# Текст запиту без рядкових коментарів. #>
		param([string]$Text)
		return (($Text -split "`r?`n") | ForEach-Object { ($_ -replace '--.*$', '') }) -join "`n"
	}
}

Describe 'Запит колектора <Name>' -ForEach $QueryCases {
	BeforeAll {
		$script:Text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
		$script:Code = Get-ColTestSqlCode -Text $script:Text
	}

	It 'рівно одна інструкція SELECT (або WITH ... SELECT), що завершується крапкою з комою' {
		$script:Code.Trim() | Should -Match '^(SELECT|WITH)\b'
		$script:Code.Trim() | Should -Match ';$'
		([regex]::Matches($script:Code, ';')).Count | Should -Be 1
	}

	It 'без DECLARE, тимчасових таблиць, SELECT INTO, DML, DDL і EXEC' {
		$script:Code | Should -Not -Match '(?i)\b(DECLARE|INTO|INSERT|UPDATE|DELETE|MERGE|EXEC|EXECUTE|CREATE|ALTER|DROP|TRUNCATE|GRANT|SET)\b'
		$script:Code | Should -Not -Match '#'
		$script:Code | Should -Not -Match '(?i)\bOPTION\s*\('
		$script:Code | Should -Not -Match '(?i)\bTOP\s*\('
		$script:Code | Should -Not -Match '(?i)\bOFFSET\b'
		$script:Code | Should -Not -Match '(?i)\bOPEN(ROWSET|QUERY|DATASOURCE)\b'
	}

	It 'джерела FROM/JOIN — лише sys.* або CTE цього запиту' {
		$ctes = @([regex]::Matches($script:Code, '(?i)(?:\bWITH|,)\s*(\w+)\s+AS\s*\(') | ForEach-Object { $_.Groups[1].Value })
		$sources = @([regex]::Matches($script:Code, '(?i)\b(?:FROM|JOIN)\s+([\w.\[\]]+)') | ForEach-Object { $_.Groups[1].Value })
		$sources.Count | Should -BeGreaterThan 0
		foreach ($source in $sources) {
			($source -like 'sys.*' -or $source -in $ctes) | Should -BeTrue -Because "джерело $source"
		}
	}

	It 'параметри лише іменовані @camelCase, рядки до 160 символів, відступи табами' {
		foreach ($match in [regex]::Matches($script:Code, '(?<!@)@(?!@)(\w+)')) {
			$match.Groups[1].Value | Should -MatchExactly '^[a-z][A-Za-z0-9]*$'
		}
		foreach ($line in ($script:Text -split "`r?`n")) {
			$line.Length | Should -BeLessOrEqual 160
			$line | Should -Not -Match '^ +'
		}
	}

	It 'ScriptDom (TSql160Parser): без помилок, один батч, одна SelectStatement без INTO' -Skip:(-not $ScriptDomReady) {
		if (-not ('Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -as [type])) {
			Add-Type -LiteralPath $ScriptDomPath
		}
		$parser = New-Object -TypeName 'Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -ArgumentList $true
		$errors = $null
		$tree = $parser.Parse([System.IO.StringReader]::new($script:Text), [ref]$errors)
		@($errors).Count | Should -Be 0
		@($tree.Batches).Count | Should -Be 1
		$statements = @($tree.Batches[0].Statements)
		$statements.Count | Should -Be 1
		$statements[0].GetType().Name | Should -Be 'SelectStatement'
		$statements[0].Into | Should -BeNullOrEmpty
	}

	It 'Test-IaSelectOnly і Test-IaSystemSourcesOnly (Core) приймають запит' -Skip:(-not $CoreReady) {
		$select = & $script:Module { param($s) Test-IaSelectOnly -Sql $s } $script:Text
		$select.isValid | Should -BeTrue -Because (($select.errors | ForEach-Object { $_.message }) -join '; ')
		$sources = & $script:Module { param($s) Test-IaSystemSourcesOnly -Sql $s } $script:Text
		$sources.isValid | Should -BeTrue -Because (($sources.errors | ForEach-Object { $_.message }) -join '; ')
	}
}

Describe 'Тексти запитів колектора' {
	It 'Get-IaColQueryText читає файл і кешує текст; невідомий запит — помилка' {
		$first = & $script:Module { Get-IaColQueryText -Name 'topology' }
		$second = & $script:Module { Get-IaColQueryText -Name 'topology' }
		$first | Should -BeExactly $second
		$first | Should -Match 'sys\.availability_replicas'
		{ & $script:Module { Get-IaColQueryText -Name 'no_such_query' } } | Should -Throw
	}

	It 'запит топології містить усі джерела з контракту' {
		$text = & $script:Module { Get-IaColQueryText -Name 'topology' }
		foreach ($source in @("SERVERPROPERTY('IsHadrEnabled')", "SERVERPROPERTY('IsClustered')", '@@SERVERNAME', 'sys.availability_groups', 'sys.availability_replicas',
				'sys.availability_group_listeners', 'sys.dm_hadr_availability_replica_states')) {
			$text | Should -Match ([regex]::Escape($source))
		}
	}

	It 'запити великих наборів мають детермінований ORDER BY' -ForEach @(
		@{ Name = 'tables' }, @{ Name = 'columns' }, @{ Name = 'indexes' }, @{ Name = 'index_columns' }, @{ Name = 'index_usage' }, @{ Name = 'index_operational' },
		@{ Name = 'partition_stats' }, @{ Name = 'missing_indexes' }, @{ Name = 'missing_index_queries' }, @{ Name = 'foreign_keys' }, @{ Name = 'module_hints' },
		@{ Name = 'query_store_top_queries' }, @{ Name = 'query_store_time_profile' }, @{ Name = 'query_store_plan_list' }, @{ Name = 'query_store_plan_stats' },
		@{ Name = 'query_store_plan_xml' }, @{ Name = 'query_store_hint_texts' }, @{ Name = 'databases' }
	) {
		$text = & $script:Module { param($n) Get-IaColQueryText -Name $n } $Name
		$text | Should -Match '(?s)\bORDER BY\b[^;]+;\s*$'
	}
}
