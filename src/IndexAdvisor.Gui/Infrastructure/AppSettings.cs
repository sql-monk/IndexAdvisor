using System.Text.Json;
using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>
/// Налаштування користувача: %APPDATA%\IndexAdvisor\gui-settings.json.
/// Секретів тут немає: лише шляхи, імена серверів і параметри форми.
/// </summary>
public sealed class AppSettings
{
	private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

	public static string FilePath { get; } = Path.Combine(
		Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
		"IndexAdvisor",
		"gui-settings.json");

	/// <summary>Явний шлях до IndexAdvisor.psd1; порожньо — автоматичний пошук.</summary>
	public string? ModulePath { get; set; }

	public string? ResultsRoot { get; set; }

	public List<string> RecentConfigs { get; set; } = [];

	public RunOptions RunOptions { get; set; } = new();

	public static AppSettings Load()
	{
		try
		{
			if (File.Exists(FilePath))
			{
				return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), JsonOptions) ?? new AppSettings();
			}
		}
		catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
		{
			// Пошкоджений файл налаштувань не повинен заважати запуску.
		}
		return new AppSettings();
	}

	public void Save()
	{
		try
		{
			Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
			File.WriteAllText(FilePath, JsonSerializer.Serialize(this, JsonOptions));
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			// Налаштування не критичні.
		}
	}

	public void RememberConfig(string? path)
	{
		if (string.IsNullOrWhiteSpace(path))
		{
			return;
		}
		RecentConfigs.RemoveAll(item => string.Equals(item, path, StringComparison.OrdinalIgnoreCase));
		RecentConfigs.Insert(0, path);
		if (RecentConfigs.Count > 10)
		{
			RecentConfigs.RemoveRange(10, RecentConfigs.Count - 10);
		}
	}
}
