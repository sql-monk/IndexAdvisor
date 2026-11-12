using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Інші команди модуля: New-IaIndexMaintenance і Install-IaServiceLogin з усіма параметрами.</summary>
public sealed class ToolsViewModel : ObservableObject
{
	private readonly IndexAdvisorService _service;
	private readonly LogViewModel _log;
	private readonly ConfigStateViewModel _config;
	private CancellationTokenSource? _cancellation;
	private bool _isRunning;
	private string? _statusText;
	private Severity _statusSeverity;

	// New-IaIndexMaintenance
	private string? _maintenanceArchive;
	private string? _maintenanceConfig;
	private string? _maintenanceResult;
	private string? _maintenanceOutput;
	private string? _maintenanceDirectory;

	// Install-IaServiceLogin
	private string? _loginServers;
	private string _loginMode = "Verify";
	private string? _loginDatabases;
	private string? _loginName;
	private bool _windowsLogin;
	private string? _secretName;
	private string? _vault;
	private bool _askCredential;

	public ToolsViewModel(IndexAdvisorService service, LogViewModel log, ConfigStateViewModel config)
	{
		_service = service;
		_log = log;
		_config = config;
		PropertyChanged += OnOwnPropertyChanged;
		_config.PropertyChanged += (_, e) =>
		{
			if (e.PropertyName is nameof(ConfigStateViewModel.Path) or nameof(ConfigStateViewModel.Summary))
			{
				OnPropertyChanged(nameof(MaintenanceConfigHint));
				OnPropertyChanged(nameof(LoginNameHint));
				UpdatePreviews();
			}
		};

		BrowseMaintenanceArchiveCommand = new RelayCommand(() => MaintenanceArchive = DialogService.OpenFile(DialogService.ArchiveFilter, MaintenanceArchive ?? _config.Summary?.ArchivePath, "Архів зібраних даних") ?? MaintenanceArchive);
		BrowseMaintenanceConfigCommand = new RelayCommand(() => MaintenanceConfig = DialogService.OpenFile(DialogService.YamlFilter, MaintenanceConfig ?? _config.Path, "Конфігурація") ?? MaintenanceConfig);
		BrowseMaintenanceResultCommand = new RelayCommand(() => MaintenanceResult = DialogService.OpenFile(DialogService.JsonFilter, MaintenanceResult ?? _config.Summary?.OutputPath, "result.json запуску") ?? MaintenanceResult);
		BrowseMaintenanceOutputCommand = new RelayCommand(() => MaintenanceOutput = DialogService.PickFolder(MaintenanceOutput ?? _config.Summary?.OutputPath, "Каталог результатів") ?? MaintenanceOutput);
		RunMaintenanceCommand = new AsyncRelayCommand(RunMaintenanceAsync, () => !IsRunning);
		OpenMaintenanceDirectoryCommand = new RelayCommand(() => DialogService.OpenWithShell(MaintenanceDirectory!), () => MaintenanceDirectory is not null);
		RunLoginCommand = new AsyncRelayCommand(RunLoginAsync, () => !IsRunning);
		StopCommand = new RelayCommand(() => _cancellation?.Cancel(), () => IsRunning);
		CopyMaintenanceCommand = new RelayCommand(() => Clipboard.SetText(MaintenanceCommand));
		CopyLoginCommand = new RelayCommand(() => Clipboard.SetText(LoginCommand));
		UpdatePreviews();
	}

	public LogViewModel Log => _log;

	public IReadOnlyList<ChoiceOption> LoginModes { get; } =
	[
		new("Verify", "Verify — перевірити фактичні права (лише читання)"),
		new("Install", "Install — створити логін, ролі й користувачів"),
		new("AddDatabase", "AddDatabase — додати бази"),
		new("Remove", "Remove — повністю видалити обліковий запис"),
	];

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

	public string? StatusText
	{
		get => _statusText;
		private set => SetProperty(ref _statusText, value);
	}

	public Severity StatusSeverity
	{
		get => _statusSeverity;
		private set => SetProperty(ref _statusSeverity, value);
	}

	public string? MaintenanceArchive
	{
		get => _maintenanceArchive;
		set => SetProperty(ref _maintenanceArchive, value);
	}

	public string? MaintenanceConfig
	{
		get => _maintenanceConfig;
		set => SetProperty(ref _maintenanceConfig, value);
	}

	public string MaintenanceConfigHint => _config.Path is { } path ? $"як на вкладці «Запуск»: {path}" : "без конфігурації — значення за замовчуванням";

	public string? MaintenanceResult
	{
		get => _maintenanceResult;
		set => SetProperty(ref _maintenanceResult, value);
	}

	public string? MaintenanceOutput
	{
		get => _maintenanceOutput;
		set => SetProperty(ref _maintenanceOutput, value);
	}

	public string? MaintenanceDirectory
	{
		get => _maintenanceDirectory;
		private set => SetProperty(ref _maintenanceDirectory, value);
	}

	public string MaintenanceCommand { get; private set; } = string.Empty;

	public string? LoginServers
	{
		get => _loginServers;
		set => SetProperty(ref _loginServers, value);
	}

	public string LoginMode
	{
		get => _loginMode;
		set => SetProperty(ref _loginMode, value ?? "Verify");
	}

	public string? LoginDatabases
	{
		get => _loginDatabases;
		set => SetProperty(ref _loginDatabases, value);
	}

	public string? LoginName
	{
		get => _loginName;
		set => SetProperty(ref _loginName, value);
	}

	public string LoginNameHint => _config.Summary?.Login is { Length: > 0 } login ? $"з конфігурації: {login}" : "index-advisor";

	public bool WindowsLogin
	{
		get => _windowsLogin;
		set => SetProperty(ref _windowsLogin, value);
	}

	public string? SecretName
	{
		get => _secretName;
		set => SetProperty(ref _secretName, value);
	}

	public string? Vault
	{
		get => _vault;
		set => SetProperty(ref _vault, value);
	}

	public bool AskCredential
	{
		get => _askCredential;
		set => SetProperty(ref _askCredential, value);
	}

	public string LoginCommand { get; private set; } = string.Empty;

	public ICommand BrowseMaintenanceArchiveCommand { get; }
	public ICommand BrowseMaintenanceConfigCommand { get; }
	public ICommand BrowseMaintenanceResultCommand { get; }
	public ICommand BrowseMaintenanceOutputCommand { get; }
	public ICommand RunMaintenanceCommand { get; }
	public ICommand OpenMaintenanceDirectoryCommand { get; }
	public ICommand RunLoginCommand { get; }
	public ICommand StopCommand { get; }
	public ICommand CopyMaintenanceCommand { get; }
	public ICommand CopyLoginCommand { get; }

	internal IReadOnlyList<CommandParameter> MaintenanceParameters()
	{
		var parameters = new List<CommandParameter>();
		void Add(string name, string? value)
		{
			if (!string.IsNullOrWhiteSpace(value))
			{
				parameters.Add(new CommandParameter(name, value.Trim().Trim('"')));
			}
		}
		Add("FromArchive", MaintenanceArchive);
		Add("Config", string.IsNullOrWhiteSpace(MaintenanceConfig) ? _config.Path : MaintenanceConfig);
		Add("ResultPath", MaintenanceResult);
		Add("OutputPath", MaintenanceOutput);
		return parameters;
	}

	internal IReadOnlyList<CommandParameter> LoginParameters()
	{
		var parameters = new List<CommandParameter>();
		var servers = CommandLineBuilder.SplitList(LoginServers);
		if (servers.Length > 0)
		{
			parameters.Add(new CommandParameter("SqlInstance", servers));
		}
		parameters.Add(new CommandParameter("Mode", LoginMode));
		var databases = CommandLineBuilder.SplitList(LoginDatabases);
		if (databases.Length > 0)
		{
			parameters.Add(new CommandParameter("Database", databases));
		}
		var login = string.IsNullOrWhiteSpace(LoginName) ? _config.Summary?.Login : LoginName.Trim();
		if (!string.IsNullOrWhiteSpace(login))
		{
			parameters.Add(new CommandParameter("LoginName", login));
		}
		if (WindowsLogin)
		{
			parameters.Add(new CommandParameter("WindowsLogin", true));
		}
		if (!string.IsNullOrWhiteSpace(SecretName))
		{
			parameters.Add(new CommandParameter("SecretName", SecretName.Trim()));
		}
		if (!string.IsNullOrWhiteSpace(Vault))
		{
			parameters.Add(new CommandParameter("Vault", Vault.Trim()));
		}
		return parameters;
	}

	private void OnOwnPropertyChanged(object? sender, PropertyChangedEventArgs e)
	{
		if (e.PropertyName is nameof(MaintenanceCommand) or nameof(LoginCommand) or nameof(IsRunning) or nameof(StatusText)
			or nameof(StatusSeverity) or nameof(MaintenanceDirectory))
		{
			return;
		}
		UpdatePreviews();
	}

	private void UpdatePreviews()
	{
		MaintenanceCommand = CommandLineBuilder.FormatCommand("New-IaIndexMaintenance", MaintenanceParameters());
		OnPropertyChanged(nameof(MaintenanceCommand));
		LoginCommand = CommandLineBuilder.FormatCommand("Install-IaServiceLogin", LoginParameters())
			+ (AskCredential ? " -SqlCredential (Get-Credential)" : string.Empty);
		OnPropertyChanged(nameof(LoginCommand));
	}

	private async Task RunMaintenanceAsync()
	{
		if (string.IsNullOrWhiteSpace(MaintenanceArchive) || !File.Exists(MaintenanceArchive.Trim('"')))
		{
			DialogService.Error("Вкажіть існуючий архів зібраних даних (*.zip).", "Обслуговування індексів");
			return;
		}
		if (!string.IsNullOrWhiteSpace(MaintenanceResult) && !File.Exists(MaintenanceResult.Trim('"')))
		{
			DialogService.Error("Файл result.json не знайдено.", "Обслуговування індексів");
			return;
		}
		var parameters = MaintenanceParameters();
		var config = parameters.FirstOrDefault(p => p.Name == "Config")?.Value as string;
		var workingDirectory = Path.GetDirectoryName(config ?? MaintenanceArchive.Trim('"'));
		await RunAsync(MaintenanceCommand, async token =>
		{
			MaintenanceDirectory = await _service.NewMaintenanceAsync(parameters, workingDirectory, token);
			return MaintenanceDirectory is null ? "Готово." : $"Скрипти обслуговування: {MaintenanceDirectory}";
		});
	}

	private async Task RunLoginAsync()
	{
		var parameters = LoginParameters();
		var servers = CommandLineBuilder.SplitList(LoginServers);
		if (servers.Length == 0)
		{
			DialogService.Error("Вкажіть хоча б один сервер (SqlInstance).", "Штатний логін");
			return;
		}
		if (LoginMode != "Verify")
		{
			var action = LoginMode switch
			{
				"Install" => "створити логін (пароль генерується й зберігається в SecretManagement), серверну роль і ролі в базах",
				"AddDatabase" => "створити користувача й роль db_index_advisor у вказаних базах",
				"Remove" => "ПОВНІСТЮ ВИДАЛИТИ логін, ролі й користувачів IndexAdvisor",
				_ => LoginMode,
			};
			var answer = DialogService.Ask(
				$"Режим {LoginMode} змінює сервери: {action}.{Environment.NewLine}{Environment.NewLine}Сервери: {string.Join(", ", servers)}{Environment.NewLine}{Environment.NewLine}Продовжити?",
				"Штатний логін",
				MessageBoxButton.YesNo,
				LoginMode == "Remove" ? MessageBoxImage.Warning : MessageBoxImage.Question);
			if (answer != MessageBoxResult.Yes)
			{
				return;
			}
		}
		var askCredential = AskCredential;
		await RunAsync(LoginCommand, async token =>
		{
			await _service.InstallServiceLoginAsync(parameters, askCredential, token);
			return $"Install-IaServiceLogin {LoginMode}: виконано.";
		});
	}

	private async Task RunAsync(string command, Func<CancellationToken, Task<string>> action)
	{
		_cancellation = new CancellationTokenSource();
		IsRunning = true;
		StatusText = "Виконується…";
		StatusSeverity = Severity.None;
		var errorsBefore = _log.ErrorCount;
		_log.Enqueue(HostLine.System("▶ " + command));
		try
		{
			var message = await action(_cancellation.Token);
			_log.Flush();
			var failed = _log.ErrorCount > errorsBefore;
			StatusText = failed ? message + " Є помилки — див. журнал." : message;
			StatusSeverity = failed ? Severity.Warning : Severity.Success;
			_log.Enqueue(HostLine.System("■ " + StatusText));
		}
		catch (OperationCanceledException)
		{
			StatusText = "Зупинено.";
			StatusSeverity = Severity.Warning;
		}
		catch (Exception ex)
		{
			StatusText = "Помилка: " + ex.Message;
			StatusSeverity = Severity.Error;
			_log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Error, ex.Message));
		}
		finally
		{
			_cancellation.Dispose();
			_cancellation = null;
			IsRunning = false;
		}
	}
}
