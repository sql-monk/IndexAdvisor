# Тести обгортки скрипта штатного логіна (CONTRACTS.md, розділ 10) з моками dbatools і SecretManagement.
BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')

	# Замінник команди dbatools, щоб Pester міг її замокати без імпорту dbatools.
	function global:Invoke-DbaQuery {
		param($SqlInstance, $SqlCredential, $Database, $Query, $SqlParameter, $As, [switch]$MessagesToOutput, [switch]$EnableException)
	}
}

AfterAll {
	Remove-Item -Path 'function:global:Invoke-DbaQuery' -ErrorAction SilentlyContinue
}

Describe 'Install-IaServiceLogin' {
	BeforeEach {
		$script:SavedPassword = $null
		$script:Queries = [System.Collections.Generic.List[object]]::new()
		Mock -ModuleName IndexAdvisor Import-IaCliDbatools { }
		Mock -ModuleName IndexAdvisor Get-Secret { throw 'Секрет не знайдено' }
		Mock -ModuleName IndexAdvisor Set-Secret { $script:SavedPassword = ConvertFrom-SecureString -SecureString $Secret -AsPlainText }
		Mock -ModuleName IndexAdvisor Invoke-DbaQuery {
			$script:Queries.Add([ordered]@{ instance = $SqlInstance; database = $Database; query = $Query; parameters = $SqlParameter; credential = $SqlCredential })
			'Створено логін index-advisor.'
		}
	}

	It 'Install SQL-логіна: пароль генерується, одразу зберігається Set-Secret і передається лише параметром' {
		$output = Install-IaServiceLogin -SqlInstance 'SQL01', 'SQL02' -Mode Install -Verbose *>&1
		Should -Invoke -ModuleName IndexAdvisor Set-Secret -Times 1 -Exactly -ParameterFilter { $Name -eq 'IndexAdvisor-index-advisor' -and $Secret -is [securestring] }
		Should -Invoke -ModuleName IndexAdvisor Invoke-DbaQuery -Times 2 -Exactly
		$script:SavedPassword | Should -Not -BeNullOrEmpty
		$script:SavedPassword.Length | Should -Be 32
		foreach ($call in $script:Queries) {
			$call.database | Should -Be 'master'
			$call.parameters.IaLoginPassword | Should -BeExactly $script:SavedPassword
			$call.query | Should -Not -Match ([regex]::Escape($script:SavedPassword))
			$call.query | Should -Match 'DECLARE @loginPassword NVARCHAR\(128\) = @IaLoginPassword;'
			$call.query | Should -Match "DECLARE @mode NVARCHAR\(20\) = N'Install';"
			$call.query | Should -Match "DECLARE @loginType NVARCHAR\(20\) = N'Sql';"
			$call.query | Should -Match "DECLARE @databases NVARCHAR\(MAX\) = N'ALL';"
			$call.query | Should -Not -Match '\$\('
		}
		@($script:Queries | ForEach-Object { $_.instance }) | Should -Be @('SQL01', 'SQL02')
		$text = ($output | Out-String)
		$text | Should -Not -Match ([regex]::Escape($script:SavedPassword))
		$results = @($output | Where-Object { $_.PSObject.Properties['SqlInstance'] })
		$results.Count | Should -Be 2
		$results[0].Success | Should -BeTrue
		$results[0].Message | Should -Match "secret:IndexAdvisor-index-advisor"
	}

	It 'наявний секрет використовується повторно, Set-Secret не викликається' {
		Mock -ModuleName IndexAdvisor Get-Secret { ConvertTo-SecureString -String 'Existing#Passw0rd!Value' -AsPlainText -Force }
		Install-IaServiceLogin -SqlInstance 'SQL03' -Mode Install -Vault 'Corp' | Out-Null
		Should -Invoke -ModuleName IndexAdvisor Set-Secret -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Get-Secret -Times 1 -Exactly -ParameterFilter { $Vault -eq 'Corp' -and $Name -eq 'IndexAdvisor-index-advisor' }
		$script:Queries[0].parameters.IaLoginPassword | Should -BeExactly 'Existing#Passw0rd!Value'
	}

	It 'Windows-логін: без пароля й без сховища, права так само через ролі' {
		$result = Install-IaServiceLogin -SqlInstance 'SQL01' -Mode Install -WindowsLogin -LoginName 'CONTOSO\index-advisor' -Database 'Sales', 'Dwh'
		Should -Invoke -ModuleName IndexAdvisor Set-Secret -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Get-Secret -Times 0 -Exactly
		$script:Queries[0].query | Should -Match "N'Windows'"
		$script:Queries[0].query | Should -Match "N'CONTOSO\\index-advisor'"
		$script:Queries[0].query | Should -Match "N'Sales,Dwh'"
		$script:Queries[0].parameters.IaLoginPassword | Should -Be ''
		$result.Success | Should -BeTrue
		{ Install-IaServiceLogin -SqlInstance 'SQL01' -WindowsLogin -LoginName 'nodomain' } | Should -Throw
	}

	It 'значення sqlcmd-змінних екрануються' {
		Install-IaServiceLogin -SqlInstance 'SQL01' -Mode AddDatabase -LoginName "j-o'brien" -Database "Sales'; DROP DATABASE x; --" | Out-Null
		$query = $script:Queries[0].query
		$query | Should -Match "DECLARE @loginName NVARCHAR\(128\) = N'j-o''brien';"
		$query | Should -Match "N'Sales''; DROP DATABASE x; --'"
		Should -Invoke -ModuleName IndexAdvisor Set-Secret -Times 0 -Exactly
	}

	It 'недопустимі імена баз і логіна відхиляються до підключення' {
		{ Install-IaServiceLogin -SqlInstance 'SQL01' -Mode AddDatabase -Database "a,b" } | Should -Throw
		{ Install-IaServiceLogin -SqlInstance 'SQL01' -Mode AddDatabase -LoginName "bad`nname" } | Should -Throw
		Should -Invoke -ModuleName IndexAdvisor Invoke-DbaQuery -Times 0 -Exactly
	}

	It '-WhatIf: нічого не зберігає й не виконує' {
		Install-IaServiceLogin -SqlInstance 'SQL01' -Mode Install -WhatIf | Out-Null
		Should -Invoke -ModuleName IndexAdvisor Set-Secret -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Invoke-DbaQuery -Times 0 -Exactly
	}

	It 'Verify: лише читання, зайві права — попередження' {
		Mock -ModuleName IndexAdvisor Invoke-DbaQuery {
			$script:Queries.Add([ordered]@{ instance = $SqlInstance; query = $Query; parameters = $SqlParameter })
			[pscustomobject]@{ ServerName = 'SQL01'; DatabaseName = $null; PrincipalName = 'index-advisor'; Kind = 'ServerRole'; Name = 'srv_index_advisor'; State = 'MEMBER'; IsExcessive = $false; Warning = $null }
			[pscustomobject]@{ ServerName = 'SQL01'; DatabaseName = 'Sales'; PrincipalName = 'index-advisor'; Kind = 'DatabaseRole'; Name = 'db_datareader'; State = 'MEMBER'; IsExcessive = $true; Warning = 'Зайве: членство в db_datareader дає доступ до даних або змін.' }
		}
		$warnings = $null
		$result = Install-IaServiceLogin -SqlInstance 'SQL01' -Mode Verify -WarningVariable warnings -WarningAction SilentlyContinue
		Should -Invoke -ModuleName IndexAdvisor Set-Secret -Times 0 -Exactly
		Should -Invoke -ModuleName IndexAdvisor Get-Secret -Times 0 -Exactly
		$script:Queries[0].query | Should -Match "N'Verify'"
		@($result.Permissions).Count | Should -Be 2
		$result.Message | Should -Match 'зайвих прав 1'
		($warnings -join ' ') | Should -Match 'db_datareader'
	}

	It 'помилка сервера: пароль не потрапляє в повідомлення' {
		Mock -ModuleName IndexAdvisor Invoke-DbaQuery { throw "Login failed for password $($SqlParameter.IaLoginPassword)" }
		$output = Install-IaServiceLogin -SqlInstance 'SQL01' -Mode Install *>&1
		$script:SavedPassword | Should -Not -BeNullOrEmpty
		($output | Out-String) | Should -Not -Match ([regex]::Escape($script:SavedPassword))
		$result = @($output | Where-Object { $_.PSObject.Properties['SqlInstance'] })[0]
		$result.Success | Should -BeFalse
		$result.Message | Should -Match '\*\*\*'
	}
}

Describe 'Expand-IaCliSqlcmdVariables і New-IaCliServicePassword' {
	It 'підставляє лише літерали N''$(Ім''я)'' і перевіряє імена' {
		InModuleScope IndexAdvisor {
			$script = "DECLARE @a NVARCHAR(10) = N'`$(A)';`nDECLARE @p NVARCHAR(10) = N'`$(Secret)';"
			$result = Expand-IaCliSqlcmdVariables -Script $script -Variables ([ordered]@{ A = "x'y" }) -ParameterVariables @('Secret')
			$result | Should -Be "DECLARE @a NVARCHAR(10) = N'x''y';`nDECLARE @p NVARCHAR(10) = @IaSecret;"
			{ Expand-IaCliSqlcmdVariables -Script "SELECT N'`$(B)';" -Variables ([ordered]@{ A = '1' }) } | Should -Throw -ExpectedMessage "*'B'*"
			{ Expand-IaCliSqlcmdVariables -Script "SELECT `$(A);" -Variables ([ordered]@{ A = '1' }) } | Should -Throw -ExpectedMessage '*лише як рядковий літерал*'
			{ Expand-IaCliSqlcmdVariables -Script "SELECT N'`$(A B)';" -Variables ([ordered]@{ A = '1' }) } | Should -Throw
			{ Expand-IaCliSqlcmdVariables -Script "SELECT N'`$(A)';" -Variables ([ordered]@{ 'A-1' = '1' }) } | Should -Throw -ExpectedMessage "*ім'я*"
			{ Expand-IaCliSqlcmdVariables -Script "SELECT N'`$(A)';" -Variables ([ordered]@{ A = "1`r`n2" }) } | Should -Throw -ExpectedMessage '*керівні*'
			{ Expand-IaCliSqlcmdVariables -Script ":setvar A 1`nSELECT N'`$(A)';" -Variables ([ordered]@{ A = '1' }) } | Should -Throw -ExpectedMessage '*sqlcmd*'
		}
	}

	It 'скрипт логіна містить лише безпечні посилання на змінні' {
		InModuleScope IndexAdvisor {
			$template = Get-Content -LiteralPath (Get-IaCliLoginScriptPath) -Raw
			$variables = [ordered]@{ Mode = 'Verify'; LoginName = 'index-advisor'; LoginType = 'Sql'; Databases = 'ALL' }
			$query = Expand-IaCliSqlcmdVariables -Script $template -Variables $variables -ParameterVariables @('LoginPassword')
			$query | Should -Not -Match '\$\('
		}
	}

	It 'пароль відповідає політиці складності й не містить лапок' {
		InModuleScope IndexAdvisor {
			$passwords = 1..50 | ForEach-Object { New-IaCliServicePassword }
			@($passwords | Select-Object -Unique).Count | Should -Be 50
			foreach ($password in $passwords) {
				$password.Length | Should -Be 32
				$password | Should -MatchExactly '[A-Z]'
				$password | Should -MatchExactly '[a-z]'
				$password | Should -Match '[0-9]'
				$password | Should -Match '[^A-Za-z0-9]'
				$password | Should -Not -Match "['""`$;\\\[\]()]"
			}
		}
	}
}
