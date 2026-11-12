# Юніт-тести обслуговування індексів через usp_AdaptiveIndexDefrag (потік Output): план за snapshot, скрипти, завдання SQL Agent,
# звіт, перевизначення CLI і New-IaIndexMaintenance з архіву. Сервери не потрібні: усе будується з фікстури.

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:Module = Get-Module IndexAdvisor

	function Get-MntTestPlan {
		param([System.Collections.IDictionary]$Snapshot = (Get-IaTestSnapshot), [System.Collections.IDictionary]$Config = (Get-IaTestConfig), [object[]]$Recommendations = @())
		& $script:Module { param($s, $c, $r) Get-IaMaintenancePlan -Snapshot $s -Config $c -Recommendations $r -RunId 'run-1' } $Snapshot $Config $Recommendations
	}

	function Get-MntTestScripts {
		param([System.Collections.IDictionary]$Plan)
		& $script:Module {
			param($p)
			[ordered]@{
				script = ConvertTo-IaMaintenanceSql -Plan $p
				rollback = ConvertTo-IaMaintenanceRollbackSql -Plan $p
				job = ConvertTo-IaMaintenanceJobSql -Plan $p
				jobRollback = ConvertTo-IaMaintenanceJobRollbackSql -Plan $p
			}
		} $Plan
	}

	function Get-MntTestParseErrors {
		param([string]$Text)
		$errors = $null
		$parser = & $script:Module { Get-IaScriptDomParser }
		$null = $parser.Parse([System.IO.StringReader]::new($Text), [ref]$errors)
		return , @($errors | ForEach-Object { "L$($_.Line): $($_.Message)" })
	}

	function New-MntTestDropRecommendation {
		param([string]$Table, [string]$Index, [string]$Status = 'Passed')
		[ordered]@{
			action = 'DropIndex'
			title = "Видалити $Index"
			target = [ordered]@{ server = 'SQL01'; database = 'Sales'; schema = 'dbo'; table = $Table; index = $Index; objectKey = "sales.dbo.$Table.$Index" }
			validation = [ordered]@{ status = $Status; checks = @() }
		}
	}

	function Find-MntTestCandidate {
		param([System.Collections.IDictionary]$Plan, [string]$Index)
		return @($Plan.databases[0].candidates | Where-Object { $_.index -eq $Index }) | Select-Object -First 1
	}
}

Describe 'Get-IaMaintenancePlan' {
	It 'бере базу AG з primary-репліки й відбирає кандидатів за порогами rules.fragmentation' {
		$plan = Get-MntTestPlan
		@($plan.databases).Count | Should -Be 1
		$database = $plan.databases[0]
		$database.name | Should -Be 'Sales'
		$database.server | Should -Be 'SQL01'
		$database.availabilityGroup | Should -Be 'AG1'
		(Find-MntTestCandidate $plan 'IX_Comment').operation | Should -Be 'Rebuild'
		(Find-MntTestCandidate $plan 'IX_CustomerId_OrderDate_INC').operation | Should -Be 'Reorganize'
		Find-MntTestCandidate $plan 'PK_Orders' | Should -BeNullOrEmpty
		Find-MntTestCandidate $plan 'PK_Customers' | Should -BeNullOrEmpty
		$database.summary.candidates | Should -Be @($database.candidates).Count
		$database.summary.rebuild + $database.summary.reorganize | Should -Be $database.summary.candidates
		$database.candidates[0].operation | Should -Be 'Rebuild'
		@($database.notes) -join ' ' | Should -Match 'AG1'
	}

	It 'параметри процедури: пороги з конфігурації, ONLINE і RESUMABLE для Enterprise 2022, без SORT_IN_TEMPDB разом з RESUMABLE' {
		$parameters = (Get-MntTestPlan).databases[0].parameters
		$parameters['@minFragmentation'] | Should -Be 10
		$parameters['@rebuildThreshold'] | Should -Be 30
		$parameters['@minPageCount'] | Should -Be 1000
		$parameters['@onlineRebuild'] | Should -Be 1
		$parameters['@resumableRebuild'] | Should -Be 1
		$parameters['@sortInTempDB'] | Should -Be 0
		$parameters['@defragOrderColumn'] | Should -Be 'range_scan_count'
		$parameters.Contains('@dealMaxPartition') | Should -BeTrue
		$parameters['@dealMaxPartition'] | Should -BeNullOrEmpty
	}

	It 'редакція без ONLINE: перебудова офлайн, SORT_IN_TEMPDB і застереження про блокування' {
		$snapshot = Get-IaTestSnapshot
		foreach ($instance in $snapshot.instances) {
			$instance.supportsOnlineIndexOps = $false
			$instance.edition = 'Standard Edition (64-bit)'
		}
		$database = (Get-MntTestPlan -Snapshot $snapshot).databases[0]
		$database.parameters['@onlineRebuild'] | Should -Be 0
		$database.parameters['@resumableRebuild'] | Should -Be 0
		$database.parameters['@sortInTempDB'] | Should -Be 1
		@($database.notes) -join ' ' | Should -Match 'ONLINE'
	}

	It 'індекс, рекомендований до видалення, стає винятком з exclusionMask = -1; відхилена перевіркою рекомендація — ні' {
		$recs = @(
			New-MntTestDropRecommendation -Table 'Orders' -Index 'IX_Status'
			New-MntTestDropRecommendation -Table 'Orders' -Index 'IX_Comment' -Status 'Failed'
		)
		$plan = Get-MntTestPlan -Recommendations $recs
		$exclusions = @($plan.databases[0].exclusions)
		$exclusions.Count | Should -Be 1
		$exclusions[0].index | Should -Be 'IX_Status'
		$exclusions[0].exclusionMask | Should -Be -1
		$exclusions[0].indexId | Should -Be 4
		Find-MntTestCandidate $plan 'IX_Status' | Should -BeNullOrEmpty
		Find-MntTestCandidate $plan 'IX_Comment' | Should -Not -BeNullOrEmpty
	}

	It 'excludeDropCandidates = false — винятків немає' {
		$config = Get-IaTestConfig
		$config.maintenance.excludeDropCandidates = $false
		$plan = Get-MntTestPlan -Config $config -Recommendations @(New-MntTestDropRecommendation -Table 'Orders' -Index 'IX_Status')
		@($plan.databases[0].exclusions).Count | Should -Be 0
	}

	It 'великі індекси обслуговуються лише в largeIndexDays: @maxPageCount з порогу в сторінках' {
		$config = Get-IaTestConfig
		$config.maintenance.largeIndexMb = 500
		$plan = Get-MntTestPlan -Config $config
		$plan.largeIndexMaxPageCount | Should -Be 64000
		$plan.largeIndexDayMask | Should -Be 65
		(Find-MntTestCandidate $plan 'IX_Comment').isLarge | Should -BeTrue
		(Find-MntTestCandidate $plan 'IX_Status').isLarge | Should -BeFalse
		(Get-MntTestScripts -Plan $plan).job | Should -Match '@maxPageCount = @maxPageCount'
	}

	It 'без обмеження великих індексів <Case> — @maxPageCount не передається' -ForEach @(
		@{ Case = '(largeIndexMb = 0)'; Mb = 0; Days = @('Saturday', 'Sunday') }
		@{ Case = '(largeIndexDays — увесь розклад)'; Mb = 500; Days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') }
	) {
		$config = Get-IaTestConfig
		$config.maintenance.largeIndexMb = $Mb
		$config.maintenance.largeIndexDays = $Days
		$plan = Get-MntTestPlan -Config $config
		$plan.largeIndexMaxPageCount | Should -BeNullOrEmpty
		(Get-MntTestScripts -Plan $plan).job | Should -Not -Match 'maxPageCount'
	}

	It 'попереджає, якщо дні великих індексів не перетинаються з розкладом' {
		$config = Get-IaTestConfig
		$config.maintenance.scheduleDays = @('Monday', 'Wednesday')
		$plan = Get-MntTestPlan -Config $config
		@($plan.warnings) -join ' ' | Should -Match 'не обслуговуватиме'
	}

	It 'некоректна конфігурація: <Case>' -ForEach @(
		@{ Case = 'час не HH:mm'; Key = 'startTime'; Value = '25:00'; Pattern = 'HH:mm' }
		@{ Case = 'порожній розклад'; Key = 'scheduleDays'; Value = @(); Pattern = 'scheduleDays' }
	) {
		$config = Get-IaTestConfig
		$config.maintenance[$Key] = $Value
		{ Get-MntTestPlan -Config $config } | Should -Throw "*$Pattern*"
	}
}

Describe 'Скрипти обслуговування' {
	BeforeAll {
		$script:Plan = Get-MntTestPlan -Recommendations @(New-MntTestDropRecommendation -Table 'Orders' -Index 'IX_Status')
		$script:Scripts = Get-MntTestScripts -Plan $script:Plan
	}

	It '<Name> розбирається ScriptDom без помилок, рядки не довші за 160 символів, без GRANT' -ForEach @(
		@{ Name = 'script' }
		@{ Name = 'rollback' }
		@{ Name = 'job' }
		@{ Name = 'jobRollback' }
	) {
		$text = [string]$script:Scripts[$Name]
		$text | Should -Not -BeNullOrEmpty
		Get-MntTestParseErrors -Text $text | Should -BeNullOrEmpty
		@($text -split "`r?`n" | Where-Object { $_.Length -gt 160 }) | Should -BeNullOrEmpty
		$text | Should -Not -Match '(?i)\bGRANT\b'
	}

	It 'ручний скрипт: перевірка процедури, винятки, попередній перегляд за замовчуванням, лише primary для AG' {
		$text = $script:Scripts.script
		$text | Should -Match ([regex]::Escape("IF OBJECT_ID(N'dbo.usp_AdaptiveIndexDefrag', N'P') IS NULL"))
		$text | Should -Match 'USE \[msdb\];'
		$text | Should -Match 'DECLARE @execPrint BIT = 0;'
		$text | Should -Match ([regex]::Escape("(N'Sales', 201, 4, N'dbo.Orders', N'IX_Status', -1)"))
		$text | Should -Match 'INSERT INTO dbo\.tbl_AdaptiveIndexDefrag_Exceptions'
		$text | Should -Match ([regex]::Escape("sys.fn_hadr_is_primary_replica(N'Sales') = 1"))
		$text | Should -Match ([regex]::Escape("@dbScope = N'Sales'"))
		$text | Should -Match '@timeLimit = @minutesLeft'
	}

	It 'відкат видаляє лише винятки плану; без винятків файлу відкату немає' {
		$script:Scripts.rollback | Should -Match 'DELETE e'
		$script:Scripts.rollback | Should -Match ([regex]::Escape("N'IX_Status'"))
		$withoutExclusions = Get-MntTestScripts -Plan (Get-MntTestPlan)
		$withoutExclusions.rollback | Should -BeNullOrEmpty
	}

	It 'завдання: кроки процедури й очищення журналів, щоденний розклад, заміна лише за @replaceExisting = 1' {
		$text = $script:Scripts.job
		$text | Should -Match 'DECLARE @replaceExisting BIT = 0;'
		$text | Should -Match 'msdb\.dbo\.sp_add_job\b'
		$text | Should -Match "@step_name = N'AdaptiveIndexDefrag',"
		$text | Should -Match 'usp_AdaptiveIndexDefrag_PurgeLogs'
		$text | Should -Match '@freq_type = 4,'
		$text | Should -Match '@active_start_time = 10000;'
		$text | Should -Match 'msdb\.dbo\.sp_add_jobserver'
		# Команда кроку — рядковий літерал: апострофи подвоєні, крок виконує процедуру (@execPrint = 1).
		$text | Should -Match ([regex]::Escape("@dbScope = N''Sales''"))
		$text | Should -Match 'DECLARE @execPrint BIT = 1;'
	}

	It 'тижневий розклад, власник завдання і без кроку очищення журналів' {
		$config = Get-IaTestConfig
		$config.maintenance.scheduleDays = @('Monday', 'Wednesday', 'Saturday')
		$config.maintenance.startTime = '23:30'
		$config.maintenance.jobOwner = 'CONTOSO\sql-agent'
		$config.maintenance.purgeLogs = $false
		$text = (Get-MntTestScripts -Plan (Get-MntTestPlan -Config $config)).job
		$text | Should -Match '@freq_type = 8,'
		$text | Should -Match '@freq_interval = 74,'
		$text | Should -Match '@active_start_time = 233000;'
		$text | Should -Match ([regex]::Escape("@owner_login_name = N'CONTOSO\sql-agent',"))
		$text | Should -Not -Match 'PurgeLogs'
		$text | Should -Match '@on_success_action = 1,'
	}

	It 'апострофи в іменах екрануються і в скрипті, і в команді кроку завдання' {
		$snapshot = Get-IaTestSnapshot
		foreach ($instance in $snapshot.instances) {
			foreach ($database in $instance.databases) {
				$database.name = "O'Sales"
			}
		}
		$scripts = Get-MntTestScripts -Plan (Get-MntTestPlan -Snapshot $snapshot)
		$scripts.script | Should -Match ([regex]::Escape("@dbScope = N'O''Sales'"))
		$scripts.job | Should -Match ([regex]::Escape("@dbScope = N''O''''Sales''"))
		Get-MntTestParseErrors -Text $scripts.script | Should -BeNullOrEmpty
		Get-MntTestParseErrors -Text $scripts.job | Should -BeNullOrEmpty
	}
}

Describe 'Обслуговування у звіті й конвеєрі' {
	It 'Export-IaReport пише maintenance/*.sql і розділ звіту, якщо в запуску є план' {
		$config = Get-IaTestConfig
		$config.output.formats = @('Markdown')
		$run = & $script:Module { New-IaRunResult -RequestedServer 'AGL-SALES' -Module 'Indexes' }
		$run.maintenance = Get-MntTestPlan -Config $config
		$files = & $script:Module { param($r, $c) Export-IaReport -RunResult $r -Config $c } $run $config
		$names = @($files | ForEach-Object { Split-Path $_ -Leaf })
		$names | Should -Contain 'index_maintenance.sql'
		$names | Should -Contain 'index_maintenance_job.sql'
		$names | Should -Contain 'index_maintenance_job_rollback.sql'
		$markdown = Get-Content -LiteralPath ($files | Where-Object { $_ -like '*recommendations.md' }) -Raw -Encoding utf8
		$markdown | Should -Match 'Обслуговування індексів \(AdaptiveIndexDefrag\)'
		$markdown | Should -Match 'IX_Comment'
	}

	It '-Maintenance вмикає maintenance.enabled' {
		$overrides = & $script:Module { ConvertTo-IaCliOverrides -BoundParameters ([ordered]@{ Maintenance = [switch]::new($true) }) }
		$overrides.maintenance.enabled | Should -BeTrue
	}

	It 'конфігурація за замовчуванням: вимкнено, msdb, щодня о 01:00, великі індекси у вихідні' {
		$config = & $script:Module { Get-IaDefaultConfig }
		$config.maintenance.enabled | Should -BeFalse
		$config.maintenance.procedureDatabase | Should -Be 'msdb'
		@($config.maintenance.scheduleDays).Count | Should -Be 7
		$config.maintenance.startTime | Should -Be '01:00'
		@($config.maintenance.largeIndexDays) | Should -Be @('Saturday', 'Sunday')
	}
}

Describe 'New-IaIndexMaintenance' {
	It 'будує скрипти з архіву без збору й LLM; рекомендації на видалення з result.json стають винятками' {
		$root = (Get-PSDrive TestDrive).Root
		$config = Get-IaTestConfig -Root $root
		$prompt = [ordered]@{ templateId = 'index-analysis'; templateVersion = 1; messages = @(); toolSchemas = @(); responseSchema = [ordered]@{ type = 'object' } }
		$archivePath = & $script:Module {
			param($s, $p, $c)
			Save-IaSnapshotArchive -Snapshot $s -Prompts @($p) -MaskingMap $null -RunId '0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b' -Config $c
		} (Get-IaTestSnapshot) $prompt $config
		$resultPath = Join-Path $root 'result.json'
		ConvertTo-Json -Depth 10 -InputObject ([ordered]@{ runId = 'run-7'; recommendations = @(New-MntTestDropRecommendation -Table 'Orders' -Index 'IX_Status') }) |
			Set-Content -LiteralPath $resultPath -Encoding utf8
		$result = New-IaIndexMaintenance -FromArchive $archivePath -ResultPath $resultPath -OutputPath (Join-Path $root 'mnt') -PassThru 6>$null
		$result.plan.runId | Should -Be 'run-7'
		@($result.plan.databases[0].exclusions).Count | Should -Be 1
		$names = @($result.files | ForEach-Object { Split-Path $_ -Leaf })
		$names | Should -Contain 'index_maintenance.sql'
		$names | Should -Contain 'index_maintenance_rollback.sql'
		$names | Should -Contain 'maintenance_plan.md'
		Get-Content -LiteralPath ($result.files | Where-Object { $_ -like '*maintenance_plan.md' }) -Raw -Encoding utf8 | Should -Match '# План обслуговування індексів'
	}
}
