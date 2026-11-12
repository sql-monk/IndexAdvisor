# Інтеграційний тест справжнього драйвера Invoke-IaDbCommand (живий SQL Server). За замовчуванням не запускається:
# потрібні тег Integration і змінна середовища IA_TEST_SQL_SERVER (лише SELECT із системних DMV); автентифікація — як у
# tests/Integration/LiveRun.Integration.Tests.ps1 (IA_TEST_SQL_LOGIN / IA_TEST_SQL_PASSWORD або Windows).

BeforeAll {
	. (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
	$script:IaModule = Get-Module IndexAdvisor
}

Describe 'Invoke-IaDbCommand на живому сервері' -Tag 'Integration' {
	BeforeAll {
		$script:IaTestServer = $env:IA_TEST_SQL_SERVER
		# IA_TEST_SQL_LOGIN / IA_TEST_SQL_PASSWORD — SQL-автентифікація; інакше Windows. Пароль у рядку підключення лише в пам'яті тесту.
		$builder = [System.Data.Common.DbConnectionStringBuilder]::new()
		$builder['Data Source'] = $script:IaTestServer
		$builder['Initial Catalog'] = 'master'
		if ([string]::IsNullOrWhiteSpace($env:IA_TEST_SQL_LOGIN)) {
			$builder['Integrated Security'] = 'True'
		}
		else {
			$builder['User ID'] = $env:IA_TEST_SQL_LOGIN
			$builder['Password'] = $env:IA_TEST_SQL_PASSWORD
		}
		$builder['Encrypt'] = 'Optional'
		$builder['TrustServerCertificate'] = 'True'
		$builder['Pooling'] = 'False'
		$script:IaTestConnectionString = $builder.ConnectionString
	}

	It 'читає не більше MaxRows рядків і повідомляє hasMoreRows' -Skip:([string]::IsNullOrEmpty($env:IA_TEST_SQL_SERVER)) {
		$connectionString = $script:IaTestConnectionString
		$result = & $script:IaModule {
			param($cs)
			Invoke-IaDbCommand -ConnectionString $cs -CommandText 'SELECT TOP (10) o.name FROM sys.all_objects AS o WHERE o.name LIKE @Pattern OPTION (MAXDOP 1);' `
				-Parameters @(@{ name = '@Pattern'; value = 'sys%'; sqlType = 'NVarChar' }) -MaxRows 3
		} $connectionString
		@($result.rows).Count | Should -Be 3
		$result.hasMoreRows | Should -BeTrue
		$result.columns[0].name | Should -Be 'name'
	}

	It 'таймаут команди повертає код Timeout' -Skip:([string]::IsNullOrEmpty($env:IA_TEST_SQL_SERVER)) {
		$connectionString = $script:IaTestConnectionString
		$caught = $null
		try {
			& $script:IaModule {
				param($cs)
				# COUNT_BIG(*) по CROSS JOIN SQL Server 2025 рахує без перебору рядків (~1 с), тому агрегат обчислюється для кожного рядка.
				$text = 'SELECT MAX(CHECKSUM(a.name, b.name, c.name)) AS c FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b ' +
					'CROSS JOIN sys.all_objects AS c OPTION (MAXDOP 1);'
				Invoke-IaDbCommand -ConnectionString $cs -CommandText $text -CommandTimeoutSeconds 1
			} $connectionString
		}
		catch {
			$caught = $_
		}
		$caught.FullyQualifiedErrorId | Should -BeLike 'Timeout*'
	}
}
