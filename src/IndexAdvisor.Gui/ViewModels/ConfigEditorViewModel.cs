using System.Text;
using System.Windows;
using System.Windows.Input;
using ICSharpCode.AvalonEdit.Document;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Редактор YAML-конфігурації: відкриття, шаблон (New-IaConfigTemplate), збереження, перевірка.</summary>
public sealed class ConfigEditorViewModel : ObservableObject
{
	private static readonly UTF8Encoding Utf8NoBom = new(false);

	private readonly IndexAdvisorService _service;
	private readonly AppSettings _settings;
	private string? _filePath;
	private bool _isDirty;
	private bool _isBusy;

	public ConfigEditorViewModel(IndexAdvisorService service, ConfigStateViewModel state, AppSettings settings)
	{
		_service = service;
		State = state;
		_settings = settings;
		Document.UndoStack.PropertyChanged += (_, e) =>
		{
			if (e.PropertyName == nameof(UndoStack.IsOriginalFile))
			{
				IsDirty = !Document.UndoStack.IsOriginalFile;
			}
		};
		State.PathChanged += (_, _) => OnStatePathChanged();

		OpenCommand = new RelayCommand(Open);
		NewCommand = new AsyncRelayCommand(NewFromTemplateAsync, () => !_isBusy);
		SaveCommand = new RelayCommand(() => Save(), () => FilePath is not null && IsDirty);
		SaveAsCommand = new RelayCommand(() => SaveAs(), () => FilePath is not null || Document.TextLength > 0);
		ReloadCommand = new RelayCommand(Reload, () => FilePath is not null && File.Exists(FilePath));
		ValidateCommand = new AsyncRelayCommand(ValidateAsync, () => FilePath is not null && !State.IsChecking);
		GoToErrorCommand = new RelayCommand(parameter =>
		{
			if (parameter is ConfigError { Line: int line } error)
			{
				GoToLineRequested?.Invoke(this, (line, error.Column ?? 1));
			}
		});
	}

	public ConfigStateViewModel State { get; }

	public TextDocument Document { get; } = new();

	public string? FilePath
	{
		get => _filePath;
		private set
		{
			if (SetProperty(ref _filePath, value))
			{
				OnPropertyChanged(nameof(Title));
			}
		}
	}

	public bool IsDirty
	{
		get => _isDirty;
		private set
		{
			if (SetProperty(ref _isDirty, value))
			{
				OnPropertyChanged(nameof(Title));
			}
		}
	}

	public string Title => FilePath is null ? "Файл не відкрито" : FilePath + (IsDirty ? " •" : string.Empty);

	public event EventHandler<(int Line, int Column)>? GoToLineRequested;

	public ICommand OpenCommand { get; }
	public ICommand NewCommand { get; }
	public ICommand SaveCommand { get; }
	public ICommand SaveAsCommand { get; }
	public ICommand ReloadCommand { get; }
	public ICommand ValidateCommand { get; }
	public ICommand GoToErrorCommand { get; }

	/// <summary>
	/// Перед запуском чи перевіркою: якщо змінено файл, який використовує форма, — зберегти, не зберігати або скасувати.
	/// Повертає false, якщо користувач скасував.
	/// </summary>
	public bool EnsureSaved()
	{
		if (!IsDirty || FilePath is null || !string.Equals(FilePath, State.Path, StringComparison.OrdinalIgnoreCase))
		{
			return true;
		}
		var answer = DialogService.Ask(
			$"Конфігурацію змінено в редакторі:{Environment.NewLine}{FilePath}{Environment.NewLine}{Environment.NewLine}Зберегти зміни перед продовженням?",
			"Незбережені зміни",
			MessageBoxButton.YesNoCancel,
			MessageBoxImage.Question);
		return answer switch
		{
			MessageBoxResult.Yes => Save(),
			MessageBoxResult.No => true,
			_ => false,
		};
	}

	/// <summary>Для закриття вікна: питає про будь-які незбережені зміни.</summary>
	public bool ConfirmClose()
	{
		if (!IsDirty)
		{
			return true;
		}
		var answer = DialogService.Ask(
			$"Зберегти зміни в {FilePath ?? "конфігурації"}?",
			"Незбережені зміни",
			MessageBoxButton.YesNoCancel,
			MessageBoxImage.Question);
		return answer switch
		{
			MessageBoxResult.Yes => FilePath is null ? SaveAs() : Save(),
			MessageBoxResult.No => true,
			_ => false,
		};
	}

	public void Load(string path)
	{
		Document.Text = File.ReadAllText(path);
		Document.UndoStack.ClearAll();
		Document.UndoStack.MarkAsOriginalFile();
		FilePath = path;
		IsDirty = false;
	}

	private void OnStatePathChanged()
	{
		var path = State.Path;
		if (path is null || string.Equals(path, FilePath, StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
		{
			return;
		}
		if (IsDirty)
		{
			// Не втрачаємо незбережені правки іншого файлу: редактор лишається на ньому.
			return;
		}
		TryLoad(path);
	}

	private void TryLoad(string path)
	{
		try
		{
			Load(path);
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			DialogService.Error($"Не вдалося прочитати {path}: {ex.Message}");
		}
	}

	private void Open()
	{
		if (!ConfirmClose())
		{
			return;
		}
		var path = DialogService.OpenFile(DialogService.YamlFilter, FilePath ?? State.Path, "Конфігурація IndexAdvisor");
		if (path is null)
		{
			return;
		}
		TryLoad(path);
		State.Path = path;
		_settings.RememberConfig(path);
	}

	private async Task NewFromTemplateAsync()
	{
		if (!ConfirmClose())
		{
			return;
		}
		var suggested = Path.Combine(
			Path.GetDirectoryName(FilePath ?? State.Path ?? string.Empty) is { Length: > 0 } directory
				? directory
				: Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
			"run.yaml");
		var path = DialogService.SaveFile(DialogService.YamlFilter, suggested, "Новий файл конфігурації з шаблону");
		if (path is null)
		{
			return;
		}
		_isBusy = true;
		try
		{
			await _service.NewConfigTemplateAsync(path);
			TryLoad(path);
			State.Path = path;
			_settings.RememberConfig(path);
		}
		finally
		{
			_isBusy = false;
			CommandManager.InvalidateRequerySuggested();
		}
	}

	private bool Save()
	{
		if (FilePath is null)
		{
			return SaveAs();
		}
		return WriteTo(FilePath);
	}

	private bool SaveAs()
	{
		var path = DialogService.SaveFile(DialogService.YamlFilter, FilePath ?? "run.yaml", "Зберегти конфігурацію як");
		if (path is null || !WriteTo(path))
		{
			return false;
		}
		FilePath = path;
		State.Path = path;
		_settings.RememberConfig(path);
		return true;
	}

	private bool WriteTo(string path)
	{
		try
		{
			File.WriteAllText(path, Document.Text, Utf8NoBom);
			Document.UndoStack.MarkAsOriginalFile();
			IsDirty = false;
			return true;
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			DialogService.Error($"Не вдалося зберегти {path}: {ex.Message}");
			return false;
		}
	}

	private void Reload()
	{
		if (FilePath is null)
		{
			return;
		}
		if (IsDirty && DialogService.Ask("Відкинути незбережені зміни й перечитати файл?", "Перечитати", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
		{
			return;
		}
		TryLoad(FilePath);
	}

	private async Task ValidateAsync()
	{
		if (FilePath is null)
		{
			return;
		}
		if (IsDirty && !Save())
		{
			return;
		}
		State.Path = FilePath;
		var isValid = await State.ValidateAsync();
		if (!isValid && State.Errors.FirstOrDefault(error => error.Line is not null) is { } first)
		{
			GoToLineRequested?.Invoke(this, (first.Line!.Value, first.Column ?? 1));
		}
	}
}
