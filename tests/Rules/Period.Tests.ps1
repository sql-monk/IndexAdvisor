BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	. (Join-Path $PSScriptRoot 'Rules.TestHelpers.ps1')
	function Get-TestWindow {
		param($Config, [datetime]$NowUtc)
		return InModuleScope IndexAdvisor -Parameters @{ Config = $Config; NowUtc = $NowUtc } { Get-IaAnalysisWindow -Config $Config -NowUtc $NowUtc }
	}
	function Get-TestPeriods {
		param($Snapshot, $Config)
		return , @(InModuleScope IndexAdvisor -Parameters @{ Snapshot = $Snapshot; Config = $Config } { Get-IaDataPeriod -Snapshot $Snapshot -Config $Config })
	}
	function New-TestUtc {
		param([int]$Year, [int]$Month, [int]$Day, [int]$Hour = 10)
		return [datetime]::new($Year, $Month, $Day, $Hour, 0, 0, [System.DateTimeKind]::Utc)
	}
}

Describe 'Get-IaAnalysisWindow' {
	BeforeEach {
		$config = Get-IaTestConfig
	}

	It 'на початку місяця вікно охоплює весь попередній місяць разом з його кінцем' {
		$window = Get-TestWindow $config (New-TestUtc 2026 11 3)
		$window.mode | Should -Be 'PreviousMonth'
		$window.fromUtc | Should -Be '2026-10-01T00:00:00.000Z'
		$window.toUtc | Should -Be '2026-11-03T10:00:00.000Z'
		$window.reason | Should -Match '2026-10'
	}

	It 'на початку січня — увесь грудень попереднього року' {
		$window = Get-TestWindow $config (New-TestUtc 2027 1 2)
		$window.mode | Should -Be 'PreviousMonth'
		$window.fromUtc | Should -Be '2026-12-01T00:00:00.000Z'
	}

	It 'межа analysisWindow.monthStartDays включна' {
		(Get-TestWindow $config (New-TestUtc 2026 11 5)).mode | Should -Be 'PreviousMonth'
		(Get-TestWindow $config (New-TestUtc 2026 11 6)).mode | Should -Be 'Days'
	}

	It 'у середині місяця — analysisWindow.days' {
		$window = Get-TestWindow $config (New-TestUtc 2026 11 20)
		$window.mode | Should -Be 'Days'
		$window.fromUtc | Should -Be '2026-10-21T10:00:00.000Z'
		$window.toUtc | Should -Be '2026-11-20T10:00:00.000Z'
		$window.reason | Should -Be 'analysisWindow.days = 30'
	}

	It 'monthStartRule = $false — завжди analysisWindow.days' {
		$config.analysisWindow.monthStartRule = $false
		(Get-TestWindow $config (New-TestUtc 2026 11 2)).mode | Should -Be 'Days'
	}

	It 'довше вікно analysisWindow.days на початку місяця не скорочується' {
		$config.analysisWindow.days = 90
		$window = Get-TestWindow $config (New-TestUtc 2026 11 2)
		$window.mode | Should -Be 'PreviousMonth'
		$window.fromUtc | Should -Be '2026-08-04T10:00:00.000Z'
	}
}

Describe 'Get-IaDataPeriod' {
	BeforeEach {
		$snapshot = Get-IaTestSnapshot
		$config = Get-IaTestConfig
	}

	It 'період для кожного інстансу і бази; для бази в AG — найкоротший серед реплік' {
		$periods = Get-TestPeriods $snapshot $config
		$periods.Count | Should -Be 3
		$sql01 = $periods | Where-Object { $_.server -eq 'SQL01' }
		$sql01.database | Should -BeNullOrEmpty
		$sql01.uptimeDays | Should -Be 70.21
		$sql01.statsFromUtc | Should -Be '2026-09-01T03:00:00.000Z'
		$sales = $periods | Where-Object { $_.server -eq 'AG1' -and $_.database -eq 'Sales' }
		$sales.uptimeDays | Should -Be 16.25
		$sales.sqlserverStartTimeUtc | Should -Be '2026-10-25T02:00:00.000Z'
		$sales.queryStoreFromUtc | Should -Be '2026-08-12T00:00:00.000Z'
		$sales.queryStoreDays | Should -Be 90.33
		$sales.minRequiredDays | Should -Be 14
		$sales.isSufficient | Should -BeTrue
		$sales.warnings.Count | Should -Be 0
	}

	It 'відповідає recommendation.schema.json ($defs.dataPeriod)' {
		$period = (Get-TestPeriods $snapshot $config) | Where-Object { $_.database -eq 'Sales' }
		$recommendation = New-IaRuleTestRecommendation -Action 'DropIndex' -Index 'IX_Status'
		$recommendation.dataPeriod = $period
		Test-IaJsonAgainstSchema -Json ($recommendation | ConvertTo-Json -Depth 50) -Schema recommendation | Should -BeTrue
	}

	It 'observationOverrides: найточніший збіг (база важливіша за сервер), listener як ім''я сервера' {
		$config.rules.observationOverrides = @(
			[ordered]@{ server = 'AG1'; database = ''; table = ''; minUptimeDays = 40 }
			[ordered]@{ server = 'AGL-SALES'; database = 'Sales'; table = ''; minUptimeDays = 20 }
		)
		$periods = Get-TestPeriods $snapshot $config
		$sales = $periods | Where-Object { $_.database -eq 'Sales' }
		$sales.minRequiredDays | Should -Be 20
		$sales.isSufficient | Should -BeFalse
		($sales.warnings -join ' ') | Should -Match 'коротший за мінімальний 20'
		($periods | Where-Object { $_.server -eq 'SQL02' }).minRequiredDays | Should -Be 14
	}

	It 'override для сервера застосовується до інстансу' {
		$config.rules.observationOverrides = @([ordered]@{ server = 'SQL01'; database = ''; table = ''; minUptimeDays = 100 })
		$sql01 = (Get-TestPeriods $snapshot $config) | Where-Object { $_.server -eq 'SQL01' }
		$sql01.minRequiredDays | Should -Be 100
		$sql01.isSufficient | Should -BeFalse
	}

	It 'короткий період — попередження; failover скорочує період' {
		$snapshot.instances[1].sqlserverStartTimeUtc = '2026-11-05T08:01:00.000Z'
		$snapshot.instances[0].lastFailoverUtc = '2026-10-01T00:00:00.000Z'
		$periods = Get-TestPeriods $snapshot $config
		$sales = $periods | Where-Object { $_.database -eq 'Sales' }
		$sales.uptimeDays | Should -Be 5
		$sales.isSufficient | Should -BeFalse
		($sales.warnings -join ' ') | Should -Match 'не зараховується до серії'
		$sql01 = $periods | Where-Object { $_.server -eq 'SQL01' }
		$sql01.statsFromUtc | Should -Be '2026-10-01T00:00:00.000Z'
		$sql01.lastFailoverUtc | Should -Be '2026-10-01T00:00:00.000Z'
	}

	It 'попереджає про відсутній чи обмежений Query Store' {
		$snapshot.instances[0].databases[0].queryStore = $null
		($((Get-TestPeriods $snapshot $config) | Where-Object { $_.database -eq 'Sales' }).warnings -join ' ') | Should -Match 'Query Store бази Sales не зібрано'
		$snapshot = Get-IaTestSnapshot
		$queryStore = $snapshot.instances[0].databases[0].queryStore
		$queryStore.actualState = 'READ_ONLY'
		$queryStore.periodDays = 5
		$queryStore.staleQueryThresholdDays = 7
		$warnings = ((Get-TestPeriods $snapshot $config) | Where-Object { $_.database -eq 'Sales' }).warnings -join ' '
		$warnings | Should -Match 'READ_ONLY'
		$warnings | Should -Match 'лише за 5'
		$warnings | Should -Match 'Термін зберігання'
	}
}
