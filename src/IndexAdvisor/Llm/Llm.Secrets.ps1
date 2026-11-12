# Секрети (ТЗ розділ 5: ключі лише в захищеному сховищі або змінній середовища; CONTRACTS.md 3.4).
# Значення секретів ніколи не логуються й не потрапляють у тексти винятків.

function Test-IaSecretReference {
	<# $true, якщо рядок має формат SecretRef (а не схожий на відкритий секрет). #>
	[CmdletBinding()]
	[OutputType([bool])]
	param([AllowEmptyString()][AllowNull()][string]$Reference)
	if ([string]::IsNullOrWhiteSpace($Reference) -or $Reference.Trim() -ne $Reference) {
		return $false
	}
	if ($Reference -match '^(?i:env):[A-Za-z_][A-Za-z0-9_]*$') {
		return $true
	}
	return ($Reference -match '^(?i:secret):(?:[^/\s][^/]*/)?[^/\s][^/]*$') -and -not $Reference.EndsWith(' ')
}

function Get-IaSecret {
	<# Читає секрет за SecretRef: 'env:NAME' | 'secret:Name' | 'secret:Vault/Name' (SecretManagement: Get-Secret).
	   За замовчуванням повертає SecureString; з -AsPlainText — рядок. Кидає виняток 'IaSecretNotFound', якщо секрету немає. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Reference,
		[switch]$AsPlainText
	)
	if (-not (Test-IaSecretReference -Reference $Reference)) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaSecretNotFound' -Category InvalidArgument -Message (
			'Посилання на секрет має неправильний формат: очікується env:ІМ''Я_ЗМІННОЇ, secret:ІмяСекрету або secret:Сховище/ІмяСекрету. ' +
			'Значення не показується з міркувань безпеки; відкриті ключі в конфігурації заборонені.')))
	}
	$separator = $Reference.IndexOf(':')
	$scheme = $Reference.Substring(0, $separator).ToLowerInvariant()
	$name = $Reference.Substring($separator + 1)

	if ($scheme -eq 'env') {
		$plain = [System.Environment]::GetEnvironmentVariable($name)
		if ([string]::IsNullOrEmpty($plain)) {
			$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaSecretNotFound' -Category ObjectNotFound -Message "Змінну середовища '$name' для секрету не задано або вона порожня."))
		}
		if ($AsPlainText) {
			return $plain
		}
		return (ConvertTo-SecureString -String $plain -AsPlainText -Force)
	}

	$vault = $null
	$slash = $name.IndexOf('/')
	if ($slash -gt 0) {
		$vault = $name.Substring(0, $slash)
		$name = $name.Substring($slash + 1)
	}
	$where = if ($vault) { "у сховищі '$vault'" } else { 'у зареєстрованих сховищах SecretManagement' }
	$secretParameters = @{ Name = $name; ErrorAction = 'Stop' }
	if ($vault) {
		$secretParameters['Vault'] = $vault
	}
	$secret = $null
	try {
		$secret = Get-Secret @secretParameters
	}
	catch {
		# Текст винятку сховища не передається далі: він може містити службові подробиці сховища.
		$secret = $null
	}
	$secure = $null
	if ($secret -is [securestring]) {
		$secure = $secret
	}
	elseif ($secret -is [pscredential]) {
		$secure = $secret.Password
	}
	elseif ($secret -is [string] -and $secret.Length -gt 0) {
		$secure = ConvertTo-SecureString -String $secret -AsPlainText -Force
	}
	if ($null -eq $secure -or $secure.Length -eq 0) {
		$PSCmdlet.ThrowTerminatingError((New-IaLlmErrorRecord -ErrorId 'IaSecretNotFound' -Category ObjectNotFound -Message (
			"Секрет '$name' не знайдено $where (або він порожній чи має непідтримуваний тип). " +
			'Збережіть його командою Set-Secret і вкажіть посилання secret:Ім''я або secret:Сховище/Ім''я.')))
	}
	if ($AsPlainText) {
		return [System.Net.NetworkCredential]::new('', $secure).Password
	}
	return $secure
}
