@{
	RootModule = 'IndexAdvisor.psm1'
	ModuleVersion = '0.1.0'
	GUID = 'b3f1c2a4-7d5e-4c8a-9f21-6a0e5d4c3b21'
	Author = 'IndexAdvisor'
	CompanyName = 'IndexAdvisor'
	Copyright = '(c) IndexAdvisor'
	Description = 'AI Index Advisor: read-only аналіз індексів SQL Server 2019+ з використанням LLM. Програма ніколи не змінює цільові бази.'
	PowerShellVersion = '7.2'
	CompatiblePSEditions = @('Core')
	RequiredModules = @('powershell-yaml', 'Microsoft.PowerShell.SecretManagement')
	FunctionsToExport = @(
		'Invoke-IndexAdvisor'
		'New-IaConfigTemplate'
		'Test-IaConfig'
		'Install-IaServiceLogin'
		'New-IaIndexMaintenance'
	)
	CmdletsToExport = @()
	VariablesToExport = @()
	AliasesToExport = @()
	PrivateData = @{
		PSData = @{
			Tags = @('SqlServer', 'Index', 'LLM', 'QueryStore', 'dbatools')
			# dbatools завантажується ліниво (лише для реальних підключень і скрипта логіна), щоб юніт-тести працювали швидко.
			ExternalModuleDependencies = @('dbatools')
		}
	}
}
