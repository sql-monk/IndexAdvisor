using System.Text.Json;
using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>
/// Налаштування користувача: %APPDATA%\IndexAdvisor\gui-settings.json.
/// Секретів тут немає: лише шляхи, імена серверів і параметри форми.
/// </summary>
public sealed class AppSettings
{
	private static readonly JsonSerializerOptions JsonOptions = new()
	{
		WriteIndented = true,
		Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() },
	};

	public static string FilePath { get; } = Path.Combine(
		Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
		"IndexAdvisor",
		"gui-settings.json");

	/// <summary>Явний шлях до IndexAdvisor.psd1; порожньо — автоматичний пошук.</summary>
	public string? ModulePath { get; set; }

	public string? ResultsRoot { get; set; }

	public List<string> RecentConfigs { get; set; } = [];

	public RunOptions RunOptions { get; set; } = new();

	// Параметри програми (вкладка «Параметри»).

	public AppTheme Theme { get; set; } = AppTheme.System;

	/// <summary>Політика виконання вбудованого PowerShell для процесу: RemoteSigned, AllSigned, Unrestricted, Bypass.</summary>
	public string ExecutionPolicy { get; set; } = "RemoteSigned";

	/// <summary>Розмір шрифту журналу й редакторів.</summary>
	public double FontSize { get; set; } = 13;

	public bool LogWordWrap { get; set; } = true;

	public int MaxLogLines { get; set; } = 20000;

	/// <summary>Перевіряти конфігурацію (Test-IaConfig) одразу після вибору файлу.</summary>
	public bool AutoValidateConfig { get; set; } = true;

	/// <summary>Блимати кнопкою на панелі завдань, коли модуль чекає на відповідь.</summary>
	public bool FlashOnPrompt { get; set; } = true;

	public bool SoundOnFinish { get; set; }

	/// <summary>Перейти на вкладку «Результати» після запуску з результатами.</summary>
	public bool OpenResultsAfterRun { get; set; }

	/// <summary>Глибина пошуку result.json у каталозі результатів.</summary>
	public int ResultsScanDepth { get; set; } = 3;

	/// <summary>Вкладка редактора конфігурації за замовчуванням: форма (true) або текст YAML.</summary>
	public bool ConfigFormFirst { get; set; } = true;

	/// <summary>Тека шаблонів конфігурацій; порожньо — %APPDATA%\IndexAdvisor\templates.</summary>
	public string? TemplatesFolder { get; set; }

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
