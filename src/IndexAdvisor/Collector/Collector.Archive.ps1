# Локальний ZIP-архів запуску (ТЗ 4.2; CONTRACTS.md 5.12): manifest.json, snapshot.json, prompts/<templateId>.json.
# Мапа маскування — поруч із ZIP у <ім'я>.map.json. Каталог обмежено правами NTFS (archive.restrictAcl).

$script:IaColArchiveNamePattern = '^\d{8}_\d{6}_.+\.(zip|map\.json)$'
$script:IaColUnmaskedWarning = 'Архів містить немасковані тексти запитів і структуру баз; його не можна передавати в зовнішні сервіси без перевірки.'

function Resolve-IaColArchivePath {
	<# Повний шлях каталогу архівів (відносний — від поточного каталогу). #>
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$path = [string]$Config.archive.path
	if ([string]::IsNullOrWhiteSpace($path)) {
		$path = './archive'
	}
	return [System.IO.Path]::GetFullPath($path, (Get-Location -PSProvider FileSystem).ProviderPath)
}

function Set-IaColRestrictedAcl {
	<# NTFS: лише поточний користувач, SYSTEM і Administrators, без успадкування. Не Windows — попередження. #>
	param([Parameter(Mandatory)][string]$Path)
	if (-not $IsWindows) {
		Write-Warning ("Обмеження NTFS для '{0}' не застосовано: підтримується лише Windows." -f $Path)
		return
	}
	$security = [System.Security.AccessControl.DirectorySecurity]::new()
	$security.SetAccessRuleProtection($true, $false)
	$inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
	$identities = @(
		[System.Security.Principal.WindowsIdentity]::GetCurrent().User
		[System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
		[System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
	)
	foreach ($sid in $identities) {
		$rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
			[System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
		$security.AddAccessRule($rule)
	}
	[System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($Path), $security)
}

function Initialize-IaColArchiveDirectory {
	<# Створює каталог архівів з обмеженням NTFS; наявний каталог без обмеження — попередження (права не змінюються). #>
	param([Parameter(Mandatory)][string]$Path, [bool]$RestrictAcl)
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
		[void][System.IO.Directory]::CreateDirectory($Path)
		if ($RestrictAcl) {
			Set-IaColRestrictedAcl -Path $Path
		}
		return
	}
	if ($RestrictAcl -and $IsWindows) {
		$acl = [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]::new($Path))
		if (-not $acl.AreAccessRulesProtected) {
			Write-Warning ("Каталог архівів '{0}' уже існує й успадковує права: доступ не обмежено правами NTFS, перевірте права вручну." -f $Path)
		}
	}
}

function ConvertTo-IaColFileNamePart {
	<# Безпечна частина імені файлу (ім'я сервера з '\' тощо). #>
	param([AllowEmptyString()][string]$Text)
	$invalid = [regex]::Escape(-join [System.IO.Path]::GetInvalidFileNameChars())
	$safe = [regex]::Replace([string]$Text, "[$invalid\s]", '_')
	if ([string]::IsNullOrEmpty($safe)) {
		return 'server'
	}
	return $safe
}

function Write-IaColJsonFile {
	param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowNull()]$Value)
	$json = ConvertTo-Json -InputObject $Value -Depth 50
	[System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Save-IaSnapshotArchive {
	<# Один ZIP на запуск (Compress-Archive): snapshot.json, prompts/<templateId>.json (кожен Prompt), manifest.json.
	   Snapshot і Prompts передаються вже в тому вигляді, в якому йдуть у модель (масковані, якщо маскування ввімкнене).
	   Мапа маскування (якщо є) зберігається ПОРУЧ із ZIP у <ім'я>.map.json, не всередині. Повертає шлях або $null, якщо archive.enabled = $false. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
		[System.Collections.IDictionary[]]$Prompts = @(),
		[System.Collections.IDictionary]$MaskingMap,
		[Parameter(Mandatory)][string]$RunId,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Config
	)
	if (-not (ConvertTo-IaColBool $Config.archive.enabled -Default $true)) {
		Write-Verbose 'Архів вимкнено (archive.enabled = false).'
		return $null
	}
	$directory = Resolve-IaColArchivePath -Config $Config
	Initialize-IaColArchiveDirectory -Path $directory -RestrictAcl (ConvertTo-IaColBool $Config.archive.restrictAcl -Default $true)
	$timestamp = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss', [cultureinfo]::InvariantCulture)
	$runId8 = ($RunId -replace '[^0-9A-Za-z]', '')
	$runId8 = $runId8.Substring(0, [Math]::Min(8, $runId8.Length))
	$baseName = '{0}_{1}_{2}' -f $timestamp, (ConvertTo-IaColFileNamePart ([string]$Snapshot.requestedServer)), $runId8
	$zipPath = Join-Path $directory ($baseName + '.zip')
	$mapPath = Join-Path $directory ($baseName + '.map.json')
	$masking = $Snapshot.masking
	$namesMasked = [bool]($masking -and $masking.namesMasked)
	$literalsMasked = [bool]($masking -and $masking.literalsMasked)
	$templates = @(
		foreach ($prompt in @($Prompts)) {
			if ($null -ne $prompt) {
				[ordered]@{ id = [string]$prompt.templateId; version = $prompt.templateVersion }
			}
		}
	)
	$manifest = [ordered]@{
		schemaVersion = '1.0'
		runId = $RunId
		snapshotId = [string]$Snapshot.snapshotId
		createdAtUtc = ConvertTo-IaUtcString -Date ([datetime]::UtcNow)
		toolVersion = [string]$script:IaToolVersion
		requestedServer = [string]$Snapshot.requestedServer
		namesMasked = $namesMasked
		literalsMasked = $literalsMasked
		promptTemplates = $templates
		warning = $(if ($namesMasked) { $null } else { $script:IaColUnmaskedWarning })
	}
	$staging = Join-Path $directory ('.staging_' + [guid]::NewGuid().ToString('N'))
	[void][System.IO.Directory]::CreateDirectory((Join-Path $staging 'prompts'))
	try {
		Write-IaColJsonFile -Path (Join-Path $staging 'manifest.json') -Value $manifest
		Write-IaColJsonFile -Path (Join-Path $staging 'snapshot.json') -Value $Snapshot
		$usedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($prompt in @($Prompts)) {
			if ($null -eq $prompt) {
				continue
			}
			$name = ConvertTo-IaColFileNamePart ([string]$prompt.templateId)
			$candidate = $name
			$suffix = 2
			while (-not $usedNames.Add($candidate)) {
				$candidate = '{0}_{1}' -f $name, $suffix
				$suffix++
			}
			Write-IaColJsonFile -Path (Join-Path (Join-Path $staging 'prompts') ($candidate + '.json')) -Value $prompt
		}
		Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
	}
	finally {
		Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
	}
	if ($null -ne $MaskingMap -and $MaskingMap.Count -gt 0) {
		Write-IaColJsonFile -Path $mapPath -Value $MaskingMap
	}
	if (-not $namesMasked) {
		Write-Warning ("{0} Архів: {1}" -f $script:IaColUnmaskedWarning, $zipPath)
	}
	return $zipPath
}

function ConvertTo-IaColJsonDateStrings {
	<# Запасний шлях для PowerShell без ConvertFrom-Json -DateKind: дати знову стають рядками ISO 8601 UTC. #>
	param($Value)
	if ($Value -is [datetime] -or $Value -is [System.DateTimeOffset]) {
		return ConvertTo-IaUtcString -Date $Value
	}
	if ($Value -is [System.Collections.IDictionary]) {
		foreach ($key in @($Value.Keys)) {
			$Value[$key] = ConvertTo-IaColJsonDateStrings $Value[$key]
		}
		return $Value
	}
	if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
		for ($i = 0; $i -lt $Value.Count; $i++) {
			$Value[$i] = ConvertTo-IaColJsonDateStrings $Value[$i]
		}
		return , $Value
	}
	return $Value
}

function ConvertFrom-IaColJson {
	<# JSON -> хеш-таблиці; дати лишаються рядками, як у snapshot (контракт: рядки ISO 8601 UTC). #>
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
	if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
		return , (ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 100 -DateKind String)
	}
	return , (ConvertTo-IaColJsonDateStrings (ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 100))
}

function Read-IaColZipEntryText {
	param([Parameter(Mandatory)][object]$Entry)
	$stream = $Entry.Open()
	try {
		$reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
		try {
			return $reader.ReadToEnd()
		}
		finally {
			$reader.Dispose()
		}
	}
	finally {
		$stream.Dispose()
	}
}

function Read-IaSnapshotArchive {
	<# Читає ZIP для повторного аналізу без нового збору. Повертає @{ manifest; snapshot; prompts; maskingMap (або $null) }. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)][string]$Path)
	$fullPath = [System.IO.Path]::GetFullPath($Path, (Get-Location -PSProvider FileSystem).ProviderPath)
	if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
		Stop-IaColWithError -ErrorId 'IaArchiveInvalid' -Message ("Архів не знайдено: {0}" -f $fullPath) -Category ObjectNotFound
	}
	Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.ZipFile -ErrorAction SilentlyContinue
	$manifest = $null
	$snapshot = $null
	$prompts = [System.Collections.Generic.List[object]]::new()
	try {
		$zip = [System.IO.Compression.ZipFile]::OpenRead($fullPath)
	}
	catch {
		Stop-IaColWithError -ErrorId 'IaArchiveInvalid' -Message ("Файл '{0}' не є ZIP-архівом: {1}" -f $fullPath, $_.Exception.Message) -Category InvalidData
	}
	try {
		foreach ($entry in ($zip.Entries | Sort-Object FullName)) {
			$entryName = $entry.FullName.Replace('\', '/')
			if ($entryName -eq 'manifest.json') {
				$manifest = ConvertFrom-IaColJson -Text (Read-IaColZipEntryText -Entry $entry)
			}
			elseif ($entryName -eq 'snapshot.json') {
				$snapshot = ConvertFrom-IaColJson -Text (Read-IaColZipEntryText -Entry $entry)
			}
			elseif ($entryName -like 'prompts/*.json') {
				$prompts.Add((ConvertFrom-IaColJson -Text (Read-IaColZipEntryText -Entry $entry)))
			}
		}
	}
	catch {
		Stop-IaColWithError -ErrorId 'IaArchiveInvalid' -Message ("Архів '{0}' пошкоджено: {1}" -f $fullPath, $_.Exception.Message) -Category InvalidData
	}
	finally {
		$zip.Dispose()
	}
	if ($null -eq $manifest -or $null -eq $snapshot) {
		Stop-IaColWithError -ErrorId 'IaArchiveInvalid' -Message ("Архів '{0}' не містить manifest.json або snapshot.json" -f $fullPath) -Category InvalidData
	}
	if ([string]$manifest.schemaVersion -ne '1.0') {
		Stop-IaColWithError -ErrorId 'IaArchiveInvalid' -Message ("Непідтримувана версія архіву '{0}': {1}" -f $fullPath, $manifest.schemaVersion) -Category InvalidData
	}
	$mapPath = [regex]::Replace($fullPath, '\.zip$', '', 'IgnoreCase') + '.map.json'
	$maskingMap = $null
	if (Test-Path -LiteralPath $mapPath -PathType Leaf) {
		$maskingMap = ConvertFrom-IaColJson -Text (Get-Content -LiteralPath $mapPath -Raw -Encoding utf8)
	}
	if (-not $manifest.namesMasked) {
		Write-Warning ("{0} Архів: {1}" -f $script:IaColUnmaskedWarning, $fullPath)
	}
	return [ordered]@{
		manifest = $manifest
		snapshot = $snapshot
		prompts = @($prompts.ToArray())
		maskingMap = $maskingMap
	}
}

function Remove-IaExpiredArchives {
	<# Видаляє архіви (і їхні .map.json), старші за archive.retentionDays. Повертає шляхи видалених файлів. #>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
	$directory = Resolve-IaColArchivePath -Config $Config
	if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
		return
	}
	$retentionDays = [int]$Config.archive.retentionDays
	if ($retentionDays -lt 1) {
		$retentionDays = 1
	}
	$cutoff = [datetime]::UtcNow.AddDays(-$retentionDays)
	$removed = [System.Collections.Generic.List[string]]::new()
	$files = @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -match $script:IaColArchiveNamePattern })
	$expiredZips = @($files | Where-Object { $_.Name -like '*.zip' -and $_.LastWriteTimeUtc -lt $cutoff })
	$expiredBaseNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($zip in $expiredZips) {
		[void]$expiredBaseNames.Add([System.IO.Path]::GetFileNameWithoutExtension($zip.Name))
	}
	foreach ($file in $files) {
		$isMap = $file.Name -like '*.map.json'
		$baseName = if ($isMap) { $file.Name.Substring(0, $file.Name.Length - '.map.json'.Length) } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
		$expired = ($file.LastWriteTimeUtc -lt $cutoff) -or ($isMap -and $expiredBaseNames.Contains($baseName))
		if (-not $expired) {
			continue
		}
		if ($PSCmdlet.ShouldProcess($file.FullName, 'Видалити прострочений архів')) {
			Remove-Item -LiteralPath $file.FullName -Force
			$removed.Add($file.FullName)
		}
	}
	return $removed.ToArray()
}
