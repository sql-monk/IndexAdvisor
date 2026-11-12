# Тести модуля та контрактів. Власник — оркестратор.
BeforeAll {
	. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Модуль IndexAdvisor' {
	It 'завантажується без помилок у файлах' {
		$loadErrors = & (Get-Module IndexAdvisor) { $script:IaLoadErrors }
		$loadErrors | Should -BeNullOrEmpty
	}

	It 'експортує лише публічні команди з маніфесту' {
		$exported = (Get-Module IndexAdvisor).ExportedFunctions.Keys | Sort-Object
		$exported | Should -Be @('Install-IaServiceLogin', 'Invoke-IndexAdvisor', 'New-IaConfigTemplate', 'New-IaIndexMaintenance', 'Test-IaConfig')
	}

	It 'має всі контрактні функції' {
		$contract = @(
			'Invoke-IaSqlQuery', 'Invoke-IaDbCommand', 'Test-IaSelectOnly', 'Test-IaSystemSourcesOnly', 'ConvertTo-IaSqlFragment', 'Get-IaScriptDomParser',
			'New-IaConnectionString', 'Assert-IaStandardLogin', 'Get-IaLoginPermissions', 'Start-IaSession', 'Get-IaSession', 'Stop-IaSession',
			'Write-IaLog', 'Protect-IaLogValue', 'Get-IaUnsafeFlags', 'ConvertTo-IaJsonValue',
			'Get-IaTopology', 'Get-IaDatasetSelection', 'Invoke-IaCollection', 'Save-IaSnapshotArchive', 'Read-IaSnapshotArchive', 'Remove-IaExpiredArchives',
			'Import-IaToolDefinitions', 'ConvertFrom-IaToolMarkdown', 'ConvertTo-IaToolJsonSchema', 'Test-IaToolArguments', 'Invoke-IaTool',
			'Request-IaToolApproval', 'Invoke-IaAnalysisLoop',
			'Get-IaSecret', 'Test-IaSecretReference', 'Get-IaLlmProviderConfig', 'Assert-IaProviderAllowed', 'Invoke-IaLlmChat', 'Get-IaBudgetStatus',
			'Get-IaLlmCost', 'Measure-IaTokens', 'New-IaMaskingMap', 'ConvertTo-IaMaskedObject', 'ConvertFrom-IaMaskedObject', 'Remove-IaSqlLiterals',
			'New-IaLlmContext', 'Get-IaPromptTemplate', 'New-IaPrompt', 'ConvertFrom-IaLlmResponse', 'Invoke-IaCrossCheck',
			'Invoke-IaRulesEngine', 'Merge-IaMissingIndexes', 'Get-IaIndexCreateEstimate', 'Get-IaAnalysisWindow', 'Get-IaDataPeriod',
			'Test-IaExpensiveIndex', 'Get-IaDropEligibility', 'Test-IaRecommendation', 'Invoke-IaPartitionAnalysis', 'New-IaObjectVerdicts',
			'Export-IaReport', 'Save-IaRunToRepository', 'Get-IaRecommendationHistory', 'Remove-IaExpiredHistory',
			'Invoke-IndexAdvisor', 'Get-IaConfig', 'Test-IaConfig', 'New-IaConfigTemplate', 'Install-IaServiceLogin',
			'Get-IaDefaultConfig', 'Get-IaObjectKey', 'New-IaTarget', 'New-IaResponse', 'New-IaError', 'New-IaFinding', 'New-IaRecommendation',
			'New-IaRunResult', 'Copy-IaObject', 'ConvertTo-IaUtcString'
		)
		$module = Get-Module IndexAdvisor
		$missing = $contract | Where-Object { -not (& $module { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $_) }
		$missing | Should -BeNullOrEmpty
	}
}

Describe 'Спільні контракти' {
	It 'Get-IaDefaultConfig повертає значення зі схеми' {
		$config = & (Get-Module IndexAdvisor) { Get-IaDefaultConfig }
		$config.limits.defaultFetch | Should -Be 300
		$config.limits.maxRows | Should -Be 5000
		$config.rules.drop.requiredConsecutive | Should -Be 3
		$config.rules.drop.minUptimeDays | Should -Be 14
		$config.connection.lockTimeoutMs | Should -Be 1000
		$config.unsafe.allowFreeQuery | Should -BeFalse
		@($config.output.formats) | Should -Be @('Markdown', 'Sql', 'Console')
		$config.llm.providers.Count | Should -Be 0
	}

	It 'Get-IaObjectKey нормалізує регістр' {
		& (Get-Module IndexAdvisor) { Get-IaObjectKey -Server 'AG1' -Database 'Sales' -Schema 'dbo' -Table 'Orders' -Index 'IX_Status' } |
			Should -Be 'ag1|sales|dbo.orders|ix_status'
	}

	It 'ConvertTo-IaUtcString форматує UTC' {
		$value = & (Get-Module IndexAdvisor) { ConvertTo-IaUtcString -Date ([datetime]::new(2026, 11, 10, 8, 0, 0, [System.DateTimeKind]::Utc)) }
		$value | Should -Be '2026-11-10T08:00:00.000Z'
	}

	It 'фікстура snapshot відповідає contracts/snapshot.schema.json' {
		$json = Get-Content -LiteralPath (Join-Path $script:IaFixturesPath 'snapshot.sample.json') -Raw
		Test-IaJsonAgainstSchema -Json $json -Schema snapshot | Should -BeTrue
	}

	It 'фікстура відповіді моделі відповідає contracts/llm-response.schema.json' {
		$json = Get-Content -LiteralPath (Join-Path $script:IaFixturesPath 'llm-response.sample.json') -Raw
		Test-IaJsonAgainstSchema -Json $json -Schema 'llm-response' | Should -BeTrue
	}

	It 'New-IaRecommendation будує рекомендацію за contracts/recommendation.schema.json' {
		$draft = (Get-IaTestFixture -Name 'llm-response.sample.json').recommendations[0]
		$rec = & (Get-Module IndexAdvisor) { param($d) New-IaRecommendation -Draft $d -RunId ([guid]::NewGuid().ToString()) -Module Indexes } $draft
		$rec.target.objectKey | Should -Be 'ag1|sales|dbo.orders|ix_orderdate_inc'
		$json = $rec | ConvertTo-Json -Depth 50
		Test-IaJsonAgainstSchema -Json $json -Schema recommendation | Should -BeTrue
	}
}
