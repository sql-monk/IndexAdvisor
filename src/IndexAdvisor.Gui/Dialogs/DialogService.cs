using System.Windows;
using Microsoft.Win32;

namespace IndexAdvisor.Gui.Dialogs;

/// <summary>Стандартні діалоги Windows для моделей подання.</summary>
public static class DialogService
{
	public const string YamlFilter = "Конфігурація YAML (*.yaml;*.yml)|*.yaml;*.yml|Усі файли (*.*)|*.*";
	public const string ArchiveFilter = "Архів запуску (*.zip)|*.zip|Усі файли (*.*)|*.*";
	public const string JsonFilter = "Результат запуску (result.json)|*.json|Усі файли (*.*)|*.*";
	public const string SqlFilter = "Скрипт T-SQL (*.sql)|*.sql|Усі файли (*.*)|*.*";

	private static Window? Owner => Application.Current?.MainWindow;

	public static string? OpenFile(string filter, string? initialPath = null, string? title = null)
	{
		var dialog = new OpenFileDialog { Filter = filter, Title = title ?? "Відкрити", CheckFileExists = true };
		ApplyInitialDirectory(dialog, initialPath);
		return dialog.ShowDialog(Owner) == true ? dialog.FileName : null;
	}

	public static string? SaveFile(string filter, string? suggestedPath = null, string? title = null)
	{
		var dialog = new SaveFileDialog { Filter = filter, Title = title ?? "Зберегти", OverwritePrompt = true };
		if (!string.IsNullOrWhiteSpace(suggestedPath))
		{
			dialog.FileName = Path.GetFileName(suggestedPath);
		}
		ApplyInitialDirectory(dialog, suggestedPath);
		return dialog.ShowDialog(Owner) == true ? dialog.FileName : null;
	}

	public static string? PickFolder(string? initialPath = null, string? title = null)
	{
		var dialog = new OpenFolderDialog { Title = title ?? "Вибрати теку" };
		if (!string.IsNullOrWhiteSpace(initialPath) && Directory.Exists(initialPath))
		{
			dialog.InitialDirectory = initialPath;
		}
		return dialog.ShowDialog(Owner) == true ? dialog.FolderName : null;
	}

	public static MessageBoxResult Ask(string message, string caption, MessageBoxButton buttons = MessageBoxButton.YesNo, MessageBoxImage image = MessageBoxImage.Question)
		=> Owner is { } owner
			? MessageBox.Show(owner, message, caption, buttons, image)
			: MessageBox.Show(message, caption, buttons, image);

	public static void Info(string message, string caption = "IndexAdvisor")
		=> Ask(message, caption, MessageBoxButton.OK, MessageBoxImage.Information);

	public static void Error(string message, string caption = "IndexAdvisor")
		=> Ask(message, caption, MessageBoxButton.OK, MessageBoxImage.Error);

	/// <summary>Відкриває файл або теку програмою за замовчуванням (report.html — у браузері).</summary>
	public static void OpenWithShell(string path)
	{
		if (!File.Exists(path) && !Directory.Exists(path))
		{
			Error($"Не знайдено: {path}");
			return;
		}
		System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
	}

	private static void ApplyInitialDirectory(FileDialog dialog, string? path)
	{
		if (string.IsNullOrWhiteSpace(path))
		{
			return;
		}
		var directory = Directory.Exists(path) ? path : Path.GetDirectoryName(path);
		if (!string.IsNullOrWhiteSpace(directory) && Directory.Exists(directory))
		{
			dialog.InitialDirectory = directory;
		}
	}
}
