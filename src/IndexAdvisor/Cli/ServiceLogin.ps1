# Обгортка скрипта штатного логіна sql/Setup-IndexAdvisorLogin.sql (CONTRACTS.md, розділ 10) для кількох серверів через dbatools.
# Пароль SQL-логіна генерується тут, одразу зберігається в SecretManagement і передається скрипту параметром запиту:
# він не потрапляє в текст скрипта, у вивід чи в журнал.

$script:IaCliSqlcmdNamePattern = '^[A-Za-z_][A-Za-z0-9_]{0,127}$'

function Import-IaCliDbatools {
	<# Лінивий імпорт dbatools (лише для реальних підключень). #>
	[CmdletBinding()]
	param()
	if (-not (Get-Command -Name 'Invoke-DbaQuery' -ErrorAction Ignore)) {
		Import-Module -Name 'dbatools' -ErrorAction Stop
	}
}

function Get-IaCliLoginScriptPath {
	<# Шлях до sql/Setup-IndexAdvisorLogin.sql (поруч із src у поставці). #>
	[CmdletBinding()]
	param()
	$candidates = @(
		(Join-Path $script:IaModuleRoot '..\..\sql\Setup-IndexAdvisorLogin.sql')
		(Join-Path $script:IaModuleRoot 'sql\Setup-IndexAdvisorLogin.sql')
	)
	foreach ($candidate in $candidates) {
		if (Test-Path -LiteralPath $candidate -PathType Leaf) {
			return (Resolve-Path -LiteralPath $candidate).Path
		}
	}
	throw 'Не знайдено скрипт sql/Setup-IndexAdvisorLogin.sql.'
}

function Expand-IaCliSqlcmdVariables {
	<# Безпечна підстановка sqlcmd-змінних. Змінні дозволені лише як цілий рядковий літерал N'$(Ім'я)';
	   імена перевіряються, значення екрануються (' -> ''), керівні символи заборонені. Змінні з ParameterVariables
	   замінюються параметром запиту @Ia<Ім'я>, тож їхні значення (пароль) не потрапляють у текст. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Script,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Variables,
		[string[]]$ParameterVariables = @()
	)
	foreach ($name in @($Variables.Keys) + @($ParameterVariables)) {
		if ([string]$name -notmatch $script:IaCliSqlcmdNamePattern) {
			throw "Недопустиме ім'я sqlcmd-змінної '$name'."
		}
	}
	foreach ($name in $Variables.Keys) {
		$value = [string]$Variables[$name]
		if ($value -match '[\x00-\x1F\x7F]') {
			throw "Значення sqlcmd-змінної '$name' містить керівні символи."
		}
		if ($value.Length -gt 4000) {
			throw "Значення sqlcmd-змінної '$name' задовге."
		}
	}
	foreach ($line in ($Script -split "`r?`n")) {
		if ($line -match '^\s*(:[A-Za-z]|!!)') {
			throw "Скрипт містить команду sqlcmd '$($line.Trim())', яку обгортка не підтримує."
		}
	}
	foreach ($match in [regex]::Matches($Script, '\$\(([^)]*)\)')) {
		$name = $match.Groups[1].Value
		if ($name -notmatch $script:IaCliSqlcmdNamePattern) {
			throw "Недопустиме посилання на sqlcmd-змінну '$($match.Value)'."
		}
		if (-not ($Variables.Contains($name) -or $name -in $ParameterVariables)) {
			throw "Для sqlcmd-змінної '$name' не передано значення."
		}
	}
	$literalPattern = "N'\$\(([A-Za-z_][A-Za-z0-9_]*)\)'"
	if ([regex]::IsMatch([regex]::Replace($Script, $literalPattern, ''), '\$\(')) {
		throw "sqlcmd-змінні дозволено використовувати лише як рядковий літерал N'`$(Ім'я)'."
	}
	$evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
		param($match)
		$name = $match.Groups[1].Value
		if ($name -in $ParameterVariables) {
			return "@Ia$name"
		}
		return "N'" + ([string]$Variables[$name]).Replace("'", "''") + "'"
	}
	return [regex]::Replace($Script, $literalPattern, $evaluator)
}

function New-IaCliServicePassword {
	<# Випадковий пароль за політикою складності: великі й малі літери, цифри, спецсимволи; без лапок і символів sqlcmd. #>
	[CmdletBinding()]
	[OutputType([string])]
	param([ValidateRange(16, 128)][int]$Length = 32)
	$classes = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%*+-=?@^_~')
	$all = -join $classes
	$chars = [System.Collections.Generic.List[char]]::new()
	foreach ($class in $classes) {
		$chars.Add($class[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
	}
	while ($chars.Count -lt $Length) {
		$chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
	}
	for ($i = $chars.Count - 1; $i -gt 0; $i--) {
		$j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
		$swap = $chars[$i]
		$chars[$i] = $chars[$j]
		$chars[$j] = $swap
	}
	return -join $chars
}

function Get-IaCliServicePassword {
	<# Пароль штатного логіна: наявний секрет у SecretManagement або новий згенерований, одразу збережений Set-Secret. #>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)][string]$SecretName,
		[string]$Vault
	)
	$secretArguments = @{ Name = $SecretName; ErrorAction = 'Stop' }
	if ($Vault) {
		$secretArguments.Vault = $Vault
	}
	$existing = $null
	try {
		$existing = Get-Secret @secretArguments
	}
	catch {
		$existing = $null
	}
	if ($null -ne $existing) {
		Write-Verbose "Використано наявний секрет '$SecretName': пароль логіна синхронізується з ним."
		if ($existing -is [securestring]) {
			return (ConvertFrom-SecureString -SecureString $existing -AsPlainText)
		}
		if ($existing -is [pscredential]) {
			return $existing.GetNetworkCredential().Password
		}
		return [string]$existing
	}
	$plain = New-IaCliServicePassword
	$secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
	Set-Secret @secretArguments -Secret $secure
	Write-Verbose "Згенеровано пароль і збережено в секреті '$SecretName'."
	return $plain
}

function Install-IaServiceLogin {
	<# Обгортка над sql/Setup-IndexAdvisorLogin.sql для кількох серверів (dbatools). Режими: Install, AddDatabase, Remove, Verify.
	   Для SQL-логіна генерує пароль (CHECK_POLICY = ON) і одразу зберігає його в SecretManagement (Set-Secret).
	   Verify лише читає й показує фактичні права та зайві права. #>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string[]]$SqlInstance,
		[ValidateSet('Install', 'AddDatabase', 'Remove', 'Verify')][string]$Mode = 'Install',
		[string[]]$Database = @(),
		[string]$LoginName = 'index-advisor',
		[switch]$WindowsLogin,
		[string]$SecretName,
		[string]$Vault,
		[pscredential]$SqlCredential
	)
	$loginType = if ($WindowsLogin) { 'Windows' } else { 'Sql' }
	if ([string]::IsNullOrWhiteSpace($LoginName) -or $LoginName.Length -gt 128 -or $LoginName -match '[\x00-\x1F\x7F]') {
		throw "Недопустиме ім'я логіна '$LoginName'."
	}
	if ($WindowsLogin -and $LoginName -notmatch '^[^\\]+\\[^\\]+$') {
		throw 'Для Windows-логіна вкажіть ім''я у форматі DOMAIN\user.'
	}
	$databaseNames = @($Database | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
	foreach ($name in $databaseNames) {
		if ($name.Length -gt 128 -or $name -match '[,\x00-\x1F\x7F]') {
			throw "Недопустиме ім'я бази '$name' (кома й керівні символи заборонені)."
		}
	}
	$databasesValue = if ($databaseNames.Count -gt 0) { $databaseNames -join ',' } else { 'ALL' }
	if (-not $SecretName) {
		$SecretName = "IndexAdvisor-$LoginName"
	}
	if (-not $WindowsLogin -and $SecretName -match '[/\\\x00-\x1F]') {
		throw "Недопустиме ім'я секрету '$SecretName'."
	}
	$template = Get-Content -LiteralPath (Get-IaCliLoginScriptPath) -Raw -Encoding utf8
	$variables = [ordered]@{ Mode = $Mode; LoginName = $LoginName; LoginType = $loginType; Databases = $databasesValue }
	$query = Expand-IaCliSqlcmdVariables -Script $template -Variables $variables -ParameterVariables @('LoginPassword')

	$password = ''
	if ($Mode -eq 'Install' -and -not $WindowsLogin) {
		$target = if ($Vault) { "$Vault/$SecretName" } else { $SecretName }
		if (-not $PSCmdlet.ShouldProcess("секрет $target", 'Згенерувати пароль штатного логіна й зберегти в SecretManagement (або використати наявний)')) {
			return
		}
		$password = Get-IaCliServicePassword -SecretName $SecretName -Vault $Vault
	}
	Import-IaCliDbatools
	try {
		foreach ($instance in $SqlInstance) {
			if ($Mode -ne 'Verify' -and -not $PSCmdlet.ShouldProcess($instance, "Setup-IndexAdvisorLogin.sql: $Mode для $LoginName")) {
				continue
			}
			$result = [ordered]@{
				SqlInstance = $instance
				Mode = $Mode
				LoginName = $LoginName
				LoginType = $loginType
				Databases = $databasesValue
				Success = $false
				Message = $null
				Permissions = @()
			}
			try {
				$arguments = @{
					SqlInstance = $instance
					Database = 'master'
					Query = $query
					SqlParameter = @{ IaLoginPassword = $password }
					As = 'PSObject'
					MessagesToOutput = $true
					EnableException = $true
				}
				if ($SqlCredential) {
					$arguments.SqlCredential = $SqlCredential
				}
				$output = @(Invoke-DbaQuery @arguments)
				$messages = @($output | Where-Object { $_ -is [string] })
				$rows = @($output | Where-Object { $null -ne $_ -and $_ -isnot [string] })
				foreach ($message in $messages) {
					Write-Verbose "[$instance] $message"
				}
				if ($Mode -eq 'Verify') {
					$result.Permissions = $rows
					foreach ($row in $rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Warning) }) {
						$scope = if ($row.DatabaseName) { "$instance/$($row.DatabaseName)" } else { $instance }
						Write-Warning "[$scope] $($row.Warning)"
					}
					$excessive = @($rows | Where-Object { $_.IsExcessive -eq $true -or $_.IsExcessive -eq 1 }).Count
					$result.Message = "Перевірено: записів $($rows.Count), зайвих прав $excessive."
				}
				elseif ($Mode -eq 'Install' -and -not $WindowsLogin) {
					$reference = if ($Vault) { "secret:$Vault/$SecretName" } else { "secret:$SecretName" }
					$result.Message = "Виконано. Пароль збережено в SecretManagement; у конфігурації: connection.login = '$LoginName', connection.passwordRef = '$reference'."
				}
				else {
					$result.Message = 'Виконано.'
				}
				if ($Mode -eq 'Remove') {
					$result.Message += " Секрет '$SecretName' (якщо є) не видалено: логін може використовуватися на інших серверах."
				}
				$result.Success = $true
			}
			catch {
				$text = $_.Exception.Message
				if ($password) {
					$text = $text.Replace($password, '***')
				}
				$result.Message = "Помилка: $text"
				Write-Error -Message "[$instance] $($result.Message)" -ErrorId 'IaServiceLoginFailed' -ErrorAction Continue
			}
			[pscustomobject]$result
		}
	}
	finally {
		$password = $null
		$query = $null
	}
}
