using System.Windows.Input;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Корінь: вкладки «Запуск», «Конфігурація», «Результати», «Інструменти», «Параметри» і спільний журнал PowerShell.</summary>
public sealed class MainViewModel : ObservableObject
{
	public const int RunTab = 0;
	public const int ConfigTab = 1;
	public const int ResultsTab = 2;
	public const int ToolsTab = 3;
	public const int PreferencesTab = 4;

	private readonly AppSettings _settings;
	private int _selectedTab;
	private string _modulePath;

	public MainViewModel(AppSettings settings)
	{
		_settings = settings;
		_modulePath = ModuleLocator.Resolve(settings.ModulePath);
		Log = new LogViewModel();
		PreferencesViewModel.ApplyAll(settings, Log);
		var interaction = new InteractionService(Log);
		var service = new IndexAdvisorService(new PowerShellRunner(interaction), () => _modulePath);

		Config = new ConfigStateViewModel(service, Log);
		Results = new ResultsViewModel(settings);
		Editor = new ConfigEditorViewModel(service, new YamlService(), Config, settings, () => _modulePath);
		Run = new RunViewModel(
			service,
			Log,
			Config,
			Results,
			settings,
			() => _modulePath,
			Editor,
			() => SelectedTab = ResultsTab,
			() => SelectedTab = ConfigTab);

		Tools = new ToolsViewModel(service, Log, Config);
		Preferences = new PreferencesViewModel(settings, Log, this);

		Config.PathChanged += (_, _) =>
		{
			if (Config.Exists && !Run.IsRunning && _settings.AutoValidateConfig)
			{
				_ = Config.ValidateAsync();
			}
		};

		BrowseModuleCommand = new RelayCommand(BrowseModule);
		ResetModuleCommand = new RelayCommand(() => SetModulePath(null), () => !string.IsNullOrWhiteSpace(_settings.ModulePath));
	}

	public LogViewModel Log { get; }

	public ConfigStateViewModel Config { get; }

	public RunViewModel Run { get; }

	public ConfigEditorViewModel Editor { get; }

	public ResultsViewModel Results { get; }

	public ToolsViewModel Tools { get; }

	public PreferencesViewModel Preferences { get; }

	public int SelectedTab
	{
		get => _selectedTab;
		set => SetProperty(ref _selectedTab, value);
	}

	public string ModulePath
	{
		get => _modulePath;
		private set
		{
			if (SetProperty(ref _modulePath, value))
			{
				OnPropertyChanged(nameof(ModuleText));
			}
		}
	}

	public string ModuleText
	{
		get
		{
			var version = ModuleLocator.ReadModuleVersion(_modulePath);
			var source = File.Exists(_modulePath) ? _modulePath : $"{_modulePath} (з PSModulePath)";
			return $"Модуль IndexAdvisor {version ?? "?"}: {source} · PowerShell {ModuleLocator.PowerShellVersion}";
		}
	}

	public ICommand BrowseModuleCommand { get; }

	public ICommand ResetModuleCommand { get; }

	/// <summary>
	/// Після показу вікна: відновити форму й прочитати каталог результатів.
	/// Аргумент командного рядка: *.yaml — конфігурація; тека або result.json — результати.
	/// </summary>
	public async Task InitializeAsync(IReadOnlyList<string>? args = null)
	{
		// До першої перевірки конфігурації: заблокований модуль інакше не завантажиться.
		CheckDownloadMark();
		Run.LoadOptions(_settings.RunOptions);
		foreach (var arg in args ?? [])
		{
			var target = Path.GetFullPath(arg.Trim('"'));
			if (File.Exists(target) && Path.GetExtension(target) is ".yaml" or ".yml")
			{
				Config.Path = target;
			}
			else if (Directory.Exists(target))
			{
				Results.Root = target;
				SelectedTab = ResultsTab;
			}
			else if (File.Exists(target) && string.Equals(Path.GetFileName(target), Gui.Results.RunResultStore.ResultFileName, StringComparison.OrdinalIgnoreCase))
			{
				Results.Root = Path.GetDirectoryName(Path.GetDirectoryName(target));
				SelectedTab = ResultsTab;
			}
		}
		if (Config.Path is { } path && File.Exists(path))
		{
			try
			{
				Editor.Load(path);
			}
			catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
			{
				Log.Enqueue(HostLine.System($"Не вдалося відкрити {path}: {ex.Message}"));
			}
		}
		if (!File.Exists(_modulePath))
		{
			Log.Enqueue(HostLine.System("Маніфест IndexAdvisor.psd1 не знайдено поруч із програмою: модуль імпортуватиметься з PSModulePath. Шлях можна вказати на вкладці «Параметри»."));
		}
		await Editor.InitializeAsync();
		if (Results.Root is not null)
		{
			await Results.RefreshAsync();
		}
	}

	public bool ConfirmClose()
	{
		if (Run.IsRunning
			&& DialogService.Ask("Аналіз ще виконується. Закрити програму й перервати його?", "IndexAdvisor", System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Warning)
				!= System.Windows.MessageBoxResult.Yes)
		{
			return false;
		}
		if (!Editor.ConfirmClose())
		{
			return false;
		}
		var options = Run.ToOptions();
		options.UnsafeDisableSelectCheck = false;
		options.UnsafeDisableMaxdop = false;
		options.UnsafeDisableTimeouts = false;
		options.UnsafeAllowFreeQuery = false;
		options.AllowNonStandardLogin = false;
		_settings.RunOptions = options;
		_settings.Save();
		return true;
	}

	private void BrowseModule()
	{
		var path = DialogService.OpenFile("Маніфест модуля (IndexAdvisor.psd1)|IndexAdvisor.psd1|Маніфест PowerShell (*.psd1)|*.psd1", _modulePath, "Модуль IndexAdvisor");
		if (path is not null)
		{
			SetModulePath(path);
		}
	}

	private void SetModulePath(string? path)
	{
		_settings.ModulePath = path;
		_settings.Save();
		ModulePath = ModuleLocator.Resolve(path);
		CheckDownloadMark();
		_ = Editor.SyncFormAsync(force: true);
	}

	/// <summary>
	/// Модуль із ZIP, завантаженого з Інтернету й розпакованого Провідником, має позначку Mark of the Web:
	/// з політикою RemoteSigned/AllSigned PowerShell його не завантажить. Пропонуємо зняти позначку (як Unblock-File).
	/// </summary>
	internal void CheckDownloadMark()
	{
		if (!File.Exists(_modulePath) || PowerShellRunner.ProcessExecutionPolicy == Microsoft.PowerShell.ExecutionPolicy.Bypass)
		{
			return;
		}
		var directory = Path.GetDirectoryName(_modulePath)!;
		var marked = DownloadMark.FindMarked(directory);
		if (marked.Count == 0)
		{
			return;
		}
		var answer = DialogService.Ask(
			$"Файли модуля IndexAdvisor позначено Windows як завантажені з Інтернету ({marked.Count}):{Environment.NewLine}{directory}{Environment.NewLine}{Environment.NewLine}" +
			$"З політикою виконання {PowerShellRunner.ProcessExecutionPolicy} PowerShell не завантажить ці непідписані скрипти, і аналіз не запуститься.{Environment.NewLine}{Environment.NewLine}" +
			"Розблокувати їх зараз? Це те саме, що Unblock-File: знімається лише позначка, вміст файлів не змінюється.",
			"Файли модуля заблоковано",
			System.Windows.MessageBoxButton.YesNo,
			System.Windows.MessageBoxImage.Warning);
		if (answer != System.Windows.MessageBoxResult.Yes)
		{
			Log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Warning,
				$"Файли модуля в {directory} заблоковано (завантажено з Інтернету): модуль не завантажиться. Розблокуйте теку: Get-ChildItem '{directory}' -Recurse | Unblock-File"));
			return;
		}
		var failed = DownloadMark.Unblock(marked);
		Log.Enqueue(HostLine.System($"Розблоковано файлів модуля: {marked.Count - failed.Count} ({directory})."));
		foreach (var file in failed.Take(10))
		{
			Log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Error, $"Не вдалося розблокувати: {file}"));
		}
	}
}
