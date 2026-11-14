using System.Collections.ObjectModel;
using System.Net.Http;
using System.Windows;
using System.Windows.Input;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Рядок таблиці залежностей на вкладці «Параметри».</summary>
public sealed class DependencyItem
{
	public DependencyItem(DependencyInfo info, DependencyModuleStatus? status, string modulesRoot)
	{
		Name = info.Name;
		Purpose = info.Purpose;
		Required = info.Required;
		Version = status?.Version;
		Path = status?.Path;
		IsMissing = status?.Path is null;
		InAppFolder = Path is not null && IsUnder(Path, modulesRoot);
		var others = (status?.Copies ?? 0) - 1;
		Location = IsMissing
			? Required ? "не знайдено" : "не знайдено (потрібне лише як сховище за замовчуванням)"
			: others > 0 ? $"{Path} (ще копій у PSModulePath: {others})" : Path!;
	}

	public string Name { get; }
	public string Purpose { get; }
	public bool Required { get; }
	public string? Version { get; }
	public string? Path { get; }
	public bool IsMissing { get; }

	/// <summary>Узято з теки залежностей IndexAdvisor, а не з профілю PowerShell.</summary>
	public bool InAppFolder { get; }

	public string Location { get; }

	/// <summary>Бракує обов'язкової залежності.</summary>
	public bool IsProblem => IsMissing && Required;

	internal static bool IsUnder(string path, string root)
	{
		var full = System.IO.Path.GetFullPath(path).TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
		var parent = System.IO.Path.GetFullPath(root).TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
		return full.StartsWith(parent, StringComparison.OrdinalIgnoreCase);
	}
}

/// <summary>
/// Залежності модуля IndexAdvisor з PowerShell Gallery: що й звідки бере вбудований PowerShell і встановлення
/// в теку залежностей %LOCALAPPDATA%\IndexAdvisor\Modules (перша в PSModulePath).
/// </summary>
public sealed class DependenciesViewModel : ObservableObject
{
	private readonly PowerShellRunner _runner;
	private readonly LogViewModel _log;
	private readonly Func<GalleryInstaller> _installerFactory;
	private bool _isBusy;
	private string? _summary;
	private bool _hasProblems;

	public DependenciesViewModel(PowerShellRunner runner, LogViewModel log, Func<GalleryInstaller>? installerFactory = null)
	{
		_runner = runner;
		_log = log;
		_installerFactory = installerFactory ?? (() => new GalleryInstaller());
		RefreshCommand = new AsyncRelayCommand(() => RefreshAsync(), () => !IsBusy);
		InstallCommand = new AsyncRelayCommand(InstallInteractiveAsync, () => !IsBusy);
		OpenFolderCommand = new RelayCommand(() =>
		{
			Directory.CreateDirectory(ModulesRoot);
			DialogService.OpenWithShell(ModulesRoot);
		});
		CopyCommandCommand = new RelayCommand(() => Clipboard.SetText(SaveModuleCommand));
	}

	/// <summary>Тека залежностей IndexAdvisor.</summary>
	public string ModulesRoot => PowerShellRunner.DependencyModulesPath;

	public string SaveModuleCommand => Dependencies.SaveModuleCommand(ModulesRoot);

	public ObservableCollection<DependencyItem> Items { get; } = [];

	/// <summary>PSModulePath вбудованого PowerShell у порядку пошуку.</summary>
	public ObservableCollection<string> SearchOrder { get; } = [];

	public bool IsBusy
	{
		get => _isBusy;
		private set
		{
			if (SetProperty(ref _isBusy, value))
			{
				CommandManager.InvalidateRequerySuggested();
			}
		}
	}

	public string? Summary
	{
		get => _summary;
		private set => SetProperty(ref _summary, value);
	}

	public bool HasProblems
	{
		get => _hasProblems;
		private set => SetProperty(ref _hasProblems, value);
	}

	public ICommand RefreshCommand { get; }

	public ICommand InstallCommand { get; }

	public ICommand OpenFolderCommand { get; }

	public ICommand CopyCommandCommand { get; }

	/// <summary>Перевірити залежності; <paramref name="logProblems"/> — записати в журнал, чого бракує (під час запуску програми).</summary>
	public async Task RefreshAsync(bool logProblems = false)
	{
		IsBusy = true;
		try
		{
			var report = await Dependencies.CheckAsync(_runner);
			Apply(report);
			if (logProblems && HasProblems)
			{
				_log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Warning,
					$"{Summary} Встановіть їх на вкладці «Параметри» → «Залежності модуля» (у {ModulesRoot}) або командою: {SaveModuleCommand}"));
			}
		}
		catch (Exception ex) when (ex is not OperationCanceledException)
		{
			Summary = $"Залежності не перевірено: {ex.Message}";
			HasProblems = true;
		}
		finally
		{
			IsBusy = false;
		}
	}

	internal void Apply(DependencyReport report)
	{
		Items.Clear();
		foreach (var info in Dependencies.All)
		{
			var status = report.Modules.FirstOrDefault(item => string.Equals(item.Name, info.Name, StringComparison.OrdinalIgnoreCase));
			Items.Add(new DependencyItem(info, status, ModulesRoot));
		}
		SearchOrder.Clear();
		foreach (var path in report.ModulePath)
		{
			SearchOrder.Add(path);
		}
		var missing = Items.Where(item => item.IsProblem).Select(item => item.Name).ToList();
		HasProblems = missing.Count > 0;
		Summary = HasProblems
			? $"Не знайдено модулі PowerShell: {string.Join(", ", missing)}."
			: "Усі потрібні модулі знайдено.";
	}

	private async Task InstallInteractiveAsync()
	{
		var answer = DialogService.Ask(
			$"Завантажити з PowerShell Gallery ({GalleryInstaller.DefaultFeed.Host}) найновіші версії модулів{Environment.NewLine}" +
			$"{string.Join(", ", Dependencies.All.Select(item => item.Name))}{Environment.NewLine}" +
			$"у теку {ModulesRoot}?{Environment.NewLine}{Environment.NewLine}" +
			"Це близько 80 МБ завантаження й 350 МБ на диску (найбільший — dbatools.library). Наявні версії не завантажуються вдруге; " +
			"модулі з цієї теки мають пріоритет над копіями в профілі PowerShell.",
			"Залежності IndexAdvisor");
		if (answer == MessageBoxResult.Yes)
		{
			await InstallAsync(CancellationToken.None);
		}
	}

	/// <summary>Усі залежності в ModulesRoot; помилка одного пакета не зупиняє інші.</summary>
	internal async Task<int> InstallAsync(CancellationToken cancellationToken)
	{
		IsBusy = true;
		var failed = 0;
		try
		{
			using var installer = _installerFactory();
			var progress = new Progress<string>(text => _log.Enqueue(HostLine.System(text)));
			foreach (var info in Dependencies.All)
			{
				try
				{
					_log.Enqueue(HostLine.System($"{info.Name}: PowerShell Gallery → {ModulesRoot}"));
					var result = await installer.InstallAsync(info.Name, ModulesRoot, progress, cancellationToken);
					_log.Enqueue(HostLine.System(result.AlreadyInstalled
						? $"{result.Name} {result.Version} уже встановлено: {result.Directory}"
						: $"{result.Name} {result.Version} встановлено: {result.Directory}"));
				}
				catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidDataException or UnauthorizedAccessException or TaskCanceledException && !cancellationToken.IsCancellationRequested)
				{
					failed++;
					_log.Enqueue(new HostLine(DateTime.Now, HostLineKind.Error,
						$"{info.Name} не встановлено: {ex.Message}. Без доступу до PowerShell Gallery виконайте в PowerShell (можна з -Repository внутрішнього репозиторію): {SaveModuleCommand}"));
				}
			}
		}
		finally
		{
			IsBusy = false;
		}
		await RefreshAsync();
		return failed;
	}
}
