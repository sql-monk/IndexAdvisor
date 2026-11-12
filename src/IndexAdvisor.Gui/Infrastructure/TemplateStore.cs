using System.Text;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>Шаблон конфігурації: файл YAML у теці шаблонів або вбудований шаблон модуля (New-IaConfigTemplate).</summary>
public sealed record ConfigTemplate(string Name, string? Path, string Description, DateTime? Modified)
{
	public bool IsBuiltIn => Path is null;

	public string Details => IsBuiltIn
		? Description
		: string.IsNullOrWhiteSpace(Description)
			? $"змінено {Modified:yyyy-MM-dd HH:mm}"
			: $"{Description} · змінено {Modified:yyyy-MM-dd HH:mm}";
}

/// <summary>
/// Шаблони конфігурацій: звичайні YAML-файли в теці (типово %APPDATA%\IndexAdvisor\templates; можна вказати спільну теку команди).
/// Шаблон зазвичай зберігається без серверів і баз — їх підставляють під час створення конфігурації.
/// </summary>
public static class TemplateStore
{
	private const string DescriptionPrefix = "# Опис:";

	public static string DefaultFolder { get; } = Path.Combine(
		Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
		"IndexAdvisor",
		"templates");

	public static ConfigTemplate BuiltIn { get; } = new(
		"Стандартний шаблон модуля",
		null,
		"New-IaConfigTemplate: усі параметри зі значеннями за замовчуванням",
		null);

	public static string Folder(AppSettings settings)
		=> string.IsNullOrWhiteSpace(settings.TemplatesFolder) ? DefaultFolder : settings.TemplatesFolder.Trim();

	/// <summary>Вбудований шаблон першим, далі файли теки за назвою.</summary>
	public static IReadOnlyList<ConfigTemplate> List(string folder)
	{
		var templates = new List<ConfigTemplate> { BuiltIn };
		if (!Directory.Exists(folder))
		{
			return templates;
		}
		var files = Directory.EnumerateFiles(folder, "*.yaml")
			.Concat(Directory.EnumerateFiles(folder, "*.yml"))
			.OrderBy(path => Path.GetFileNameWithoutExtension(path), StringComparer.CurrentCultureIgnoreCase);
		foreach (var file in files)
		{
			templates.Add(new ConfigTemplate(Path.GetFileNameWithoutExtension(file), file, ReadDescription(file), File.GetLastWriteTime(file)));
		}
		return templates;
	}

	/// <summary>Ім'я файлу з назви шаблону: недопустимі символи замінюються на «_».</summary>
	public static string ToFileName(string name)
	{
		var text = new StringBuilder();
		var invalid = Path.GetInvalidFileNameChars();
		foreach (var ch in name.Trim())
		{
			text.Append(invalid.Contains(ch) ? '_' : ch);
		}
		var result = text.ToString().Trim('.', ' ');
		return (result.Length == 0 ? "шаблон" : result) + ".yaml";
	}

	public static string PathFor(string folder, string name) => Path.Combine(folder, ToFileName(name));

	/// <summary>Заголовок шаблону: назва й опис у коментарях (опис показується у списку шаблонів).</summary>
	public static string Header(string name, string? description, bool withoutServers, bool withoutDatabases)
	{
		var lines = new List<string> { $"Шаблон конфігурації IndexAdvisor: {name}" };
		if (!string.IsNullOrWhiteSpace(description))
		{
			lines.Add("Опис: " + description.Trim().Replace('\n', ' ').Replace("\r", string.Empty, StringComparison.Ordinal));
		}
		if (withoutServers || withoutDatabases)
		{
			lines.Add("Без " + string.Join(" і ", new[] { withoutServers ? "серверів" : null, withoutDatabases ? "баз" : null }.Where(part => part is not null))
				+ ": їх підставляють під час створення конфігурації (IndexAdvisor GUI → «Нова з шаблону»).");
		}
		return string.Join("\n", lines);
	}

	private static string ReadDescription(string file)
	{
		try
		{
			foreach (var line in File.ReadLines(file).Take(10))
			{
				if (line.StartsWith(DescriptionPrefix, StringComparison.Ordinal))
				{
					return line[DescriptionPrefix.Length..].Trim();
				}
			}
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			return string.Empty;
		}
		return string.Empty;
	}
}
