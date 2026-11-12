# Тести перевірки аргументів дозапиту (Test-IaToolArguments) і виконання інструмента (Invoke-IaTool), потік Tools.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Tools.TestHelpers.ps1')
	$script:module = Get-Module IndexAdvisor
	$content = @'
# typed_tool

## Description
Інструмент з усіма типами параметрів.

## Method
Query

## Parameters
- @Name: string {maxLength=5} - Рядок
- @Mode: string? {enum=Seek|Scan, default=Seek} - Режим
- @Count: int? {min=1, max=10, default=3} - Ціле
- @Big: bigint? - Велике ціле
- @Ratio: decimal? {min=0, max=1.5} - Дробове
- @Flag: bool? - Прапорець
- @FromUtc: datetime? - Дата
- @Id: guid? - Ідентифікатор

## Query
```sql
SELECT o.name FROM sys.objects AS o
WHERE o.name = @Name AND @Mode IS NOT NULL AND @Count > 0 AND @Big IS NULL AND @Ratio IS NULL AND @Flag IS NULL
	AND @FromUtc IS NULL AND @Id IS NULL;
```
'@
	$path = New-TestToolFile -Name 'typed_tool.md' -Content $content
	$script:tool = & $script:module { param($p) ConvertFrom-IaToolMarkdown -Path $p } $path

	function Invoke-TestArguments {
		param([System.Collections.IDictionary]$Arguments)
		return (& $script:module { param($t, $a) Test-IaToolArguments -Tool $t -Arguments $a } $script:tool $Arguments)
	}

	function New-TestArgumentSet {
		<# Обов'язковий Name = 'a' плюс один аргумент (може перекрити Name). #>
		param([string]$Param, [AllowNull()]$Value)
		$arguments = [ordered]@{ Name = 'a' }
		$arguments[$Param] = $Value
		return $arguments
	}
}

Describe 'Test-IaToolArguments' {
	It 'приймає мінімальний набір і підставляє default та $null для необов''язкових' {
		$result = Invoke-TestArguments -Arguments @{ Name = 'abc' }
		$result.isValid | Should -BeTrue
		@($result.errors).Count | Should -Be 0
		$result.arguments.Name | Should -Be 'abc'
		$result.arguments.Mode | Should -Be 'Seek'
		$result.arguments.Count | Should -Be 3
		$result.arguments.Contains('Big') | Should -BeTrue
		$result.arguments.Big | Should -BeNullOrEmpty
		@($result.arguments.Keys) | Should -Be @('Name', 'Mode', 'Count', 'Big', 'Ratio', 'Flag', 'FromUtc', 'Id')
	}

	It 'безпечно приводить рядки до типів: <Param> = <Value>' -TestCases @(
		@{ Param = 'Count'; Value = '7'; Expected = 7; Type = [int] }
		@{ Param = 'Count'; Value = 7L; Expected = 7; Type = [int] }
		@{ Param = 'Count'; Value = 7.0; Expected = 7; Type = [int] }
		@{ Param = 'Big'; Value = '9000000000'; Expected = 9000000000; Type = [long] }
		@{ Param = 'Ratio'; Value = '1.25'; Expected = [decimal]1.25; Type = [decimal] }
		@{ Param = 'Ratio'; Value = 0.5; Expected = [decimal]0.5; Type = [decimal] }
		@{ Param = 'Flag'; Value = 'TRUE'; Expected = $true; Type = [bool] }
		@{ Param = 'Flag'; Value = '0'; Expected = $false; Type = [bool] }
		@{ Param = 'Flag'; Value = $false; Expected = $false; Type = [bool] }
		@{ Param = 'Id'; Value = '6f9619ff-8b86-d011-b42d-00c04fc964ff'; Expected = [guid]'6f9619ff-8b86-d011-b42d-00c04fc964ff'; Type = [guid] }
	) {
		param($Param, $Value, $Expected, $Type)
		$result = Invoke-TestArguments -Arguments (New-TestArgumentSet -Param $Param -Value $Value)
		$result.isValid | Should -BeTrue -Because ($result.errors -join '; ')
		$result.arguments[$Param] | Should -BeOfType $Type
		$result.arguments[$Param] | Should -Be $Expected
	}

	It 'дати переводить в UTC' {
		$result = Invoke-TestArguments -Arguments @{ Name = 'a'; FromUtc = '2026-11-01T10:00:00+02:00' }
		$result.isValid | Should -BeTrue
		$result.arguments.FromUtc | Should -BeOfType [datetime]
		$result.arguments.FromUtc.Kind | Should -Be ([System.DateTimeKind]::Utc)
		$result.arguments.FromUtc | Should -Be ([datetime]::new(2026, 11, 1, 8, 0, 0, [System.DateTimeKind]::Utc))
		$local = [datetime]::SpecifyKind([datetime]::new(2026, 11, 1, 8, 0, 0), [System.DateTimeKind]::Local)
		(Invoke-TestArguments -Arguments @{ Name = 'a'; FromUtc = $local }).arguments.FromUtc | Should -Be $local.ToUniversalTime()
		(Invoke-TestArguments -Arguments @{ Name = 'a'; FromUtc = '2026-11-01' }).arguments.FromUtc | Should -Be ([datetime]::new(2026, 11, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
	}

	It 'відхиляє неправильний тип: <Param> = <Value>' -TestCases @(
		@{ Param = 'Name'; Value = 5 }
		@{ Param = 'Count'; Value = 'abc' }
		@{ Param = 'Count'; Value = '1.5' }
		@{ Param = 'Count'; Value = 2.5 }
		@{ Param = 'Count'; Value = '99999999999' }
		@{ Param = 'Count'; Value = $true }
		@{ Param = 'Big'; Value = '1e3' }
		@{ Param = 'Ratio'; Value = '1,25' }
		@{ Param = 'Ratio'; Value = 'NaN' }
		@{ Param = 'Flag'; Value = 'yes' }
		@{ Param = 'Flag'; Value = 1 }
		@{ Param = 'FromUtc'; Value = 'вчора' }
		@{ Param = 'FromUtc'; Value = '1' }
		@{ Param = 'Id'; Value = 'not-a-guid' }
	) {
		param($Param, $Value)
		$result = Invoke-TestArguments -Arguments (New-TestArgumentSet -Param $Param -Value $Value)
		$result.isValid | Should -BeFalse
		($result.errors -join '; ') | Should -BeLike "*'$Param'*"
		$result.arguments.Contains($Param) | Should -BeFalse
	}

	It 'перевіряє обов''язковість' {
		$missing = Invoke-TestArguments -Arguments @{}
		$missing.isValid | Should -BeFalse
		($missing.errors -join '; ') | Should -BeLike "*обов'язковий аргумент 'Name'*"
		(Invoke-TestArguments -Arguments @{ Name = $null }).isValid | Should -BeFalse
	}

	It 'перевіряє enum без урахування регістру з нормалізацією' {
		$ok = Invoke-TestArguments -Arguments @{ Name = 'a'; Mode = 'SCAN' }
		$ok.isValid | Should -BeTrue
		$ok.arguments.Mode | Should -BeExactly 'Scan'
		$bad = Invoke-TestArguments -Arguments @{ Name = 'a'; Mode = 'Lookup' }
		$bad.isValid | Should -BeFalse
		($bad.errors -join '; ') | Should -BeLike '*Seek, Scan*'
	}

	It 'перевіряє min і max' {
		(Invoke-TestArguments -Arguments @{ Name = 'a'; Count = 0 }).errors | Should -BeLike '*мінімум 1*'
		(Invoke-TestArguments -Arguments @{ Name = 'a'; Count = 11 }).errors | Should -BeLike '*максимум 10*'
		(Invoke-TestArguments -Arguments @{ Name = 'a'; Count = 10 }).isValid | Should -BeTrue
		(Invoke-TestArguments -Arguments @{ Name = 'a'; Ratio = '1.6' }).errors | Should -BeLike '*максимум 1.5*'
		(Invoke-TestArguments -Arguments @{ Name = 'a'; Ratio = -0.1 }).errors | Should -BeLike '*мінімум 0*'
	}

	It 'перевіряє maxLength' {
		(Invoke-TestArguments -Arguments @{ Name = 'abcde' }).isValid | Should -BeTrue
		$long = Invoke-TestArguments -Arguments @{ Name = 'abcdef' }
		$long.isValid | Should -BeFalse
		($long.errors -join '; ') | Should -BeLike '*maxLength 5*'
	}

	It 'відхиляє невідомі аргументи й приймає імена з @' {
		$unknown = Invoke-TestArguments -Arguments @{ Name = 'a'; Extra = 1 }
		$unknown.isValid | Should -BeFalse
		($unknown.errors -join '; ') | Should -BeLike "*невідомий аргумент 'Extra'*"
		$shadow = Invoke-TestArguments -Arguments @{ Name = 'a'; Keys = 'x'; Count = 2 }
		$shadow.isValid | Should -BeFalse
		($shadow.errors -join '; ') | Should -BeLike "*невідомий аргумент 'Keys'*"
		$prefixed = Invoke-TestArguments -Arguments @{ '@Name' = 'a'; '@Count' = 2 }
		$prefixed.isValid | Should -BeTrue
		$prefixed.arguments.Count | Should -Be 2
	}

	It 'відхиляє той самий аргумент з @ і без' {
		$arguments = [ordered]@{ Name = 'a' }
		$arguments['@Name'] = 'b'
		$result = Invoke-TestArguments -Arguments $arguments
		$result.isValid | Should -BeFalse
		($result.errors -join '; ') | Should -BeLike '*більше одного разу*'
	}
}

Describe 'Invoke-IaTool' {
	BeforeAll {
		$script:config = Get-IaTestConfig
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery { New-TestEnvelope -Server $Server -Database $Database }
	}

	It 'виконує запит інструмента через Invoke-IaSqlQuery з Purpose Tool і типізованими параметрами' {
		$response = & $script:module { param($t, $c) Invoke-IaTool -Tool $t -Arguments @{ Name = 'a'; Count = '4' } -Server 'SQL01' -Database 'Sales' -Fetch 20 -Skip 5 -Config $c } $script:tool $script:config
		$response.success | Should -BeTrue
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly -ParameterFilter {
			$Server -eq 'SQL01' -and $Database -eq 'Sales' -and $Purpose -eq 'Tool' -and $Fetch -eq 20 -and $Skip -eq 5 -and
			$Query -like 'SELECT o.name FROM sys.objects*' -and @($Parameters.get_Keys()).Count -eq 8 -and $Parameters['Count'] -is [int] -and $Parameters['Count'] -eq 4 -and
			$Parameters['Mode'] -eq 'Seek' -and $Parameters.Contains('Id') -and $null -eq $Parameters['Id']
		}
	}

	It 'зафіксовані у визначенні сервер і база мають пріоритет' {
		$fixed = [ordered]@{}
		foreach ($key in $script:tool.Keys) {
			$fixed[$key] = $script:tool[$key]
		}
		$fixed.server = 'FIXED01'
		$fixed.database = 'FixedDb'
		$null = & $script:module { param($t, $c) Invoke-IaTool -Tool $t -Arguments @{ Name = 'a' } -Server 'SQL01' -Database 'Sales' -Config $c } $fixed $script:config
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly -ParameterFilter { $Server -eq 'FIXED01' -and $Database -eq 'FixedDb' -and $null -eq $Fetch -and $Skip -eq 0 }
	}

	It 'невалідні аргументи повертаються в конверті ArgumentInvalid без звернення до SQL' {
		$response = & $script:module { param($t, $c) Invoke-IaTool -Tool $t -Arguments @{ Name = 'toolong'; Bad = 1 } -Server 'SQL01' -Database 'Sales' -Config $c } $script:tool $script:config
		$response.success | Should -BeFalse
		$response.error.code | Should -Be 'ArgumentInvalid'
		$response.error.message | Should -BeLike '*Bad*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 0 -Exactly
	}

	It 'free_query виконується з Purpose FreeQuery лише при unsafe.allowFreeQuery' {
		$config = Get-IaTestConfig
		$config.unsafe.allowFreeQuery = $true
		$freeQuery = & $script:module { param($c) New-IaToolFreeQueryDefinition -Config $c } $config
		$sql = 'SELECT name FROM sys.databases;'
		$response = & $script:module { param($t, $c, $q) Invoke-IaTool -Tool $t -Arguments @{ Sql = $q } -Server 'SQL01' -Database 'master' -Config $c } $freeQuery $config $sql
		$response.success | Should -BeTrue
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly -ParameterFilter { $Purpose -eq 'FreeQuery' -and $Query -eq $sql -and $Parameters.Count -eq 0 }
		$config.unsafe.allowFreeQuery = $false
		$blocked = & $script:module { param($t, $c, $q) Invoke-IaTool -Tool $t -Arguments @{ Sql = $q } -Server 'SQL01' -Database 'master' -Config $c } $freeQuery $config $sql
		$blocked.success | Should -BeFalse
		$blocked.error.message | Should -BeLike '*unsafe.allowFreeQuery*'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 1 -Exactly
	}
}
