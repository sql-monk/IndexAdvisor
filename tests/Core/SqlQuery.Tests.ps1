# Юніт-тести конвеєра Invoke-IaSqlQuery (CONTRACTS.md 3.1.1). Драйвер Invoke-IaDbCommand і Get-IaSecret мокаються.

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:IaModule = Get-Module IndexAdvisor

	function Invoke-IaTestQuery {
		param([hashtable]$Arguments = @{})
		if (-not $Arguments.ContainsKey('Server')) { $Arguments.Server = 'srv1' }
		if (-not $Arguments.ContainsKey('Database')) { $Arguments.Database = 'db1' }
		if (-not $Arguments.ContainsKey('Query')) { $Arguments.Query = 'SELECT o.name FROM sys.objects AS o;' }
		if (-not $Arguments.ContainsKey('Config')) { $Arguments.Config = Get-IaTestConfig }
		& $script:IaModule { param($a) Invoke-IaSqlQuery @a } $Arguments
	}
}

Describe 'Invoke-IaSqlQuery' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Get-IaSecret { 'TestPassword1!' }
		Mock -ModuleName IndexAdvisor Invoke-IaDbCommand {
			@{ columns = @(@{ name = 'name'; type = 'nvarchar' }); rows = @(, [object[]]@('a')); messages = @(); hasMoreRows = $false }
		}
	}

	Context 'Крок 1: перевірка аргументів до підключення' {
		It 'повертає <Code> для <Name>' -ForEach @(
			@{ Name = 'порожнього сервера'; Arguments = @{ Server = '' }; Code = 'ArgumentInvalid' }
			@{ Name = 'сервера $null'; Arguments = @{ Server = $null }; Code = 'ArgumentInvalid' }
			@{ Name = 'порожньої бази'; Arguments = @{ Database = ' ' }; Code = 'ArgumentInvalid' }
			@{ Name = 'порожнього запиту'; Arguments = @{ Query = '' }; Code = 'ArgumentInvalid' }
			@{ Name = 'від''ємного Fetch'; Arguments = @{ Fetch = -1 }; Code = 'ArgumentInvalid' }
			@{ Name = 'від''ємного Skip'; Arguments = @{ Skip = -5 }; Code = 'ArgumentInvalid' }
		) {
			$response = Invoke-IaTestQuery -Arguments $Arguments
			$response.success | Should -BeFalse
			$response.error.code | Should -Be $Code
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
			Should -Invoke -ModuleName IndexAdvisor Get-IaSecret -Times 0 -Exactly
		}

		It 'повертає CommandTooLong, якщо текст довший за limits.maxCommandLength' {
			$config = Get-IaTestConfig
			$config.limits.maxCommandLength = 100
			$query = 'SELECT o.name FROM sys.objects AS o WHERE o.name = N''' + ('x' * 100) + ''';'
			$response = Invoke-IaTestQuery -Arguments @{ Query = $query; Config = $config }
			$response.error.code | Should -Be 'CommandTooLong'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}

		It 'не кидає винятків навіть на внутрішній помилці' {
			Mock -ModuleName IndexAdvisor ConvertTo-IaSqlFragment { throw 'ScriptDom недоступний' }
			{ Invoke-IaTestQuery } | Should -Not -Throw
			$response = Invoke-IaTestQuery
			$response.success | Should -BeFalse
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}
	}

	Context 'Кроки 2 і 5: Fetch, ліміти, TOP і OFFSET' {
		It 'за замовчуванням Fetch = limits.defaultFetch: TOP (301) і драйвер читає не більше 301 рядка' {
			Invoke-IaTestQuery | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				$CommandText -match 'SELECT\s+TOP \(301\) o\.name' -and $MaxRows -eq 301
			}
		}

		It 'обрізає Fetch до limits.maxRows з повідомленням і попереджає про обсяг' {
			$output = Invoke-IaTestQuery -Arguments @{ Fetch = 6000; Purpose = 'Tool' } 3>&1
			$warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
			$response = $output | Where-Object { $_ -is [System.Collections.IDictionary] }
			$warnings.Count | Should -Be 1
			($response.messages -join "`n") | Should -Match 'limits\.maxRows = 5000'
			($response.messages -join "`n") | Should -Match 'largeResultWarningRows'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'TOP \(5001\)' -and $MaxRows -eq 5001 }
		}

		It 'попереджає лише понад поріг largeResultWarningRows і лише для дозапитів (<Purpose>, <Fetch> -> <Expected>)' -ForEach @(
			@{ Purpose = 'Tool'; Fetch = 1000; Expected = 0 }
			@{ Purpose = 'Tool'; Fetch = 1001; Expected = 1 }
			@{ Purpose = 'Collector'; Fetch = 5000; Expected = 0 }
		) {
			$output = Invoke-IaTestQuery -Arguments @{ Fetch = $Fetch; Purpose = $Purpose } 3>&1
			@($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be $Expected
		}

		It 'зменшує наявний TOP до ліміту' {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT TOP 100000 o.name FROM sys.objects AS o;'; Fetch = 10 } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'TOP \(11\)' -and $CommandText -notmatch '100000' }
		}

		It 'зберігає менший наявний TOP' {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT TOP (5) o.name FROM sys.objects AS o;' } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'TOP \(5\)' -and $CommandText -notmatch '301' }
		}

		It 'при Skip > 0 додає OFFSET … FETCH і ORDER BY (SELECT NULL)' {
			Invoke-IaTestQuery -Arguments @{ Fetch = 50; Skip = 20 } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				$CommandText -match 'ORDER BY \(SELECT NULL\)' -and $CommandText -match 'OFFSET 20 ROWS FETCH NEXT 51 ROWS ONLY' -and $CommandText -notmatch 'TOP' -and $MaxRows -eq 51
			}
		}

		It 'при Skip > 0 зберігає наявний ORDER BY' {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o ORDER BY o.name;'; Fetch = 10; Skip = 10 } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				$CommandText -match 'ORDER BY o\.name\s+OFFSET 10 ROWS FETCH NEXT 11 ROWS ONLY' -and $CommandText -notmatch 'SELECT NULL'
			}
		}

		It 'Skip разом із TOP — ArgumentInvalid' {
			$response = Invoke-IaTestQuery -Arguments @{ Query = 'SELECT TOP (5) o.name FROM sys.objects AS o;'; Skip = 1 }
			$response.error.code | Should -Be 'ArgumentInvalid'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}

		It 'UNION з ORDER BY обмежується через OFFSET 0 ROWS FETCH NEXT' {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT name FROM sys.objects UNION ALL SELECT name FROM sys.columns ORDER BY name;'; Fetch = 7 } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'OFFSET 0 ROWS FETCH NEXT 8 ROWS ONLY' -and $MaxRows -eq 8 }
		}

		It 'truncated = $true, якщо прочитано більше Fetch рядків; повертається рівно Fetch' {
			Mock -ModuleName IndexAdvisor Invoke-IaDbCommand {
				@{ columns = @(@{ name = 'n'; type = 'int' }); rows = @(1..4 | ForEach-Object { , [object[]]@($_) }); messages = @(); hasMoreRows = $false }
			}
			$response = Invoke-IaTestQuery -Arguments @{ Fetch = 3 }
			$response.rowCount | Should -Be 3
			@($response.rows).Count | Should -Be 3
			$response.truncated | Should -BeTrue
		}

		It 'truncated = $false, якщо рядків рівно Fetch' {
			Mock -ModuleName IndexAdvisor Invoke-IaDbCommand {
				@{ columns = @(@{ name = 'n'; type = 'int' }); rows = @(1..3 | ForEach-Object { , [object[]]@($_) }); messages = @(); hasMoreRows = $false }
			}
			$response = Invoke-IaTestQuery -Arguments @{ Fetch = 3 }
			$response.rowCount | Should -Be 3
			$response.truncated | Should -BeFalse
		}

		It 'truncated = $true, якщо драйвер повідомив hasMoreRows' {
			Mock -ModuleName IndexAdvisor Invoke-IaDbCommand {
				@{ columns = @(@{ name = 'n'; type = 'int' }); rows = @(, [object[]]@(1)); messages = @(); hasMoreRows = $true }
			}
			(Invoke-IaTestQuery -Arguments @{ Fetch = 5 }).truncated | Should -BeTrue
		}

		It 'Fetch = 0: TOP (1), жодного рядка, truncated при наявності даних' {
			$response = Invoke-IaTestQuery -Arguments @{ Fetch = 0 }
			$response.success | Should -BeTrue
			$response.rowCount | Should -Be 0
			$response.truncated | Should -BeTrue
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'TOP \(1\)' -and $MaxRows -eq 1 }
		}
	}

	Context 'Крок 6: OPTION (MAXDOP 1)' {
		It 'додає OPTION (MAXDOP 1)' {
			Invoke-IaTestQuery | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'OPTION \(MAXDOP 1\);' }
		}

		It 'зливає з наявним OPTION' {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o OPTION (RECOMPILE);' } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'OPTION \(RECOMPILE, MAXDOP 1\)' }
		}

		It 'замінює наявний MAXDOP на 1' {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o OPTION (MAXDOP 8, RECOMPILE);' } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				$CommandText -match 'OPTION \(MAXDOP 1, RECOMPILE\)' -and $CommandText -notmatch 'MAXDOP 8'
			}
		}

		It 'не додає MAXDOP при unsafe.disableMaxdop і пише про це в messages' {
			$config = Get-IaTestConfig
			$config.unsafe.disableMaxdop = $true
			$response = Invoke-IaTestQuery -Arguments @{ Config = $config }
			($response.messages -join "`n") | Should -Match 'unsafe\.disableMaxdop'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -notmatch 'MAXDOP' }
		}
	}

	Context 'Кроки 7 і 8: префікс сесії, підключення, таймаути' {
		It 'додає префікс сесії перед запитом у тому самому батчі' {
			$config = Get-IaTestConfig
			$config.connection.lockTimeoutMs = 2500
			Invoke-IaTestQuery -Arguments @{ Config = $config } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				$CommandText -match '^SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;\s+SET LOCK_TIMEOUT 2500;\s+SET DEADLOCK_PRIORITY LOW;\s+SELECT'
			}
		}

		It 'передає таймаут виконання з connection.commandTimeoutSeconds і рядок підключення без пулу' {
			$config = Get-IaTestConfig
			$config.connection.commandTimeoutSeconds = 45
			Invoke-IaTestQuery -Arguments @{ Config = $config } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				$CommandTimeoutSeconds -eq 45 -and $ConnectionString -match 'Pooling=False' -and $ConnectionString -notmatch 'ApplicationIntent'
			}
		}

		It 'unsafe.disableTimeouts вимикає лише таймаут команди; LOCK_TIMEOUT лишається' {
			$config = Get-IaTestConfig
			$config.unsafe.disableTimeouts = $true
			$response = Invoke-IaTestQuery -Arguments @{ Config = $config }
			($response.messages -join "`n") | Should -Match 'unsafe\.disableTimeouts'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				$CommandTimeoutSeconds -eq 0 -and $CommandText -match 'SET LOCK_TIMEOUT 1000;' -and $ConnectionString -match 'Connect Timeout=15'
			}
		}

		It 'передає ApplicationIntent лише якщо його задано' {
			Invoke-IaTestQuery -Arguments @{ ApplicationIntent = 'ReadOnly' } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $ConnectionString -match 'ApplicationIntent=ReadOnly' }
		}

		It 'відмовляє з LoginRefused для нештатного логіна без прапорця' {
			$config = Get-IaTestConfig
			$config.connection.login = 'sa'
			$response = Invoke-IaTestQuery -Arguments @{ Config = $config }
			$response.error.code | Should -Be 'LoginRefused'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
			Should -Invoke -ModuleName IndexAdvisor Get-IaSecret -Times 0 -Exactly
		}

		It 'виконує запит під нештатним логіном при unsafe.allowNonStandardLogin' {
			$config = Get-IaTestConfig
			$config.connection.login = 'sa'
			$config.unsafe.allowNonStandardLogin = $true
			(Invoke-IaTestQuery -Arguments @{ Config = $config }).success | Should -BeTrue
		}

		It 'відсутній секрет — ConnectionFailed без виклику драйвера' {
			Mock -ModuleName IndexAdvisor Get-IaSecret { Write-Error -ErrorId 'IaSecretNotFound' -Message 'Секрет не знайдено' -ErrorAction Stop }
			$response = Invoke-IaTestQuery
			$response.error.code | Should -Be 'ConnectionFailed'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}
	}

	Context 'Крок 4: іменовані параметри' {
		It 'приймає ключ з @ і без @ та передає значення окремим параметром (<Key>)' -ForEach @(@{ Key = 'Name' }, @{ Key = '@Name' }) {
			$response = Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o WHERE o.name = @Name;'; Parameters = @{ $Key = 'Orders' } }
			$response.success | Should -BeTrue
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter {
				@($Parameters).Count -eq 1 -and $Parameters[0].name -eq '@Name' -and $Parameters[0].value -eq 'Orders' -and $Parameters[0].sqlType -eq 'NVarChar' -and
				$CommandText -match '@Name' -and $CommandText -notmatch 'Orders'
			}
		}

		It 'визначає SqlDbType за типом значення (<Type>)' -ForEach @(
			@{ Type = 'Int'; Value = 5 }
			@{ Type = 'BigInt'; Value = [long]5 }
			@{ Type = 'Bit'; Value = $true }
			@{ Type = 'Decimal'; Value = [decimal]1.5 }
			@{ Type = 'DateTime2'; Value = [datetime]::new(2026, 1, 1) }
			@{ Type = 'UniqueIdentifier'; Value = [guid]::Empty }
			@{ Type = 'NVarChar'; Value = $null }
		) {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o WHERE o.object_id = @Id;'; Parameters = @{ Id = $Value } } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $Parameters[0].sqlType -eq $Type }
		}

		It 'використовує написання імені з тексту запиту (без урахування регістру ключа)' {
			Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o WHERE o.name = @ObjName;'; Parameters = @{ objname = 'x' } } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $Parameters[0].name -eq '@ObjName' }
		}

		It 'невідомий параметр — UnknownParameter' {
			$response = Invoke-IaTestQuery -Arguments @{ Parameters = @{ Extra = 1 } }
			$response.error.code | Should -Be 'UnknownParameter'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}

		It 'змінна без значення — MissingParameter' {
			$response = Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o WHERE o.name = @Name AND o.type = @Type;'; Parameters = @{ Name = 'x' } }
			$response.error.code | Should -Be 'MissingParameter'
			$response.error.message | Should -Match '@Type'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}

		It 'не вважає параметрами @@-функції, @ у рядках і коментарях' {
			$query = "SELECT @@SERVERNAME AS s, N'@NotParam' AS t FROM sys.objects AS o; -- @AlsoNot"
			(Invoke-IaTestQuery -Arguments @{ Query = $query }).success | Should -BeTrue
		}

		It 'відхиляє нескалярне значення параметра' {
			$response = Invoke-IaTestQuery -Arguments @{ Query = 'SELECT o.name FROM sys.objects AS o WHERE o.name = @Name;'; Parameters = @{ Name = @{ a = 1 } } }
			$response.error.code | Should -Be 'ArgumentInvalid'
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 0 -Exactly
		}
	}

	Context 'Крок 9: нормалізація і конверт' {
		It 'повертає конверт з усіма полями контракту' {
			$response = Invoke-IaTestQuery
			@($response.Keys) | Should -Be @('success', 'requestId', 'server', 'database', 'durationMs', 'rowCount', 'truncated', 'columns', 'rows', 'messages', 'error')
			$response.success | Should -BeTrue
			$response.server | Should -Be 'srv1'
			$response.database | Should -Be 'db1'
			$response.requestId | Should -Match '^[0-9a-f-]{36}$'
			$response.error | Should -BeNullOrEmpty
			$response.columns[0].name | Should -Be 'name'
			$response.columns[0].type | Should -Be 'nvarchar'
			$response.rows[0]['name'] | Should -Be 'a'
		}

		It 'нормалізує значення для JSON і перейменовує дублікати колонок' {
			Mock -ModuleName IndexAdvisor Invoke-IaDbCommand {
				@{
					columns = @(
						@{ name = 'v'; type = 'decimal' }, @{ name = 'v'; type = 'datetime2' }, @{ name = 'v'; type = 'uniqueidentifier' },
						@{ name = ''; type = 'varbinary' }, @{ name = 'n'; type = 'int' }, @{ name = 'z'; type = 'nvarchar' }
					)
					rows = @(, [object[]]@([decimal]::Parse('12.50', [cultureinfo]::InvariantCulture), [datetime]::new(2026, 3, 4, 5, 6, 7, 890), [guid]'11111111-2222-3333-4444-555555555555', [byte[]](1, 2, 3), 42, [System.DBNull]::Value))
					messages = @('Повідомлення сервера')
					hasMoreRows = $false
				}
			}
			$response = Invoke-IaTestQuery
			@($response.columns | ForEach-Object { $_.name }) | Should -Be @('v', 'v_2', 'v_3', 'column4', 'n', 'z')
			$row = $response.rows[0]
			$row['v'] | Should -BeOfType [string]
			$row['v'] | Should -Be '12.50'
			$row['v_2'] | Should -Be '2026-03-04T05:06:07.890Z'
			$row['v_3'] | Should -Be '11111111-2222-3333-4444-555555555555'
			$row['column4'] | Should -Be 'AQID'
			$row['n'] | Should -Be 42
			$row['z'] | Should -BeNullOrEmpty
			$response.messages | Should -Contain 'Повідомлення сервера'
			{ ConvertTo-Json -InputObject $response -Depth 10 } | Should -Not -Throw
		}
	}

	Context 'Помилки драйвера' {
		It 'перетворює помилку з ErrorId <Code> у конверт' -ForEach @(@{ Code = 'Timeout' }, @{ Code = 'ConnectionFailed' }, @{ Code = 'SqlError' }) {
			Mock -ModuleName IndexAdvisor Invoke-IaDbCommand { Write-Error -ErrorId $Code -Message "Помилка $Code" -ErrorAction Stop }
			$response = Invoke-IaTestQuery
			$response.success | Should -BeFalse
			$response.error.code | Should -Be $Code
			$response.error.message | Should -Match "Помилка $Code"
		}

		It 'TimeoutException у ланцюжку винятків — код Timeout' {
			Mock -ModuleName IndexAdvisor Invoke-IaDbCommand { throw [System.InvalidOperationException]::new('обгортка', [System.TimeoutException]::new('таймаут')) }
			(Invoke-IaTestQuery).error.code | Should -Be 'Timeout'
		}

		It 'довільна помилка — SqlError без винятку' {
			Mock -ModuleName IndexAdvisor Invoke-IaDbCommand { throw 'Invalid object name' }
			{ Invoke-IaTestQuery } | Should -Not -Throw
			(Invoke-IaTestQuery).error.code | Should -Be 'SqlError'
		}
	}

	Context 'Крок 10: журнал' {
		BeforeEach {
			$script:IaTestConfig = Get-IaTestConfig
			$script:IaTestSession = & $script:IaModule { param($c) Start-IaSession -Config $c -Command 'Pester' } $script:IaTestConfig
		}
		AfterEach {
			& $script:IaModule { Stop-IaSession }
		}

		It 'записує виклик з полями, маскуванням параметрів і повним текстом' {
			$response = Invoke-IaTestQuery -Arguments @{
				Query = 'SELECT o.name FROM sys.objects AS o WHERE o.name = @ApiToken AND o.type = @Kind;'
				Parameters = @{ ApiToken = 'SuperSecretValue'; Kind = 'U' }
				Purpose = 'Tool'
				Config = $script:IaTestConfig
			}
			$log = Get-Content -LiteralPath $script:IaTestSession.logPath -Raw -Encoding utf8
			$log | Should -Match ([regex]::Escape("### $($response.requestId)"))
			$log | Should -Match 'Purpose: Tool'
			$log | Should -Match 'Fetch: 300'
			$log | Should -Match 'Skip: 0'
			$log | Should -Match 'Кількість рядків: 1'
			$log | Should -Match 'Успіх: true'
			$log | Should -Match '@ApiToken \(NVarChar\) = \*\*\*'
			$log | Should -Match '@Kind \(NVarChar\) = U'
			$log | Should -Not -Match 'SuperSecretValue'
			$log | Should -Match 'SET LOCK_TIMEOUT 1000;'
			$log | Should -Match 'OPTION \(MAXDOP 1\)'
			$log | Should -Not -Match 'TestPassword1!'
		}

		It 'записує заблокований виклик з помилкою' {
			$response = Invoke-IaTestQuery -Arguments @{ Query = 'DROP TABLE dbo.Orders;'; Config = $script:IaTestConfig }
			$log = Get-Content -LiteralPath $script:IaTestSession.logPath -Raw -Encoding utf8
			$log | Should -Match ([regex]::Escape("### $($response.requestId)"))
			$log | Should -Match 'Успіх: false'
			$log | Should -Match 'NotSingleSelect'
			$log | Should -Match 'DROP TABLE dbo\.Orders;'
		}

		It 'бере конфігурацію з поточної сесії, якщо -Config не передано' {
			$config = Get-IaTestConfig
			$config.connection.lockTimeoutMs = 777
			& $script:IaModule { param($c) Start-IaSession -Config $c } $config | Out-Null
			& $script:IaModule { Invoke-IaSqlQuery -Server 'srv1' -Database 'db1' -Query 'SELECT o.name FROM sys.objects AS o;' } | Out-Null
			Should -Invoke -ModuleName IndexAdvisor Invoke-IaDbCommand -Times 1 -Exactly -ParameterFilter { $CommandText -match 'SET LOCK_TIMEOUT 777;' }
		}
	}
}
