namespace IndexAdvisor.Gui.PowerShell;

/// <summary>
/// Скрипти, які GUI виконує в runspace з GuiHost. Публічний API модуля: Invoke-IndexAdvisor, Test-IaConfig, New-IaConfigTemplate.
/// Get-IaConfig і ConvertTo-IaCliOverrides (внутрішні) викликаються в області модуля лише для підсумку конфігурації
/// й теки результатів; їх збій не перериває запуск.
/// </summary>
internal static class HostedScripts
{
	public const string Run = """
		param(
			[Parameter(Mandatory)][string]$ModulePath,
			[Parameter(Mandatory)][hashtable]$Arguments
		)
		Import-Module -Name $ModulePath -Force -ErrorAction Stop
		if (-not (Get-Module -Name IndexAdvisor)) {
			# Import-Module не завжди кидає виняток, коли скрипти модуля заблоковано політикою виконання.
			throw "Модуль IndexAdvisor не завантажено ($ModulePath): $(if ($Error.Count -gt 0) { $Error[0].Exception.Message } else { 'причина невідома' })"
		}
		$global:LASTEXITCODE = 0
		$results = @(Invoke-IndexAdvisor @Arguments -PassThru) |
			Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('runId') }
		$exitCode = [int]$global:LASTEXITCODE
		$outputRoot = $null
		try {
			$outputRoot = & (Get-Module IndexAdvisor) {
				param([hashtable]$CliArguments)
				$bound = [ordered]@{}
				foreach ($key in $CliArguments.Keys) {
					if ($key -notin @('Config', 'FromArchive', 'PassThru') -and $key -notin [System.Management.Automation.PSCmdlet]::CommonParameters) {
						$bound[$key] = $CliArguments[$key]
					}
				}
				$config = Get-IaConfig -Path ([string]$CliArguments['Config']) -Overrides (ConvertTo-IaCliOverrides -BoundParameters $bound)
				$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$config.output.path)
			} $Arguments
		}
		catch {
			Write-Verbose "Каталог результатів не визначено: $($_.Exception.Message)"
		}
		[pscustomobject]@{
			ExitCode = $exitCode
			OutputRoot = $outputRoot
			Results = [string[]]@($results | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 50 -Compress })
		}
		""";

	public const string TestConfig = """
		param(
			[Parameter(Mandatory)][string]$ModulePath,
			[Parameter(Mandatory)][string]$Path
		)
		Import-Module -Name $ModulePath -Force -ErrorAction Stop
		if (-not (Get-Module -Name IndexAdvisor)) {
			# Import-Module не завжди кидає виняток, коли скрипти модуля заблоковано політикою виконання.
			throw "Модуль IndexAdvisor не завантажено ($ModulePath): $(if ($Error.Count -gt 0) { $Error[0].Exception.Message } else { 'причина невідома' })"
		}
		$check = Test-IaConfig -Path $Path
		$summary = $null
		if ($check.isValid) {
			try {
				$cfg = & (Get-Module IndexAdvisor) { param([string]$ConfigPath) Get-IaConfig -Path $ConfigPath } $Path
				$providers = @()
				$providerDetails = @()
				$model = [string]$cfg.llm.model
				if ($cfg.llm.providers -is [System.Collections.IDictionary]) {
					$providers = @($cfg.llm.providers.Keys | ForEach-Object { [string]$_ })
					$providerDetails = @(foreach ($name in $providers) {
						$item = $cfg.llm.providers[$name]
						[ordered]@{ name = $name; type = [string]$item.type; endpoint = [string]$item.endpoint; model = [string]$item.model }
					})
					if (-not $model -and $cfg.llm.provider -and $cfg.llm.providers.Contains([string]$cfg.llm.provider)) {
						$model = [string]$cfg.llm.providers[[string]$cfg.llm.provider].model
					}
				}
				$datasets = @()
				if ($cfg.collector.datasets -is [System.Collections.IDictionary]) {
					$datasets = @($cfg.collector.datasets.Keys | Where-Object { [bool]$cfg.collector.datasets[$_] } | ForEach-Object { [string]$_ })
				}
				$resolve = { param([string]$p) if ($p) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) } }
				$summary = [ordered]@{
					servers = @($cfg.servers | ForEach-Object { [string]$_ })
					module = [string]$cfg.module
					databases = @($cfg.scope.databases.include | ForEach-Object { [string]$_ })
					excludeDatabases = @($cfg.scope.databases.exclude | ForEach-Object { [string]$_ })
					provider = [string]$cfg.llm.provider
					providers = $providers
					providerDetails = $providerDetails
					model = $model
					crossCheckProvider = [string]$cfg.llm.crossCheckProvider
					analysisWindowDays = [int]$cfg.analysisWindow.days
					datasets = $datasets
					outputPath = & $resolve ([string]$cfg.output.path)
					archivePath = & $resolve ([string]$cfg.archive.path)
					formats = @($cfg.output.formats | ForEach-Object { [string]$_ })
					login = [string]$cfg.connection.login
					authentication = [string]$cfg.connection.authentication
					repositoryEnabled = [bool]$cfg.repository.enabled
					repository = if ($cfg.repository.server) { "$($cfg.repository.server)/$($cfg.repository.database)" } else { $null }
					archiveEnabled = [bool]$cfg.archive.enabled
					maskNames = [bool]$cfg.llm.maskNames
					localOnly = [bool]$cfg.llm.localOnly
					autoApprove = [bool]$cfg.llm.autoApproveToolRequests
					nonInteractive = [bool]$cfg.run.nonInteractive
					maintenance = [bool]$cfg.maintenance.enabled
				}
			}
			catch {
				Write-Warning "Підсумок конфігурації недоступний: $($_.Exception.Message)"
			}
		}
		[ordered]@{
			isValid = [bool]$check.isValid
			errors = @($check.errors | ForEach-Object {
				[ordered]@{ line = $_.line; column = $_.column; path = [string]$_.path; message = [string]$_.message }
			})
			summary = $summary
		} | ConvertTo-Json -Depth 8 -Compress
		""";

	public const string NewTemplate = """
		param(
			[Parameter(Mandatory)][string]$ModulePath,
			[Parameter(Mandatory)][string]$Path
		)
		Import-Module -Name $ModulePath -Force -ErrorAction Stop
		if (-not (Get-Module -Name IndexAdvisor)) {
			# Import-Module не завжди кидає виняток, коли скрипти модуля заблоковано політикою виконання.
			throw "Модуль IndexAdvisor не завантажено ($ModulePath): $(if ($Error.Count -gt 0) { $Error[0].Exception.Message } else { 'причина невідома' })"
		}
		New-IaConfigTemplate -Path $Path -Force -Confirm:$false
		""";

	public const string NewMaintenance = """
		param(
			[Parameter(Mandatory)][string]$ModulePath,
			[Parameter(Mandatory)][hashtable]$Arguments
		)
		Import-Module -Name $ModulePath -Force -ErrorAction Stop
		if (-not (Get-Module -Name IndexAdvisor)) {
			# Import-Module не завжди кидає виняток, коли скрипти модуля заблоковано політикою виконання.
			throw "Модуль IndexAdvisor не завантажено ($ModulePath): $(if ($Error.Count -gt 0) { $Error[0].Exception.Message } else { 'причина невідома' })"
		}
		$result = New-IaIndexMaintenance @Arguments -PassThru
		[string]$result.directory
		""";

	/// <summary>
	/// Install-IaServiceLogin; облікові дані адміністратора SQL — через діалог хоста (PromptForCredential).
	/// Результат кожного сервера друкується в журнал.
	/// </summary>
	public const string ServiceLogin = """
		param(
			[Parameter(Mandatory)][string]$ModulePath,
			[Parameter(Mandatory)][hashtable]$Arguments,
			[bool]$AskCredential
		)
		Import-Module -Name $ModulePath -Force -ErrorAction Stop
		if (-not (Get-Module -Name IndexAdvisor)) {
			# Import-Module не завжди кидає виняток, коли скрипти модуля заблоковано політикою виконання.
			throw "Модуль IndexAdvisor не завантажено ($ModulePath): $(if ($Error.Count -gt 0) { $Error[0].Exception.Message } else { 'причина невідома' })"
		}
		if ($AskCredential) {
			$credential = $Host.UI.PromptForCredential('IndexAdvisor: обліковий запис SQL Server',
				'Логін з правами на створення логінів, ролей і користувачів (або на перегляд прав для Verify).', '', '')
			if ($null -eq $credential -or [string]::IsNullOrEmpty($credential.UserName)) {
				throw 'Облікові дані не введено.'
			}
			$Arguments['SqlCredential'] = $credential
		}
		foreach ($item in @(Install-IaServiceLogin @Arguments)) {
			Write-Host (($item | Format-List | Out-String -Width 180).Trim())
			Write-Host ''
		}
		""";
}
