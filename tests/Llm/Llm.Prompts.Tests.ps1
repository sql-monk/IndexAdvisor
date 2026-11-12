BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'LlmTestHelpers.ps1')
}

Describe 'Get-IaPromptTemplate' {
	It 'шаблон <Name> є, має розділи System і User і версію' -TestCases @(@{ Name = 'index-analysis' }, @{ Name = 'partition-analysis' }, @{ Name = 'cross-check' }) {
		$template = InModuleScope IndexAdvisor -Parameters @{ Name = $Name } { param($Name) Get-IaPromptTemplate -Name $Name }
		@($template.Keys) | Should -Be @('id', 'version', 'system', 'user', 'path')
		$template.id | Should -Be $Name
		$template.version | Should -BeGreaterOrEqual 1
		$template.system | Should -Not -BeNullOrEmpty
		$template.user | Should -Match '\{\{payload\}\}'
		$template.system | Should -Match '\{\{responseSchema\}\}'
		Test-Path -LiteralPath $template.path | Should -BeTrue
		$template.path | Should -Match "Llm[\\/]Prompts[\\/]$Name\.v\d+\.md$"
	}

	It 'Version = 0 повертає найновішу версію (числове порівняння), Version = N — задану' {
		$directory = Join-Path $TestDrive 'prompts'
		$null = New-Item -ItemType Directory -Path $directory -Force
		foreach ($version in @(1, 2, 10)) {
			Set-Content -LiteralPath (Join-Path $directory "index-analysis.v$version.md") -Value "# v$version`n## System`nsystem v$version`n## User`nuser v$version {{payload}}" -Encoding utf8
		}
		Set-Content -LiteralPath (Join-Path $directory 'index-analysis.vX.md') -Value 'broken' -Encoding utf8
		Mock -ModuleName IndexAdvisor Get-ChildItem { Get-ChildItem -LiteralPath (Join-Path $TestDrive 'prompts') -Filter $Filter -File } -ParameterFilter { $Filter -like 'index-analysis.v*' }
		$latest = InModuleScope IndexAdvisor { Get-IaPromptTemplate -Name 'index-analysis' }
		$latest.version | Should -Be 10
		$latest.system | Should -Be 'system v10'
		$latest.user | Should -Be 'user v10 {{payload}}'
		(InModuleScope IndexAdvisor { Get-IaPromptTemplate -Name 'index-analysis' -Version 2 }).system | Should -Be 'system v2'
		{ InModuleScope IndexAdvisor { Get-IaPromptTemplate -Name 'index-analysis' -Version 5 } } | Should -Throw
	}

	It 'index-analysis містить вимоги до моделі' {
		$text = (InModuleScope IndexAdvisor { Get-IaPromptTemplate -Name 'index-analysis' }).system
		foreach ($required in @('ONLINE = ON, RESUMABLE = ON', 'supportsOnlineIndexOps', 'replacesIndexes', 'DropIndex', 'DISABLE', 'columnstore', 'CCSI', 'CS_',
				'CI_', 'IX_', 'toolRequests', 'rollbackScript', 'executeScript', 'risk.level', 'rationale', 'isPrimaryKey', 'referencedByForeignKeys',
				'usedByReplication', 'hintReferences', 'ВЕЛИКИМИ', '{{toolSchemas}}', '{{maxToolRequests}}', 'JSON')) {
			$text | Should -Match ([regex]::Escape($required)) -Because "шаблон має згадувати '$required'"
		}
		$text | Should -Match '(?i)злиття missing index'
		$text | Should -Match '(?i)вплив на запис'
	}

	It 'partition-analysis містить усі пункти розділу 4.6 ТЗ' {
		$text = (InModuleScope IndexAdvisor { Get-IaPromptTemplate -Name 'partition-analysis' }).system
		foreach ($required in @('partition elimination', 'перекіс', 'порожні', 'майбутніх періодів', 'clusteredIndexRebuild', 'nonAlignedIndexes', 'PK і UNIQUE',
				'FK', 'реплікацію', 'queriesWithoutPartitionFilter', 'SWITCH', 'TRUNCATE TABLE', 'архівування', 'статистика по секціях', 'migrationPlan',
				'functionScript', 'schemeScript', 'PartitionTable', 'AlterPartitioning', 'нічого не виконує', 'drafts', 'toolRequests', 'pf_', 'ps_')) {
			$text | Should -Match ([regex]::Escape($required)) -Because "шаблон має згадувати '$required'"
		}
	}

	It 'T-SQL у шаблонах — ключові слова ВЕЛИКИМИ' {
		foreach ($name in @('index-analysis', 'partition-analysis', 'cross-check')) {
			$template = InModuleScope IndexAdvisor -Parameters @{ Name = $name } { param($Name) Get-IaPromptTemplate -Name $Name }
			# Фрагменти T-SQL у `...`; шляхи до полів контексту (target.index, sys.indexes) не перевіряються.
			$code = ([regex]::Matches($template.system, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value } |
				Where-Object { $_ -notmatch '^[a-z][A-Za-z0-9_.\[\]]*$' }) -join "`n"
			$code | Should -Not -MatchExactly '\b(create|drop|alter|index|online|resumable|on|switch|truncate|table|partition|with|disable|exists|select)\b(?=\s|\(|$|;|\s*=)' -Because "у $name ключові слова T-SQL мають бути великими"
		}
	}
}

Describe 'New-IaPrompt' {
	BeforeAll {
		$script:Config = Get-IaTestConfig
		$script:Config.limits.maxToolRequestsPerAnalysis = 7
		$script:Payload = [ordered]@{
			module = 'Indexes'
			masking = [ordered]@{ namesMasked = $true; literalsMasked = $true }
			databases = @([ordered]@{ server = 'srv1'; database = 'db1'; note = 'текст із {{payload}} не підставляється' })
		}
		$script:Tools = @([ordered]@{ name = 'index_usage_stats'; description = 'Статистика'; parameters = [ordered]@{ type = 'object'; properties = [ordered]@{}; required = @(); additionalProperties = $false } })
	}

	It 'будує повідомлення system і user з підставленими плейсхолдерами' {
		$prompt = InModuleScope IndexAdvisor -Parameters @{ Payload = $script:Payload; Tools = $script:Tools; Config = $script:Config } {
			param($Payload, $Tools, $Config)
			New-IaPrompt -TemplateName 'index-analysis' -Payload $Payload -ToolSchemas $Tools -Config $Config
		}
		@($prompt.Keys) | Should -Be @('templateId', 'templateVersion', 'messages', 'toolSchemas', 'responseSchema')
		$prompt.templateId | Should -Be 'index-analysis'
		$prompt.templateVersion | Should -Be 1
		$prompt.messages.Count | Should -Be 2
		$prompt.messages[0].role | Should -Be 'system'
		$prompt.messages[1].role | Should -Be 'user'
		$prompt.messages[0].content | Should -Not -Match '\{\{(toolSchemas|responseSchema|maxToolRequests|namesMasked|payload)\}\}'
		$prompt.messages[0].content | Should -Match 'index_usage_stats'
		$prompt.messages[0].content | Should -Match 'Не більше 7 дозапитів'
		$prompt.messages[0].content | Should -Match '"toolRequests"'
		$prompt.messages[1].content | Should -Match 'Імена замасковано: true'
		$prompt.messages[1].content | Should -Match ([regex]::Escape('"database":"db1"'))
		$prompt.messages[1].content | Should -Match ([regex]::Escape('текст із {{payload}} не підставляється'))
		$prompt.toolSchemas.Count | Should -Be 1
		$prompt.responseSchema.required | Should -Be @('recommendations', 'toolRequests')
	}

	It 'без інструментів передає порожній масив схем' {
		$prompt = InModuleScope IndexAdvisor -Parameters @{ Payload = $script:Payload; Config = $script:Config } {
			param($Payload, $Config)
			New-IaPrompt -TemplateName 'partition-analysis' -Payload $Payload -Config $Config
		}
		$prompt.templateId | Should -Be 'partition-analysis'
		$prompt.toolSchemas.Count | Should -Be 0
		$prompt.messages[0].content | Should -Match '(?m)^\[\]$'
	}

	It 'cross-check має власну схему відповіді з verdict' {
		$prompt = InModuleScope IndexAdvisor -Parameters @{ Payload = $script:Payload; Config = $script:Config } {
			param($Payload, $Config)
			New-IaPrompt -TemplateName 'cross-check' -Payload $Payload -Config $Config
		}
		$prompt.responseSchema.properties.verdict.enum | Should -Be @('Agree', 'Disagree', 'Uncertain')
		$prompt.messages[0].content | Should -Match '"verdict"'
	}
}
