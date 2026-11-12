using System.Globalization;
using System.Windows.Input;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;
using Microsoft.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Параметри програми: тема, модуль, політика виконання PowerShell, журнал, поведінка. Зберігаються одразу.</summary>
public sealed class PreferencesViewModel : ObservableObject
{
	private readonly AppSettings _settings;
	private readonly LogViewModel _log;
	private readonly MainViewModel _main;

	public PreferencesViewModel(AppSettings settings, LogViewModel log, MainViewModel main)
	{
		_settings = settings;
		_log = log;
		_main = main;
		OpenSettingsFolderCommand = new RelayCommand(() =>
		{
			var folder = Path.GetDirectoryName(AppSettings.FilePath)!;
			Directory.CreateDirectory(folder);
			DialogService.OpenWithShell(folder);
		});
		ResetRunFormCommand = new RelayCommand(() => _main.Run.ResetOverridesCommand.Execute(null));
		BrowseTemplatesFolderCommand = new RelayCommand(() =>
		{
			var folder = DialogService.PickFolder(TemplatesFolder, "Тека шаблонів конфігурацій");
			if (folder is not null)
			{
				SetTemplatesFolder(folder);
			}
		});
		ResetTemplatesFolderCommand = new RelayCommand(() => SetTemplatesFolder(null), () => !string.IsNullOrWhiteSpace(_settings.TemplatesFolder));
		OpenTemplatesFolderCommand = new RelayCommand(() =>
		{
			Directory.CreateDirectory(TemplatesFolder);
			DialogService.OpenWithShell(TemplatesFolder);
		});
	}

	public IReadOnlyList<ChoiceOption> ThemeChoices { get; } =
	[
		new(nameof(AppTheme.System), "Як у Windows"),
		new(nameof(AppTheme.Light), "Світла"),
		new(nameof(AppTheme.Dark), "Темна"),
	];

	public IReadOnlyList<ChoiceOption> PolicyChoices { get; } =
	[
		new(nameof(ExecutionPolicy.RemoteSigned), "RemoteSigned — локальні скрипти й підписані завантажені (рекомендовано)"),
		new(nameof(ExecutionPolicy.AllSigned), "AllSigned — лише підписані скрипти"),
		new(nameof(ExecutionPolicy.Unrestricted), "Unrestricted — усі, з попередженням для завантажених"),
		new(nameof(ExecutionPolicy.Bypass), "Bypass — без перевірок"),
	];

	public IReadOnlyList<double> FontSizes { get; } = [10, 11, 12, 12.5, 13, 14, 15, 16, 18, 20];

	public string Theme
	{
		get => _settings.Theme.ToString();
		set
		{
			if (Enum.TryParse<AppTheme>(value, out var theme) && theme != _settings.Theme)
			{
				_settings.Theme = theme;
				Save();
				ThemeManager.Apply(theme);
				OnPropertyChanged();
			}
		}
	}

	public string ExecutionPolicyName
	{
		get => _settings.ExecutionPolicy;
		set
		{
			if (Enum.TryParse<ExecutionPolicy>(value, out _) && value != _settings.ExecutionPolicy)
			{
				_settings.ExecutionPolicy = value;
				Save();
				ApplyExecutionPolicy(_settings);
				OnPropertyChanged();
				OnPropertyChanged(nameof(PolicyWarning));
			}
		}
	}

	public string? PolicyWarning => _settings.ExecutionPolicy is "Bypass" or "Unrestricted"
		? "Слабша політика дозволяє виконувати непідписані скрипти з Інтернету в процесі програми. Залиште RemoteSigned, якщо немає причини."
		: null;

	public double FontSize
	{
		get => _settings.FontSize;
		set
		{
			if (Math.Abs(value - _settings.FontSize) > 0.01)
			{
				_settings.FontSize = value;
				Save();
				ApplyAppearance(_settings, _log);
				OnPropertyChanged();
			}
		}
	}

	public bool LogWordWrap
	{
		get => _settings.LogWordWrap;
		set => Update(_settings.LogWordWrap, value, v => _settings.LogWordWrap = v, () => ApplyAppearance(_settings, _log));
	}

	public string MaxLogLinesText
	{
		get => _settings.MaxLogLines.ToString(CultureInfo.InvariantCulture);
		set
		{
			if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var lines) && lines is >= 1000 and <= 500000)
			{
				_settings.MaxLogLines = lines;
				Save();
				ApplyAppearance(_settings, _log);
			}
			OnPropertyChanged();
		}
	}

	public bool AutoValidateConfig
	{
		get => _settings.AutoValidateConfig;
		set => Update(_settings.AutoValidateConfig, value, v => _settings.AutoValidateConfig = v);
	}

	public bool FlashOnPrompt
	{
		get => _settings.FlashOnPrompt;
		set => Update(_settings.FlashOnPrompt, value, v => _settings.FlashOnPrompt = v, () => PromptDialog.FlashTaskbar = value);
	}

	public bool SoundOnFinish
	{
		get => _settings.SoundOnFinish;
		set => Update(_settings.SoundOnFinish, value, v => _settings.SoundOnFinish = v);
	}

	public bool OpenResultsAfterRun
	{
		get => _settings.OpenResultsAfterRun;
		set => Update(_settings.OpenResultsAfterRun, value, v => _settings.OpenResultsAfterRun = v);
	}

	public bool ConfigFormFirst
	{
		get => _settings.ConfigFormFirst;
		set => Update(_settings.ConfigFormFirst, value, v => _settings.ConfigFormFirst = v);
	}

	public string ResultsScanDepthText
	{
		get => _settings.ResultsScanDepth.ToString(CultureInfo.InvariantCulture);
		set
		{
			if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var depth) && depth is >= 0 and <= 8)
			{
				_settings.ResultsScanDepth = depth;
				Save();
			}
			OnPropertyChanged();
		}
	}

	public string SettingsFilePath => AppSettings.FilePath;

	/// <summary>Тека шаблонів конфігурацій (може бути спільною мережевою текою команди).</summary>
	public string TemplatesFolder => TemplateStore.Folder(_settings);

	public ICommand BrowseTemplatesFolderCommand { get; }

	public ICommand ResetTemplatesFolderCommand { get; }

	public ICommand OpenTemplatesFolderCommand { get; }

	private void SetTemplatesFolder(string? folder)
	{
		_settings.TemplatesFolder = folder;
		Save();
		OnPropertyChanged(nameof(TemplatesFolder));
	}

	public MainViewModel Main => _main;

	public ICommand OpenSettingsFolderCommand { get; }

	public ICommand ResetRunFormCommand { get; }

	/// <summary>Застосувати збережені параметри під час запуску програми.</summary>
	public static void ApplyAll(AppSettings settings, LogViewModel? log)
	{
		ThemeManager.Apply(settings.Theme);
		ApplyExecutionPolicy(settings);
		PromptDialog.FlashTaskbar = settings.FlashOnPrompt;
		ApplyAppearance(settings, log);
	}

	private static void ApplyExecutionPolicy(AppSettings settings)
		=> PowerShellRunner.ProcessExecutionPolicy = Enum.TryParse<ExecutionPolicy>(settings.ExecutionPolicy, out var policy)
			? policy
			: ExecutionPolicy.RemoteSigned;

	private static void ApplyAppearance(AppSettings settings, LogViewModel? log)
	{
		EditorTheming.SetFontSize(settings.FontSize);
		if (log is not null)
		{
			log.FontSize = settings.FontSize;
			log.WordWrap = settings.LogWordWrap;
			log.MaxLines = settings.MaxLogLines;
		}
	}

	private void Update(bool current, bool value, Action<bool> set, Action? apply = null, [System.Runtime.CompilerServices.CallerMemberName] string? name = null)
	{
		if (current == value)
		{
			return;
		}
		set(value);
		Save();
		apply?.Invoke();
		OnPropertyChanged(name);
	}

	private void Save() => _settings.Save();
}
