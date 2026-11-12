# Статичні перевірки SQL-скриптів поставки: права лише через ролі, без ролей з доступом до даних, ідемпотентність, синтаксис (ScriptDom).
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')

	$script:LoginScriptPath = Join-Path $script:IaRepoRoot 'sql\Setup-IndexAdvisorLogin.sql'
	$script:RepositoryScriptPath = Join-Path $script:IaRepoRoot 'sql\Repository\IndexAdvisor.Repository.sql'
	$script:AllowedRoles = @('[srv_index_advisor]', '[db_index_advisor]')

	function Get-TestSqlCode {
		<# Текст без коментарів; подвоєні лапки динамічного SQL нормалізуються до одинарних. #>
		param([Parameter(Mandatory)][string]$Path)
		$text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
		$text = [regex]::Replace($text, '(?s)/\*.*?\*/', '')
		$text = [regex]::Replace($text, '(?m)--.*$', '')
		return $text.Replace("''", "'")
	}

	function Get-TestSqlParseErrors {
		<# Розбір T-SQL справжнім ScriptDom (dbatools.library). #>
		param([Parameter(Mandatory)][string]$Sql)
		if (-not ('Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -as [type])) {
			Import-Module -Name 'dbatools.library' -ErrorAction Stop
		}
		$parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser]::new($true)
		$errors = $null
		$null = $parser.Parse([System.IO.StringReader]::new($Sql), [ref]$errors)
		return , @($errors | ForEach-Object { "$($_.Line):$($_.Column) $($_.Message)" })
	}
}

Describe 'sql/Setup-IndexAdvisorLogin.sql' {
	BeforeAll {
		$script:LoginCode = Get-TestSqlCode -Path $script:LoginScriptPath
		$script:LoginText = Get-Content -LiteralPath $script:LoginScriptPath -Raw -Encoding utf8
	}

	It 'надає права лише ролям srv_index_advisor і db_index_advisor, ніколи логіну чи користувачу' {
		$grants = [regex]::Matches($script:LoginCode, '(?i)\bGRANT\s+([^;]+?)\s+TO\s+(\[[^\]]+\]|[^\s;]+)')
		$grants.Count | Should -Be 4
		foreach ($grant in $grants) {
			$script:AllowedRoles | Should -Contain $grant.Groups[2].Value
			$grant.Groups[1].Value | Should -Match '^VIEW (SERVER STATE|ANY DEFINITION|DATABASE STATE|DEFINITION)$'
		}
		$script:LoginCode | Should -Not -Match '(?i)\b(DENY|REVOKE)\b'
		$script:LoginCode | Should -Not -Match '(?i)GRANT[^;]*QUOTENAME'
	}

	It 'членство лише в ролях програми, без db_datareader, db_owner, sysadmin' {
		$members = [regex]::Matches($script:LoginCode, '(?i)ALTER\s+(SERVER\s+)?ROLE\s+(\[[^\]]+\]|\S+)\s+ADD\s+MEMBER')
		$members.Count | Should -Be 2
		foreach ($member in $members) {
			$script:AllowedRoles | Should -Contain $member.Groups[2].Value
		}
		$script:LoginCode | Should -Not -Match '(?i)(db_datareader|db_datawriter|db_owner|sysadmin|securityadmin)\]?\s+ADD\s+MEMBER'
		$script:LoginCode | Should -Not -Match '(?i)sp_add(srv)?rolemember'
		$script:LoginCode | Should -Not -Match '(?i)GRANT\s+SELECT'
	}

	It 'ідемпотентний: перевірка ролі через USER_ID, логіна й серверної ролі через SUSER_ID' {
		$script:LoginCode | Should -Match ([regex]::Escape("IF USER_ID('db_index_advisor') IS NULL CREATE ROLE [db_index_advisor];"))
		$script:LoginCode | Should -Match ([regex]::Escape("IF SUSER_ID(N'srv_index_advisor') IS NULL"))
		$script:LoginCode | Should -Match ([regex]::Escape('IF SUSER_ID(@loginName) IS NULL'))
		$script:LoginCode | Should -Match ([regex]::Escape('IF USER_ID(@loginName) IS NULL'))
	}

	It 'SQL-логін з CHECK_POLICY = ON; підтримка Windows-логіна' {
		$script:LoginCode | Should -Match 'CHECK_POLICY = ON'
		$script:LoginCode | Should -Not -Match 'CHECK_POLICY = OFF'
		$script:LoginCode | Should -Match 'FROM WINDOWS'
	}

	It 'має режими Install, AddDatabase, Remove, Verify і sqlcmd-змінні лише як рядкові літерали' {
		foreach ($mode in @('Install', 'AddDatabase', 'Remove', 'Verify')) {
			$script:LoginCode | Should -Match "N'$mode'"
		}
		foreach ($name in @('Mode', 'LoginName', 'LoginType', 'LoginPassword', 'Databases')) {
			$script:LoginText | Should -Match ([regex]::Escape("N'`$($name)'"))
		}
		$withoutLiterals = [regex]::Replace($script:LoginCode, "N'\$\([A-Za-z]+\)'", '')
		$withoutLiterals | Should -Not -Match '\$\('
		$script:LoginCode | Should -Match 'DROP LOGIN'
		$script:LoginCode | Should -Match 'DROP USER'
		$script:LoginCode | Should -Match 'DROP SERVER ROLE \[srv_index_advisor\]'
	}

	It 'Verify виконує лише SELECT і попереджає про зайві права' {
		$match = [regex]::Match($script:LoginText, '(?s)\[Verify:begin\](.*?)\[Verify:end\]')
		$match.Success | Should -BeTrue
		$verify = $match.Groups[1].Value
		$verify | Should -Not -Match '(?i)\b(CREATE|ALTER|DROP)\s+(LOGIN|USER|ROLE|SERVER|TABLE|INDEX|SCHEMA|PROCEDURE|VIEW)\b'
		$verify | Should -Not -Match '(?i)\b(GRANT|DENY|REVOKE|MERGE|TRUNCATE)\s'
		$verify | Should -Not -Match '(?i)\bINSERT\s+INTO\b|\bDELETE\s+FROM\b|\bUPDATE\s+\S+\s+SET\b|\bSELECT\b[^;]*\bINTO\s+[#@\[]'
		$verify | Should -Match 'EXEC sys\.sp_executesql @sql'
		foreach ($role in @('sysadmin', 'db_owner', 'db_datareader', 'db_datawriter')) {
			$verify | Should -Match $role
		}
		$verify | Should -Match 'IsExcessive'
	}

	It 'синтаксично коректний T-SQL (ScriptDom) після підстановки змінних' {
		$text = $script:LoginText
		foreach ($pair in @(@('Mode', 'Install'), @('LoginName', 'index-advisor'), @('LoginType', 'Sql'), @('Databases', 'ALL'))) {
			$text = $text.Replace("N'`$($($pair[0]))'", "N'$($pair[1])'")
		}
		$text = $text.Replace("N'`$(LoginPassword)'", '@IaLoginPassword')
		Get-TestSqlParseErrors -Sql $text | Should -BeNullOrEmpty
	}

	It 'рядки не довші за 160 символів' {
		$long = @(Get-Content -LiteralPath $script:LoginScriptPath -Encoding utf8 | Where-Object { $_.Replace("`t", '    ').Length -gt 160 })
		$long | Should -BeNullOrEmpty
	}
}

Describe 'sql/Repository/IndexAdvisor.Repository.sql' {
	BeforeAll {
		$script:RepositoryCode = Get-TestSqlCode -Path $script:RepositoryScriptPath
		$script:RepositoryText = Get-Content -LiteralPath $script:RepositoryScriptPath -Raw -Encoding utf8
	}

	It 'створює всі таблиці схеми Advisor ідемпотентно, з ON DELETE CASCADE для дочірніх таблиць' {
		foreach ($table in @('AnalysisRun', 'RunDataPeriod', 'LlmCall', 'ToolRequest', 'Recommendation', 'ObjectVerdict')) {
			$script:RepositoryCode | Should -Match ([regex]::Escape("IF OBJECT_ID(N'Advisor.$table', N'U') IS NULL"))
			$script:RepositoryCode | Should -Match "CREATE TABLE Advisor\.$table\b"
		}
		([regex]::Matches($script:RepositoryCode, 'REFERENCES Advisor\.AnalysisRun \(RunId\) ON DELETE CASCADE')).Count | Should -Be 5
		$script:RepositoryCode | Should -Match 'IX_ObjectKey_CreatedAtUtc ON Advisor\.Recommendation \(ObjectKey, CreatedAtUtc\)'
		$script:RepositoryCode | Should -Match 'IX_ObjectKey_AnalyzedAtUtc ON Advisor\.ObjectVerdict \(ObjectKey, AnalyzedAtUtc\)'
		$script:RepositoryCode | Should -Match 'PRIMARY KEY CLUSTERED \(RunId, ObjectKey\)'
	}

	It 'права лише через роль db_index_advisor на схему Advisor' {
		$script:RepositoryCode | Should -Match ([regex]::Escape("IF USER_ID('db_index_advisor') IS NULL CREATE ROLE [db_index_advisor];"))
		$grants = [regex]::Matches($script:RepositoryCode, '(?i)\bGRANT\s+([^;]+?)\s+TO\s+(\[[^\]]+\]|[^\s;]+)')
		$grants.Count | Should -Be 1
		$grants[0].Groups[1].Value | Should -Be 'SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[Advisor]'
		$grants[0].Groups[2].Value | Should -Be '[db_index_advisor]'
		$members = [regex]::Matches($script:RepositoryCode, '(?i)ALTER\s+(SERVER\s+)?ROLE\s+(\[[^\]]+\]|\S+)\s+ADD\s+MEMBER')
		foreach ($member in $members) {
			$member.Groups[2].Value | Should -Be '[db_index_advisor]'
		}
		$script:RepositoryCode | Should -Not -Match '(?i)(db_datareader|db_datawriter|db_owner|sysadmin)\]?\s+ADD\s+MEMBER'
	}

	It 'не зберігає сирі дані DMV і Query Store' {
		$script:RepositoryCode | Should -Not -Match '(?i)QueryText|PlanXml|query_plan|SnapshotJson'
	}

	It 'синтаксично коректний T-SQL (ScriptDom)' {
		$text = $script:RepositoryText.Replace("N'`$(RepositoryLogin)'", "N'CONTOSO\index-advisor'")
		Get-TestSqlParseErrors -Sql $text | Should -BeNullOrEmpty
		$long = @(Get-Content -LiteralPath $script:RepositoryScriptPath -Encoding utf8 | Where-Object { $_.Replace("`t", '    ').Length -gt 160 })
		$long | Should -BeNullOrEmpty
	}
}
