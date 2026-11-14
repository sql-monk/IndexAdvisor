using System.Reflection;
using System.Text.RegularExpressions;

namespace IndexAdvisor.Gui.PowerShell;

/// <summary>Звідки взято модуль IndexAdvisor.</summary>
public enum ModuleSource
{
	/// <summary>Вибраний на вкладці «Параметри».</summary>
	Configured,

	/// <summary>src\IndexAdvisor репозиторію, з якого зібрано програму (лише збірка для розробки, не publish).</summary>
	Repository,

	/// <summary>Копія Modules\IndexAdvisor у теці програми.</summary>
	Bundled,

	/// <summary>Маніфест не знайдено там, де його шукали.</summary>
	Missing,
}

/// <param name="Path">Повний шлях до IndexAdvisor.psd1 (для Missing — де його очікували).</param>
/// <param name="Source">Звідки взято модуль.</param>
/// <param name="Configured">Шлях з «Параметрів», якщо його задано.</param>
public sealed record ModuleLocation(string Path, ModuleSource Source, string? Configured)
{
	public bool Exists => Source != ModuleSource.Missing;

	public string SourceText => Source switch
	{
		ModuleSource.Configured => "вибраний у «Параметрах»",
		ModuleSource.Repository => "з репозиторію (збірка для розробки)",
		ModuleSource.Bundled => "вбудований у програму",
		_ => Configured is null ? "не знайдено" : "вибраний у «Параметрах» не знайдено",
	};
}

/// <summary>
/// Пошук маніфесту модуля IndexAdvisor і точки входу CLI. Одне правило, без пошуку вгору по теках і без PSModulePath:
/// шлях з «Параметрів» (якщо задано — лише він, без підміни іншим модулем) → src\IndexAdvisor репозиторію збірки
/// для розробки → Modules\IndexAdvisor у теці програми.
/// </summary>
public static partial class ModuleLocator
{
	public const string ManifestName = "IndexAdvisor.psd1";

	/// <summary>Ключ AssemblyMetadata зі шляхом до src\IndexAdvisor\IndexAdvisor.psd1 (див. IndexAdvisor.Gui.csproj).</summary>
	public const string RepositoryModuleKey = "IndexAdvisor.RepositoryModule";

	[GeneratedRegex(@"ModuleVersion\s*=\s*['""](?<v>[^'""]+)['""]")]
	private static partial Regex ModuleVersionPattern();

	/// <summary>Маніфест модуля, вбудованого в програму: Modules\IndexAdvisor поруч з IndexAdvisor.Gui.exe.</summary>
	public static string BundledPath { get; } = System.IO.Path.Combine(AppContext.BaseDirectory, "Modules", "IndexAdvisor", ManifestName);

	/// <summary>
	/// Живий модуль репозиторію: шлях записується в збірку під час dotnet build/run і тестів з репозиторію;
	/// у опублікованій програмі (dotnet publish, build.ps1) його немає.
	/// </summary>
	public static string? RepositoryPath { get; } = typeof(ModuleLocator).Assembly
		.GetCustomAttributes<AssemblyMetadataAttribute>()
		.FirstOrDefault(attribute => attribute.Key == RepositoryModuleKey)?.Value is { Length: > 0 } value
			? System.IO.Path.GetFullPath(value)
			: null;

	public static ModuleLocation Locate(string? configuredPath) => Locate(configuredPath, RepositoryPath, BundledPath);

	internal static ModuleLocation Locate(string? configuredPath, string? repositoryPath, string bundledPath)
	{
		if (!string.IsNullOrWhiteSpace(configuredPath))
		{
			var configured = NormalizeConfigured(configuredPath);
			// Явний вибір не підмінюється іншим модулем: зниклий шлях видно в рядку стану й у журналі.
			return new ModuleLocation(configured, File.Exists(configured) ? ModuleSource.Configured : ModuleSource.Missing, configured);
		}
		if (repositoryPath is not null && File.Exists(repositoryPath))
		{
			return new ModuleLocation(repositoryPath, ModuleSource.Repository, null);
		}
		return new ModuleLocation(bundledPath, File.Exists(bundledPath) ? ModuleSource.Bundled : ModuleSource.Missing, null);
	}

	/// <summary>Шлях до IndexAdvisor.psd1 за тими самими правилами (для тестів і скриптів).</summary>
	public static string Resolve(string? configuredPath) => Locate(configuredPath).Path;

	/// <summary>Тека з маніфестом або сам маніфест → повний шлях до .psd1.</summary>
	internal static string NormalizeConfigured(string configuredPath)
	{
		var path = configuredPath.Trim().Trim('"');
		if (Directory.Exists(path))
		{
			path = System.IO.Path.Combine(path, ManifestName);
		}
		return System.IO.Path.GetFullPath(path);
	}

	/// <summary>bin/IndexAdvisor.ps1 поруч із src/IndexAdvisor (лише в репозиторії).</summary>
	public static string? FindCliScript(string modulePath)
	{
		if (!File.Exists(modulePath))
		{
			return null;
		}
		var moduleDirectory = System.IO.Path.GetDirectoryName(modulePath);
		if (moduleDirectory is null)
		{
			return null;
		}
		var script = System.IO.Path.GetFullPath(System.IO.Path.Combine(moduleDirectory, "..", "..", "bin", "IndexAdvisor.ps1"));
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
			return ParseModuleVersion(File.ReadAllText(modulePath));
		}
		catch (IOException)
		{
			return null;
		}
	}

	/// <summary>ModuleVersion з тексту маніфесту .psd1.</summary>
	public static string? ParseModuleVersion(string manifestText)
	{
		var match = ModuleVersionPattern().Match(manifestText);
		return match.Success ? match.Groups["v"].Value : null;
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
