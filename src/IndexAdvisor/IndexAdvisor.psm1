#Requires -Version 7.2
# Завантажувач модуля IndexAdvisor. Власник — оркестратор.
# Порядок тек фіксований; у кожній теці спершу завантажуються *.Stubs.ps1, потім реалізації,
# тож реалізація завжди перекриває заглушку з тим самим іменем.

$script:IaModuleRoot = $PSScriptRoot
$script:IaLoadErrors = [System.Collections.Generic.List[string]]::new()
$script:IaToolVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'IndexAdvisor.psd1')).ModuleVersion

$iaLoadOrder = @('Shared', 'Core', 'Collector', 'Tools', 'Llm', 'Rules', 'Output', 'Cli')
foreach ($iaFolder in $iaLoadOrder) {
	$iaFolderPath = Join-Path $PSScriptRoot $iaFolder
	if (-not (Test-Path -LiteralPath $iaFolderPath)) {
		continue
	}
	$iaFiles = Get-ChildItem -LiteralPath $iaFolderPath -Filter '*.ps1' -File -Recurse |
		Sort-Object @{ Expression = { $_.Name -notlike '*.Stubs.ps1' } }, FullName
	foreach ($iaFile in $iaFiles) {
		try {
			. $iaFile.FullName
		}
		catch {
			$script:IaLoadErrors.Add("$($iaFile.FullName): $($_.Exception.Message)")
			Write-Warning "IndexAdvisor: не вдалося завантажити '$($iaFile.Name)': $($_.Exception.Message)"
		}
	}
}
Remove-Variable -Name iaLoadOrder, iaFolder, iaFolderPath, iaFiles, iaFile -ErrorAction SilentlyContinue
