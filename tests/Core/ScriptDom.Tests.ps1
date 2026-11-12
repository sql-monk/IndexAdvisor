# Юніт-тести ScriptDom і перевірок тексту (потік Core). ScriptDom — справжній (dbatools.library), не мокається.

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:IaModule = Get-Module IndexAdvisor
}

Describe 'Get-IaScriptDomParser і ConvertTo-IaSqlFragment' {
	It 'повертає найновіший парсер TSqlNNNParser не нижче 150' {
		$parser = & $script:IaModule { Get-IaScriptDomParser }
		$parser.GetType().Name | Should -Match '^TSql(\d+)Parser$'
		[int]($parser.GetType().Name -replace '\D', '') | Should -BeGreaterOrEqual 150
	}

	It 'розбирає валідний T-SQL без помилок' {
		$result = & $script:IaModule { ConvertTo-IaSqlFragment -Sql 'SELECT o.name FROM sys.objects AS o;' }
		$result.fragment | Should -Not -BeNullOrEmpty
		@($result.errors).Count | Should -Be 0
		$result.parserName | Should -Match '^TSql\d+Parser$'
	}

	It 'повертає помилки розбору з рядком і стовпцем і fragment = $null' {
		$result = & $script:IaModule { ConvertTo-IaSqlFragment -Sql "SELECT 1`nFROM WHERE" }
		$result.fragment | Should -BeNullOrEmpty
		@($result.errors).Count | Should -BeGreaterThan 0
		$result.errors[0].code | Should -Be 'SqlError'
		$result.errors[0].line | Should -Be 2
		$result.errors[0].column | Should -BeGreaterThan 0
	}
}

Describe 'Test-IaSelectOnly' {
	It 'одна інструкція SELECT валідна' {
		$result = & $script:IaModule { Test-IaSelectOnly -Sql 'WITH c AS (SELECT 1 AS a) SELECT a FROM c ORDER BY a;' }
		$result.isValid | Should -BeTrue
		$result.statementCount | Should -Be 1
		@($result.errors).Count | Should -Be 0
	}

	It 'рахує інструкції і відхиляє дві SELECT' {
		$result = & $script:IaModule { Test-IaSelectOnly -Sql 'SELECT 1; SELECT 2;' }
		$result.isValid | Should -BeFalse
		$result.statementCount | Should -Be 2
	}

	It 'відхиляє порожній текст і текст лише з коментарем' -ForEach @(@{ Sql = '' }, @{ Sql = '-- SELECT 1' }) {
		$result = & $script:IaModule { param($s) Test-IaSelectOnly -Sql $s } $Sql
		$result.isValid | Should -BeFalse
		$result.statementCount | Should -Be 0
	}

	It 'позначає позицію забороненої інструкції' {
		$result = & $script:IaModule { Test-IaSelectOnly -Sql "SELECT 1;`nDROP TABLE dbo.t;" }
		$dropError = @($result.errors) | Where-Object { $_.message -match 'DropTable' }
		$dropError.line | Should -Be 2
	}
}

Describe 'Test-IaSystemSourcesOnly' {
	It 'дозволяє: <Name>' -ForEach @(
		@{ Name = 'CTE без схеми'; Sql = 'WITH c AS (SELECT name FROM sys.objects) SELECT name FROM c;' }
		@{ Name = 'рекурсивний CTE'; Sql = 'WITH n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 5) SELECT i FROM n;' }
		@{ Name = 'INFORMATION_SCHEMA у нижньому регістрі'; Sql = 'SELECT * FROM information_schema.columns;' }
		@{ Name = 'системна скалярна функція'; Sql = 'SELECT sys.fn_varbintohexstr(0x01) AS h;' }
		@{ Name = 'системна функція з префіксом бази'; Sql = 'SELECT master.sys.fn_varbintohexstr(0x01) AS h;' }
		@{ Name = 'XML-методи value і nodes'; Sql = "SELECT n.c.value('@a', 'int') AS a FROM sys.dm_exec_query_stats AS s CROSS APPLY sys.dm_exec_query_plan(s.plan_handle) AS p CROSS APPLY p.query_plan.nodes('//x') AS n(c);" }
		@{ Name = 'вбудовані табличні функції'; Sql = "SELECT value FROM STRING_SPLIT(N'a,b', N',');" }
		@{ Name = 'OPENJSON для параметра'; Sql = 'SELECT [key] FROM OPENJSON(@json);' }
		@{ Name = 'VALUES як джерело'; Sql = "SELECT v.a FROM (VALUES (1), (2)) AS v (a);" }
		@{ Name = 'системний тип CLR'; Sql = 'SELECT geography::Point(0, 0, 4326).STAsText() AS p;' }
	) {
		$result = & $script:IaModule { param($s) Test-IaSystemSourcesOnly -Sql $s } $Sql
		$result.errors | Should -BeNullOrEmpty
		$result.isValid | Should -BeTrue
	}

	It 'забороняє: <Name>' -ForEach @(
		@{ Name = 'CTE зі схемою'; Sql = 'WITH c AS (SELECT name FROM sys.objects) SELECT name FROM dbo.c;' }
		@{ Name = 'тимчасова таблиця'; Sql = 'SELECT * FROM #t;' }
		@{ Name = 'таблична змінна'; Sql = 'SELECT * FROM @t;' }
		@{ Name = 'CHANGETABLE користувацької таблиці'; Sql = 'SELECT * FROM CHANGETABLE(CHANGES dbo.Orders, 0) AS c;' }
		@{ Name = 'користувацька таблиця в підзапиті'; Sql = 'SELECT name FROM sys.objects WHERE object_id IN (SELECT ObjectId FROM dbo.Secrets);' }
		@{ Name = 'користувацька таблиця в JOIN'; Sql = 'SELECT o.name FROM sys.objects AS o INNER JOIN dbo.Orders AS x ON x.Id = o.object_id;' }
		@{ Name = 'функція з префіксом бази'; Sql = 'SELECT Sales.dbo.fnSecret() AS v;' }
		@{ Name = 'CONTAINSTABLE'; Sql = "SELECT * FROM CONTAINSTABLE(dbo.Docs, Body, N'x') AS f;" }
		@{ Name = 'текст не розбирається'; Sql = 'SELECT FROM' }
	) {
		$result = & $script:IaModule { param($s) Test-IaSystemSourcesOnly -Sql $s } $Sql
		$result.isValid | Should -BeFalse
		@($result.errors)[0].code | Should -Be 'ForbiddenSource'
	}
}
