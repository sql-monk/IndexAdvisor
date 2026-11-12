using System.Collections.ObjectModel;
using System.Windows.Input;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.Results;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Перелік запусків у каталозі результатів і подробиці вибраного.</summary>
public sealed class ResultsViewModel : ObservableObject
{
	private readonly AppSettings _settings;
	private readonly List<RunListEntry> _sessionRuns = [];
	private string? _root;
	private RunListEntry? _selectedRun;
	private RunDetailsViewModel? _details;
	private bool _isLoading;
	private string? _statusText;
	private int _loadVersion;

	public ResultsViewModel(AppSettings settings)
	{
		_settings = settings;
		_root = settings.ResultsRoot;
		BrowseRootCommand = new RelayCommand(BrowseRoot);
		RefreshCommand = new AsyncRelayCommand(RefreshAsync, () => !string.IsNullOrWhiteSpace(Root));
		OpenFileCommand = new RelayCommand(OpenFile);
		OpenRootCommand = new RelayCommand(() => DialogService.OpenWithShell(Root!), () => Root is not null && Directory.Exists(Root));
	}

	public string? Root
	{
		get => _root;
		set
		{
			if (SetProperty(ref _root, string.IsNullOrWhiteSpace(value) ? null : value.Trim().Trim('"')))
			{
				_settings.ResultsRoot = _root;
			}
		}
	}

	public ObservableCollection<RunListEntry> Runs { get; } = [];

	public RunListEntry? SelectedRun
	{
		get => _selectedRun;
		set
		{
			if (SetProperty(ref _selectedRun, value))
			{
				_ = LoadDetailsAsync(value);
			}
		}
	}

	public RunDetailsViewModel? Details
	{
		get => _details;
		private set => SetProperty(ref _details, value);
	}

	public bool IsLoading
	{
		get => _isLoading;
		private set => SetProperty(ref _isLoading, value);
	}

	public string? StatusText
	{
		get => _statusText;
		private set => SetProperty(ref _statusText, value);
	}

	public ICommand BrowseRootCommand { get; }
	public ICommand RefreshCommand { get; }
	public ICommand OpenFileCommand { get; }
	public ICommand OpenRootCommand { get; }

	/// <summary>Каталог результатів з конфігурації, якщо користувач ще не вибрав свій.</summary>
	public void SuggestRoot(string root)
	{
		if (Root is null)
		{
			Root = root;
			_ = RefreshAsync();
		}
	}

	/// <summary>Після запуску: показати його результати. Повертає true, якщо є що показати.</summary>
	public bool AcceptOutcome(RunOutcome outcome)
	{
		var created = new List<RunListEntry>();
		foreach (var json in outcome.ResultJson)
		{
			try
			{
				var run = RunResultStore.Parse(json);
				var onDisk = outcome.OutputRoot is null ? null : FindResultFile(outcome.OutputRoot, run.RunId);
				created.Add(RunResultStore.CreateEntry(run, onDisk, onDisk is null ? json : null));
			}
			catch (Exception ex) when (ex is System.Text.Json.JsonException or InvalidDataException)
			{
				// Некоректний RunResult не повинен ламати показ решти.
			}
		}
		_sessionRuns.InsertRange(0, created.Where(entry => entry.InMemoryJson is not null));
		if (outcome.OutputRoot is not null)
		{
			Root = outcome.OutputRoot;
		}
		_ = RefreshAsync(created.FirstOrDefault()?.RunId);
		return created.Count > 0;
	}

	public async Task RefreshAsync() => await RefreshAsync(SelectedRun?.RunId);

	private async Task RefreshAsync(string? selectRunId)
	{
		var root = Root;
		IsLoading = true;
		try
		{
			var scanned = root is null ? [] : await Task.Run(() => RunResultStore.Scan(root, _settings.ResultsScanDepth));
			var scannedIds = scanned.Select(entry => entry.RunId).ToHashSet(StringComparer.OrdinalIgnoreCase);
			var all = _sessionRuns.Where(entry => !scannedIds.Contains(entry.RunId)).Concat(scanned)
				.OrderByDescending(entry => entry.StartedAt ?? DateTimeOffset.MinValue)
				.ToList();
			Runs.Clear();
			foreach (var entry in all)
			{
				Runs.Add(entry);
			}
			StatusText = root is null
				? "Виберіть каталог результатів (output.path)."
				: Runs.Count == 0 ? $"У {root} немає result.json. Додайте формат Json, щоб результати зберігалися на диску." : $"Запусків: {Runs.Count}";
			SelectedRun = Runs.FirstOrDefault(entry => string.Equals(entry.RunId, selectRunId, StringComparison.OrdinalIgnoreCase))
				?? (selectRunId is null ? Runs.FirstOrDefault() : SelectedRun);
		}
		catch (Exception ex)
		{
			StatusText = $"Не вдалося прочитати {root}: {ex.Message}";
		}
		finally
		{
			IsLoading = false;
		}
	}

	private async Task LoadDetailsAsync(RunListEntry? entry)
	{
		var version = ++_loadVersion;
		if (entry is null)
		{
			Details = null;
			return;
		}
		try
		{
			var run = await Task.Run(() => RunResultStore.Load(entry));
			if (version == _loadVersion)
			{
				Details = new RunDetailsViewModel(run, entry.Directory);
			}
		}
		catch (Exception ex)
		{
			if (version == _loadVersion)
			{
				Details = null;
				StatusText = $"Не вдалося прочитати результат: {ex.Message}";
			}
		}
	}

	private void BrowseRoot()
	{
		var folder = DialogService.PickFolder(Root, "Каталог результатів IndexAdvisor");
		if (folder is not null)
		{
			Root = folder;
			_ = RefreshAsync(null);
		}
	}

	private void OpenFile()
	{
		var path = DialogService.OpenFile(DialogService.JsonFilter, Root, "Результат запуску");
		if (path is null)
		{
			return;
		}
		try
		{
			var run = RunResultStore.Parse(File.ReadAllText(path));
			var entry = RunResultStore.CreateEntry(run, path, null);
			var existing = Runs.FirstOrDefault(item => string.Equals(item.RunId, entry.RunId, StringComparison.OrdinalIgnoreCase));
			if (existing is null)
			{
				Runs.Insert(0, entry);
				existing = entry;
			}
			SelectedRun = existing;
		}
		catch (Exception ex) when (ex is System.Text.Json.JsonException or IOException or InvalidDataException)
		{
			DialogService.Error($"Це не результат запуску IndexAdvisor: {ex.Message}");
		}
	}

	/// <summary>Тека запуску — &lt;час&gt;_&lt;сервер&gt;_&lt;перші 8 символів runId&gt;.</summary>
	private static string? FindResultFile(string root, string? runId)
	{
		if (string.IsNullOrWhiteSpace(runId) || !Directory.Exists(root))
		{
			return null;
		}
		var suffix = "_" + runId.Replace("-", string.Empty, StringComparison.Ordinal)[..Math.Min(8, runId.Replace("-", string.Empty, StringComparison.Ordinal).Length)];
		return Directory.EnumerateDirectories(root, "*" + suffix)
			.Select(directory => Path.Combine(directory, RunResultStore.ResultFileName))
			.FirstOrDefault(File.Exists);
	}
}
