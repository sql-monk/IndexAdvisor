#Requires -Version 7.2

<#
.SYNOPSIS
	Збирає графічний інтерфейс IndexAdvisor (src\IndexAdvisor.Gui) в exe.

.DESCRIPTION
	За замовчуванням — один файл «все в одному» (-Mode SingleFile): .NET 10, PowerShell 7.6 (SDK) і копія модуля
	IndexAdvisor усередині exe. На машині DBA не потрібні ні .NET, ні pwsh — лише модулі PowerShell з розділу
	«Встановлення» README. Під час першого запуску exe розпаковує вміст у %TEMP%\.net\<ім'я exe>\<хеш>
	(близько 200 МБ; наступні запуски беруть його звідти, кожна нова збірка — нова тека). Інше місце задає змінна
	середовища DOTNET_BUNDLE_EXTRACT_BASE_DIR.

	Інші режими — тека з IndexAdvisor.Gui.exe і копією модуля в Modules\IndexAdvisor:
	  SelfContained       з .NET усередині;
	  FrameworkDependent  без .NET, потрібен .NET 10 Desktop Runtime.

	Результат — у -OutputPath (за замовчуванням dist у корені репозиторію, git його ігнорує):
	  SingleFile          IndexAdvisor-<версія>-<rid>.exe
	  SelfContained       IndexAdvisor-<версія>-<rid>\
	  FrameworkDependent  IndexAdvisor-<версія>-<rid>-fx\
	Версія — <Version> з src\IndexAdvisor.Gui\IndexAdvisor.Gui.csproj. Попередній результат того самого режиму
	видаляється перед збиранням.

	Exe з теки всередині репозиторію працює з живим модулем src\IndexAdvisor, а не зі своєю копією (так GUI шукає
	модуль); одиночний exe завжди бере свою копію.

	Потрібен .NET SDK 10 або новіший: https://dotnet.microsoft.com/download/dotnet/10.0

.PARAMETER Mode
	SingleFile (за замовчуванням), SelfContained, FrameworkDependent або All; кілька — через кому.

.PARAMETER Runtime
	Платформа: win-x64 (за замовчуванням) або win-arm64.

.PARAMETER Configuration
	Release (за замовчуванням) або Debug.

.PARAMETER OutputPath
	Тека результатів; за замовчуванням dist у корені репозиторію.

.PARAMETER Test
	Перед збиранням запустити тести GUI (tests\Gui\IndexAdvisor.Gui.Tests); якщо вони не пройдуть, збирання не почнеться.

.PARAMETER Zip
	Запакувати теки SelfContained і FrameworkDependent у zip і записати SHA256SUMS.txt для всіх файлів цього запуску
	(exe і zip), як у релізах GitHub.

.EXAMPLE
	./build.ps1

	Один exe: dist\IndexAdvisor-0.2.0-win-x64.exe.

.EXAMPLE
	./build.ps1 -Mode All -Test -Zip

	Тести GUI, потім exe, IndexAdvisor-0.2.0-win-x64.zip, IndexAdvisor-0.2.0-win-x64-fx.zip і SHA256SUMS.txt.

.OUTPUTS
	Для кожного результату — Mode, Path, SizeMB.
#>
[CmdletBinding()]
param(
	[ValidateSet('SingleFile', 'SelfContained', 'FrameworkDependent', 'All')]
	[string[]]$Mode = 'SingleFile',

	[ValidateSet('win-x64', 'win-arm64')]
	[string]$Runtime = 'win-x64',

	[ValidateSet('Release', 'Debug')]
	[string]$Configuration = 'Release',

	[string]$OutputPath = (Join-Path $PSScriptRoot 'dist'),

	[switch]$Test,

	[switch]$Zip
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$project = Join-Path $PSScriptRoot 'src\IndexAdvisor.Gui\IndexAdvisor.Gui.csproj'
$testProject = Join-Path $PSScriptRoot 'tests\Gui\IndexAdvisor.Gui.Tests\IndexAdvisor.Gui.Tests.csproj'
$manifest = Join-Path $PSScriptRoot 'src\IndexAdvisor\IndexAdvisor.psd1'
$exeName = 'IndexAdvisor.Gui.exe'
$sdkUrl = 'https://dotnet.microsoft.com/download/dotnet/10.0'

function Invoke-Dotnet {
	param([Parameter(Mandatory)][string[]]$Arguments)

	Write-Host "dotnet $($Arguments -join ' ')" -ForegroundColor DarkGray
	# Вивід dotnet — на екран, а не в результат скрипта (результат — лише перелік зібраного).
	& dotnet @Arguments | Out-Host
	if ($LASTEXITCODE -ne 0) {
		throw "dotnet $($Arguments[0]) завершився з кодом $LASTEXITCODE."
	}
}

function Remove-Output {
	param([Parameter(Mandatory)][string]$Path)

	if (Test-Path -LiteralPath $Path) {
		try {
			Remove-Item -LiteralPath $Path -Recurse -Force
		}
		catch {
			throw "Не вдалося видалити попередній результат $Path (програму запущено звідти?): $($_.Exception.Message)"
		}
	}
}

function Get-Size {
	param([Parameter(Mandatory)][string]$Path)

	$bytes = if (Test-Path -LiteralPath $Path -PathType Container) {
		(Get-ChildItem -LiteralPath $Path -Recurse -File | Measure-Object -Property Length -Sum).Sum
	}
	else {
		(Get-Item -LiteralPath $Path).Length
	}
	[math]::Round($bytes / 1MB, 1)
}

# .NET SDK 10 або новіший (net10.0-windows).
if (-not (Get-Command -Name dotnet -CommandType Application -ErrorAction SilentlyContinue)) {
	throw "Не знайдено dotnet. Потрібен .NET SDK 10 або новіший: $sdkUrl"
}
$sdkVersions = @(& dotnet --list-sdks | ForEach-Object { ($_ -split ' ')[0] } | Where-Object { $_ })
if (-not ($sdkVersions | Where-Object { [int](($_ -split '\.')[0]) -ge 10 })) {
	$found = if ($sdkVersions) { $sdkVersions -join ', ' } else { 'жодного' }
	throw "Потрібен .NET SDK 10 або новіший (встановлено: $found): $sdkUrl"
}

$versionNode = ([xml](Get-Content -LiteralPath $project -Raw)).SelectSingleNode('/Project/PropertyGroup/Version')
if (-not $versionNode) {
	throw "У $project немає <Version>."
}
$version = $versionNode.InnerText.Trim()
$moduleVersion = (Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion

$allModes = 'SingleFile', 'SelfContained', 'FrameworkDependent'
$modes = if ($Mode -contains 'All') { $allModes } else { $allModes | Where-Object { $_ -in $Mode } }
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$baseName = "IndexAdvisor-$version-$Runtime"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "IndexAdvisor GUI $version (модуль IndexAdvisor $moduleVersion): $($modes -join ', '); $Runtime, $Configuration -> $OutputPath" -ForegroundColor Cyan

if ($Test) {
	Write-Host ''
	Write-Host '== Тести GUI' -ForegroundColor Cyan
	Invoke-Dotnet -Arguments @('test', $testProject, '-c', $Configuration, '--nologo')
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($current in $modes) {
	Write-Host ''
	Write-Host "== $current" -ForegroundColor Cyan
	$publish = @('publish', $project, '-c', $Configuration, '-r', $Runtime, '-nologo')
	switch ($current) {
		'SingleFile' {
			# Публікація в тимчасову теку: поруч з exe не має лишитися нічого, крім символів налагодження.
			$target = Join-Path $OutputPath "$baseName.exe"
			$publishDir = Join-Path $OutputPath ".publish-$baseName-single"
			Remove-Output -Path $target
			Remove-Output -Path $publishDir
			Invoke-Dotnet -Arguments ($publish + @('--self-contained', 'true', '-p:PublishSingleFile=true', '-o', $publishDir))
			$extra = @(Get-ChildItem -LiteralPath $publishDir | Where-Object { $_.Name -ne $exeName -and $_.Extension -ne '.pdb' })
			if ($extra) {
				throw "Exe вийшов не самодостатнім, поруч лишилися: $($extra.Name -join ', ') ($publishDir)."
			}
			Move-Item -LiteralPath (Join-Path $publishDir $exeName) -Destination $target
			Remove-Output -Path $publishDir
		}
		'SelfContained' {
			$target = Join-Path $OutputPath $baseName
			Remove-Output -Path $target
			Invoke-Dotnet -Arguments ($publish + @('--self-contained', 'true', '-o', $target))
		}
		'FrameworkDependent' {
			$target = Join-Path $OutputPath "$baseName-fx"
			Remove-Output -Path $target
			Invoke-Dotnet -Arguments ($publish + @('--self-contained', 'false', '-o', $target))
		}
	}
	$results.Add([pscustomobject]@{ Mode = $current; Path = $target; SizeMB = Get-Size -Path $target })
}

if ($Zip) {
	Write-Host ''
	Write-Host '== Архіви й контрольні суми' -ForegroundColor Cyan
	foreach ($result in @($results)) {
		if (Test-Path -LiteralPath $result.Path -PathType Container) {
			$archive = "$($result.Path).zip"
			Remove-Output -Path $archive
			# Тека з іменем архіву всередині zip, як у релізах.
			[System.IO.Compression.ZipFile]::CreateFromDirectory($result.Path, $archive, [System.IO.Compression.CompressionLevel]::Optimal, $true)
			$results.Add([pscustomobject]@{ Mode = "$($result.Mode) zip"; Path = $archive; SizeMB = Get-Size -Path $archive })
		}
	}
	$sums = Join-Path $OutputPath 'SHA256SUMS.txt'
	$results |
		Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf } |
		ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.Path -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Path $_.Path -Leaf) } |
		Set-Content -LiteralPath $sums -Encoding utf8NoBOM
	Write-Host "Контрольні суми: $sums"
}

Write-Host ''
Write-Host ("Готово за {0:mm\:ss}." -f $stopwatch.Elapsed) -ForegroundColor Green
$results
