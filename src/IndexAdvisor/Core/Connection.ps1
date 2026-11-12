# Підключення: рядок підключення, політика штатного логіна, перевірка фактичних прав (потік Core, CONTRACTS.md 3.1.2).

# Права, які штатний логін отримує через ролі скрипта підготовки (і неявні з них у SQL Server 2022), та права ролі public.
$script:IaCoreAllowedServerPermissions = @(
	'CONNECT SQL', 'VIEW ANY DATABASE', 'VIEW SERVER STATE', 'VIEW ANY DEFINITION', 'VIEW SERVER PERFORMANCE STATE',
	'VIEW SERVER SECURITY STATE', 'VIEW ANY PERFORMANCE DEFINITION', 'VIEW ANY SECURITY DEFINITION',
	'VIEW ANY CRYPTOGRAPHICALLY SECURED DEFINITION', 'VIEW ANY ERROR LOG'
)
$script:IaCoreAllowedDatabasePermissions = @(
	'CONNECT', 'VIEW DATABASE STATE', 'VIEW DEFINITION', 'VIEW DATABASE PERFORMANCE STATE', 'VIEW DATABASE SECURITY STATE',
	'VIEW PERFORMANCE DEFINITION', 'VIEW SECURITY DEFINITION', 'VIEW CRYPTOGRAPHICALLY SECURED DEFINITION',
	'VIEW ANY COLUMN ENCRYPTION KEY DEFINITION', 'VIEW ANY COLUMN MASTER KEY DEFINITION'
)
$script:IaCoreExcessiveServerRoles = @('sysadmin', 'serveradmin', 'securityadmin', 'processadmin', 'setupadmin', 'bulkadmin', 'diskadmin', 'dbcreator')
$script:IaCoreExcessiveDatabaseRoles = @('db_owner', 'db_datareader', 'db_datawriter', 'db_ddladmin', 'db_securityadmin', 'db_accessadmin', 'db_backupoperator')

$script:IaCoreLoginQuery = @'
SELECT
	SUSER_SNAME() AS loginName,
	USER_NAME() AS userName;
'@

$script:IaCoreRoleQuery = @'
SELECT
	N'SERVER' AS scope,
	sp.name AS roleName
FROM sys.server_principals AS sp
WHERE sp.type = 'R'
	AND IS_SRVROLEMEMBER(sp.name) = 1
UNION ALL
SELECT
	N'DATABASE' AS scope,
	dp.name AS roleName
FROM sys.database_principals AS dp
WHERE dp.type = 'R'
	AND IS_ROLEMEMBER(dp.name) = 1
ORDER BY scope, roleName;
'@

$script:IaCorePermissionQuery = @'
SELECT
	N'SERVER' AS scope,
	p.permission_name AS permissionName
FROM sys.fn_my_permissions(NULL, N'SERVER') AS p
UNION ALL
SELECT
	N'DATABASE' AS scope,
	p.permission_name AS permissionName
FROM sys.fn_my_permissions(NULL, N'DATABASE') AS p
ORDER BY scope, permissionName;
'@

$script:IaCoreObjectGrantQuery = @'
SELECT
	dp.class_desc AS classDesc,
	dp.permission_name AS permissionName,
	dp.state_desc AS stateDesc,
	pr.name AS grantee,
	CASE dp.class WHEN 3 THEN SCHEMA_NAME(dp.major_id) ELSE CONCAT(OBJECT_SCHEMA_NAME(dp.major_id), N'.', OBJECT_NAME(dp.major_id)) END AS objectName
FROM sys.database_permissions AS dp
INNER JOIN sys.database_principals AS pr ON pr.principal_id = dp.grantee_principal_id
WHERE dp.class IN (1, 3)
	AND dp.major_id > 0
	AND dp.state IN ('G', 'W')
	AND dp.permission_name NOT IN (N'VIEW DEFINITION', N'VIEW CHANGE TRACKING')
	AND (pr.principal_id = DATABASE_PRINCIPAL_ID() OR (pr.type = 'R' AND IS_ROLEMEMBER(pr.name) = 1))
ORDER BY classDesc, objectName, permissionName;
'@

function New-IaCoreError {
	<# ErrorRecord з ErrorId політики чи конфігурації (IaLoginRefused, IaConfigInvalid тощо). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$ErrorId,
		[Parameter(Mandatory)][string]$Message,
		[System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidOperation,
		[object]$TargetObject
	)
	return [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message), $ErrorId, $Category, $TargetObject)
}

function New-IaConnectionString {
	<# Рядок підключення до цільового сервера: Windows або SQL-автентифікація (пароль лише через Get-IaSecret з connection.passwordRef),
	   Encrypt, TrustServerCertificate, Application Name, Connect Timeout, Pooling = false; ApplicationIntent лише якщо передано. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][string]$Database,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config,
		[ValidateSet('ReadOnly')][string]$ApplicationIntent
	)
	$connection = $Config['connection']
	$builder = [System.Data.Common.DbConnectionStringBuilder]::new()
	$builder['Data Source'] = $Server
	$builder['Initial Catalog'] = $Database
	if ($connection['authentication'] -eq 'Windows') {
		$builder['Integrated Security'] = 'True'
	}
	else {
		if ([string]::IsNullOrWhiteSpace([string]$connection['login'])) {
			$PSCmdlet.ThrowTerminatingError((New-IaCoreError -ErrorId 'IaConfigInvalid' -Message 'Для SQL-автентифікації не задано connection.login.'))
		}
		if ([string]::IsNullOrWhiteSpace([string]$connection['passwordRef'])) {
			$PSCmdlet.ThrowTerminatingError((New-IaCoreError -ErrorId 'IaConfigInvalid' -Message 'Для SQL-автентифікації не задано connection.passwordRef (посилання на пароль у захищеному сховищі).'))
		}
		$secret = Get-IaSecret -Reference ([string]$connection['passwordRef']) -AsPlainText
		if ($secret -is [securestring]) {
			$secret = [System.Net.NetworkCredential]::new('', $secret).Password
		}
		if ([string]::IsNullOrEmpty([string]$secret)) {
			$PSCmdlet.ThrowTerminatingError((New-IaCoreError -ErrorId 'IaSecretNotFound' -Message ("Пароль за посиланням '{0}' порожній або не знайдений." -f $connection['passwordRef']) -Category ObjectNotFound))
		}
		$builder['User ID'] = [string]$connection['login']
		$builder['Password'] = [string]$secret
	}
	$builder['Encrypt'] = [string]$connection['encrypt']
	$builder['TrustServerCertificate'] = $(if ($connection['trustServerCertificate']) { 'True' } else { 'False' })
	$builder['Application Name'] = [string]$connection['applicationName']
	$builder['Connect Timeout'] = ([int]$connection['connectTimeoutSeconds']).ToString([cultureinfo]::InvariantCulture)
	$builder['Pooling'] = 'False'
	if ($ApplicationIntent) {
		$builder['ApplicationIntent'] = $ApplicationIntent
	}
	# Явний виклик get_ConnectionString: PowerShell трактує DbConnectionStringBuilder як словник.
	return $builder.get_ConnectionString()
}

function Test-IaCoreStandardLogin {
	<# Обчислює логін підключення і чи він штатний (без журналу й винятків). #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$authentication = [string]$Config['connection']['authentication']
	$login = if ($authentication -eq 'Windows') { Get-IaCoreUserName } else { [string]$Config['connection']['login'] }
	$standardLogin = [string]$Config['security']['standardLogin']
	$isStandard = -not [string]::IsNullOrWhiteSpace($login) -and [string]::Equals($login, $standardLogin, [System.StringComparison]::OrdinalIgnoreCase)
	$message = $null
	if (-not $isStandard) {
		$message = ("Логін '{0}' ({1}-автентифікація) не є штатним логіном '{2}' (security.standardLogin). " -f $login, $authentication, $standardLogin) +
			'Програма за замовчуванням підключається лише під штатним логіном із правами читання метаданих, створеним скриптом sql/Setup-IndexAdvisorLogin.sql.'
	}
	return [ordered]@{
		login = $login
		authentication = $authentication
		isStandard = $isStandard
		allowed = $isStandard -or [bool]$Config['unsafe']['allowNonStandardLogin']
		message = $message
	}
}

function Assert-IaStandardLogin {
	<# Політика «лише штатний логін» до підключення. Кидає виняток з ErrorId 'IaLoginRefused', якщо логін не штатний
	   і unsafe.allowNonStandardLogin = $false. Повертає @{ login; authentication; isStandard; warnings }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$check = Test-IaCoreStandardLogin -Config $Config
	$warnings = @()
	if (-not $check.isStandard) {
		if (-not $check.allowed) {
			$message = $check.message + ' Щоб працювати під іншим логіном, явно ввімкніть unsafe.allowNonStandardLogin (CLI: -AllowNonStandardLogin); ' +
				'тоді програма перевірить фактичні права логіна й попередить про зайві.'
			Write-IaLog -Level Security -Message "Підключення відхилено: $message" -Data ([ordered]@{ login = $check.login; authentication = $check.authentication })
			$PSCmdlet.ThrowTerminatingError((New-IaCoreError -ErrorId 'IaLoginRefused' -Message $message -Category PermissionDenied -TargetObject $check.login))
		}
		$warning = $check.message + ' Увімкнено unsafe.allowNonStandardLogin: фактичні права логіна буде перевірено на кожному сервері й у кожній базі.'
		$warnings = @($warning)
		Write-IaLog -Level Security -Message $warning -Data ([ordered]@{ login = $check.login; authentication = $check.authentication })
	}
	return [ordered]@{
		login = $check.login
		authentication = $check.authentication
		isStandard = $check.isStandard
		warnings = $warnings
	}
}

function Get-IaLoginPermissions {
	<# Фактичні права поточного логіна (лише SELECT через Invoke-IaSqlQuery -Purpose PermissionCheck):
	   sysadmin, серверні ролі, db_owner, db_datareader, db_datawriter, права на зміну даних.
	   Повертає @{ server; database; login; isSysadmin; serverRoles; databaseRoles; excessive = @(@{ permission; scope; details }); warnings }. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Server,
		[Parameter(Mandatory)][string]$Database,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	$excessive = [System.Collections.Generic.List[object]]::new()
	$warnings = [System.Collections.Generic.List[string]]::new()
	$serverRoles = [System.Collections.Generic.List[string]]::new()
	$databaseRoles = [System.Collections.Generic.List[string]]::new()
	$login = (Test-IaCoreStandardLogin -Config $Config).login
	$fetch = [int]$Config['limits']['maxRows']
	$run = {
		param([string]$Query, [string]$What)
		$response = Invoke-IaSqlQuery -Server $Server -Database $Database -Query $Query -Fetch $fetch -Purpose PermissionCheck -Config $Config
		if (-not $response.success) {
			$warnings.Add(("Не вдалося перевірити {0} на {1}/{2}: {3}" -f $What, $Server, $Database, $response.error.message))
			return @()
		}
		if ($response.truncated) {
			$warnings.Add(("Перелік ({0}) на {1}/{2} обрізано до {3} рядків." -f $What, $Server, $Database, $fetch))
		}
		return $response.rows
	}

	foreach ($row in @(& $run $script:IaCoreLoginQuery 'ім''я логіна')) {
		if (-not [string]::IsNullOrEmpty([string]$row.loginName)) {
			$login = [string]$row.loginName
		}
	}
	foreach ($row in @(& $run $script:IaCoreRoleQuery 'членство в ролях')) {
		$roleName = [string]$row.roleName
		if ($row.scope -eq 'SERVER') {
			$serverRoles.Add($roleName)
			if ($roleName -in $script:IaCoreExcessiveServerRoles) {
				$excessive.Add([ordered]@{ permission = $roleName; scope = 'SERVER'; details = "Членство у фіксованій серверній ролі $roleName" })
			}
		}
		else {
			$databaseRoles.Add($roleName)
			if ($roleName -in $script:IaCoreExcessiveDatabaseRoles) {
				$excessive.Add([ordered]@{ permission = $roleName; scope = 'DATABASE'; details = "Членство у фіксованій ролі бази $roleName ($Database)" })
			}
		}
	}
	foreach ($row in @(& $run $script:IaCorePermissionQuery 'фактичні права')) {
		$permission = [string]$row.permissionName
		if ($row.scope -eq 'SERVER') {
			if ($permission -notin $script:IaCoreAllowedServerPermissions) {
				$excessive.Add([ordered]@{ permission = $permission; scope = 'SERVER'; details = 'Право на рівні сервера понад читання метаданих' })
			}
		}
		elseif ($permission -notin $script:IaCoreAllowedDatabasePermissions) {
			$excessive.Add([ordered]@{ permission = $permission; scope = 'DATABASE'; details = "Право на рівні бази $Database понад читання метаданих" })
		}
	}
	foreach ($row in @(& $run $script:IaCoreObjectGrantQuery 'права на схеми й об''єкти')) {
		$excessive.Add([ordered]@{
				permission = [string]$row.permissionName
				scope = [string]$row.classDesc
				details = ("{0} на {1} (через {2}, {3})" -f $row.permissionName, $row.objectName, $row.grantee, $row.stateDesc)
			})
	}
	$isSysadmin = $serverRoles -contains 'sysadmin'
	if ($excessive.Count -gt 0) {
		$names = @($excessive | ForEach-Object { '{0} ({1})' -f $_.permission, $_.scope } | Select-Object -Unique)
		$warnings.Insert(0, ("Логін '{0}' має зайві права на {1}/{2}: {3}." -f $login, $Server, $Database, ($names -join ', ')))
	}
	return [ordered]@{
		server = $Server
		database = $Database
		login = $login
		isSysadmin = $isSysadmin
		serverRoles = $serverRoles.ToArray()
		databaseRoles = $databaseRoles.ToArray()
		excessive = $excessive.ToArray()
		warnings = $warnings.ToArray()
	}
}
