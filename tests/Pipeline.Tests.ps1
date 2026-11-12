# Наскрізний тест конвеєра на справжньому коді всіх потоків. Власник — оркестратор.
# Межі мокаються: збору з SQL немає (-FromArchive з фікстури), HTTP до моделі — мок Invoke-RestMethod.
BeforeAll {
	. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
	$script:module = Get-Module IndexAdvisor
	$script:root = (Get-PSDrive TestDrive).Root
	$env:IA_TEST_OPENAI_KEY = 'sk-test-not-a-real-key'

	$yamlPath = Join-Path $script:root 'run.yaml'
	@"
version: 1
servers: [AGL-SALES]
archive:
  path: '$(Join-Path $script:root 'archive')'
logging:
  path: '$(Join-Path $script:root 'logs')'
output:
  path: '$(Join-Path $script:root 'out')'
  formats: [Markdown, Sql, Html, Json]
repository:
  enabled: false
llm:
  provider: openai
  budgetLedgerPath: '$(Join-Path $script:root 'state\llm-usage.json')'
  providers:
    openai:
      type: OpenAI
      model: gpt-test
      apiKeyRef: env:IA_TEST_OPENAI_KEY
      inputPricePer1MTokensUsd: 2
      outputPricePer1MTokensUsd: 8
run:
  nonInteractive: true
"@ | Set-Content -LiteralPath $yamlPath -Encoding utf8
	$script:yamlPath = $yamlPath

	$config = Get-IaTestConfig -Root $script:root
	$config.archive.path = Join-Path $script:root 'source-archive'
	$snapshot = Get-IaTestSnapshot
	$script:archivePath = & $script:module {
		param($s, $c)
		Save-IaSnapshotArchive -Snapshot $s -Prompts @() -RunId ([guid]::NewGuid().ToString()) -Config $c
	} $snapshot $config 3>$null

	$script:modelText = Get-Content -LiteralPath (Join-Path $script:IaFixturesPath 'llm-response.sample.json') -Raw -Encoding utf8
}

AfterAll {
	Remove-Item Env:\IA_TEST_OPENAI_KEY -ErrorAction SilentlyContinue
}

Describe 'Конвеєр Invoke-IndexAdvisor -FromArchive' {
	BeforeAll {
		Mock -ModuleName IndexAdvisor Invoke-RestMethod {
			$script:requestBodies.Add([string]$Body)
			[pscustomobject]@{
				id = 'chatcmpl-test'
				model = 'gpt-test'
				choices = @([pscustomobject]@{ index = 0; finish_reason = 'stop'; message = [pscustomobject]@{ role = 'assistant'; content = $script:modelText } })
				usage = [pscustomobject]@{ prompt_tokens = 1000; completion_tokens = 200; total_tokens = 1200 }
			}
		}
		Mock -ModuleName IndexAdvisor Invoke-IaDbCommand { throw 'Підключення до SQL у цьому тесті не очікується' }
		$script:requestBodies = [System.Collections.Generic.List[string]]::new()
		$script:result = @(Invoke-IndexAdvisor -Config $script:yamlPath -FromArchive $script:archivePath -PassThru 3>$null 6>$null)[0]
		$script:exitCode = $global:LASTEXITCODE
	}

	It 'завершується без помилок і без підключень до SQL' {
		$script:result | Should -Not -BeNullOrEmpty
		@($script:result.errors) | Should -BeNullOrEmpty
		$script:exitCode | Should -BeIn @(0, 1)
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly -Scope Describe
	}

	It 'викликає модель один раз і рахує токени та вартість' {
		Should -Invoke -ModuleName IndexAdvisor Invoke-RestMethod -Times 1 -Exactly -Scope Describe
		$script:result.llm.totalInputTokens | Should -Be 1000
		$script:result.llm.totalOutputTokens | Should -Be 200
		[double]$script:result.llm.totalCostUsd | Should -BeGreaterThan 0
	}

	It 'не передає моделі літерали з текстів запитів' {
		$script:requestBodies[0] | Should -Not -Match '2026-10-01'
		$script:requestBodies[0] | Should -Match 'Orders'
	}

	It 'будує, перевіряє й оцінює рекомендації' {
		$recommendations = @($script:result.recommendations)
		$recommendations.Count | Should -Be 2
		$create = $recommendations | Where-Object action -eq 'CreateIndex'
		$drop = $recommendations | Where-Object action -eq 'DropIndex'
		$create.validation.status | Should -BeIn @('Passed', 'Warning')
		$create.dataPeriod | Should -Not -BeNullOrEmpty
		$drop.target.objectKey | Should -Be 'ag1|sales|dbo.orders|ix_status'
		$drop.dropEligibility | Should -Not -BeNullOrEmpty
		@($drop.dropEligibility.conditions).Count | Should -BeGreaterThan 5
		foreach ($rec in $recommendations) {
			Test-IaJsonAgainstSchema -Json ($rec | ConvertTo-Json -Depth 50) -Schema recommendation | Should -BeTrue
		}
	}

	It 'записує знахідки rules engine, періоди даних і вердикти' {
		@($script:result.findings).Count | Should -BeGreaterThan 0
		@($script:result.dataPeriods).Count | Should -BeGreaterThan 0
		@($script:result.verdicts | Where-Object objectKey -eq 'ag1|sales|dbo.orders|ix_status').Count | Should -Be 1
	}

	It 'створює MD, SQL, HTML і JSON з періодом даних та скриптами відкату' {
		$out = Join-Path $script:root 'out'
		$md = Get-ChildItem -LiteralPath $out -Recurse -Filter 'recommendations.md' | Select-Object -First 1
		$html = Get-ChildItem -LiteralPath $out -Recurse -Filter 'report.html' | Select-Object -First 1
		$json = Get-ChildItem -LiteralPath $out -Recurse -Filter 'result.json' | Select-Object -First 1
		$md | Should -Not -BeNullOrEmpty
		$html | Should -Not -BeNullOrEmpty
		$json | Should -Not -BeNullOrEmpty
		$sql = @(Get-ChildItem -LiteralPath $out -Recurse -Filter '*.sql')
		@($sql | Where-Object Name -like '*rollback*').Count | Should -Be 2
		($sql.Count - @($sql | Where-Object Name -like '*rollback*').Count) | Should -Be 2
		$mdText = Get-Content -LiteralPath $md.FullName -Raw
		$mdText | Should -Match '2026-09-01'
		$mdText | Should -Match 'IX_Status'
		# SQL у HTML підсвічено тегами span; без них текст скрипта той самий.
		((Get-Content -LiteralPath $html.FullName -Raw) -replace '<span class="[a-z]">|</span>', '') | Should -Match 'DROP INDEX'
	}
}
