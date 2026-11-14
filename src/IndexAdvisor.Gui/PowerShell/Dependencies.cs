using System.Text.Json;

namespace IndexAdvisor.Gui.PowerShell;

/// <summary>Модуль PowerShell Gallery, потрібний модулю IndexAdvisor.</summary>
/// <param name="Name">Ім'я модуля й пакета PowerShell Gallery.</param>
/// <param name="Purpose">Навіщо він модулю.</param>
/// <param name="Required">false — потрібен лише за певного налаштування (сховище секретів).</param>
public sealed record DependencyInfo(string Name, string Purpose, bool Required);

/// <summary>Що знайшов Get-Module -ListAvailable: перша копія — та, яку візьме Import-Module.</summary>
public sealed class DependencyModuleStatus
{
	public string Name { get; init; } = string.Empty;
	public string? Version { get; init; }
	public string? Path { get; init; }
	public int Copies { get; init; }
}

/// <summary>Залежності й тека пошуку вбудованого PowerShell.</summary>
public sealed class DependencyReport
{
	/// <summary>PSModulePath runspace у порядку пошуку.</summary>
	public string[] ModulePath { get; init; } = [];
	public DependencyModuleStatus[] Modules { get; init; } = [];
}

public static class Dependencies
{
	/// <summary>
	/// Порядок важливий для встановлення: dbatools.library — до dbatools (RequiredModules), SecretManagement — до SecretStore.
	/// </summary>
	public static IReadOnlyList<DependencyInfo> All { get; } =
	[
		new("powershell-yaml", "розбір YAML конфігурації", Required: true),
		new("Microsoft.PowerShell.SecretManagement", "паролі SQL і ключі LLM (secret:)", Required: true),
		new("Microsoft.PowerShell.SecretStore", "сховище секретів за замовчуванням; не потрібне з іншим сховищем SecretManagement", Required: false),
		new("dbatools.library", "ScriptDom і SqlClient, разом із dbatools", Required: true),
		new("dbatools", "підключення до SQL Server", Required: true),
	];

	/// <summary>Та сама дія в сесії PowerShell (pwsh або Windows PowerShell 5.1), напр. з внутрішнім репозиторієм.</summary>
	public static string SaveModuleCommand(string directory)
	{
		var path = $"'{directory.Replace("'", "''", StringComparison.Ordinal)}'";
		// Save-Module вимагає наявної теки.
		return $"New-Item -ItemType Directory -Force -Path {path} | Out-Null; " +
			$"Save-Module -Name {string.Join(", ", All.Select(item => item.Name))} -Path {path} -Repository PSGallery";
	}

	/// <summary>
	/// Get-Module -ListAvailable іде в порядку PSModulePath, а в межах теки — від новішої версії;
	/// Import-Module бере першу знайдену копію.
	/// </summary>
	internal const string CheckScript = """
		param([Parameter(Mandatory)][string[]]$Names)
		[ordered]@{
			modulePath = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })
			modules = @(foreach ($name in $Names) {
				$found = @(Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue)
				[ordered]@{
					name = $name
					version = if ($found.Count -gt 0) { [string]$found[0].Version } else { $null }
					path = if ($found.Count -gt 0) { [string]$found[0].ModuleBase } else { $null }
					copies = $found.Count
				}
			})
		} | ConvertTo-Json -Depth 4 -Compress
		""";

	public static async Task<DependencyReport> CheckAsync(PowerShellRunner runner, CancellationToken cancellationToken = default)
	{
		var output = await runner.InvokeAsync(
			CheckScript,
			new Dictionary<string, object?> { ["Names"] = All.Select(item => item.Name).ToArray() },
			null,
			cancellationToken);
		var json = output.LastOrDefault()?.BaseObject as string
			?? throw new InvalidOperationException("Перевірка залежностей не повернула результату.");
		return JsonSerializer.Deserialize<DependencyReport>(json, IndexAdvisorService.JsonOptions)
			?? throw new InvalidOperationException("Порожній результат перевірки залежностей.");
	}
}
