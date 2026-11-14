#Requires -Version 7.2

<#
.SYNOPSIS
	Збирає графічний інтерфейс IndexAdvisor (src\IndexAdvisor.Gui) в exe.

.DESCRIPTION
	За замовчуванням — один файл «все в одному» (-Mode SingleFile): невеликий самодостатній лаунчер
	(src\IndexAdvisor.Launcher) з архівом програми всередині — .NET 10, PowerShell 7.6 (SDK) і копія модуля IndexAdvisor.
	На машині DBA не потрібні ні .NET, ні pwsh. Під час першого запуску версії exe розпаковує програму в
	%LOCALAPPDATA%\IndexAdvisor\app\<версія> (близько 220 МБ, 2–3 с), прибирає там інші версії й розпакування exe
	до 0.3.0 у %TEMP%\.net, а далі лише запускає звідти IndexAdvisor.Gui.exe. Залежності модуля з PowerShell Gallery
	програма шукає насамперед у %LOCALAPPDATA%\IndexAdvisor\Modules і вміє встановити їх туди (вкладка «Параметри»).

	Інші режими — тека з IndexAdvisor.Gui.exe і копією модуля в Modules\IndexAdvisor (працює з того місця, куди її
	розпакували):
	  SelfContained       з .NET усередині;
	  FrameworkDependent  без .NET, потрібен .NET 10 Desktop Runtime.

	Результат — у -OutputPath (за замовчуванням dist у корені репозиторію, git його ігнорує):
	  SingleFile          IndexAdvisor-<версія>-<rid>.exe
	  SelfContained       IndexAdvisor-<версія>-<rid>\
	  FrameworkDependent  IndexAdvisor-<версія>-<rid>-fx\
	Версія — <Version> з src\IndexAdvisor.Gui\IndexAdvisor.Gui.csproj. Попередній результат того самого режиму
	видаляється перед збиранням.

	Опублікована програма завжди бере свою копію модуля (Modules\IndexAdvisor), навіть якщо лежить у репозиторії;
	живий src\IndexAdvisor бере лише збірка для розробки (dotnet run, dotnet build, тести).

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

	Один exe: dist\IndexAdvisor-0.3.0-win-x64.exe.

.EXAMPLE
	./build.ps1 -Mode All -Test -Zip

	Тести GUI, потім exe, IndexAdvisor-0.3.0-win-x64.zip, IndexAdvisor-0.3.0-win-x64-fx.zip і SHA256SUMS.txt.

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
$launcherProject = Join-Path $PSScriptRoot 'src\IndexAdvisor.Launcher\IndexAdvisor.Launcher.csproj'
$testProject = Join-Path $PSScriptRoot 'tests\Gui\IndexAdvisor.Gui.Tests\IndexAdvisor.Gui.Tests.csproj'
$manifest = Join-Path $PSScriptRoot 'src\IndexAdvisor\IndexAdvisor.psd1'
$launcherExeName = 'IndexAdvisor.Launcher.exe'
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
	# Опублікована програма бере лише свою копію модуля (без шляху до src\IndexAdvisor цього репозиторію).
	$publish = @('publish', $project, '-c', $Configuration, '-r', $Runtime, '-nologo', '-p:UseRepositoryModule=false')
	switch ($current) {
		'SingleFile' {
			# Програма (тека SelfContained) -> zip -> ресурс лаунчера; проміжне — у тимчасовій теці поруч.
			$target = Join-Path $OutputPath "$baseName.exe"
			$workDir = Join-Path $OutputPath ".publish-$baseName-single"
			$appDir = Join-Path $workDir 'app'
			$launcherDir = Join-Path $workDir 'launcher'
			$payload = Join-Path $workDir 'payload.zip'
			Remove-Output -Path $target
			Remove-Output -Path $workDir
			Invoke-Dotnet -Arguments ($publish + @('--self-contained', 'true', '-o', $appDir))
			if (-not (Test-Path -LiteralPath (Join-Path $appDir 'Modules\IndexAdvisor\IndexAdvisor.psd1'))) {
				throw "У програмі немає Modules\IndexAdvisor ($appDir)."
			}
			[System.IO.Compression.ZipFile]::CreateFromDirectory($appDir, $payload, [System.IO.Compression.CompressionLevel]::Optimal, $false)
			# Ідентифікатор збірки: лаунчер не розпаковує ту саму збірку вдруге й замінює іншу збірку тієї самої версії.
			$payloadId = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()
			Invoke-Dotnet -Arguments @(
				'publish', $launcherProject, '-c', $Configuration, '-r', $Runtime, '-nologo',
				'-p:PublishSingleFile=true', "-p:Version=$version", "-p:PayloadPath=$payload", "-p:PayloadId=$payloadId",
				'-o', $launcherDir)
			# Лаунчер нічого не розпаковує поруч із собою: крім exe, допустимі лише символи налагодження.
			$extra = @(Get-ChildItem -LiteralPath $launcherDir | Where-Object { $_.Name -ne $launcherExeName -and $_.Extension -ne '.pdb' })
			if ($extra) {
				throw "Exe вийшов не самодостатнім, поруч лишилися: $($extra.Name -join ', ') ($launcherDir)."
			}
			Move-Item -LiteralPath (Join-Path $launcherDir $launcherExeName) -Destination $target
			Remove-Output -Path $workDir
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
