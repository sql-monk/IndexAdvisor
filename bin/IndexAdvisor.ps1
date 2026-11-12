#Requires -Version 7.2
<#
	Точка входу IndexAdvisor для неінтерактивного запуску (SQL Agent, Rundeck, cron).
	Імпортує модуль, передає параметри Invoke-IndexAdvisor і завершує процес з кодом повернення:
	0 Success, 1 SuccessWithWarnings, 2 ConfigError, 3 ConnectionRefused, 4 CollectionFailed, 5 LlmFailed, 6 RepositoryFailed, 9 Unexpected.

	Приклади:
		pwsh -NoProfile -File bin/IndexAdvisor.ps1 -Config run.yaml -NonInteractive
		pwsh -NoProfile -File bin/IndexAdvisor.ps1 -Config run.yaml -Server SQL01 -Format Markdown,Sql,Html -NoRepository
		pwsh -NoProfile -File bin/IndexAdvisor.ps1 -Config run.yaml -FromArchive ./archive/20261110_080000_SQL01_5f0c1a2b.zip -Provider local
#>
[CmdletBinding()]
param(
	[string]$Config,
	[string[]]$Server,
	[string[]]$Database,
	[string[]]$ExcludeDatabase,
	[string[]]$Schema,
	[string[]]$ExcludeSchema,
	[string[]]$Table,
	[string[]]$ExcludeTable,
	[ValidateSet('Indexes', 'Partitioning', 'Both')][string]$Module,
	[string]$Provider,
	[string]$Model,
	[string]$CrossCheckProvider,
	[ValidateRange(1, 3650)][int]$AnalysisWindowDays,
	[string[]]$Dataset,
	[string[]]$ExcludeDataset,
	[string]$OutputPath,
	[string[]]$Format,
	[switch]$NoRepository,
	[switch]$NoArchive,
	[string]$FromArchive,
	[switch]$NonInteractive,
	[switch]$AutoApprove,
	[switch]$LocalOnly,
	[switch]$MaskNames,
	[switch]$UnsafeDisableSelectCheck,
	[switch]$UnsafeDisableMaxdop,
	[switch]$UnsafeDisableTimeouts,
	[switch]$UnsafeAllowFreeQuery,
	[switch]$AllowNonStandardLogin,
	[switch]$Maintenance
)

$exitCode = 9
try {
	$manifest = Join-Path $PSScriptRoot '..\src\IndexAdvisor\IndexAdvisor.psd1'
	Import-Module -Name $manifest -Force -ErrorAction Stop
	# Параметри, отримані через -File як рядки (наприклад, "A,B"), розбиваються на масиви.
	$arguments = @{}
	foreach ($key in $PSBoundParameters.Keys) {
		$value = $PSBoundParameters[$key]
		if ($value -is [string[]]) {
			$value = [string[]]@($value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
		}
		$arguments[$key] = $value
	}
	$global:LASTEXITCODE = 0
	Invoke-IndexAdvisor @arguments
	$exitCode = [int]$global:LASTEXITCODE
}
catch {
	[Console]::Error.WriteLine("IndexAdvisor: непередбачена помилка: $($_.Exception.Message)")
	$exitCode = 9
}
exit $exitCode
