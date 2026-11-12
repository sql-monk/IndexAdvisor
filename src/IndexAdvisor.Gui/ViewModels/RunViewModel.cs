using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Форма запуску Invoke-IndexAdvisor, прев'ю командного рядка, стан виконання.</summary>
public sealed class RunViewModel : ObservableObject
{
	private readonly IndexAdvisorService _service;
	private readonly LogViewModel _log;
	private readonly ResultsViewModel _results;
	private readonly AppSettings _settings;
	private readonly Func<string> _modulePath;
	private readonly Func<bool> _ensureConfigSaved;
	private readonly ConfigEditorViewModel _editor;
	private readonly Action _showResults;
	private readonly Action _showEditor;
	private readonly DispatcherTimer _elapsedTimer;
	private readonly Stopwatch _stopwatch = new();
	private CancellationTokenSource? _cancellation;

	private string? _module = string.Empty;
	private string? _provider;
	private string? _model;
	private string? _crossCheckProvider;
	private string? _analysisWindowDaysText;
	private bool _datasetsExplicit;
	private string? _outputPath;
	private bool _formatsExplicit;
	private string? _fromArchive;
	private bool _verbose;
	private string _powerShellCommand = string.Empty;
	private string? _pwshCommand;
	private bool _isRunning;
	private string _statusText = "Готово до запуску.";
	private Severity _statusSeverity;
	private string? _elapsedText;
	private bool _hasResults;
	private string _moduleHint = string.Empty;
	private string _providerHint = string.Empty;
	private string _modelHint = string.Empty;
	private string _daysHint = string.Empty;
	private string _outputHint = string.Empty;
	private string _datasetsHint = string.Empty;
	private string _formatsHint = string.Empty;
	private bool _suspendPreview;

	public RunViewModel(
		IndexAdvisorService service,
		LogViewModel log,
		ConfigStateViewModel config,
		ResultsViewModel results,
		AppSettings settings,
		Func<string> modulePath,
		ConfigEditorViewModel editor,
		Action showResults,
		Action showEditor)
	{
		_service = service;
		_log = log;
		Config = config;
		_results = results;
		_settings = settings;
		_modulePath = modulePath;
		_editor = editor;
		_ensureConfigSaved = editor.EnsureSaved;
		_showResults = showResults;
		_showEditor = showEditor;

		ScopeOptions =
		[
			new("Server", "Сервери", "Сервери або listener'и AG (через кому). Для AG програма сама визначає репліки."),
			new("Database", "Бази", "Лише ці бази (через кому)."),
			new("ExcludeDatabase", "Крім баз", "Виключити бази (через кому)."),
			new("Schema", "Схеми", "Лише ці схеми."),
			new("ExcludeSchema", "Крім схем", "Виключити схеми."),
			new("Table", "Таблиці", "Лише ці таблиці: schema.table, допускається * (dbo.Log*)."),
			new("ExcludeTable", "Крім таблиць", "Виключити таблиці: schema.table, допускається *."),
		];
		Flags =
		[
			new("NoRepository", "Без запису в репозиторій", "Разовий аналіз: результати не зберігаються в базі IndexAdvisor (-NoRepository).", invertedInConfig: true),
			new("NoArchive", "Без архіву зібраних даних", "Не зберігати ZIP-архів snapshot (-NoArchive).", invertedInConfig: true),
			new("Maintenance", "Скрипти обслуговування індексів", "Скрипти AdaptiveIndexDefrag разом з аналізом (-Maintenance)."),
			new("MaskNames", "Маскувати імена об'єктів для моделі", "Імена серверів, баз, таблиць та індексів замінюються псевдонімами (-MaskNames)."),
			new("LocalOnly", "Лише локальна модель", "Дозволено лише провайдер з isLocal (-LocalOnly)."),
			new("AutoApprove", "Автопідтвердження дозапитів моделі", "Дозапити моделі виконуються без діалогу підтвердження (-AutoApprove)."),
			new("NonInteractive", "Неінтерактивний режим", "Без діалогів: дозапити моделі відхиляються, якщо не ввімкнено автопідтвердження (-NonInteractive)."),
		];
		UnsafeFlags =
		[
			new("UnsafeDisableSelectCheck", "Вимкнути перевірку SELECT (ScriptDom)", "-UnsafeDisableSelectCheck", isThreeState: false),
			new("UnsafeDisableMaxdop", "Вимкнути OPTION (MAXDOP 1)", "-UnsafeDisableMaxdop", isThreeState: false),
			new("UnsafeDisableTimeouts", "Вимкнути таймаути запитів", "-UnsafeDisableTimeouts", isThreeState: false),
			new("UnsafeAllowFreeQuery", "Дозволити моделі вільні запити", "-UnsafeAllowFreeQuery", isThreeState: false),
			new("AllowNonStandardLogin", "Дозволити нештатний логін", "-AllowNonStandardLogin", isThreeState: false),
		];
		Datasets = new ObservableCollection<CheckItem>(
			IaConstants.OptionalDatasets.Select(name => new CheckItem(name, IaConstants.DescribeDataset(name))));
		Formats = new ObservableCollection<CheckItem>(
			IaConstants.Formats.Select(name => new CheckItem(name, IaConstants.DescribeFormat(name), name is "Markdown" or "Sql" or "Html" or "Json")));
		ModuleChoices =
		[
			new(string.Empty, "з конфігурації"),
			new("Indexes", "Індекси"),
			new("Partitioning", "Партиціонування"),
			new("Both", "Індекси й партиціонування"),
		];

		foreach (var item in ScopeOptions)
		{
			item.PropertyChanged += OnOptionChanged;
		}
		foreach (var item in Flags.Concat(UnsafeFlags))
		{
			item.PropertyChanged += OnOptionChanged;
		}
		foreach (var item in Datasets.Concat(Formats))
		{
			item.PropertyChanged += OnOptionChanged;
		}
		PropertyChanged += OnOwnPropertyChanged;
		Config.PropertyChanged += (_, e) =>
		{
			if (e.PropertyName == nameof(ConfigStateViewModel.Path))
			{
				UpdatePreview();
			}
		};
		Config.SummaryChanged += (_, _) => ApplySummaryHints();

		_elapsedTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
		_elapsedTimer.Tick += (_, _) => ElapsedText = FormatElapsed(_stopwatch.Elapsed);

		BrowseConfigCommand = new RelayCommand(BrowseConfig, () => !IsRunning);
		ValidateConfigCommand = new AsyncRelayCommand(ValidateConfigAsync, () => Config.Exists && !Config.IsChecking);
		EditConfigCommand = new RelayCommand(_showEditor);
		BrowseOutputCommand = new RelayCommand(BrowseOutput);
		BrowseArchiveCommand = new RelayCommand(BrowseArchive);
		RunCommand = new AsyncRelayCommand(RunAsync, () => !IsRunning);
		StopCommand = new RelayCommand(Stop, () => IsRunning && _cancellation is { IsCancellationRequested: false });
		CopyPowerShellCommand = new RelayCommand(() => Clipboard.SetText(PowerShellCommand));
		CopyPwshCommand = new RelayCommand(() => Clipboard.SetText(PwshCommand ?? string.Empty), () => PwshCommand is not null);
		ResetOverridesCommand = new RelayCommand(ResetOverrides, () => !IsRunning);
		SaveToConfigCommand = new AsyncRelayCommand(SaveToConfigAsync, () => !IsRunning);
		OpenResultsCommand = new RelayCommand(_showResults, () => HasResults);

		ApplySummaryHints();
		UpdatePreview();
	}

	public ConfigStateViewModel Config { get; }

	public ObservableCollection<TextOption> ScopeOptions { get; }

	public ObservableCollection<FlagOption> Flags { get; }

	public ObservableCollection<FlagOption> UnsafeFlags { get; }

	public ObservableCollection<CheckItem> Datasets { get; }

	public ObservableCollection<CheckItem> Formats { get; }

	public IReadOnlyList<ChoiceOption> ModuleChoices { get; }

	public ObservableCollection<string> ProviderChoices { get; } = [];

	public IReadOnlyList<string> MandatoryDatasetsText { get; } = IaConstants.MandatoryDatasets;

	public string? Module
	{
		get => _module;
		set => SetProperty(ref _module, value);
	}

	public string? Provider
	{
		get => _provider;
		set => SetProperty(ref _provider, value);
	}

	public string? Model
	{
		get => _model;
		set => SetProperty(ref _model, value);
	}

	public string? CrossCheckProvider
	{
		get => _crossCheckProvider;
		set => SetProperty(ref _crossCheckProvider, value);
	}

	public string? AnalysisWindowDaysText
	{
		get => _analysisWindowDaysText;
		set => SetProperty(ref _analysisWindowDaysText, value);
	}

	public bool DatasetsExplicit
	{
		get => _datasetsExplicit;
		set => SetProperty(ref _datasetsExplicit, value);
	}

	public string? OutputPath
	{
		get => _outputPath;
		set => SetProperty(ref _outputPath, value);
	}

	public bool FormatsExplicit
	{
		get => _formatsExplicit;
		set => SetProperty(ref _formatsExplicit, value);
	}

	public string? FromArchive
	{
		get => _fromArchive;
		set => SetProperty(ref _fromArchive, value);
	}

	public bool Verbose
	{
		get => _verbose;
		set => SetProperty(ref _verbose, value);
	}

	public string ModuleHint
	{
		get => _moduleHint;
		private set => SetProperty(ref _moduleHint, value);
	}

	public string ProviderHint
	{
		get => _providerHint;
		private set => SetProperty(ref _providerHint, value);
	}

	public string ModelHint
	{
		get => _modelHint;
		private set => SetProperty(ref _modelHint, value);
	}

	public string DaysHint
	{
		get => _daysHint;
		private set => SetProperty(ref _daysHint, value);
	}

	public string OutputHint
	{
		get => _outputHint;
		private set => SetProperty(ref _outputHint, value);
	}

	public string DatasetsHint
	{
		get => _datasetsHint;
		private set => SetProperty(ref _datasetsHint, value);
	}

	public string FormatsHint
	{
		get => _formatsHint;
		private set => SetProperty(ref _formatsHint, value);
	}

	public string PowerShellCommand
	{
		get => _powerShellCommand;
		private set => SetProperty(ref _powerShellCommand, value);
	}

	public string? PwshCommand
	{
		get => _pwshCommand;
		private set => SetProperty(ref _pwshCommand, value);
	}

	public bool HasUnsafeSelection => UnsafeFlags.Any(flag => flag.Value == true);

	public bool IsRunning
	{
		get => _isRunning;
		private set
		{
			if (SetProperty(ref _isRunning, value))
			{
				CommandManager.InvalidateRequerySuggested();
			}
		}
	}

	public string StatusText
	{
		get => _statusText;
		private set => SetProperty(ref _statusText, value);
	}

	public Severity StatusSeverity
	{
		get => _statusSeverity;
		private set => SetProperty(ref _statusSeverity, value);
	}

	public string? ElapsedText
	{
		get => _elapsedText;
		private set => SetProperty(ref _elapsedText, value);
	}

	public bool HasResults
	{
		get => _hasResults;
		private set => SetProperty(ref _hasResults, value);
	}

	public ICommand BrowseConfigCommand { get; }
	public ICommand ValidateConfigCommand { get; }
	public ICommand EditConfigCommand { get; }
	public ICommand BrowseOutputCommand { get; }
	public ICommand BrowseArchiveCommand { get; }
	public ICommand RunCommand { get; }
	public ICommand StopCommand { get; }
	public ICommand CopyPowerShellCommand { get; }
	public ICommand CopyPwshCommand { get; }
	public ICommand ResetOverridesCommand { get; }
	public ICommand SaveToConfigCommand { get; }

	/// <summary>Нова конфігурація з шаблону (та сама команда, що в редакторі).</summary>
	public ICommand NewFromTemplateCommand => _editor.NewCommand;
	public ICommand OpenResultsCommand { get; }

	/// <summary>Параметри форми як RunOptions (без перевірки).</summary>
	public RunOptions ToOptions()
	{
		string? Scope(string key) => ScopeOptions.First(option => option.Key == key).Value;
		bool? Flag(string key) => Flags.Concat(UnsafeFlags).First(option => option.Key == key).EffectiveValue;
		return new RunOptions
		{
			ConfigPath = Config.Path,
			Servers = Scope("Server"),
			Databases = Scope("Database"),
			ExcludeDatabases = Scope("ExcludeDatabase"),
			Schemas = Scope("Schema"),
			ExcludeSchemas = Scope("ExcludeSchema"),
			Tables = Scope("Table"),
			ExcludeTables = Scope("ExcludeTable"),
			Module = string.IsNullOrWhiteSpace(Module) ? null : Module,
			Provider = Provider,
			Model = Model,
			CrossCheckProvider = CrossCheckProvider,
			AnalysisWindowDays = int.TryParse(AnalysisWindowDaysText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var days) ? days : null,
			Datasets = DatasetsExplicit ? Datasets.Where(item => item.IsChecked).Select(item => item.Name).ToList() : null,
			OutputPath = OutputPath,
			Formats = FormatsExplicit ? Formats.Where(item => item.IsChecked).Select(item => item.Name).ToList() : null,
			FromArchive = FromArchive,
			NoRepository = Flag("NoRepository"),
			NoArchive = Flag("NoArchive"),
			Maintenance = Flag("Maintenance"),
			MaskNames = Flag("MaskNames"),
			LocalOnly = Flag("LocalOnly"),
			AutoApprove = Flag("AutoApprove"),
			NonInteractive = Flag("NonInteractive"),
			UnsafeDisableSelectCheck = Flag("UnsafeDisableSelectCheck") == true,
			UnsafeDisableMaxdop = Flag("UnsafeDisableMaxdop") == true,
			UnsafeDisableTimeouts = Flag("UnsafeDisableTimeouts") == true,
			UnsafeAllowFreeQuery = Flag("UnsafeAllowFreeQuery") == true,
			AllowNonStandardLogin = Flag("AllowNonStandardLogin") == true,
			Verbose = Verbose,
		};
	}

	/// <summary>Відновлює форму зі збережених налаштувань. Небезпечні режими не відновлюються.</summary>
	public void LoadOptions(RunOptions options)
	{
		_suspendPreview = true;
		try
		{
			Config.Path = options.ConfigPath;
			void SetScope(string key, string? value) => ScopeOptions.First(option => option.Key == key).Value = value;
			SetScope("Server", options.Servers);
			SetScope("Database", options.Databases);
			SetScope("ExcludeDatabase", options.ExcludeDatabases);
			SetScope("Schema", options.Schemas);
			SetScope("ExcludeSchema", options.ExcludeSchemas);
			SetScope("Table", options.Tables);
			SetScope("ExcludeTable", options.ExcludeTables);
			Module = options.Module ?? string.Empty;
			Provider = options.Provider;
			Model = options.Model;
			CrossCheckProvider = options.CrossCheckProvider;
			AnalysisWindowDaysText = options.AnalysisWindowDays?.ToString(CultureInfo.InvariantCulture);
			DatasetsExplicit = options.Datasets is not null;
			if (options.Datasets is not null)
			{
				foreach (var item in Datasets)
				{
					item.IsChecked = options.Datasets.Contains(item.Name, StringComparer.OrdinalIgnoreCase);
				}
			}
			OutputPath = options.OutputPath;
			FormatsExplicit = options.Formats is not null;
			if (options.Formats is not null)
			{
				foreach (var item in Formats)
				{
					item.IsChecked = options.Formats.Contains(item.Name, StringComparer.OrdinalIgnoreCase);
				}
			}
			FromArchive = options.FromArchive;
			void SetFlag(string key, bool? value) => Flags.First(option => option.Key == key).Value = value;
			SetFlag("NoRepository", options.NoRepository);
			SetFlag("NoArchive", options.NoArchive);
			SetFlag("Maintenance", options.Maintenance);
			SetFlag("MaskNames", options.MaskNames);
			SetFlag("LocalOnly", options.LocalOnly);
			SetFlag("AutoApprove", options.AutoApprove);
			SetFlag("NonInteractive", options.NonInteractive);
			Verbose = options.Verbose;
		}
		finally
		{
			_suspendPreview = false;
		}
		UpdatePreview();
	}

	private void OnOptionChanged(object? sender, PropertyChangedEventArgs e)
	{
		if (sender is FlagOption && e.PropertyName == nameof(FlagOption.Value))
		{
			OnPropertyChanged(nameof(HasUnsafeSelection));
		}
		UpdatePreview();
	}

	private void OnOwnPropertyChanged(object? sender, PropertyChangedEventArgs e)
	{
		switch (e.PropertyName)
		{
			case nameof(Module):
			case nameof(Provider):
			case nameof(Model):
			case nameof(CrossCheckProvider):
			case nameof(AnalysisWindowDaysText):
			case nameof(DatasetsExplicit):
			case nameof(OutputPath):
			case nameof(FormatsExplicit):
			case nameof(FromArchive):
			case nameof(Verbose):
				UpdatePreview();
				break;
		}
	}

	private void UpdatePreview()
	{
		if (_suspendPreview)
		{
			return;
		}
		var options = ToOptions();
		PowerShellCommand = CommandLineBuilder.FormatPowerShell(options);
		var script = ModuleLocator.FindCliScript(_modulePath());
		PwshCommand = script is null ? null : CommandLineBuilder.FormatPwshFile(options, script);
	}

	private void ApplySummaryHints()
	{
		var summary = Config.Summary;
		static string Join(IEnumerable<string> items, string empty)
		{
			var text = string.Join(", ", items);
			return string.IsNullOrWhiteSpace(text) ? empty : text;
		}
		foreach (var option in ScopeOptions)
		{
			option.Hint = summary is null
				? "з конфігурації"
				: option.Key switch
				{
					"Server" => "з конфігурації: " + Join(summary.Servers, "не задано"),
					"Database" => "з конфігурації: " + Join(summary.Databases, "усі бази"),
					"ExcludeDatabase" => "з конфігурації: " + Join(summary.ExcludeDatabases, "немає"),
					_ => "з конфігурації",
				};
		}
		ModuleHint = summary?.Module is { Length: > 0 } module ? $"з конфігурації: {Results.Labels.Module(module)}" : "з конфігурації";
		ProviderHint = summary is null ? "з конфігурації" : "з конфігурації: " + (string.IsNullOrWhiteSpace(summary.Provider) ? "не задано" : summary.Provider);
		ModelHint = summary is null ? "з конфігурації" : "з конфігурації: " + (string.IsNullOrWhiteSpace(summary.Model) ? "не задано" : summary.Model);
		DaysHint = summary?.AnalysisWindowDays is int days ? $"з конфігурації: {days}" : "з конфігурації";
		OutputHint = summary?.OutputPath is { Length: > 0 } output ? $"з конфігурації: {output}" : "з конфігурації (./out)";
		DatasetsHint = summary is null ? "з конфігурації" : "з конфігурації: " + Join(summary.Datasets.Except(IaConstants.MandatoryDatasets), "лише обов'язкові");
		FormatsHint = summary is null ? "з конфігурації" : "з конфігурації: " + Join(summary.Formats, "—");

		ProviderChoices.Clear();
		foreach (var provider in summary?.Providers ?? [])
		{
			ProviderChoices.Add(provider);
		}
		foreach (var flag in Flags)
		{
			flag.ConfigValue = summary is null
				? null
				: flag.Key switch
				{
					"NoRepository" => !summary.RepositoryEnabled,
					"NoArchive" => !summary.ArchiveEnabled,
					"Maintenance" => summary.Maintenance,
					"MaskNames" => summary.MaskNames,
					"LocalOnly" => summary.LocalOnly,
					"AutoApprove" => summary.AutoApprove,
					"NonInteractive" => summary.NonInteractive,
					_ => null,
				};
		}
		if (summary?.OutputPath is { Length: > 0 } root && string.IsNullOrWhiteSpace(OutputPath))
		{
			_results.SuggestRoot(root);
		}
	}

	private void BrowseConfig()
	{
		var path = DialogService.OpenFile(DialogService.YamlFilter, Config.Path, "Конфігурація IndexAdvisor");
		if (path is not null)
		{
			Config.Path = path;
		}
	}

	private async Task ValidateConfigAsync()
	{
		if (!_ensureConfigSaved())
		{
			return;
		}
		await Config.ValidateAsync();
	}

	private void BrowseOutput()
	{
		var folder = DialogService.PickFolder(OutputPath ?? Config.Summary?.OutputPath, "Каталог результатів");
		if (folder is not null)
		{
			OutputPath = folder;
		}
	}

	private void BrowseArchive()
	{
		var path = DialogService.OpenFile(DialogService.ArchiveFilter, FromArchive ?? Config.Summary?.ArchivePath, "Архів зібраних даних");
		if (path is not null)
		{
			FromArchive = path;
		}
	}

	private void ResetOverrides()
	{
		var path = Config.Path;
		LoadOptions(new RunOptions { ConfigPath = path });
		foreach (var flag in UnsafeFlags)
		{
			flag.Value = false;
		}
		foreach (var item in Datasets)
		{
			item.IsChecked = true;
		}
		foreach (var item in Formats)
		{
			item.IsChecked = item.Name is "Markdown" or "Sql" or "Html" or "Json";
		}
	}

	/// <summary>
	/// Поля форми запуску → YAML: у поточну конфігурацію (або нову, якщо файлу немає), далі зберегти в той самий
	/// чи новий файл. Перевизначення після цього очищаються: значення вже у файлі.
	/// </summary>
	private async Task SaveToConfigAsync()
	{
		var options = ToOptions();
		if (!string.IsNullOrWhiteSpace(AnalysisWindowDaysText) && options.AnalysisWindowDays is not (>= 1 and <= 3650))
		{
			DialogService.Error("Вікно аналізу — ціле число днів від 1 до 3650.", "Зберегти в конфігурацію");
			return;
		}
		// Редактор має містити файл, вибраний у формі запуску (або нову конфігурацію без файлу).
		if (Config.Path is { } path && !string.Equals(path, _editor.FilePath, StringComparison.OrdinalIgnoreCase))
		{
			if (!_editor.ConfirmClose())
			{
				return;
			}
			_editor.Load(path);
		}
		var applied = await _editor.MergeRunOptionsAsync(options);
		if (applied is null)
		{
			return;
		}
		bool saved;
		if (_editor.FilePath is { } current)
		{
			var answer = DialogService.Ask(
				(applied.Count > 0 ? "Перенесено в конфігурацію: " + string.Join(", ", applied) + "." : "Перевизначень у формі немає.")
				+ Environment.NewLine + Environment.NewLine
				+ $"Зберегти в поточний файл?{Environment.NewLine}{current}{Environment.NewLine}{Environment.NewLine}«Ні» — зберегти як новий файл.",
				"Зберегти в конфігурацію",
				MessageBoxButton.YesNoCancel,
				MessageBoxImage.Question);
			if (answer == MessageBoxResult.Cancel)
			{
				return;
			}
			saved = _editor.SaveTo(currentFile: answer == MessageBoxResult.Yes);
		}
		else
		{
			saved = _editor.SaveTo(currentFile: false);
		}
		if (!saved)
		{
			return;
		}
		// Значення вже у файлі: форма знову показує їх як «з конфігурації». Архів і -Verbose стосуються лише запуску.
		var fromArchive = FromArchive;
		var verbose = Verbose;
		ResetOverrides();
		FromArchive = fromArchive;
		Verbose = verbose;
		await Config.ValidateAsync();
	}

	private string? ValidateForm(RunOptions options)
	{
		if (!string.IsNullOrWhiteSpace(AnalysisWindowDaysText)
			&& options.AnalysisWindowDays is not (>= 1 and <= 3650))
		{
			return "Вікно аналізу — ціле число днів від 1 до 3650.";
		}
		if (options.ConfigPath is not null && !File.Exists(options.ConfigPath))
		{
			return $"Файл конфігурації не знайдено: {options.ConfigPath}";
		}
		if (!string.IsNullOrWhiteSpace(options.FromArchive) && !File.Exists(options.FromArchive))
		{
			return $"Архів не знайдено: {options.FromArchive}";
		}
		if (options.Formats is { Count: 0 })
		{
			return "Позначте хоча б один формат результату або поверніть «з конфігурації».";
		}
		if (options.ConfigPath is null && CommandLineBuilder.SplitList(options.Servers).Length == 0 && string.IsNullOrWhiteSpace(options.FromArchive))
		{
			return "Вкажіть конфігурацію YAML, сервер або архів зібраних даних.";
		}
		return null;
	}

	private async Task RunAsync()
	{
		// Спершу — збереження конфігурації з редактора: нова конфігурація отримує файл, і він потрапляє в параметри.
		if (!_ensureConfigSaved())
		{
			return;
		}
		var options = ToOptions();
		var problem = ValidateForm(options);
		if (problem is not null)
		{
			DialogService.Error(problem, "Запуск неможливий");
			return;
		}
		if (options.HasUnsafeFlags)
		{
			var flags = string.Join(Environment.NewLine, UnsafeFlags.Where(flag => flag.Value == true).Select(flag => "• " + flag.Label));
			var answer = DialogService.Ask(
				$"Увімкнено небезпечні режими:{Environment.NewLine}{flags}{Environment.NewLine}{Environment.NewLine}" +
				"Вони записуються в журнал і в кожну рекомендацію. Продовжити?",
				"Небезпечні режими",
				MessageBoxButton.YesNo,
				MessageBoxImage.Warning);
			if (answer != MessageBoxResult.Yes)
			{
				return;
			}
		}

		_settings.RunOptions = options.Clone();
		_settings.RunOptions.UnsafeDisableSelectCheck = false;
		_settings.RunOptions.UnsafeDisableMaxdop = false;
		_settings.RunOptions.UnsafeDisableTimeouts = false;
		_settings.RunOptions.UnsafeAllowFreeQuery = false;
		_settings.RunOptions.AllowNonStandardLogin = false;
		_settings.RememberConfig(options.ConfigPath);
		_settings.Save();

		_cancellation = new CancellationTokenSource();
		IsRunning = true;
		HasResults = false;
		_log.ResetCounters();
		_log.Enqueue(HostLine.System("▶ " + CommandLineBuilder.FormatPowerShell(options)));
		StatusText = "Виконується…";
		StatusSeverity = Severity.None;
		_stopwatch.Restart();
		ElapsedText = FormatElapsed(TimeSpan.Zero);
		_elapsedTimer.Start();
		try
		{
			var fallbackDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
			var outcome = await _service.RunAsync(options, fallbackDirectory, _cancellation.Token);
			StatusText = $"{ExitCodes.Describe(outcome.ExitCode)} (код {outcome.ExitCode})";
			StatusSeverity = ExitCodes.GetSeverity(outcome.ExitCode);
			_log.Enqueue(HostLine.System($"■ Завершено за {FormatElapsed(_stopwatch.Elapsed)}: {StatusText}."));
			HasResults = _results.AcceptOutcome(outcome);
			if (_settings.OpenResultsAfterRun && HasResults)
			{
				_showResults();
			}
		}
		catch (OperationCanceledException)
		{
			StatusText = "Зупинено користувачем.";
			StatusSeverity = Severity.Warning;
			_log.Enqueue(HostLine.System("■ Запуск зупинено."));
		}
		catch (Exception ex)
		{
			StatusText = $"Помилка: {ex.Message}";
			StatusSeverity = Severity.Error;
			_log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Error, ex.Message));
		}
		finally
		{
			if (_settings.SoundOnFinish)
			{
				(StatusSeverity switch
				{
					Severity.Success => System.Media.SystemSounds.Asterisk,
					Severity.Warning => System.Media.SystemSounds.Exclamation,
					_ => System.Media.SystemSounds.Hand,
				}).Play();
			}
			_elapsedTimer.Stop();
			_stopwatch.Stop();
			ElapsedText = FormatElapsed(_stopwatch.Elapsed);
			_log.ProgressText = null;
			_cancellation.Dispose();
			_cancellation = null;
			IsRunning = false;
		}
	}

	private void Stop()
	{
		if (_cancellation is null)
		{
			return;
		}
		_cancellation.Cancel();
		StatusText = "Зупинка… (поточний запит до сервера чи моделі завершиться першим)";
		CommandManager.InvalidateRequerySuggested();
	}

	private static string FormatElapsed(TimeSpan elapsed)
		=> elapsed.TotalHours >= 1
			? elapsed.ToString(@"h\:mm\:ss", CultureInfo.InvariantCulture)
			: elapsed.ToString(@"mm\:ss", CultureInfo.InvariantCulture);
}
