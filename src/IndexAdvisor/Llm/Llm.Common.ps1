# Спільні внутрішні помічники потоку LLM (префікс IaLlm).

function New-IaLlmErrorRecord {
	<# Внутрішня: ErrorRecord з ErrorId для винятків політики й конфігурації (CONTRACTS.md, розділ 2).
	   Повідомлення ніколи не містить значень секретів. #>
	param(
		[Parameter(Mandatory)][string]$ErrorId,
		[Parameter(Mandatory)][string]$Message,
		[System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidOperation
	)
	$exception = [System.InvalidOperationException]::new($Message)
	return [System.Management.Automation.ErrorRecord]::new($exception, $ErrorId, $Category, $null)
}

function Write-IaLlmLog {
	<# Внутрішня: запис у журнал сесії через Write-IaLog (Core). Помилка журналу не зупиняє роботу.
	   У журнал ніколи не пишуться ключі API і тексти промптів. #>
	param(
		[Parameter(Mandatory)][string]$Message,
		[ValidateSet('Info', 'Warning', 'Error', 'Security')][string]$Level = 'Info',
		[System.Collections.IDictionary]$Data
	)
	try {
		Write-IaLog -Message $Message -Level $Level -Data $Data -ErrorAction Stop
	}
	catch {
		Write-Verbose "IndexAdvisor LLM: $Message"
	}
}

function Get-IaLlmValue {
	<# Внутрішня: значення ключа словника або властивості об'єкта без урахування регістру; $null, якщо немає. #>
	param(
		[AllowNull()]$InputObject,
		[Parameter(Mandatory)][string]$Name
	)
	if ($null -eq $InputObject) {
		return $null
	}
	if ($InputObject -is [System.Collections.IDictionary]) {
		if ($InputObject.Contains($Name)) {
			return , $InputObject[$Name]
		}
		foreach ($key in $InputObject.Keys) {
			if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
				return , $InputObject[$key]
			}
		}
		return $null
	}
	if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) {
		return $null
	}
	$property = $InputObject.PSObject.Properties[$Name]
	if ($null -ne $property) {
		return , $property.Value
	}
	return $null
}

function ConvertTo-IaLlmBool {
	<# Внутрішня: значення конфігурації -> bool (рядок 'true' теж вважається істиною). #>
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return $false
	}
	if ($Value -is [bool]) {
		return $Value
	}
	if ($Value -is [string]) {
		return $Value.Trim() -in @('true', '1', 'yes', 'on')
	}
	return [bool]$Value
}

function Get-IaLlmNormalizedKey {
	<# Внутрішня: ключ без '_', '-', пробілів, у нижньому регістрі (index_name -> indexname). #>
	param([AllowNull()][AllowEmptyString()][string]$Key)
	if ([string]::IsNullOrEmpty($Key)) {
		return ''
	}
	return ($Key -replace '[_\s\-]', '').ToLowerInvariant()
}

function Test-IaLlmList {
	<# Внутрішня: $true для масивів і списків (але не рядків і не словників). #>
	param([AllowNull()]$Value)
	return ($null -ne $Value) -and ($Value -is [System.Collections.IList]) -and ($Value -isnot [string]) -and ($Value -isnot [System.Collections.IDictionary])
}

function ConvertTo-IaLlmPlainValue {
	<# Внутрішня: глибока копія JSON-сумісного значення: словники й PSCustomObject -> [ordered], списки -> масиви,
	   дати -> рядки ISO 8601 UTC. #>
	param([AllowNull()]$Value)
	if ($null -eq $Value -or $Value -is [System.DBNull]) {
		return $null
	}
	if ($Value -is [string]) {
		return $Value
	}
	if ($Value -is [datetime] -or $Value -is [System.DateTimeOffset]) {
		return (ConvertTo-IaUtcString -Date $Value)
	}
	if ($Value -is [System.Collections.IDictionary]) {
		$copy = [ordered]@{}
		foreach ($key in $Value.Keys) {
			$copy[[string]$key] = ConvertTo-IaLlmPlainValue -Value $Value[$key]
		}
		return $copy
	}
	if (Test-IaLlmList -Value $Value) {
		$items = [System.Collections.Generic.List[object]]::new()
		foreach ($item in $Value) {
			$items.Add((ConvertTo-IaLlmPlainValue -Value $item))
		}
		return , $items.ToArray()
	}
	if ($Value -is [System.Management.Automation.PSCustomObject]) {
		$copy = [ordered]@{}
		foreach ($property in $Value.PSObject.Properties) {
			$copy[$property.Name] = ConvertTo-IaLlmPlainValue -Value $property.Value
		}
		return $copy
	}
	return $Value
}

function ConvertTo-IaLlmUtcDate {
	<# Внутрішня: рядок ISO 8601 або дата -> [datetime] UTC; $null, якщо не вдалося. #>
	param([AllowNull()]$Value)
	if ($null -eq $Value) {
		return $null
	}
	if ($Value -is [System.DateTimeOffset]) {
		return $Value.UtcDateTime
	}
	if ($Value -is [datetime]) {
		if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
			return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
		}
		return $Value.ToUniversalTime()
	}
	$parsed = [System.DateTimeOffset]::MinValue
	if ([System.DateTimeOffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
		return $parsed.UtcDateTime
	}
	return $null
}

function ConvertTo-IaLlmJson {
	<# Внутрішня: компактний JSON для моделі й оцінки токенів. #>
	param([AllowNull()]$Value)
	return (ConvertTo-Json -InputObject $Value -Depth 50 -Compress)
}
