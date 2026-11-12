using System.Reflection;
using System.Text.RegularExpressions;

namespace IndexAdvisor.Gui.PowerShell;

/// <summary>Пошук маніфесту модуля IndexAdvisor і точки входу CLI.</summary>
public static partial class ModuleLocator
{
	public const string ManifestName = "IndexAdvisor.psd1";

	/// <summary>Ім'я для Import-Module, якщо модуль установлено в PSModulePath.</summary>
	public const string ModuleName = "IndexAdvisor";

	[GeneratedRegex(@"ModuleVersion\s*=\s*['""](?<v>[^'""]+)['""]")]
	private static partial Regex ModuleVersionPattern();

	/// <summary>
	/// Порядок: шлях із налаштувань → src/IndexAdvisor у репозиторії над exe (розробка: живий код) →
	/// копія Modules/IndexAdvisor поруч з exe (опублікована тека) → ім'я модуля з PSModulePath.
	/// </summary>
	public static string Resolve(string? configuredPath)
	{
		if (!string.IsNullOrWhiteSpace(configuredPath))
		{
			var path = configuredPath.Trim().Trim('"');
			if (Directory.Exists(path))
			{
				path = Path.Combine(path, ManifestName);
			}
			if (File.Exists(path))
			{
				return Path.GetFullPath(path);
			}
		}
		for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
		{
			var candidate = Path.Combine(directory.FullName, "src", "IndexAdvisor", ManifestName);
			if (File.Exists(candidate))
			{
				return candidate;
			}
		}
		var bundled = Path.Combine(AppContext.BaseDirectory, "Modules", "IndexAdvisor", ManifestName);
		return File.Exists(bundled) ? bundled : ModuleName;
	}

	/// <summary>bin/IndexAdvisor.ps1 поруч із src/IndexAdvisor (лише в репозиторії).</summary>
	public static string? FindCliScript(string modulePath)
	{
		if (!File.Exists(modulePath))
		{
			return null;
		}
		var moduleDirectory = Path.GetDirectoryName(modulePath);
		if (moduleDirectory is null)
		{
			return null;
		}
		var script = Path.GetFullPath(Path.Combine(moduleDirectory, "..", "..", "bin", "IndexAdvisor.ps1"));
		return File.Exists(script) ? script : null;
	}

	public static string? ReadModuleVersion(string modulePath)
	{
		try
		{
			if (!File.Exists(modulePath))
			{
				return null;
			}
			var match = ModuleVersionPattern().Match(File.ReadAllText(modulePath));
			return match.Success ? match.Groups["v"].Value : null;
		}
		catch (IOException)
		{
			return null;
		}
	}

	public static string PowerShellVersion
	{
		get
		{
			var version = typeof(System.Management.Automation.PSObject).Assembly
				.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "?";
			var end = version.IndexOfAny([' ', '+']);
			return end > 0 ? version[..end] : version;
		}
	}
}
