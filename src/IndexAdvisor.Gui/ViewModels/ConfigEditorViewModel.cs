using System.Text;
using System.Windows;
using System.Windows.Input;
using ICSharpCode.AvalonEdit.Document;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels.ConfigForm;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>
/// Редактор конфігурації: форма всіх налаштувань (зі схеми модуля) і текст YAML, синхронізовані між собою;
/// відкриття, шаблон (New-IaConfigTemplate), збереження, перевірка (Test-IaConfig).
/// Форма → YAML: при переході на текст, збереженні, перевірці й запуску. YAML → форма: при переході на форму.
/// </summary>
public sealed class ConfigEditorViewModel : ObservableObject
{
	public const int FormView = 0;
	public const int TextView = 1;

	private static readonly UTF8Encoding Utf8NoBom = new(false);

	private readonly IndexAdvisorService _service;
	private readonly YamlService _yaml;
	private readonly AppSettings _settings;
	private readonly Func<string> _modulePath;
	private string? _filePath;
	private bool _isDirty;
	private bool _isBusy;
	private int _selectedView;
	private string? _formSyncedText;
	private string? _schemaPath;
	private bool _formEditable;

	public ConfigEditorViewModel(IndexAdvisorService service, YamlService yaml, ConfigStateViewModel state, AppSettings settings, Func<string> modulePath)
	{
		_service = service;
		_yaml = yaml;
		State = state;
		_settings = settings;
		_modulePath = modulePath;
		_selectedView = settings.ConfigFormFirst ? FormView : TextView;
		Document.UndoStack.PropertyChanged += (_, e) =>
		{
			if (e.PropertyName == nameof(UndoStack.IsOriginalFile))
			{
				IsDirty = !Document.UndoStack.IsOriginalFile;
			}
		};
		State.PathChanged += (_, _) => OnStatePathChanged();
		Form.Changed += (_, _) =>
		{
			OnPropertyChanged(nameof(Title));
			OnPropertyChanged(nameof(HasChanges));
			CommandManager.InvalidateRequerySuggested();
		};

		OpenCommand = new RelayCommand(Open);
		NewCommand = new AsyncRelayCommand(NewFromTemplateAsync, () => !_isBusy);
		SaveCommand = new RelayCommand(() => Save(), () => HasChanges);
		SaveAsCommand = new RelayCommand(() => SaveAs(), () => FilePath is not null || Document.TextLength > 0 || Form.IsDirty);
		ReloadCommand = new RelayCommand(Reload, () => FilePath is not null && File.Exists(FilePath));
		ValidateCommand = new AsyncRelayCommand(ValidateAsync, () => (FilePath is not null || HasChanges) && !State.IsChecking);
		SaveAsTemplateCommand = new AsyncRelayCommand(SaveAsTemplateAsync, () => !_isBusy);
		ApplyFormCommand = new RelayCommand(() => ApplyForm(), () => Form.IsDirty);
		RevertFormCommand = new AsyncRelayCommand(() => SyncFormAsync(force: true), () => Form.IsDirty);
		GoToErrorCommand = new RelayCommand(parameter =>
		{
			if (parameter is ConfigError { Line: int line } error)
			{
				SelectedView = TextView;
				GoToLineRequested?.Invoke(this, (line, error.Column ?? 1));
			}
		});
	}

	public ConfigStateViewModel State { get; }

	public TextDocument Document { get; } = new();

	public ConfigFormViewModel Form { get; } = new();

	/// <summary>0 — форма налаштувань, 1 — текст YAML.</summary>
	public int SelectedView
	{
		get => _selectedView;
		set
		{
			if (value == _selectedView)
			{
				return;
			}
			if (value == TextView && Form.IsDirty && !ApplyForm())
			{
				// Помилки у формі: лишаємося на формі (повідомлення вже показано).
				OnPropertyChanged();
				return;
			}
			_selectedView = value;
			OnPropertyChanged();
			if (value == FormView)
			{
				_ = SyncFormAsync(force: false);
			}
		}
	}

	/// <summary>Форму можна редагувати: YAML розібрано (при помилці розбору форма лише для читання).</summary>
	public bool FormEditable
	{
		get => _formEditable;
		private set => SetProperty(ref _formEditable, value);
	}

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
				OnPropertyChanged(nameof(HasChanges));
			}
		}
	}

	/// <summary>Незбережені зміни в тексті або у формі.</summary>
	public bool HasChanges => IsDirty || Form.IsDirty;

	public string Title => (FilePath ?? "Новий файл (не збережено)") + (HasChanges ? " •" : string.Empty);

	public event EventHandler<(int Line, int Column)>? GoToLineRequested;

	public ICommand OpenCommand { get; }
	public ICommand NewCommand { get; }
	public ICommand SaveCommand { get; }
	public ICommand SaveAsCommand { get; }
	public ICommand ReloadCommand { get; }
	public ICommand ValidateCommand { get; }
	public ICommand SaveAsTemplateCommand { get; }
	public ICommand ApplyFormCommand { get; }
	public ICommand RevertFormCommand { get; }
	public ICommand GoToErrorCommand { get; }

	/// <summary>Після показу вікна: схема й розбір поточного тексту для форми.</summary>
	public Task InitializeAsync() => SelectedView == FormView ? SyncFormAsync(force: true) : Task.CompletedTask;

	/// <summary>
	/// Перед запуском чи перевіркою: якщо змінено файл, який використовує форма запуску, — зберегти, не зберігати або скасувати.
	/// Повертає false, якщо користувач скасував.
	/// </summary>
	public bool EnsureSaved()
	{
		if (FilePath is null && State.Path is null && (HasChanges || Document.TextLength > 0))
		{
			// Нова конфігурація (з шаблону чи форми) ще без файлу: модуль читає конфігурацію лише з файлу.
			var save = DialogService.Ask(
				"Нову конфігурацію в редакторі ще не збережено.\n\nЗберегти її у файл і запустити з нею?\n«Ні» — запуск без конфігурації, лише з полями форми.",
				"Нова конфігурація",
				MessageBoxButton.YesNoCancel,
				MessageBoxImage.Question);
			return save switch
			{
				MessageBoxResult.Yes => SaveAs(),
				MessageBoxResult.No => true,
				_ => false,
			};
		}
		if (!HasChanges || FilePath is null || !string.Equals(FilePath, State.Path, StringComparison.OrdinalIgnoreCase))
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

	/// <summary>Для закриття вікна чи відкриття іншого файлу: питає про будь-які незбережені зміни.</summary>
	public bool ConfirmClose()
	{
		if (!HasChanges)
		{
			return true;
		}
		var answer = DialogService.Ask(
			$"Зберегти зміни в {FilePath ?? "новій конфігурації"}?",
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
		Form.IsDirty = false;
		_formSyncedText = null;
		if (SelectedView == FormView)
		{
			_ = SyncFormAsync(force: true);
		}
	}

	/// <summary>Записати форму в текст YAML. false — у формі помилки.</summary>
	public bool ApplyForm()
	{
		if (!Form.IsDirty)
		{
			return true;
		}
		if (!Form.TryBuildYaml(out var yaml, out var errors))
		{
			DialogService.Error(
				"У формі є помилки, YAML не оновлено:" + Environment.NewLine + string.Join(Environment.NewLine, errors.Take(15).Select(error => "• " + error)),
				"Налаштування");
			return false;
		}
		if (Document.Text != yaml)
		{
			Document.Replace(0, Document.TextLength, yaml);
		}
		_formSyncedText = Document.Text;
		Form.IsDirty = false;
		OnPropertyChanged(nameof(HasChanges));
		OnPropertyChanged(nameof(Title));
		return true;
	}

	/// <summary>Розібрати текст YAML і показати у формі.</summary>
	public async Task SyncFormAsync(bool force)
	{
		if (!EnsureSchema())
		{
			return;
		}
		var text = Document.Text;
		if (!force && _formSyncedText == text && !Form.IsDirty)
		{
			return;
		}
		if (!force && Form.IsDirty)
		{
			// Незастосовані зміни форми важливіші за текст, якого користувач не змінював.
			if (_formSyncedText == text)
			{
				return;
			}
			if (DialogService.Ask("YAML змінено після редагування форми. Відкинути незастосовані зміни форми й показати поточний текст?",
					"Налаштування", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
			{
				return;
			}
		}
		Form.IsBusy = true;
		try
		{
			var result = await _yaml.ParseAsync(text);
			if (Document.Text != text)
			{
				return;
			}
			if (result.Error is not null)
			{
				Form.StatusText = "YAML не розібрано, форма недоступна для редагування — виправте текст: " + result.Error;
				FormEditable = false;
				return;
			}
			Form.Load(result.Values);
			_formSyncedText = text;
			FormEditable = true;
			OnPropertyChanged(nameof(HasChanges));
			OnPropertyChanged(nameof(Title));
		}
		catch (Exception ex)
		{
			Form.StatusText = "Не вдалося розібрати YAML: " + ex.Message;
			FormEditable = false;
		}
		finally
		{
			Form.IsBusy = false;
			CommandManager.InvalidateRequerySuggested();
		}
	}

	private bool EnsureSchema()
	{
		var schemaPath = ConfigSchemaLoader.FindSchemaPath(_modulePath());
		if (schemaPath is null)
		{
			Form.SetSchemaError("Схему конфігурації (Shared/ConfigSchema.psd1) не знайдено поруч із модулем. Вкажіть шлях до IndexAdvisor.psd1 у параметрах програми або редагуйте YAML.");
			_schemaPath = null;
			return false;
		}
		if (string.Equals(schemaPath, _schemaPath, StringComparison.OrdinalIgnoreCase) && Form.IsAvailable)
		{
			return true;
		}
		try
		{
			Form.Initialize(ConfigSchemaLoader.Load(schemaPath));
			_schemaPath = schemaPath;
			_formSyncedText = null;
			return true;
		}
		catch (Exception ex) when (ex is InvalidDataException or IOException)
		{
			Form.SetSchemaError(ex.Message);
			return false;
		}
	}

	private void OnStatePathChanged()
	{
		var path = State.Path;
		if (path is null || string.Equals(path, FilePath, StringComparison.OrdinalIgnoreCase) || !File.Exists(path))
		{
			return;
		}
		if (HasChanges)
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

	/// <summary>
	/// Нова конфігурація з шаблону: стандартного (New-IaConfigTemplate) або збереженого користувачем.
	/// Підставляються сервери й бази; файл — одразу або перед запуском.
	/// </summary>
	private async Task NewFromTemplateAsync()
	{
		if (!ConfirmClose())
		{
			return;
		}
		var directory = Path.GetDirectoryName(FilePath ?? State.Path ?? string.Empty) is { Length: > 0 } current
			? current
			: Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
		var request = NewFromTemplateDialog.Show(Application.Current?.MainWindow, TemplateStore.Folder(_settings), directory);
		if (request is null)
		{
			return;
		}
		_isBusy = true;
		try
		{
			await CreateFromTemplateAsync(request);
		}
		finally
		{
			_isBusy = false;
			CommandManager.InvalidateRequerySuggested();
		}
	}

	/// <summary>Створити конфігурацію за запитом діалогу (окремо — для тестів).</summary>
	public async Task<bool> CreateFromTemplateAsync(NewFromTemplateRequest request)
	{
		string text;
		if (request.Template.Path is { } templatePath)
		{
			text = await File.ReadAllTextAsync(templatePath);
		}
		else
		{
			var temporary = Path.Combine(Path.GetTempPath(), $"IndexAdvisor-template-{Guid.NewGuid():N}.yaml");
			try
			{
				await _service.NewConfigTemplateAsync(temporary);
				text = await File.ReadAllTextAsync(temporary);
			}
			finally
			{
				File.Delete(temporary);
			}
		}
		LoadNew(text);
		if (request.Servers is not null || request.Databases is not null)
		{
			if (!await PrepareFormAsync())
			{
				DialogService.Error("Шаблон не вдалося розібрати: сервери й бази не підставлено. " + Form.StatusText, "Нова конфігурація");
				return false;
			}
			Form.SetTarget(request.Servers, request.Databases);
			if (!ApplyForm())
			{
				return false;
			}
		}
		if (request.SavePath is { } path)
		{
			if (!WriteTo(path))
			{
				return false;
			}
			FilePath = path;
			State.Path = path;
			_settings.RememberConfig(path);
		}
		SelectedView = FormView;
		return true;
	}

	/// <summary>Новий документ без файлу (з шаблону): збереження — «Зберегти як» або перед запуском.</summary>
	public void LoadNew(string text)
	{
		Document.Text = text;
		Document.UndoStack.ClearAll();
		Document.UndoStack.DiscardOriginalFileMarker();
		FilePath = null;
		IsDirty = true;
		Form.IsDirty = false;
		_formSyncedText = null;
		// Форма запуску більше не посилається на попередній файл: запуск запропонує зберегти нову конфігурацію.
		State.Path = null;
		if (SelectedView == FormView)
		{
			_ = SyncFormAsync(force: true);
		}
	}

	/// <summary>Форма відповідає поточному тексту й доступна для редагування.</summary>
	public async Task<bool> PrepareFormAsync()
	{
		await SyncFormAsync(force: _formSyncedText != Document.Text && !Form.IsDirty);
		return Form.IsAvailable && FormEditable;
	}

	/// <summary>Перенести перевизначення форми запуску в конфігурацію редактора (текст YAML оновлюється).</summary>
	public async Task<IReadOnlyList<string>?> MergeRunOptionsAsync(RunOptions options)
	{
		if (!await PrepareFormAsync())
		{
			DialogService.Error("Форма налаштувань недоступна: " + (Form.SchemaError ?? Form.StatusText ?? "YAML не розібрано."), "Зберегти в конфігурацію");
			return null;
		}
		var applied = Form.ApplyRunOptions(options);
		return ApplyForm() ? applied : null;
	}

	/// <summary>Зберегти в поточний файл (true) або як новий (false); null — скасовано.</summary>
	public bool SaveTo(bool currentFile) => currentFile && FilePath is not null ? Save() : SaveAs();

	private async Task SaveAsTemplateAsync()
	{
		if (!await PrepareFormAsync())
		{
			DialogService.Error("Форма налаштувань недоступна: " + (Form.SchemaError ?? Form.StatusText ?? "YAML не розібрано."), "Зберегти як шаблон");
			return;
		}
		var folder = TemplateStore.Folder(_settings);
		var suggested = FilePath is null ? null : Path.GetFileNameWithoutExtension(FilePath);
		var request = SaveTemplateDialog.Show(Application.Current?.MainWindow, folder, suggested);
		if (request is null)
		{
			return;
		}
		var exclude = new List<string>();
		if (request.WithoutServers)
		{
			exclude.Add(ConfigFormViewModel.ServersPath);
		}
		if (request.WithoutDatabases)
		{
			exclude.Add(ConfigFormViewModel.DatabasesPath);
		}
		var header = TemplateStore.Header(request.Name, request.Description, request.WithoutServers, request.WithoutDatabases);
		if (!Form.TryBuildYaml(out var yaml, out var errors, exclude, header))
		{
			DialogService.Error("У формі є помилки, шаблон не збережено:" + Environment.NewLine + string.Join(Environment.NewLine, errors.Take(15).Select(error => "• " + error)), "Зберегти як шаблон");
			return;
		}
		try
		{
			Directory.CreateDirectory(folder);
			await File.WriteAllTextAsync(request.Path, yaml, Utf8NoBom);
			DialogService.Info($"Шаблон «{request.Name}» збережено:{Environment.NewLine}{request.Path}", "Зберегти як шаблон");
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			DialogService.Error($"Не вдалося зберегти шаблон: {ex.Message}", "Зберегти як шаблон");
		}
	}

	private bool Save()
	{
		if (!ApplyForm())
		{
			return false;
		}
		return FilePath is null ? SaveAs() : WriteTo(FilePath);
	}

	private bool SaveAs()
	{
		if (!ApplyForm())
		{
			return false;
		}
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
		if (HasChanges && DialogService.Ask("Відкинути незбережені зміни й перечитати файл?", "Перечитати", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
		{
			return;
		}
		TryLoad(FilePath);
	}

	private async Task ValidateAsync()
	{
		if (HasChanges && !Save())
		{
			return;
		}
		if (FilePath is null)
		{
			return;
		}
		State.Path = FilePath;
		var isValid = await State.ValidateAsync();
		if (!isValid && State.Errors.FirstOrDefault(error => error.Line is not null) is { } first)
		{
			SelectedView = TextView;
			GoToLineRequested?.Invoke(this, (first.Line!.Value, first.Column ?? 1));
		}
	}
}
