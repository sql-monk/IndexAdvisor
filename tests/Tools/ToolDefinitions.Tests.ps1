# Тести розбору Markdown-інструментів, завантаження набору і JSON-схеми (потік Tools).
BeforeDiscovery {
	. (Join-Path $PSScriptRoot 'Tools.TestHelpers.ps1')
	$manifest = Join-Path $PSScriptRoot '..\..\src\IndexAdvisor\IndexAdvisor.psd1'
	Import-Module $manifest -Force -ErrorAction Stop
	$definitionsPath = Join-Path $PSScriptRoot '..\..\src\IndexAdvisor\Tools\Definitions'
	$script:builtInFiles = @(Get-ChildItem -LiteralPath $definitionsPath -Filter '*.md' -File | ForEach-Object { @{ File = $_.FullName; Name = $_.BaseName } })
	$script:coreNotReady = $false
	try {
		$null = & (Get-Module IndexAdvisor) { Test-IaSelectOnly -Sql 'SELECT 1;'; Test-IaSystemSourcesOnly -Sql 'SELECT 1;' }
	}
	catch [System.NotImplementedException] {
		$script:coreNotReady = $true
	}
	catch {
		$script:coreNotReady = $_.Exception -is [System.NotImplementedException] -or $_.Exception.InnerException -is [System.NotImplementedException]
	}
}

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Tools.TestHelpers.ps1')
	$script:module = Get-Module IndexAdvisor
	$script:validTool = @'
# sample_tool

## Description
Тестовий інструмент.
Другий рядок опису.

## Method
Query

## Server
SQLX

## Database
SalesX

## Parameters
- @SchemaName: string {maxLength=128} - Схема
- @Kind: string? {enum=Seek|Scan, default=Seek} - Вид
- @Top: int? {min=1, max=100, default=10} - Кількість
- @Ratio: decimal? {min=0.5, max=99.5} - Частка
- @Big: bigint? - Велике число
- @Flag: bool? {default=true} - Прапорець
- @FromUtc: datetime? {default=2026-01-01T00:00:00Z} - Початок
- @Id: guid? - Ідентифікатор

## Query
```sql
-- коментар з @NotAParam
SELECT TOP (@Top) s.name, N'@AlsoNot' AS [@col], @@ROWCOUNT AS rc /* @Nope */
FROM sys.schemas AS s
WHERE s.name = @SchemaName AND @Kind IS NOT NULL AND @Ratio IS NULL AND @Big IS NULL AND @Flag = 1
	AND @FromUtc IS NOT NULL AND @Id IS NULL;
```
'@

	function Get-TestParseError {
		param([string]$Path)
		try {
			$null = & $script:module { param($p) ConvertFrom-IaToolMarkdown -Path $p } $Path
		}
		catch {
			return $_
		}
		return $null
	}
}

Describe 'ConvertFrom-IaToolMarkdown: валідний файл' {
	BeforeAll {
		$path = New-TestToolFile -Name 'sample_tool.md' -Content $script:validTool
		$script:tool = & $script:module { param($p) ConvertFrom-IaToolMarkdown -Path $p } $path
	}

	It 'читає назву, опис, метод, зафіксовані сервер і базу' {
		$script:tool.name | Should -Be 'sample_tool'
		$script:tool.description | Should -Be "Тестовий інструмент.`nДругий рядок опису."
		$script:tool.method | Should -Be 'Query'
		$script:tool.server | Should -Be 'SQLX'
		$script:tool.database | Should -Be 'SalesX'
		$script:tool.purpose | Should -Be 'Tool'
		$script:tool.path | Should -Not -BeNullOrEmpty
	}

	It 'розбирає параметри з типами й атрибутами' {
		$parameters = @($script:tool.parameters)
		$parameters.Count | Should -Be 8
		$schema = $parameters | Where-Object name -EQ 'SchemaName'
		$schema.required | Should -BeTrue
		$schema.maxLength | Should -Be 128
		$kind = $parameters | Where-Object name -EQ 'Kind'
		$kind.required | Should -BeFalse
		@($kind.enum) | Should -Be @('Seek', 'Scan')
		$kind.default | Should -Be 'Seek'
		$top = $parameters | Where-Object name -EQ 'Top'
		$top.min | Should -Be 1
		$top.max | Should -Be 100
		$top.default | Should -BeOfType [int]
		($parameters | Where-Object name -EQ 'Ratio').min | Should -BeOfType [decimal]
		($parameters | Where-Object name -EQ 'Flag').default | Should -BeTrue
		$from = ($parameters | Where-Object name -EQ 'FromUtc').default
		$from | Should -BeOfType [datetime]
		$from.Kind | Should -Be ([System.DateTimeKind]::Utc)
		($parameters | Where-Object name -EQ 'Id').hasDefault | Should -BeFalse
	}

	It 'зберігає текст запиту без огорожі' {
		$script:tool.query | Should -Match '^-- коментар'
		$script:tool.query | Should -Match '@Id IS NULL;$'
		$script:tool.query | Should -Not -Match '```'
	}

	It 'ігнорує @-імена в коментарях, рядках, [ідентифікаторах] і @@-функції' {
		$names = & $script:module { param($q) Get-IaToolQueryVariables -Sql $q } $script:tool.query
		@($names) | Should -Be @('Top', 'SchemaName', 'Kind', 'Ratio', 'Big', 'Flag', 'FromUtc', 'Id')
	}

	It 'приймає файл без розділів Server, Database і Parameters' {
		$content = "# no_params`n`n## Description`nБез параметрів.`n`n## Method`nQuery`n`n## Query`n``````sql`nSELECT 1 AS x FROM sys.objects;`n```````n"
		$tool = & $script:module { param($p) ConvertFrom-IaToolMarkdown -Path $p } (New-TestToolFile -Name 'no_params.md' -Content $content)
		$tool.server | Should -BeNullOrEmpty
		$tool.database | Should -BeNullOrEmpty
		@($tool.parameters).Count | Should -Be 0
	}
}

Describe 'ConvertFrom-IaToolMarkdown: строгий розбір невалідних файлів' {
	It 'відхиляє: <Case>' -TestCases @(
		@{ Case = 'немає заголовка'; Content = "## Description`nОпис.`n"; Reason = 'починатися з заголовка' }
		@{ Case = 'порожній файл'; Content = ''; Reason = "відсутній заголовок" }
		@{ Case = 'некоректна назва'; Content = (New-SimpleTool -Name 'Bad-Name'); Reason = 'не відповідає шаблону' }
		@{ Case = 'зарезервована назва free_query'; Content = (New-SimpleTool -Name 'free_query'); Reason = 'зарезервована' }
		@{ Case = 'невідомий розділ'; Content = (New-SimpleTool) + "`n## Extra`nx`n"; Reason = 'невідомий розділ' }
		@{ Case = 'повтор розділу'; Content = (New-SimpleTool) -replace '## Method', "## Description`nЩе.`n`n## Method"; Reason = 'повторюється' }
		@{ Case = 'немає опису'; Content = (New-SimpleTool) -replace "## Description`nОпис.`n", ''; Reason = 'Description' }
		@{ Case = 'метод не Query'; Content = (New-SimpleTool) -replace "## Method`nQuery", "## Method`nExec"; Reason = 'Method' }
		@{ Case = 'два sql-блоки'; Content = (New-SimpleTool) + "``````sql`nSELECT 2;`n```````n"; Reason = 'рівно один' }
		@{ Case = 'блок не sql'; Content = (New-SimpleTool) -replace '```sql', '```tsql'; Reason = 'має бути' }
		@{ Case = 'незакритий блок'; Content = (New-SimpleTool) -replace '```\n$', ''; Reason = 'незакритий' }
		@{ Case = 'текст у розділі Query'; Content = (New-SimpleTool) + "Зайвий текст`n"; Reason = 'дозволено лише' }
		@{ Case = 'блок поза Query'; Content = (New-SimpleTool) -replace "## Method", "``````sql`nSELECT 1;`n```````n`n## Method"; Reason = "лише в розділі '## Query'" }
		@{ Case = 'немає розділу Query'; Content = ((New-SimpleTool) -split '## Query')[0]; Reason = 'Query' }
		@{ Case = 'некоректний рядок параметра'; Content = (New-SimpleTool -Parameters '- TableName string'); Reason = 'некоректне оголошення' }
		@{ Case = 'параметр без опису'; Content = (New-SimpleTool -Parameters '- @TableName: string'); Reason = 'некоректне оголошення' }
		@{ Case = 'невідомий тип'; Content = (New-SimpleTool -Parameters '- @TableName: text - Таблиця'); Reason = 'невідомий тип' }
		@{ Case = 'невідомий атрибут'; Content = (New-SimpleTool -Parameters '- @TableName: string {length=5} - Таблиця'); Reason = 'невідомий атрибут' }
		@{ Case = 'повтор атрибута'; Content = (New-SimpleTool -Parameters '- @TableName: string {maxLength=5, maxLength=6} - Таблиця'); Reason = 'повторюється' }
		@{ Case = 'maxLength для int'; Content = (New-SimpleTool -Parameters '- @TableName: int {maxLength=5} - Таблиця'); Reason = 'maxLength' }
		@{ Case = 'min для string'; Content = (New-SimpleTool -Parameters '- @TableName: string {min=1} - Таблиця'); Reason = 'числових' }
		@{ Case = 'min більший за max'; Content = (New-SimpleTool -Parameters '- @TableName: int? {min=5, max=1} - Таблиця'); Reason = 'min більший' }
		@{ Case = 'enum неправильного типу'; Content = (New-SimpleTool -Parameters '- @TableName: int? {enum=1|x} - Таблиця'); Reason = 'enum' }
		@{ Case = 'default для обовʼязкового'; Content = (New-SimpleTool -Parameters '- @TableName: string {default=x} - Таблиця'); Reason = 'необов' }
		@{ Case = 'default поза межами'; Content = (New-SimpleTool -Parameters '- @TableName: int? {max=5, default=6} - Таблиця'); Reason = 'не відповідає обмеженням' }
		@{ Case = 'default поза enum'; Content = (New-SimpleTool -Parameters '- @TableName: string? {enum=A|B, default=C} - Таблиця'); Reason = 'не відповідає обмеженням' }
		@{ Case = 'дублікат параметра'; Content = (New-SimpleTool -Parameters "- @TableName: string - Таблиця`n- @tablename: string - Ще раз"); Reason = 'двічі' }
		@{ Case = 'параметр не використано'; Content = (New-SimpleTool -Parameters "- @TableName: string - Таблиця`n- @Extra: int? - Зайвий"); Reason = 'не використано' }
		@{ Case = 'змінну не оголошено'; Content = (New-SimpleTool -Query 'SELECT t.name FROM sys.tables AS t WHERE t.name = @TableName AND t.object_id = @Id;'); Reason = 'не оголошено' }
		@{ Case = 'DECLARE локальної змінної'; Content = (New-SimpleTool -Query "DECLARE @x INT = 1;`nSELECT t.name FROM sys.tables AS t WHERE t.name = @TableName;"); Reason = 'не оголошено' }
		@{ Case = 'два значення Server'; Content = (New-SimpleTool) -replace '## Parameters', "## Server`nA`nB`n`n## Parameters"; Reason = 'не більше одного' }
	) {
		param($Case, $Content, $Reason)
		$path = New-TestToolFile -Name 'invalid_tool.md' -Content $Content
		$errorRecord = Get-TestParseError -Path $path
		$errorRecord | Should -Not -BeNullOrEmpty -Because $Case
		$errorRecord.FullyQualifiedErrorId | Should -BeLike 'IaToolDefinitionInvalid*'
		$errorRecord.Exception.Message | Should -BeLike "*invalid_tool.md*"
		$errorRecord.Exception.Message | Should -BeLike "*$Reason*"
	}

	It 'відхиляє відсутній файл' {
		$errorRecord = Get-TestParseError -Path (Join-Path $TestDrive 'missing_tool.md')
		$errorRecord.FullyQualifiedErrorId | Should -BeLike 'IaToolDefinitionInvalid*'
		$errorRecord.Exception.Message | Should -BeLike '*missing_tool.md*не знайдено*'
	}
}

Describe 'Import-IaToolDefinitions' {
	BeforeAll {
		Mock -ModuleName IndexAdvisor Write-IaLog {}
		$script:config = Get-IaTestConfig
	}

	It 'завантажує всі вбудовані інструменти без free_query за замовчуванням' {
		$tools = & $script:module { param($c) Import-IaToolDefinitions -Config $c } $script:config
		@($tools.Keys) | Sort-Object | Should -Be @('index_operational_stats', 'index_usage_stats', 'missing_indexes', 'query_store_plans',
			'query_store_predicates', 'query_store_top_queries', 'size_and_partitions', 'table_structure')
		$tools -is [System.Collections.Specialized.OrderedDictionary] | Should -BeTrue
	}

	It 'додає free_query лише при unsafe.allowFreeQuery' {
		$config = Get-IaTestConfig
		$config.unsafe.allowFreeQuery = $true
		$tools = & $script:module { param($c) Import-IaToolDefinitions -Config $c } $config
		$tools.Contains('free_query') | Should -BeTrue
		$tools.free_query.purpose | Should -Be 'FreeQuery'
		$tools.free_query.parameters[0].name | Should -Be 'Sql'
		$tools.free_query.parameters[0].maxLength | Should -Be $config.limits.maxCommandLength
	}

	It 'бере каталог з tools.definitionsPath, а -Path має пріоритет' {
		$null = New-TestToolFile -Folder 'cfgdir' -Name 'cfg_tool.md' -Content (New-SimpleTool -Name 'cfg_tool')
		$null = New-TestToolFile -Folder 'argdir' -Name 'arg_tool.md' -Content (New-SimpleTool -Name 'arg_tool')
		$config = Get-IaTestConfig
		$config.tools.definitionsPath = Join-Path $TestDrive 'cfgdir'
		$fromConfig = & $script:module { param($c) Import-IaToolDefinitions -Config $c } $config
		@($fromConfig.Keys) | Should -Be @('cfg_tool')
		$fromPath = & $script:module { param($c, $p) Import-IaToolDefinitions -Path $p -Config $c } $config (Join-Path $TestDrive 'argdir')
		@($fromPath.Keys) | Should -Be @('arg_tool')
	}

	It 'строгий режим: невалідний файл зупиняє завантаження' {
		$null = New-TestToolFile -Folder 'strict' -Name 'a_good.md' -Content (New-SimpleTool -Name 'good_tool')
		$null = New-TestToolFile -Folder 'strict' -Name 'b_bad.md' -Content (New-SimpleTool -Name 'Bad Name')
		$caught = $null
		try {
			$null = & $script:module { param($c, $p) Import-IaToolDefinitions -Path $p -Config $c } $script:config (Join-Path $TestDrive 'strict')
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaToolDefinitionInvalid*'
		$caught.Exception.Message | Should -BeLike '*b_bad.md*'
	}

	It 'нестрогий режим: невалідний файл пропускається з попередженням і записом у журнал' {
		$null = New-TestToolFile -Folder 'lenient' -Name 'a_good.md' -Content (New-SimpleTool -Name 'good_tool')
		$null = New-TestToolFile -Folder 'lenient' -Name 'b_bad.md' -Content (New-SimpleTool -Name 'Bad Name')
		$config = Get-IaTestConfig
		$config.tools.strict = $false
		$tools = & $script:module { param($c, $p) Import-IaToolDefinitions -Path $p -Config $c -WarningAction SilentlyContinue } $config (Join-Path $TestDrive 'lenient')
		@($tools.Keys) | Should -Be @('good_tool')
		Should -Invoke -ModuleName IndexAdvisor Write-IaLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*b_bad.md*' } -Times 1 -Exactly
	}

	It 'дублікати назв заборонені навіть без строгого режиму' {
		$null = New-TestToolFile -Folder 'dup' -Name 'one.md' -Content (New-SimpleTool -Name 'same_tool')
		$null = New-TestToolFile -Folder 'dup' -Name 'two.md' -Content (New-SimpleTool -Name 'same_tool')
		$config = Get-IaTestConfig
		$config.tools.strict = $false
		$caught = $null
		try {
			$null = & $script:module { param($c, $p) Import-IaToolDefinitions -Path $p -Config $c } $config (Join-Path $TestDrive 'dup')
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaToolDefinitionInvalid*'
		$caught.Exception.Message | Should -BeLike '*two.md*same_tool*one.md*'
	}

	It 'відсутній каталог — IaToolDefinitionInvalid' {
		$caught = $null
		try {
			$null = & $script:module { param($c, $p) Import-IaToolDefinitions -Path $p -Config $c } $script:config (Join-Path $TestDrive 'nope')
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaToolDefinitionInvalid*'
	}
}

Describe 'ConvertTo-IaToolJsonSchema' {
	BeforeAll {
		$path = New-TestToolFile -Name 'sample_tool.md' -Content $script:validTool
		$script:tool = & $script:module { param($p) ConvertFrom-IaToolMarkdown -Path $p } $path
		$script:schema = & $script:module { param($t) ConvertTo-IaToolJsonSchema -Tool $t } $script:tool
	}

	It 'має name, description і об''єкт parameters з additionalProperties = false' {
		$script:schema.name | Should -Be 'sample_tool'
		$script:schema.description | Should -Not -BeNullOrEmpty
		$script:schema.parameters.type | Should -Be 'object'
		$script:schema.parameters.additionalProperties | Should -BeFalse
		$script:schema.parameters.additionalProperties | Should -BeOfType [bool]
		@($script:schema.parameters.required) | Should -Be @('SchemaName')
	}

	It 'відображає типи й обмеження: <Name>' -TestCases @(
		@{ Name = 'SchemaName'; Type = 'string'; Extra = @{ maxLength = 128 } }
		@{ Name = 'Kind'; Type = 'string'; Extra = @{ default = 'Seek' } }
		@{ Name = 'Top'; Type = 'integer'; Extra = @{ minimum = 1; maximum = 100; default = 10 } }
		@{ Name = 'Ratio'; Type = 'number'; Extra = @{ minimum = 0.5; maximum = 99.5 } }
		@{ Name = 'Big'; Type = 'integer'; Extra = @{} }
		@{ Name = 'Flag'; Type = 'boolean'; Extra = @{ default = $true } }
		@{ Name = 'FromUtc'; Type = 'string'; Extra = @{ format = 'date-time'; default = '2026-01-01T00:00:00.000Z' } }
		@{ Name = 'Id'; Type = 'string'; Extra = @{ format = 'uuid' } }
	) {
		param($Name, $Type, $Extra)
		$property = $script:schema.parameters.properties[$Name]
		$property | Should -Not -BeNullOrEmpty
		$property.type | Should -Be $Type
		$property.description | Should -Not -BeNullOrEmpty
		foreach ($key in $Extra.Keys) {
			$property[$key] | Should -Be $Extra[$key] -Because $key
		}
	}

	It 'містить enum і назви властивостей без @' {
		@($script:schema.parameters.properties['Kind'].enum) | Should -Be @('Seek', 'Scan')
		@($script:schema.parameters.properties.Keys | Where-Object { $_ -like '@*' }).Count | Should -Be 0
	}

	It 'JSON-схема відкидає зайві властивості й перевіряє обмеження' {
		$schemaJson = ConvertTo-Json -InputObject $script:schema.parameters -Depth 20
		Test-Json -Json '{"SchemaName":"dbo","Top":5}' -Schema $schemaJson | Should -BeTrue
		Test-Json -Json '{"SchemaName":"dbo","Unknown":1}' -Schema $schemaJson -ErrorAction SilentlyContinue | Should -BeFalse
		Test-Json -Json '{"SchemaName":"dbo","Top":500}' -Schema $schemaJson -ErrorAction SilentlyContinue | Should -BeFalse
		Test-Json -Json '{"Top":5}' -Schema $schemaJson -ErrorAction SilentlyContinue | Should -BeFalse
	}

	It 'будує валідні схеми для всіх вбудованих інструментів' {
		$tools = & $script:module { param($c) Import-IaToolDefinitions -Config $c } (Get-IaTestConfig)
		foreach ($tool in $tools.Values) {
			$schema = & $script:module { param($t) ConvertTo-IaToolJsonSchema -Tool $t } $tool
			$schema.parameters.additionalProperties | Should -BeFalse -Because $tool.name
			$json = ConvertTo-Json -InputObject $schema.parameters -Depth 20
			Test-Json -Json '{"unexpected_argument":1}' -Schema $json -ErrorAction SilentlyContinue | Should -BeFalse -Because $tool.name
		}
	}
}

Describe 'Вбудовані інструменти' {
	It '<Name>: завантажується й містить одну інструкцію SELECT без DECLARE і тимчасових таблиць' -TestCases $script:builtInFiles {
		param($File, $Name)
		$tool = & $script:module { param($p) ConvertFrom-IaToolMarkdown -Path $p } $File
		$tool.name | Should -Be $Name
		$tool.query | Should -Match '^SELECT\b'
		$tool.query | Should -Not -MatchExactly '\bDECLARE\b|#\w|\bINTO\b|\bEXEC(UTE)?\b|\bOPTION\s*\(|\bINSERT\b|\bUPDATE\s+\w|\bDELETE\b'
		$tool.query | Should -Match ';$'
		foreach ($line in ($tool.query -split "`n")) {
			$line.Length | Should -BeLessOrEqual 160
		}
	}

	It '<Name>: запит проходить Test-IaSelectOnly і Test-IaSystemSourcesOnly' -TestCases $script:builtInFiles -Skip:$script:coreNotReady {
		param($File, $Name)
		$tool = & $script:module { param($p) ConvertFrom-IaToolMarkdown -Path $p } $File
		$select = & $script:module { param($q) Test-IaSelectOnly -Sql $q } $tool.query
		$select.isValid | Should -BeTrue -Because (($select.errors | ForEach-Object { $_.message }) -join '; ')
		$sources = & $script:module { param($q) Test-IaSystemSourcesOnly -Sql $q } $tool.query
		$sources.isValid | Should -BeTrue -Because (($sources.errors | ForEach-Object { $_.message }) -join '; ')
	}
}
