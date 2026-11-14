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
	private ModuleLocation _module;
	private string _modulePath;

	public MainViewModel(AppSettings settings)
	{
		_settings = settings;
		_module = ModuleLocator.Locate(settings.ModulePath);
		_modulePath = _module.Path;
		Log = new LogViewModel();
		PreferencesViewModel.ApplyAll(settings, Log);
		var interaction = new InteractionService(Log);
		var runner = new PowerShellRunner(interaction);
		var service = new IndexAdvisorService(runner, () => _modulePath);
		Dependencies = new DependenciesViewModel(runner, Log);

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
		OpenModuleFolderCommand = new RelayCommand(
			() => DialogService.OpenWithShell(Path.GetDirectoryName(_modulePath)!),
			() => _module.Exists);
		OpenAppFolderCommand = new RelayCommand(() => DialogService.OpenWithShell(AppDirectory));
	}

	public DependenciesViewModel Dependencies { get; }

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

	/// <summary>Повний шлях до IndexAdvisor.psd1, з якого програма імпортує модуль (Import-Module -Name шлях).</summary>
	public string ModulePath => _modulePath;

	public ModuleLocation Module
	{
		get => _module;
		private set
		{
			if (SetProperty(ref _module, value))
			{
				_modulePath = value.Path;
				OnPropertyChanged(nameof(ModulePath));
				OnPropertyChanged(nameof(ModuleText));
				OnPropertyChanged(nameof(ModuleSummary));
				OnPropertyChanged(nameof(ModuleMissing));
			}
		}
	}

	public bool ModuleMissing => !_module.Exists;

	/// <summary>Версія й джерело модуля: «0.1.0, вбудований у програму».</summary>
	public string ModuleSummary => _module.Exists
		? $"IndexAdvisor {ModuleLocator.ReadModuleVersion(_modulePath) ?? "?"}, {_module.SourceText}"
		: _module.Configured is null
			? "Модуль IndexAdvisor не знайдено в теці програми"
			: "Вибраний модуль IndexAdvisor не знайдено (інший не підставляється)";

	/// <summary>Рядок стану внизу вікна.</summary>
	public string ModuleText => _module.Exists
		? $"Модуль {ModuleSummary}: {_modulePath} · PowerShell {ModuleLocator.PowerShellVersion}"
		: $"{ModuleSummary}: {_modulePath} — вкладка «Параметри»";

	/// <summary>Тека програми (для одиночного exe — %LOCALAPPDATA%\IndexAdvisor\app\&lt;версія&gt;).</summary>
	public string AppDirectory { get; } = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);

	/// <summary>Одиночний exe, з якого встановлено й запущено програму (null — запущено напряму).</summary>
	public string? LauncherPath { get; } = Environment.GetEnvironmentVariable(InstallLayout.LauncherVariable) is { Length: > 0 } launcher ? launcher : null;

	public string AppText => LauncherPath is null
		? $"Програма {AppVersion}: {AppDirectory}"
		: $"Програма {AppVersion}: {AppDirectory} (встановлено з {LauncherPath})";

	public static string AppVersion { get; } = typeof(MainViewModel).Assembly
		.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
		.OfType<System.Reflection.AssemblyInformationalVersionAttribute>()
		.FirstOrDefault()?.InformationalVersion.Split('+')[0] ?? "?";

	public string PowerShellText => $"PowerShell {ModuleLocator.PowerShellVersion} (вбудований, Microsoft.PowerShell.SDK)";

	public ICommand BrowseModuleCommand { get; }

	public ICommand ResetModuleCommand { get; }

	public ICommand OpenModuleFolderCommand { get; }

	public ICommand OpenAppFolderCommand { get; }

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
		LogModule();
		_ = Dependencies.RefreshAsync(logProblems: true);
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
		Module = ModuleLocator.Locate(path);
		LogModule();
		CheckDownloadMark();
		_ = Editor.SyncFormAsync(force: true);
	}

	/// <summary>Звідки модуль: у журнал під час запуску програми й після зміни в «Параметрах».</summary>
	private void LogModule()
	{
		if (_module.Exists)
		{
			Log.Enqueue(HostLine.System($"Модуль {ModuleSummary}: {_modulePath}"));
			return;
		}
		var hint = _module.Configured is null
			? "Перевстановіть програму або вкажіть IndexAdvisor.psd1 на вкладці «Параметри»."
			: "Вкажіть інший IndexAdvisor.psd1 на вкладці «Параметри» або натисніть «Вбудований модуль».";
		Log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Error, $"{ModuleSummary}: {_modulePath}. {hint}"));
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
