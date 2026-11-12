using System.Windows;
using IndexAdvisor.Gui.Infrastructure;

namespace IndexAdvisor.Gui.Dialogs;

public sealed record SaveTemplateRequest(string Name, string? Description, bool WithoutServers, bool WithoutDatabases, string Path);

public partial class SaveTemplateDialog : Window
{
	private readonly string _folder;
	private SaveTemplateRequest? _result;

	private SaveTemplateDialog(string folder, string? suggestedName)
	{
		InitializeComponent();
		_folder = folder;
		NameBox.Text = suggestedName ?? string.Empty;
		FolderText.Text = "Тека шаблонів: " + folder + " (змінити — на вкладці «Параметри»)";
		Loaded += (_, _) =>
		{
			NameBox.Focus();
			NameBox.SelectAll();
		};
	}

	public static SaveTemplateRequest? Show(Window? owner, string folder, string? suggestedName)
	{
		var dialog = new SaveTemplateDialog(folder, suggestedName);
		if (owner is { IsLoaded: true })
		{
			dialog.Owner = owner;
		}
		else
		{
			dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
		}
		return dialog.ShowDialog() == true ? dialog._result : null;
	}

	private void OnSave(object sender, RoutedEventArgs e)
	{
		var name = NameBox.Text.Trim();
		if (name.Length == 0)
		{
			ErrorText.Text = "Вкажіть назву шаблону.";
			ErrorText.Visibility = Visibility.Visible;
			return;
		}
		var path = TemplateStore.PathFor(_folder, name);
		if (File.Exists(path) && MessageBox.Show(this, $"Шаблон «{name}» уже існує. Замінити?", Title,
				MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
		{
			return;
		}
		_result = new SaveTemplateRequest(
			name,
			string.IsNullOrWhiteSpace(DescriptionBox.Text) ? null : DescriptionBox.Text.Trim(),
			WithoutServers.IsChecked == true,
			WithoutDatabases.IsChecked == true,
			path);
		DialogResult = true;
	}
}
