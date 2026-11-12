using System.Windows;
using System.Windows.Controls;
using IndexAdvisor.Gui.Infrastructure;

namespace IndexAdvisor.Gui.Dialogs;

/// <summary>Вибір шаблону та цілі (сервери, бази) для нової конфігурації.</summary>
public sealed record NewFromTemplateRequest(ConfigTemplate Template, string? Servers, string? Databases, string? SavePath);

public partial class NewFromTemplateDialog : Window
{
	private readonly string _folder;
	private NewFromTemplateRequest? _result;

	private NewFromTemplateDialog(string folder, string? suggestedDirectory)
	{
		InitializeComponent();
		_folder = folder;
		SuggestedDirectory = suggestedDirectory;
		Reload(null);
		TemplateList.SelectionChanged += (_, _) => DeleteButton.IsEnabled = TemplateList.SelectedItem is ConfigTemplate { IsBuiltIn: false };
		Loaded += (_, _) => ServersBox.Focus();
		UpdateHints();
	}

	private string? SuggestedDirectory { get; }

	public static NewFromTemplateRequest? Show(Window? owner, string folder, string? suggestedDirectory, string? selectName = null)
	{
		var dialog = new NewFromTemplateDialog(folder, suggestedDirectory);
		if (owner is { IsLoaded: true })
		{
			dialog.Owner = owner;
		}
		else
		{
			dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
		}
		if (selectName is not null)
		{
			dialog.Reload(selectName);
		}
		return dialog.ShowDialog() == true ? dialog._result : null;
	}

	private void Reload(string? selectName)
	{
		var templates = TemplateStore.List(_folder);
		TemplateList.ItemsSource = templates;
		// Користувацький шаблон зручніший за стандартний: його вибрано першим, якщо він є.
		TemplateList.SelectedItem = templates.FirstOrDefault(item => item.Name == selectName)
			?? templates.FirstOrDefault(item => !item.IsBuiltIn)
			?? templates[0];
	}

	private void OnCreate(object sender, RoutedEventArgs e)
	{
		if (TemplateList.SelectedItem is not ConfigTemplate template)
		{
			ShowError("Виберіть шаблон.");
			return;
		}
		var path = PathBox.Text.Trim().Trim('"');
		if (path.Length > 0)
		{
			if (!Path.IsPathFullyQualified(path))
			{
				ShowError("Вкажіть повний шлях до файлу або залиште поле порожнім.");
				return;
			}
			if (File.Exists(path) && MessageBox.Show(this, $"Файл уже існує:{Environment.NewLine}{path}{Environment.NewLine}{Environment.NewLine}Перезаписати?",
					Title, MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
			{
				return;
			}
		}
		_result = new NewFromTemplateRequest(template, NullIfEmpty(ServersBox.Text), NullIfEmpty(DatabasesBox.Text), path.Length > 0 ? path : null);
		DialogResult = true;
	}

	private void OnBrowse(object sender, RoutedEventArgs e)
	{
		var name = Core.CommandLineBuilder.SplitList(ServersBox.Text).FirstOrDefault() is { } server
			? TemplateStore.ToFileName(server)
			: "run.yaml";
		var dialog = new Microsoft.Win32.SaveFileDialog
		{
			Filter = DialogService.YamlFilter,
			FileName = name,
			OverwritePrompt = false,
			Title = "Файл нової конфігурації",
		};
		if (SuggestedDirectory is { } directory && Directory.Exists(directory))
		{
			dialog.InitialDirectory = directory;
		}
		if (dialog.ShowDialog(this) == true)
		{
			PathBox.Text = dialog.FileName;
		}
	}

	private void OnOpenFolder(object sender, RoutedEventArgs e)
	{
		Directory.CreateDirectory(_folder);
		DialogService.OpenWithShell(_folder);
	}

	private void OnDelete(object sender, RoutedEventArgs e)
	{
		if (TemplateList.SelectedItem is not ConfigTemplate { IsBuiltIn: false, Path: { } path } template)
		{
			return;
		}
		if (MessageBox.Show(this, $"Видалити шаблон «{template.Name}»?{Environment.NewLine}{path}", Title,
				MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
		{
			return;
		}
		try
		{
			File.Delete(path);
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			ShowError(ex.Message);
		}
		Reload(null);
	}

	private void OnTextChanged(object sender, TextChangedEventArgs e) => UpdateHints();

	private void UpdateHints()
	{
		ServersHint.Visibility = ServersBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
		DatabasesHint.Visibility = DatabasesBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
		PathHint.Visibility = PathBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
	}

	private void ShowError(string message)
	{
		ErrorText.Text = message;
		ErrorText.Visibility = Visibility.Visible;
	}

	private static string? NullIfEmpty(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
}
