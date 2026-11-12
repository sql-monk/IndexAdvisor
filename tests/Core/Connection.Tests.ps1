# Юніт-тести рядка підключення, політики штатного логіна і перевірки фактичних прав (потік Core, CONTRACTS.md 3.1.2).

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:IaModule = Get-Module IndexAdvisor

	function ConvertFrom-IaTestConnectionString {
		param([string]$ConnectionString)
		# DbConnectionStringBuilder у PowerShell — словник: властивості читаються й задаються лише через методи get_/set_.
		$builder = [System.Data.Common.DbConnectionStringBuilder]::new()
		$builder.set_ConnectionString($ConnectionString)
		$result = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($key in $builder.get_Keys()) {
			$result[$key] = [string]$builder.get_Item($key)
		}
		return $result
	}
}

Describe 'New-IaConnectionString' {
	BeforeEach {
		Mock -ModuleName IndexAdvisor Get-IaSecret { 'P@ss;word"1' }
	}

	It 'SQL-автентифікація: пароль лише через Get-IaSecret з connection.passwordRef і всі параметри' {
		$config = Get-IaTestConfig
		$text = & $script:IaModule { param($c) New-IaConnectionString -Server 'srv1,1433' -Database 'Sales' -Config $c } $config
		$builder = ConvertFrom-IaTestConnectionString -ConnectionString $text
		$builder['Data Source'] | Should -Be 'srv1,1433'
		$builder['Initial Catalog'] | Should -Be 'Sales'
		$builder['User ID'] | Should -Be 'index-advisor'
		$builder['Password'] | Should -Be 'P@ss;word"1'
		$builder['Encrypt'] | Should -Be 'Mandatory'
		$builder['TrustServerCertificate'] | Should -Be 'False'
		$builder['Application Name'] | Should -Be 'IndexAdvisor'
		$builder['Connect Timeout'] | Should -Be '15'
		$builder['Pooling'] | Should -Be 'False'
		$builder.ContainsKey('ApplicationIntent') | Should -BeFalse
		$builder.ContainsKey('Integrated Security') | Should -BeFalse
		Should -Invoke -ModuleName IndexAdvisor Get-IaSecret -Times 1 -Exactly -ParameterFilter { $Reference -eq 'secret:IndexAdvisor-index-advisor' -and $AsPlainText }
	}

	It 'додає ApplicationIntent=ReadOnly лише якщо його передано і враховує налаштування Encrypt/TrustServerCertificate' {
		$config = Get-IaTestConfig
		$config.connection.encrypt = 'Strict'
		$config.connection.trustServerCertificate = $true
		$text = & $script:IaModule { param($c) New-IaConnectionString -Server 'srv2' -Database 'db' -Config $c -ApplicationIntent ReadOnly } $config
		$builder = ConvertFrom-IaTestConnectionString -ConnectionString $text
		$builder['ApplicationIntent'] | Should -Be 'ReadOnly'
		$builder['Encrypt'] | Should -Be 'Strict'
		$builder['TrustServerCertificate'] | Should -Be 'True'
	}

	It 'Windows-автентифікація: Integrated Security без пароля і без звернення до сховища' {
		$config = Get-IaTestConfig
		$config.connection.authentication = 'Windows'
		$text = & $script:IaModule { param($c) New-IaConnectionString -Server 'srv1' -Database 'db' -Config $c } $config
		$builder = ConvertFrom-IaTestConnectionString -ConnectionString $text
		$builder['Integrated Security'] | Should -Be 'True'
		$builder.ContainsKey('Password') | Should -BeFalse
		$builder.ContainsKey('User ID') | Should -BeFalse
		Should -Invoke -ModuleName IndexAdvisor Get-IaSecret -Times 0 -Exactly
	}

	It 'перетворює SecureString від сховища на рядок' {
		Mock -ModuleName IndexAdvisor Get-IaSecret { ConvertTo-SecureString -String 'FromVault1!' -AsPlainText -Force }
		$text = & $script:IaModule { param($c) New-IaConnectionString -Server 'srv1' -Database 'db' -Config $c } (Get-IaTestConfig)
		(ConvertFrom-IaTestConnectionString -ConnectionString $text)['Password'] | Should -Be 'FromVault1!'
	}

	It 'без connection.passwordRef — виняток IaConfigInvalid' {
		$config = Get-IaTestConfig
		$config.connection.passwordRef = ''
		$caught = $null
		try {
			& $script:IaModule { param($c) New-IaConnectionString -Server 'srv1' -Database 'db' -Config $c } $config
		}
		catch {
			$caught = $_
		}
		$caught | Should -Not -BeNullOrEmpty
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaConfigInvalid*'
	}
}

Describe 'Assert-IaStandardLogin' {
	It 'штатний SQL-логін проходить (без урахування регістру)' {
		$config = Get-IaTestConfig
		$config.connection.login = 'Index-Advisor'
		$result = & $script:IaModule { param($c) Assert-IaStandardLogin -Config $c } $config
		$result.isStandard | Should -BeTrue
		$result.login | Should -Be 'Index-Advisor'
		$result.authentication | Should -Be 'Sql'
		@($result.warnings).Count | Should -Be 0
	}

	It 'нештатний логін без прапорця — виняток IaLoginRefused з поясненням' {
		$config = Get-IaTestConfig
		$config.connection.login = 'sa'
		$caught = $null
		try {
			& $script:IaModule { param($c) Assert-IaStandardLogin -Config $c } $config
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'IaLoginRefused*'
		$caught.Exception.Message | Should -Match 'sa'
		$caught.Exception.Message | Should -Match 'allowNonStandardLogin'
	}

	It 'поточний обліковий запис Windows, що не є штатним, відхиляється' {
		$config = Get-IaTestConfig
		$config.connection.authentication = 'Windows'
		{ & $script:IaModule { param($c) Assert-IaStandardLogin -Config $c } $config } | Should -Throw -ErrorId 'IaLoginRefused*'
	}

	It 'Windows-автентифікація під штатним DOMAIN\user проходить' {
		$config = Get-IaTestConfig
		$config.connection.authentication = 'Windows'
		$config.security.standardLogin = [System.Environment]::UserDomainName + '\' + [System.Environment]::UserName
		$result = & $script:IaModule { param($c) Assert-IaStandardLogin -Config $c } $config
		$result.isStandard | Should -BeTrue
		$result.login | Should -Be $config.security.standardLogin
	}

	It 'з unsafe.allowNonStandardLogin повертає isStandard = $false і попередження в журнал (Security)' {
		$config = Get-IaTestConfig
		$config.connection.login = 'sa'
		$config.unsafe.allowNonStandardLogin = $true
		$session = & $script:IaModule { param($c) Start-IaSession -Config $c } $config
		try {
			$result = & $script:IaModule { param($c) Assert-IaStandardLogin -Config $c } $config
		}
		finally {
			& $script:IaModule { Stop-IaSession }
		}
		$result.isStandard | Should -BeFalse
		@($result.warnings).Count | Should -Be 1
		Get-Content -LiteralPath $session.logPath -Raw -Encoding utf8 | Should -Match '· Security\*\*'
	}
}

Describe 'Get-IaLoginPermissions' {
	BeforeAll {
		$script:IaPermissionMock = {
			$rows = switch -Regex ($Query) {
				'SUSER_SNAME' { @([ordered]@{ loginName = 'CONTOSO\dba'; userName = 'dbo' }) }
				'IS_SRVROLEMEMBER' {
					@(
						[ordered]@{ scope = 'DATABASE'; roleName = 'db_datareader' }
						[ordered]@{ scope = 'DATABASE'; roleName = 'db_index_advisor' }
						[ordered]@{ scope = 'SERVER'; roleName = 'public' }
						[ordered]@{ scope = 'SERVER'; roleName = 'sysadmin' }
					)
				}
				'fn_my_permissions' {
					@(
						[ordered]@{ scope = 'DATABASE'; permissionName = 'CONNECT' }
						[ordered]@{ scope = 'DATABASE'; permissionName = 'INSERT' }
						[ordered]@{ scope = 'DATABASE'; permissionName = 'VIEW DATABASE STATE' }
						[ordered]@{ scope = 'SERVER'; permissionName = 'ALTER ANY LOGIN' }
						[ordered]@{ scope = 'SERVER'; permissionName = 'CONNECT SQL' }
						[ordered]@{ scope = 'SERVER'; permissionName = 'VIEW SERVER STATE' }
					)
				}
				'database_permissions' {
					@([ordered]@{ classDesc = 'OBJECT_OR_COLUMN'; permissionName = 'SELECT'; stateDesc = 'GRANT'; grantee = 'public'; objectName = 'dbo.Orders' })
				}
			}
			@{ success = $true; rows = @($rows); rowCount = @($rows).Count; truncated = $false; error = $null; messages = @() }
		}
	}

	It 'знаходить зайві права: sysadmin, db_datareader, права на зміну і доступ до даних' {
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery $script:IaPermissionMock
		$result = & $script:IaModule { param($c) Get-IaLoginPermissions -Server 'srv1' -Database 'Sales' -Config $c } (Get-IaTestConfig)
		$result.server | Should -Be 'srv1'
		$result.database | Should -Be 'Sales'
		$result.login | Should -Be 'CONTOSO\dba'
		$result.isSysadmin | Should -BeTrue
		$result.serverRoles | Should -Contain 'sysadmin'
		$result.databaseRoles | Should -Contain 'db_datareader'
		$permissions = @($result.excessive | ForEach-Object { $_.permission })
		$permissions | Should -Contain 'sysadmin'
		$permissions | Should -Contain 'db_datareader'
		$permissions | Should -Contain 'INSERT'
		$permissions | Should -Contain 'ALTER ANY LOGIN'
		$permissions | Should -Contain 'SELECT'
		$permissions | Should -Not -Contain 'public'
		$permissions | Should -Not -Contain 'db_index_advisor'
		$permissions | Should -Not -Contain 'VIEW SERVER STATE'
		$permissions | Should -Not -Contain 'CONNECT'
		$result.warnings[0] | Should -Match 'зайві права'
		Should -Invoke -ModuleName IndexAdvisor Invoke-IaSqlQuery -Times 4 -Exactly -ParameterFilter { $Purpose -eq 'PermissionCheck' -and $Server -eq 'srv1' -and $Database -eq 'Sales' }
	}

	It 'мінімальні права штатного логіна не вважаються зайвими' {
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery {
			$rows = switch -Regex ($Query) {
				'IS_SRVROLEMEMBER' { @([ordered]@{ scope = 'SERVER'; roleName = 'srv_index_advisor' }, [ordered]@{ scope = 'DATABASE'; roleName = 'db_index_advisor' }) }
				'fn_my_permissions' {
					@(
						[ordered]@{ scope = 'SERVER'; permissionName = 'VIEW ANY DEFINITION' }
						[ordered]@{ scope = 'DATABASE'; permissionName = 'VIEW DEFINITION' }
					)
				}
				default { @() }
			}
			@{ success = $true; rows = @($rows); rowCount = @($rows).Count; truncated = $false; error = $null; messages = @() }
		}
		$result = & $script:IaModule { param($c) Get-IaLoginPermissions -Server 'srv1' -Database 'Sales' -Config $c } (Get-IaTestConfig)
		@($result.excessive).Count | Should -Be 0
		$result.isSysadmin | Should -BeFalse
		@($result.warnings).Count | Should -Be 0
	}

	It 'помилка запиту перетворюється на попередження без винятку' {
		Mock -ModuleName IndexAdvisor Invoke-IaSqlQuery { @{ success = $false; rows = @(); error = @{ code = 'SqlError'; message = 'Немає доступу' }; messages = @() } }
		$result = & $script:IaModule { param($c) Get-IaLoginPermissions -Server 'srv1' -Database 'Sales' -Config $c } (Get-IaTestConfig)
		@($result.warnings).Count | Should -Be 4
		$result.warnings[0] | Should -Match 'Немає доступу'
	}

	It 'запити перевірки прав — одна інструкція SELECT лише з системних джерел' -ForEach @(
		@{ Variable = 'IaCoreLoginQuery' }, @{ Variable = 'IaCoreRoleQuery' }, @{ Variable = 'IaCorePermissionQuery' }, @{ Variable = 'IaCoreObjectGrantQuery' }
	) {
		$query = & $script:IaModule { param($v) Get-Variable -Name $v -Scope Script -ValueOnly } $Variable
		(& $script:IaModule { param($q) Test-IaSelectOnly -Sql $q } $query).isValid | Should -BeTrue
		(& $script:IaModule { param($q) Test-IaSystemSourcesOnly -Sql $q } $query).isValid | Should -BeTrue
	}
}
