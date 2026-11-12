# Тести YAML-конфігурації (CONTRACTS.md, розділ 7): перевірка за схемою з номерами рядків, секрети, пріоритет CLI, шаблон.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')

	function New-TestYaml {
		param([Parameter(Mandatory)][string]$Text, [string]$Name = ([guid]::NewGuid().ToString('N') + '.yaml'))
		$path = Join-Path $TestDrive $Name
		[System.IO.File]::WriteAllText($path, $Text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
		return $path
	}

	function Get-TestConfigErrors {
		param([Parameter(Mandatory)][string]$Path)
		return , @((Test-IaConfig -Path $Path).errors)
	}
}

Describe 'Test-IaConfig і Get-IaConfig' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Test-IaSecretReference {
			$Reference -match '^(env:[A-Za-z_][A-Za-z0-9_]*|secret:[^/\s]+(/[^/\s]+)?)$'
		}
	}

	It 'приймає валідний YAML і зливає його зі значеннями за замовчуванням' {
		$path = New-TestYaml -Text @'
version: 1
servers:
  - SQL01
  - AGL-SALES
module: Both
llm:
  provider: openai
  maskNames: true
  providers:
    openai:
      type: OpenAI
      model: gpt-4.1
      apiKeyRef: 'secret:IndexAdvisor-openai'
rules:
  relaxed:
    minWriteToReadRatio: 12.5
  observationOverrides:
    - server: AG1
      database: Sales
      minUptimeDays: 30
output:
  formats: [Markdown, Html]
'@
		$result = Test-IaConfig -Path $path
		$result.isValid | Should -BeTrue
		@($result.errors).Count | Should -Be 0

		$config = InModuleScope IndexAdvisor -Parameters @{ Path = $path } { param($Path) Get-IaConfig -Path $Path }
		@($config.servers) | Should -Be @('SQL01', 'AGL-SALES')
		$config.module | Should -Be 'Both'
		$config.llm.maskNames | Should -BeTrue
		$config.llm.providers.openai.model | Should -Be 'gpt-4.1'
		$config.llm.providers.openai.timeoutSeconds | Should -Be 120
		$config.rules.relaxed.minWriteToReadRatio | Should -Be 12.5
		$config.rules.observationOverrides[0].minUptimeDays | Should -Be 30
		$config.rules.observationOverrides[0].table | Should -Be ''
		@($config.output.formats) | Should -Be @('Markdown', 'Html')
		$config.limits.defaultFetch | Should -Be 300
		$config.rules.drop.requiredConsecutive | Should -Be 3
	}

	It 'невідомий ключ — помилка з рядком і стовпцем ключа' {
		$path = New-TestYaml -Text @'
version: 1
llm:
  provder: openai
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors.Count | Should -Be 1
		$errors[0].line | Should -Be 3
		$errors[0].column | Should -Be 3
		$errors[0].path | Should -Be 'llm.provder'
		$errors[0].message | Should -Match 'Невідомий ключ'
	}

	It 'ключ з іншим регістром — невідомий ключ з підказкою' {
		$path = New-TestYaml -Text @'
Version: 1
'@
		$errors = Get-TestConfigErrors -Path $path
		($errors | Where-Object { $_.path -ceq 'Version' }).message | Should -Match "Можливо, мали на увазі 'version'"
	}

	It 'неправильний тип — помилка з позицією значення' {
		$path = New-TestYaml -Text @'
version: 1
limits:
  defaultFetch: abc
archive:
  enabled: yes
servers: SQL01
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors.Count | Should -Be 3
		$fetch = $errors | Where-Object { $_.path -eq 'limits.defaultFetch' }
		$fetch.line | Should -Be 3
		$fetch.column | Should -Be 17
		$fetch.message | Should -Match 'ціле число'
		$enabled = $errors | Where-Object { $_.path -eq 'archive.enabled' }
		$enabled.line | Should -Be 5
		$enabled.column | Should -Be 12
		($errors | Where-Object { $_.path -eq 'servers' }).line | Should -Be 6
	}

	It 'ціле число в лапках — неправильний тип' {
		$path = New-TestYaml -Text @'
version: '1'
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors[0].path | Should -Be 'version'
		$errors[0].line | Should -Be 1
		$errors[0].column | Should -Be 10
	}

	It 'значення поза enum — помилка з переліком допустимих' {
		$path = New-TestYaml -Text @'
version: 1
module: Everything
output:
  formats:
    - Markdown
    - Pdf
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors.Count | Should -Be 2
		$module = $errors | Where-Object { $_.path -eq 'module' }
		$module.line | Should -Be 2
		$module.column | Should -Be 9
		$module.message | Should -Match 'Indexes, Partitioning, Both'
		$format = $errors | Where-Object { $_.path -eq 'output.formats[1]' }
		$format.line | Should -Be 6
		$format.column | Should -Be 7
	}

	It 'min/max — помилка з межею' {
		$path = New-TestYaml -Text @'
version: 1
limits:
  maxRows: 6000
rules:
  drop:
    minUptimeDays: 7
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors.Count | Should -Be 2
		$maxRows = $errors | Where-Object { $_.path -eq 'limits.maxRows' }
		$maxRows.line | Should -Be 3
		$maxRows.column | Should -Be 12
		$maxRows.message | Should -Match '5000'
		$minUptime = $errors | Where-Object { $_.path -eq 'rules.drop.minUptimeDays' }
		$minUptime.line | Should -Be 6
		$minUptime.message | Should -Match '14'
	}

	It "відсутній обов'язковий ключ — у корені, у map провайдерів і в елементі масиву" {
		$path = New-TestYaml -Text @'
llm:
  providers:
    local:
      model: qwen
rules:
  observationOverrides:
    - database: Sales
      minUptimeDays: 20
'@
		$errors = Get-TestConfigErrors -Path $path
		$version = $errors | Where-Object { $_.path -eq 'version' }
		$version.line | Should -Be 1
		$version.column | Should -Be 1
		$type = $errors | Where-Object { $_.path -eq 'llm.providers.local.type' }
		$type.line | Should -Be 4
		$type.column | Should -Be 7
		$type.message | Should -Match "обов'язковий"
		$server = $errors | Where-Object { $_.path -eq 'rules.observationOverrides[0].server' }
		$server.line | Should -Be 7
		$server.column | Should -Be 7
	}

	It 'секрет відкритим текстом — помилка «секрети не зберігаються в YAML»' {
		$path = New-TestYaml -Text @'
version: 1
connection:
  passwordRef: 'P@ssw0rd!'
llm:
  providers:
    openai:
      type: OpenAI
      model: gpt-4.1
      apiKeyRef: sk-live-1234567890
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors.Count | Should -Be 2
		$password = $errors | Where-Object { $_.path -eq 'connection.passwordRef' }
		$password.line | Should -Be 3
		$password.column | Should -Be 16
		$password.message | Should -Match 'Секрети не зберігаються в YAML'
		($errors | Where-Object { $_.path -eq 'llm.providers.openai.apiKeyRef' }).line | Should -Be 9
		($errors | ForEach-Object { $_.message }) -join ' ' | Should -Not -Match 'P@ssw0rd|sk-live'
	}

	It "обов'язковий набір даних не вимикається" {
		$path = New-TestYaml -Text @'
version: 1
collector:
  datasets:
    indexStructure: false
    queryStore: false
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors.Count | Should -Be 1
		$errors[0].path | Should -Be 'collector.datasets.indexStructure'
		$errors[0].line | Should -Be 4
	}

	It 'синтаксична помилка YAML — з номером рядка' {
		$path = New-TestYaml -Text @'
version: 1
llm:
  provider: x
 model: [
'@
		$result = Test-IaConfig -Path $path
		$result.isValid | Should -BeFalse
		$result.errors[0].message | Should -Match 'синтаксису YAML'
		$result.errors[0].line | Should -BeGreaterThan 1
	}

	It 'дублікат ключа — помилка з номером рядка' {
		$path = New-TestYaml -Text @'
version: 1
module: Indexes
module: Both
'@
		$errors = Get-TestConfigErrors -Path $path
		$errors[0].line | Should -Be 3
	}

	It 'відсутній файл — помилка без позиції' {
		$result = Test-IaConfig -Path (Join-Path $TestDrive 'missing.yaml')
		$result.isValid | Should -BeFalse
		$result.errors[0].message | Should -Match 'не знайдено'
	}

	It 'Get-IaConfig кидає IaConfigInvalid з масивом помилок у TargetObject' {
		$path = New-TestYaml -Text @'
version: 1
module: Wrong
'@
		$caught = $null
		try {
			InModuleScope IndexAdvisor -Parameters @{ Path = $path } { param($Path) Get-IaConfig -Path $Path }
		}
		catch {
			$caught = $_
		}
		$caught | Should -Not -BeNullOrEmpty
		$caught.FullyQualifiedErrorId | Should -Match '^IaConfigInvalid'
		@($caught.TargetObject)[0].line | Should -Be 2
		$caught.Exception.Message | Should -Match 'рядок 2, стовпець 9'
	}

	It 'параметри CLI мають пріоритет над YAML' {
		$path = New-TestYaml -Text @'
version: 1
servers: [SQL01]
module: Indexes
llm:
  provider: openai
  maskNames: false
repository:
  enabled: true
analysisWindow:
  days: 30
'@
		$config = InModuleScope IndexAdvisor -Parameters @{ Path = $path } {
			param($Path)
			$overrides = ConvertTo-IaCliOverrides -BoundParameters ([ordered]@{
					Server = @('SQL09', 'SQL10')
					Module = 'Both'
					MaskNames = [switch]$true
					NoRepository = [switch]$true
					AnalysisWindowDays = 60
					Dataset = @('usageStats')
					Format = @('Html', 'Json')
				})
			Get-IaConfig -Path $Path -Overrides $overrides
		}
		@($config.servers) | Should -Be @('SQL09', 'SQL10')
		$config.module | Should -Be 'Both'
		$config.llm.provider | Should -Be 'openai'
		$config.llm.maskNames | Should -BeTrue
		$config.repository.enabled | Should -BeFalse
		$config.analysisWindow.days | Should -Be 60
		@($config.output.formats) | Should -Be @('Html', 'Json')
		$config.collector.datasets.usageStats | Should -BeTrue
		$config.collector.datasets.indexStructure | Should -BeTrue
		$config.collector.datasets.instanceStartTime | Should -BeTrue
		$config.collector.datasets.queryStore | Should -BeFalse
	}

	It '-ExcludeDataset вимикає набір; обов''язковий або невідомий набір — IaConfigInvalid' {
		$config = InModuleScope IndexAdvisor {
			Get-IaConfig -Overrides (ConvertTo-IaCliOverrides -BoundParameters ([ordered]@{ ExcludeDataset = @('queryStore') }))
		}
		$config.collector.datasets.queryStore | Should -BeFalse
		$config.collector.datasets.usageStats | Should -BeTrue
		{ InModuleScope IndexAdvisor { ConvertTo-IaCliOverrides -BoundParameters ([ordered]@{ ExcludeDataset = @('indexStructure') }) } } |
			Should -Throw -ExpectedMessage '*indexStructure*'
		{ InModuleScope IndexAdvisor { ConvertTo-IaCliOverrides -BoundParameters ([ordered]@{ Dataset = @('bogus') }) } } |
			Should -Throw -ExpectedMessage "*bogus*"
	}
}

Describe 'New-IaConfigTemplate' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Test-IaSecretReference {
			$Reference -match '^(env:[A-Za-z_][A-Za-z0-9_]*|secret:[^/\s]+(/[^/\s]+)?)$'
		}
	}

	It 'генерує шаблон з усіма ключами, значеннями за замовчуванням і коментарями, що проходить Test-IaConfig' {
		$text = New-IaConfigTemplate
		$schema = InModuleScope IndexAdvisor { Get-IaConfigSchema }
		foreach ($property in $schema.Properties) {
			$text | Should -Match ("(?m)^{0}:" -f [regex]::Escape($property.Name))
		}
		$text | Should -Match '(?m)^# Версія формату конфігурації'
		$text | Should -Match '(?m)^  defaultFetch: 300$'
		$text | Should -Match "(?m)^  passwordRef: 'secret:IndexAdvisor-index-advisor'$"
		$text | Should -Match '(?m)^    openai:$'
		$text | Should -Match '(?m)^    local:$'
		$text | Should -Match 'Допустимі значення: Indexes, Partitioning, Both'
		$path = Join-Path $TestDrive 'template.yaml'
		New-IaConfigTemplate -Path $path | Out-Null
		$result = Test-IaConfig -Path $path
		$result.errors | ForEach-Object { "$($_.line):$($_.column) $($_.path) $($_.message)" } | Should -BeNullOrEmpty
		$result.isValid | Should -BeTrue
	}

	It 'не перезаписує файл без -Force' {
		$path = Join-Path $TestDrive 'existing.yaml'
		Set-Content -LiteralPath $path -Value 'version: 1'
		{ New-IaConfigTemplate -Path $path } | Should -Throw -ExpectedMessage '*-Force*'
		New-IaConfigTemplate -Path $path -Force | Out-Null
		(Get-Content -LiteralPath $path -Raw) | Should -Match 'Шаблон згенеровано'
	}
}
