BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:SampleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Fixtures\llm-response.sample.json') -Raw -Encoding utf8

	function Invoke-TestParse {
		param([AllowNull()][AllowEmptyString()][string]$Text)
		return InModuleScope IndexAdvisor -Parameters @{ Text = $Text } { param($Text) ConvertFrom-IaLlmResponse -Text $Text }
	}

	function New-TestDraft {
		$draft = (Get-IaTestFixture -Name 'llm-response.sample.json').recommendations[1]
		return $draft
	}
}

Describe 'ConvertFrom-IaLlmResponse' {
	It 'розбирає зразок tests/Fixtures/llm-response.sample.json без помилок' {
		$result = Invoke-TestParse -Text $script:SampleText
		@($result.Keys) | Should -Be @('recommendations', 'toolRequests', 'notes', 'parseErrors')
		$result.parseErrors.Count | Should -Be 0
		$result.recommendations.Count | Should -Be 2
		$result.toolRequests.Count | Should -Be 0
		$result.notes | Should -Match 'IX_CustomerId'
		$first = $result.recommendations[0]
		$first.action | Should -Be 'CreateIndex'
		$first.target.server | Should -Be 'AG1'
		$first.target.index | Should -Be 'IX_OrderDate_INC'
		$first.risk.level | Should -Be 'Low'
		$first.affectedQueryIds | Should -Be @(1002)
		$first.confidence | Should -Be 'High'
		$result.recommendations[1].action | Should -Be 'DropIndex'
	}

	It 'нормалізований результат відповідає contracts/llm-response.schema.json' {
		$result = Invoke-TestParse -Text $script:SampleText
		$json = ConvertTo-Json -InputObject ([ordered]@{ recommendations = $result.recommendations; toolRequests = $result.toolRequests; notes = $result.notes }) -Depth 20
		Test-IaJsonAgainstSchema -Json $json -Schema 'llm-response' | Should -BeTrue
	}

	It 'приймає JSON у ```json-блоці із зайвим текстом' {
		$text = "Ось мій аналіз:`n``````json`n$($script:SampleText)`n```````nСподіваюся, це допоможе."
		$result = Invoke-TestParse -Text $text
		$result.parseErrors.Count | Should -Be 0
		$result.recommendations.Count | Should -Be 2
	}

	It 'приймає JSON із текстом довкола без блоку коду' {
		$result = Invoke-TestParse -Text ("Відповідь: " + $script:SampleText + " Кінець {примітка}.")
		$result.parseErrors.Count | Should -Be 0
		$result.recommendations.Count | Should -Be 2
	}

	It 'обрізаний JSON — parseErrors без винятку' {
		$result = Invoke-TestParse -Text $script:SampleText.Substring(0, 300)
		$result.parseErrors.Count | Should -BeGreaterThan 0
		$result.recommendations.Count | Should -Be 0
		$result.toolRequests.Count | Should -Be 0
	}

	It 'порожня відповідь — parseErrors' -TestCases @(@{ Text = '' }, @{ Text = $null }, @{ Text = '   ' }, @{ Text = 'Не можу відповісти.' }) {
		$result = Invoke-TestParse -Text $Text
		$result.parseErrors.Count | Should -Be 1
		$result.recommendations.Count | Should -Be 0
	}

	It 'невалідна чернетка відкидається з поясненням, решта лишається' {
		$fixture = Get-IaTestFixture -Name 'llm-response.sample.json'
		$fixture.recommendations[0].Remove('rollbackScript')
		$result = Invoke-TestParse -Text (ConvertTo-Json -InputObject $fixture -Depth 20)
		$result.recommendations.Count | Should -Be 1
		$result.recommendations[0].action | Should -Be 'DropIndex'
		$result.parseErrors.Count | Should -Be 1
		$result.parseErrors[0] | Should -Match 'recommendations\[0\].*rollbackScript'
	}

	It 'відкидає недопустимі action, risk.level і DropIndex без index' {
		$bad1 = New-TestDraft; $bad1.action = 'DisableIndex'
		$bad2 = New-TestDraft; $bad2.risk.level = 'Critical'
		$bad3 = New-TestDraft; $bad3.target.index = $null
		$result = Invoke-TestParse -Text (ConvertTo-Json -InputObject ([ordered]@{ recommendations = @($bad1, $bad2, $bad3); toolRequests = @() }) -Depth 20)
		$result.recommendations.Count | Should -Be 0
		$result.parseErrors.Count | Should -Be 3
		$result.parseErrors[0] | Should -Match 'action'
		$result.parseErrors[1] | Should -Match 'risk.level'
		$result.parseErrors[2] | Should -Match 'target.index'
	}

	It 'нормалізує регістр переліків і додає відсутні необов''язкові поля' {
		$draft = New-TestDraft
		$draft.action = 'dropindex'
		$draft.risk.level = 'high'
		$draft.Remove('affectedQueryIds'); $draft.Remove('replacesIndexes'); $draft.Remove('confidence'); $draft.Remove('partitioning')
		$result = Invoke-TestParse -Text (ConvertTo-Json -InputObject ([ordered]@{ recommendations = @($draft); toolRequests = @() }) -Depth 20)
		$result.parseErrors.Count | Should -Be 0
		$item = $result.recommendations[0]
		$item.action | Should -Be 'DropIndex'
		$item.risk.level | Should -Be 'High'
		$item.affectedQueryIds.Count | Should -Be 0
		$item.replacesIndexes.Count | Should -Be 0
		$item.confidence | Should -BeNullOrEmpty
		$item.Contains('partitioning') | Should -BeTrue
	}

	It 'розбирає toolRequests і відкидає невалідні' {
		$text = @'
{"recommendations":[],"toolRequests":[
 {"tool":"index_usage_stats","server":"srv1","database":"db1","arguments":{"schema":"sch1","table":"tbl2"},"fetch":100,"reason":"Потрібна статистика"},
 {"tool":"query_store_plans","arguments":null,"reason":"Плани"},
 {"arguments":{"x":1},"reason":"без інструмента"},
 {"tool":"bad","arguments":"text","reason":"аргументи не об'єкт"}
]}
'@
		$result = Invoke-TestParse -Text $text
		$result.toolRequests.Count | Should -Be 2
		$first = $result.toolRequests[0]
		$first.tool | Should -Be 'index_usage_stats'
		$first.server | Should -Be 'srv1'
		$first.arguments.table | Should -Be 'tbl2'
		$first.fetch | Should -Be 100
		$first.skip | Should -BeNullOrEmpty
		$result.toolRequests[1].arguments.Count | Should -Be 0
		$result.toolRequests[1].server | Should -BeNullOrEmpty
		$result.parseErrors.Count | Should -Be 2
		@($result.toolRequests[0].Keys) | Should -Be @('tool', 'server', 'database', 'arguments', 'fetch', 'skip', 'reason')
	}

	It 'відсутній toolRequests не є помилкою' {
		$result = Invoke-TestParse -Text '{"recommendations":[],"notes":"Змін не потрібно"}'
		$result.parseErrors.Count | Should -Be 0
		$result.toolRequests.Count | Should -Be 0
		$result.notes | Should -Be 'Змін не потрібно'
	}

	It 'PartitionTable без partitioning відкидається; з partitioning — нормалізується' {
		$valid = [ordered]@{
			action = 'PartitionTable'
			target = [ordered]@{ server = 'AG1'; database = 'Sales'; schema = 'dbo'; table = 'Orders'; index = $null }
			title = 'Секціонування за OrderDate'; rationale = '90% запитів фільтрують за OrderDate.'
			risk = [ordered]@{ level = 'High'; description = 'Перебудова кластерного індексу.' }
			executeScript = 'CREATE PARTITION FUNCTION [pf_dbo_date] (DATE) AS RANGE RIGHT FOR VALUES (''2026-01-01'');'
			rollbackScript = 'DROP PARTITION FUNCTION [pf_dbo_date];'
			partitioning = [ordered]@{
				partitionColumn = 'OrderDate'; functionName = 'pf_dbo_date'; schemeName = 'ps_dbo_date'
				functionScript = 'CREATE PARTITION FUNCTION ...;'; schemeScript = 'CREATE PARTITION SCHEME ...;'
				boundaries = @('2026-01-01', '2026-02-01'); migrationPlan = @('Крок 1', 'Крок 2')
				impact = [ordered]@{ clusteredIndexRebuild = 'Так'; queriesWithoutPartitionFilter = @(1003) }
				maintenanceBenefits = 'SWITCH для архівування'
			}
		}
		$invalid = [ordered]@{}
		foreach ($key in $valid.Keys) { $invalid[$key] = $valid[$key] }
		$invalid.Remove('partitioning')
		$result = Invoke-TestParse -Text (ConvertTo-Json -InputObject ([ordered]@{ recommendations = @($valid, $invalid); toolRequests = @() }) -Depth 20)
		$result.recommendations.Count | Should -Be 1
		$result.parseErrors.Count | Should -Be 1
		$partitioning = $result.recommendations[0].partitioning
		$partitioning.boundaries | Should -Be @('2026-01-01', '2026-02-01')
		$partitioning.boundaries[0] | Should -BeOfType [string]
		$partitioning.impact.queriesWithoutPartitionFilter | Should -Be @(1003)
		$partitioning.eliminationAssessment | Should -BeNullOrEmpty
		$json = ConvertTo-Json -InputObject ([ordered]@{ recommendations = $result.recommendations; toolRequests = @() }) -Depth 20
		Test-IaJsonAgainstSchema -Json $json -Schema 'llm-response' | Should -BeTrue
	}

	It 'масив замість об''єкта розбирається як recommendations з попередженням' {
		$fixture = Get-IaTestFixture -Name 'llm-response.sample.json'
		$result = Invoke-TestParse -Text (ConvertTo-Json -InputObject @($fixture.recommendations) -Depth 20)
		$result.recommendations.Count | Should -Be 2
		$result.parseErrors.Count | Should -Be 1
	}
}
