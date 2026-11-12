# Спільні утиліти потоку Core: нормалізація значень для JSON, небезпечні прапорці, маскування в журналі.

$script:IaCoreSensitiveNamePattern = '(?i)password|pwd|secret|token|key|api_key|connection_?string'
$script:IaCoreMaskedValue = '***'

function ConvertTo-IaJsonValue {
	<# Нормалізація значення для JSON: decimal -> рядок (InvariantCulture), дати -> ISO 8601, uniqueidentifier -> рядок,
	   byte[] -> base64, DBNull -> $null. #>
	[CmdletBinding()]
	param([AllowNull()]$Value)
	if ($null -eq $Value -or $Value -is [System.DBNull]) {
		return $null
	}
	# Без switch ($Value): switch перебирав би елементи масивів (зокрема byte[]).
	if ($Value -is [string] -or $Value -is [bool]) {
		return $Value
	}
	if ($Value -is [decimal]) {
		return $Value.ToString([cultureinfo]::InvariantCulture)
	}
	if ($Value -is [datetime] -or $Value -is [System.DateTimeOffset]) {
		return ConvertTo-IaUtcString -Date $Value
	}
	if ($Value -is [guid]) {
		return $Value.ToString()
	}
	if ($Value -is [byte[]]) {
		return [System.Convert]::ToBase64String($Value)
	}
	if ($Value -is [timespan]) {
		return $Value.ToString('c', [cultureinfo]::InvariantCulture)
	}
	if ($Value -is [char]) {
		return [string]$Value
	}
	if ($Value -is [int] -or $Value -is [long] -or $Value -is [short] -or $Value -is [byte] -or $Value -is [sbyte] -or
		$Value -is [uint16] -or $Value -is [uint32] -or $Value -is [double] -or $Value -is [single]) {
		return $Value
	}
	if ($Value -is [uint64]) {
		return $Value.ToString([cultureinfo]::InvariantCulture)
	}
	if ($Value -is [System.Collections.IDictionary]) {
		$result = [ordered]@{}
		foreach ($key in $Value.Keys) {
			$result[[string]$key] = ConvertTo-IaJsonValue -Value $Value[$key]
		}
		return $result
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		return , @(foreach ($item in $Value) { , (ConvertTo-IaJsonValue -Value $item) })
	}
	return $Value.ToString()
}

function Get-IaUnsafeFlags {
	<# Імена активних прапорців секції unsafe (наприклад 'disableSelectCheck'). #>
	[CmdletBinding()]
	[OutputType([string[]])]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$unsafe = $Config['unsafe']
	if ($null -eq $unsafe) {
		return
	}
	foreach ($key in @($unsafe.Keys)) {
		if ($unsafe[$key] -is [bool] -and $unsafe[$key]) {
			[string]$key
		}
	}
}

function Protect-IaLogValue {
	<# Маскує значення, якщо ім'я містить password, pwd, secret, token, key, api_key або connection_string (без урахування регістру). #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string]$Name,
		[AllowNull()]$Value
	)
	if ($null -eq $Value) {
		return $null
	}
	if ($Name -match $script:IaCoreSensitiveNamePattern -or $Value -is [securestring]) {
		return $script:IaCoreMaskedValue
	}
	if ($Value -is [string]) {
		# Запобіжник: пароль у тексті на зразок рядка підключення маскується незалежно від імені.
		return ($Value -replace '(?i)\b(password|pwd)(\s*=\s*)("[^"]*"|''[^'']*''|[^;]*)', ('$1$2' + $script:IaCoreMaskedValue))
	}
	return $Value
}

function Protect-IaCoreLogData {
	<# Рекурсивне маскування словників і масивів для журналу (ключі перевіряються Protect-IaLogValue). #>
	[CmdletBinding()]
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return $null
	}
	if ($Value -is [System.Collections.IDictionary]) {
		$result = [ordered]@{}
		foreach ($key in $Value.Keys) {
			$name = [string]$key
			if ($name -match $script:IaCoreSensitiveNamePattern) {
				$result[$name] = Protect-IaLogValue -Name $name -Value $Value[$key]
			}
			else {
				$result[$name] = Protect-IaCoreLogData -Value $Value[$key]
			}
		}
		return $result
	}
	if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [byte[]]) {
		return , @(foreach ($item in $Value) { , (Protect-IaCoreLogData -Value $item) })
	}
	return Protect-IaLogValue -Name '' -Value (ConvertTo-IaJsonValue -Value $Value)
}

function Format-IaCoreLogValue {
	<# Рядкове подання значення для Markdown-журналу. #>
	[CmdletBinding()]
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return 'NULL'
	}
	if ($Value -is [string]) {
		return $Value
	}
	if ($Value -is [System.Collections.IDictionary] -or ($Value -is [System.Collections.IEnumerable])) {
		return (ConvertTo-Json -InputObject $Value -Depth 20 -Compress)
	}
	if ($Value -is [bool]) {
		return $(if ($Value) { 'true' } else { 'false' })
	}
	return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
}
