# Спільні помічники юніт-тестів. Власник — оркестратор.
# Використання у тест-файлі:  BeforeAll { . (Join-Path $PSScriptRoot '..\TestHelpers.ps1') }

$script:IaRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:IaModuleManifest = Join-Path $script:IaRepoRoot 'src\IndexAdvisor\IndexAdvisor.psd1'
$script:IaFixturesPath = Join-Path $script:IaRepoRoot 'tests\Fixtures'
$script:IaContractsPath = Join-Path $script:IaRepoRoot 'src\IndexAdvisor\contracts'

Import-Module $script:IaModuleManifest -Force -ErrorAction Stop

function Get-IaTestFixture {
	<# Читає JSON-фікстуру з tests/Fixtures як [ordered] хеш-таблиці. #>
	param([Parameter(Mandatory)][string]$Name)
	$path = Join-Path $script:IaFixturesPath $Name
	# Дати лишаються рядками ISO 8601, як вимагає контракт (без -DateKind String ConvertFrom-Json перетворює їх на DateTime).
	return , (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String)
}

function Get-IaTestSnapshot {
	<# Свіжа копія tests/Fixtures/snapshot.sample.json. #>
	return , (Get-IaTestFixture -Name 'snapshot.sample.json')
}

function Get-IaTestConfig {
	<# Конфігурація за замовчуванням з тестовими тимчасовими каталогами (TestDrive:, якщо доступний). #>
	param([string]$Root)
	$config = & (Get-Module IndexAdvisor) { Get-IaDefaultConfig }
	if (-not $Root) {
		$Root = if (Test-Path 'TestDrive:\') { (Get-PSDrive TestDrive).Root } else { Join-Path ([System.IO.Path]::GetTempPath()) ('ia-test-' + [guid]::NewGuid().ToString('N')) }
	}
	$config.archive.path = Join-Path $Root 'archive'
	$config.logging.path = Join-Path $Root 'logs'
	$config.output.path = Join-Path $Root 'out'
	$config.llm.budgetLedgerPath = Join-Path $Root 'state\llm-usage.json'
	$config.repository.enabled = $false
	$config.run.nonInteractive = $true
	return $config
}

function Test-IaJsonAgainstSchema {
	<# Перевіряє JSON-текст за схемою з contracts/. Повертає $true/$false; помилки — у -ErrorVariable. #>
	param(
		[Parameter(Mandatory)][string]$Json,
		[Parameter(Mandatory)][ValidateSet('snapshot', 'recommendation', 'llm-response')][string]$Schema
	)
	$schemaText = Get-Content -LiteralPath (Join-Path $script:IaContractsPath "$Schema.schema.json") -Raw -Encoding utf8
	return Test-Json -Json $Json -Schema $schemaText -ErrorAction SilentlyContinue
}
