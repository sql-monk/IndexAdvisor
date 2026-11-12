# Юніт-тести сесії, Markdown-журналу, маскування, unsafe-прапорців і нормалізації значень (потік Core).

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:IaModule = Get-Module IndexAdvisor
}

Describe 'Start-IaSession, Get-IaSession, Stop-IaSession' {
	AfterEach {
		& $script:IaModule { Stop-IaSession }
	}

	It 'створює сесію і файл журналу logging.path/IndexAdvisor_<дата>_<id8>.md із заголовком' {
		$config = Get-IaTestConfig
		$session = & $script:IaModule { param($c) Start-IaSession -Config $c -Command 'Invoke-IndexAdvisor -Server srv1' } $config
		@($session.Keys) | Should -Be @('sessionId', 'startedAtUtc', 'logPath', 'config', 'unsafeFlags', 'command')
		$session.command | Should -Be 'Invoke-IndexAdvisor -Server srv1'
		Split-Path -Path $session.logPath -Parent | Should -Be $config.logging.path
		Split-Path -Path $session.logPath -Leaf | Should -Match ('^IndexAdvisor_\d{8}_\d{6}_' + $session.sessionId.Substring(0, 8) + '\.md$')
		Test-Path -LiteralPath $session.logPath | Should -BeTrue
		$log = Get-Content -LiteralPath $session.logPath -Raw -Encoding utf8
		$log | Should -Match ([regex]::Escape($session.sessionId))
		$log | Should -Match ([regex]::Escape([System.Environment]::UserName))
		$log | Should -Match ([regex]::Escape([System.Environment]::MachineName))
		$log | Should -Match 'Invoke-IndexAdvisor -Server srv1'
		$log | Should -Match 'Небезпечні режими: немає'
		$log | Should -Match '"passwordRef": "\*\*\*"'
		(& $script:IaModule { Get-IaSession }).sessionId | Should -Be $session.sessionId
	}

	It 'записує активні небезпечні прапорці з попередженням' {
		$config = Get-IaTestConfig
		$config.unsafe.disableMaxdop = $true
		$config.unsafe.allowFreeQuery = $true
		$session = & $script:IaModule { param($c) Start-IaSession -Config $c } $config
		@($session.unsafeFlags) | Should -Be @('disableMaxdop', 'allowFreeQuery')
		$log = Get-Content -LiteralPath $session.logPath -Raw -Encoding utf8
		$log | Should -Match 'Небезпечні режими: disableMaxdop, allowFreeQuery'
		$log | Should -Match '· Warning\*\* — Активні небезпечні режими'
	}

	It 'Stop-IaSession дописує підсумок і скидає сесію; повторний виклик безпечний' {
		$session = & $script:IaModule { param($c) Start-IaSession -Config $c } (Get-IaTestConfig)
		& $script:IaModule { Stop-IaSession }
		(& $script:IaModule { Get-IaSession }) | Should -BeNullOrEmpty
		Get-Content -LiteralPath $session.logPath -Raw -Encoding utf8 | Should -Match '## Завершення сесії'
		{ & $script:IaModule { Stop-IaSession } } | Should -Not -Throw
	}

	It 'новий Start-IaSession завершує попередню сесію' {
		$first = & $script:IaModule { param($c) Start-IaSession -Config $c } (Get-IaTestConfig)
		$second = & $script:IaModule { param($c) Start-IaSession -Config $c } (Get-IaTestConfig)
		$second.sessionId | Should -Not -Be $first.sessionId
		Get-Content -LiteralPath $first.logPath -Raw -Encoding utf8 | Should -Match '## Завершення сесії'
	}
}

Describe 'Write-IaLog' {
	AfterEach {
		& $script:IaModule { Stop-IaSession }
	}

	It 'пише повідомлення з рівнем і маскує чутливі дані' {
		$session = & $script:IaModule { param($c) Start-IaSession -Config $c } (Get-IaTestConfig)
		& $script:IaModule {
			Write-IaLog -Level Security -Message 'Перевірка Password=Abc123;Server=x' -Data ([ordered]@{ login = 'user1'; apiKey = 'k-123'; nested = @{ client_secret = 's-456'; count = 2 } })
		}
		$log = Get-Content -LiteralPath $session.logPath -Raw -Encoding utf8
		$log | Should -Match '· Security\*\* — Перевірка Password=\*\*\*;Server=x'
		$log | Should -Match '- login: user1'
		$log | Should -Match '- apiKey: \*\*\*'
		$log | Should -Not -Match 'k-123|s-456|Abc123'
	}

	It 'без сесії нічого не пише і не кидає винятків' {
		{ & $script:IaModule { Write-IaLog -Message 'без сесії' -Level Warning } } | Should -Not -Throw
	}
}

Describe 'Protect-IaLogValue' {
	It 'маскує значення для імені <Name>' -ForEach @(
		@{ Name = 'password' }, @{ Name = 'Pwd' }, @{ Name = 'client_secret' }, @{ Name = 'AccessToken' },
		@{ Name = 'api_key' }, @{ Name = 'ApiKey' }, @{ Name = 'connection_string' }, @{ Name = 'ConnectionString' }
	) {
		& $script:IaModule { param($n) Protect-IaLogValue -Name $n -Value 'value-123' } $Name | Should -Be '***'
	}

	It 'не змінює значення з нейтральним ім''ям' {
		& $script:IaModule { Protect-IaLogValue -Name 'TableName' -Value 'Orders' } | Should -Be 'Orders'
		& $script:IaModule { Protect-IaLogValue -Name 'Count' -Value 5 } | Should -Be 5
	}

	It 'повертає $null для $null' {
		& $script:IaModule { Protect-IaLogValue -Name 'password' -Value $null } | Should -BeNullOrEmpty
	}

	It 'маскує пароль у тексті рядка підключення незалежно від імені' {
		& $script:IaModule { Protect-IaLogValue -Name 'text' -Value 'Data Source=x;User ID=u;Password=Abc;Pwd=Def' } |
			Should -Be 'Data Source=x;User ID=u;Password=***;Pwd=***'
	}
}

Describe 'Get-IaUnsafeFlags' {
	It 'повертає порожній перелік за замовчуванням' {
		@(& $script:IaModule { param($c) Get-IaUnsafeFlags -Config $c } (Get-IaTestConfig)).Count | Should -Be 0
	}

	It 'повертає імена активних прапорців' {
		$config = Get-IaTestConfig
		$config.unsafe.disableSelectCheck = $true
		$config.unsafe.disableTimeouts = $true
		@(& $script:IaModule { param($c) Get-IaUnsafeFlags -Config $c } $config) | Should -Be @('disableSelectCheck', 'disableTimeouts')
	}
}

Describe 'ConvertTo-IaJsonValue' {
	It 'перетворює <Name>' -ForEach @(
		@{ Name = 'decimal у рядок InvariantCulture'; Value = [decimal]1234.5; Expected = '1234.5' }
		@{ Name = 'дату без зони як UTC'; Value = [datetime]::new(2026, 1, 2, 3, 4, 5, 6); Expected = '2026-01-02T03:04:05.006Z' }
		@{ Name = 'DateTimeOffset у UTC'; Value = [System.DateTimeOffset]::new(2026, 1, 2, 3, 4, 5, [timespan]::FromHours(2)); Expected = '2026-01-02T01:04:05.000Z' }
		@{ Name = 'guid у рядок'; Value = [guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; Expected = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
		@{ Name = 'byte[] у base64'; Value = [byte[]](0, 255); Expected = 'AP8=' }
		@{ Name = 'TimeSpan у рядок'; Value = [timespan]::new(1, 2, 3); Expected = '01:02:03' }
		@{ Name = 'рядок без змін'; Value = 'abc'; Expected = 'abc' }
	) {
		& $script:IaModule { param($v) ConvertTo-IaJsonValue -Value $v } $Value | Should -Be $Expected
	}

	It 'decimal не залежить від культури потоку' {
		$culture = [cultureinfo]::CurrentCulture
		try {
			[cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('uk-UA')
			& $script:IaModule { ConvertTo-IaJsonValue -Value ([decimal]0.25) } | Should -Be '0.25'
		}
		finally {
			[cultureinfo]::CurrentCulture = $culture
		}
	}

	It 'DBNull і $null -> $null; числа й bool без змін' {
		& $script:IaModule { ConvertTo-IaJsonValue -Value ([System.DBNull]::Value) } | Should -BeNullOrEmpty
		& $script:IaModule { ConvertTo-IaJsonValue -Value $null } | Should -BeNullOrEmpty
		& $script:IaModule { ConvertTo-IaJsonValue -Value 42 } | Should -BeOfType [int]
		& $script:IaModule { ConvertTo-IaJsonValue -Value ([long]42) } | Should -BeOfType [long]
		& $script:IaModule { ConvertTo-IaJsonValue -Value $true } | Should -BeTrue
	}
}
