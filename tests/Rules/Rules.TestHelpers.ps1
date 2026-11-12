# Помічники тестів потоку Rules. Підключення у тест-файлі після TestHelpers.ps1:
#   BeforeAll { . (Join-Path $PSScriptRoot '..\TestHelpers.ps1'); . (Join-Path $PSScriptRoot 'Rules.TestHelpers.ps1') }
# ConvertTo-IaSqlFragment (потік Core) у тестах мокається справжнім розбором ScriptDom (TSql160Parser) зі збірки dbatools.library.

function Initialize-IaRuleTestScriptDom {
	<# Завантажує Microsoft.SqlServer.TransactSql.ScriptDom з dbatools.library, якщо тип ще не завантажено. #>
	if ('Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -as [type]) {
		return
	}
	$library = Get-Module -ListAvailable -Name dbatools.library | Sort-Object Version -Descending | Select-Object -First 1
	if (-not $library) {
		throw 'Модуль dbatools.library не знайдено: ScriptDom недоступний для тестів'
	}
	Add-Type -LiteralPath (Join-Path $library.ModuleBase 'core\lib\Microsoft.SqlServer.TransactSql.ScriptDom.dll')
}

function Invoke-IaRuleTestParse {
	<# Розбір T-SQL справжнім TSql160Parser: @{ fragment; errors; parserName } як у ConvertTo-IaSqlFragment. #>
	param([AllowEmptyString()][string]$Sql)
	Initialize-IaRuleTestScriptDom
	$parser = New-Object -TypeName 'Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -ArgumentList $true
	$parseErrors = $null
	$reader = [System.IO.StringReader]::new($Sql)
	try {
		$fragment = $parser.Parse($reader, [ref]$parseErrors)
	}
	finally {
		$reader.Dispose()
	}
	$errors = @($parseErrors | ForEach-Object { [ordered]@{ code = 'ArgumentInvalid'; message = $_.Message; line = $_.Line; column = $_.Column } })
	return [ordered]@{
		fragment = $(if ($errors.Count) { $null } else { $fragment })
		errors = $errors
		parserName = 'TSql160Parser'
	}
}

function New-IaRuleTestRecommendation {
	<# Канонічна рекомендація з чернетки (New-IaRecommendation з Shared). #>
	param(
		[Parameter(Mandatory)][string]$Action,
		[string]$Table = 'Orders',
		[string]$Index,
		[string]$ExecuteScript = '',
		[string]$RollbackScript = '',
		[string]$Server = 'AG1',
		[string]$Database = 'Sales',
		[string]$Schema = 'dbo',
		[string[]]$ReplacesIndexes = @(),
		[System.Collections.IDictionary]$Partitioning,
		[string]$RunId = 'run-current',
		[string]$Module = 'Indexes'
	)
	$draft = [ordered]@{
		action = $Action
		target = [ordered]@{ server = $Server; database = $Database; schema = $Schema; table = $Table; index = $Index }
		title = "$Action $Table.$Index"
		rationale = 'тест'
		risk = [ordered]@{ level = 'Low'; description = 'тест' }
		executeScript = $ExecuteScript
		rollbackScript = $RollbackScript
		affectedQueryIds = @()
		replacesIndexes = @($ReplacesIndexes)
		confidence = 'Medium'
		partitioning = $Partitioning
	}
	return & (Get-Module IndexAdvisor) { param($Draft, $RunId, $Module) New-IaRecommendation -Draft $Draft -RunId $RunId -Module $Module } $draft $RunId $Module
}

function Find-IaRuleTestIndex {
	<# Індекс фікстури за реплікою, таблицею й іменем. #>
	param([Parameter(Mandatory)]$Snapshot, [string]$Server = 'SQL01', [string]$Table = 'Orders', [Parameter(Mandatory)][string]$Index)
	$instance = $Snapshot.instances | Where-Object { $_.serverName -eq $Server }
	$tableObject = $instance.databases[0].tables | Where-Object { $_.name -eq $Table }
	return $tableObject.indexes | Where-Object { $_.name -eq $Index }
}

function New-IaRuleTestVerdict {
	<# Запис IndexVerdict для історії. #>
	param([string]$Verdict = 'DropRecommended', [bool]$Counts = $true, [Parameter(Mandatory)][datetime]$AnalyzedAtUtc, [string]$ObjectKey = 'ag1|sales|dbo.orders|ix_status')
	return [ordered]@{
		runId = [guid]::NewGuid().ToString()
		objectKey = $ObjectKey
		module = 'Indexes'
		analyzedAtUtc = $AnalyzedAtUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)
		verdict = $Verdict
		countsTowardSeries = $Counts
		periodDays = 30
		rulesProfile = 'Standard'
	}
}

function Copy-IaTestObject {
	<# Глибока копія об'єкта фікстури (через JSON). #>
	param([Parameter(Mandatory)]$InputObject)
	return , (ConvertTo-Json -InputObject $InputObject -Depth 50 | ConvertFrom-Json -AsHashtable -Depth 50 -DateKind String)
}
