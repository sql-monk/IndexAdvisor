using System.Collections.ObjectModel;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>
/// Поточний файл конфігурації та результат його перевірки (Test-IaConfig + підсумок Get-IaConfig).
/// Спільний для форми запуску й редактора YAML.
/// </summary>
public sealed class ConfigStateViewModel : ObservableObject
{
	private readonly IndexAdvisorService _service;
	private readonly LogViewModel _log;
	private string? _path;
	private ConfigSummary? _summary;
	private string _statusText = "Конфігурацію не вибрано: використовуються значення за замовчуванням і параметри форми.";
	private Severity _severity;
	private bool _isChecking;
	private int _checkVersion;

	public ConfigStateViewModel(IndexAdvisorService service, LogViewModel log)
	{
		_service = service;
		_log = log;
	}

	public string? Path
	{
		get => _path;
		set
		{
			var normalized = string.IsNullOrWhiteSpace(value) ? null : value.Trim().Trim('"');
			if (SetProperty(ref _path, normalized))
			{
				Summary = null;
				Errors.Clear();
				if (normalized is null)
				{
					SetStatus("Конфігурацію не вибрано: використовуються значення за замовчуванням і параметри форми.", Severity.None);
				}
				else if (!File.Exists(normalized))
				{
					SetStatus("Файл не знайдено.", Severity.Error);
				}
				else
				{
					SetStatus("Не перевірено.", Severity.None);
				}
				OnPropertyChanged(nameof(Exists));
				PathChanged?.Invoke(this, EventArgs.Empty);
			}
		}
	}

	public bool Exists => _path is not null && File.Exists(_path);

	public event EventHandler? PathChanged;

	public ConfigSummary? Summary
	{
		get => _summary;
		private set
		{
			if (SetProperty(ref _summary, value))
			{
				SummaryChanged?.Invoke(this, EventArgs.Empty);
			}
		}
	}

	public event EventHandler? SummaryChanged;

	public ObservableCollection<ConfigError> Errors { get; } = [];

	public string StatusText
	{
		get => _statusText;
		private set => SetProperty(ref _statusText, value);
	}

	public Severity Severity
	{
		get => _severity;
		private set => SetProperty(ref _severity, value);
	}

	public bool IsChecking
	{
		get => _isChecking;
		private set => SetProperty(ref _isChecking, value);
	}

	/// <summary>Перевіряє файл на диску. Повертає true, якщо конфігурація коректна.</summary>
	public async Task<bool> ValidateAsync()
	{
		var path = _path;
		if (path is null)
		{
			return true;
		}
		if (!File.Exists(path))
		{
			SetStatus("Файл не знайдено.", Severity.Error);
			return false;
		}
		var version = ++_checkVersion;
		IsChecking = true;
		SetStatus("Перевірка…", Severity.None);
		try
		{
			var result = await _service.TestConfigAsync(path);
			if (version != _checkVersion || !string.Equals(path, _path, StringComparison.OrdinalIgnoreCase))
			{
				return result.IsValid;
			}
			Errors.Clear();
			foreach (var error in result.Errors)
			{
				Errors.Add(error);
			}
			Summary = result.Summary;
			if (result.IsValid)
			{
				SetStatus("Конфігурація коректна.", Severity.Success);
			}
			else
			{
				SetStatus($"Помилок у конфігурації: {result.Errors.Length}.", Severity.Error);
				_log.Enqueue(HostLine.System($"Конфігурація {path}: помилок {result.Errors.Length}."));
				foreach (var error in result.Errors)
				{
					_log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Error, $"{System.IO.Path.GetFileName(path)}:{error.Location} {error.Path} — {error.Message}"));
				}
			}
			return result.IsValid;
		}
		catch (Exception ex)
		{
			if (version == _checkVersion)
			{
				SetStatus($"Перевірку не виконано: {ex.Message}", Severity.Error);
			}
			_log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Error, $"Test-IaConfig: {ex.Message}"));
			return false;
		}
		finally
		{
			if (version == _checkVersion)
			{
				IsChecking = false;
			}
		}
	}

	private void SetStatus(string text, Severity severity)
	{
		StatusText = text;
		Severity = severity;
	}
}
