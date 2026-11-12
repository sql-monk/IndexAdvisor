using System.Collections;
using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Infrastructure;

namespace IndexAdvisor.Gui.ViewModels.ConfigForm;

/// <summary>Розділ форми: ключ верхнього рівня YAML (connection, llm…) або «Загальні» для скалярів кореня.</summary>
public sealed class SettingSectionVm
{
	public SettingSectionVm(string key, string title, string description, IReadOnlyList<SettingNodeVm> items)
	{
		Key = key;
		Title = title;
		Description = description;
		Items = items;
	}

	public string Key { get; }

	public string Title { get; }

	public string Description { get; }

	public IReadOnlyList<SettingNodeVm> Items { get; }

	public override string ToString() => Title;
}

/// <summary>
/// Форма всіх налаштувань YAML, побудована зі схеми модуля (Shared/ConfigSchema.psd1).
/// Пошук фільтрує всі скалярні поля за назвою, ключем і описом.
/// </summary>
public sealed class ConfigFormViewModel : ObservableObject
{
	private static readonly Dictionary<string, string> SectionTitles = new()
	{
		["scope"] = "Ціль: бази, схеми, таблиці",
		["analysisWindow"] = "Вікно аналізу",
		["connection"] = "Підключення",
		["security"] = "Безпека",
		["limits"] = "Ліміти",
		["collector"] = "Збір даних",
		["archive"] = "Архів",
		["logging"] = "Журнал",
		["output"] = "Результати",
		["repository"] = "Репозиторій",
		["rules"] = "Правила",
		["partitioning"] = "Партиціонування",
		["llm"] = "LLM і провайдери",
		["tools"] = "Інструменти моделі",
		["unsafe"] = "Небезпечні режими",
		["maintenance"] = "Обслуговування індексів",
		["run"] = "Режим запуску",
	};

	private GroupSettingVm? _root;
	private SettingSectionVm? _selectedSection;
	private string? _searchText;
	private IReadOnlyList<ScalarSettingVm> _searchResults = [];
	private bool _isDirty;
	private bool _isBusy;
	private string? _statusText;
	private string? _schemaError;
	private IReadOnlyList<string> _unknownKeys = [];

	public ObservableCollection<SettingSectionVm> Sections { get; } = [];

	public bool IsAvailable => _root is not null;

	public string? SchemaError
	{
		get => _schemaError;
		private set => SetProperty(ref _schemaError, value);
	}

	public SettingSectionVm? SelectedSection
	{
		get => _selectedSection;
		set => SetProperty(ref _selectedSection, value);
	}

	public string? SearchText
	{
		get => _searchText;
		set
		{
			if (SetProperty(ref _searchText, value))
			{
				UpdateSearch();
			}
		}
	}

	public bool IsSearching => !string.IsNullOrWhiteSpace(_searchText);

	public IReadOnlyList<ScalarSettingVm> SearchResults
	{
		get => _searchResults;
		private set => SetProperty(ref _searchResults, value);
	}

	/// <summary>Форму змінено після останнього завантаження з YAML.</summary>
	public bool IsDirty
	{
		get => _isDirty;
		set => SetProperty(ref _isDirty, value);
	}

	public bool IsBusy
	{
		get => _isBusy;
		set => SetProperty(ref _isBusy, value);
	}

	/// <summary>Помилка розбору YAML або попередження про невідомі ключі.</summary>
	public string? StatusText
	{
		get => _statusText;
		set => SetProperty(ref _statusText, value);
	}

	public event EventHandler? Changed;

	public void Initialize(SchemaNode schema)
	{
		_root = new GroupSettingVm(schema, string.Empty, OnChanged);
		Sections.Clear();
		var general = _root.Children.Where(child => child is not GroupSettingVm).ToList();
		Sections.Add(new SettingSectionVm(string.Empty, "Загальні", "Версія формату, сервери й модуль аналізу", general));
		foreach (var group in _root.Children.OfType<GroupSettingVm>())
		{
			Sections.Add(new SettingSectionVm(
				group.Key,
				SectionTitles.TryGetValue(group.Key, out var title) ? title : group.Key,
				group.Node.Description,
				group.Children));
		}
		SelectedSection = Sections.FirstOrDefault();
		SchemaError = null;
		OnPropertyChanged(nameof(IsAvailable));
	}

	public void SetSchemaError(string message)
	{
		_root = null;
		Sections.Clear();
		SchemaError = message;
		OnPropertyChanged(nameof(IsAvailable));
	}

	/// <summary>Завантажити розібраний YAML (null — порожній файл).</summary>
	public void Load(JsonObject? values)
	{
		if (_root is null)
		{
			return;
		}
		var unknown = new List<string>();
		_root.Load(values, values is not null, unknown);
		_unknownKeys = unknown;
		StatusText = unknown.Count > 0
			? "Ключі, яких немає в схемі, не показано й не буде записано з форми: " + string.Join(", ", unknown)
			: null;
		IsDirty = false;
		UpdateSearch();
	}

	/// <summary>Ключі ціллі аналізу: їх шаблон може не зберігати, а нова конфігурація — підставляти.</summary>
	public const string ServersPath = "servers";
	public const string DatabasesPath = "scope.databases.include";

	/// <summary>YAML з форми. false — у формі є помилки (errors).</summary>
	public bool TryBuildYaml(out string yaml, out IReadOnlyList<string> errors)
		=> TryBuildYaml(out yaml, out errors, excludePaths: null, header: null);

	/// <param name="excludePaths">Ключі, які не записуються (наприклад, servers для шаблону).</param>
	public bool TryBuildYaml(out string yaml, out IReadOnlyList<string> errors, IEnumerable<string>? excludePaths, string? header)
	{
		yaml = string.Empty;
		var problems = new List<string>();
		if (_root is null)
		{
			errors = ["Схема конфігурації недоступна."];
			return false;
		}
		_root.TryBuild(out var value, problems);
		errors = problems;
		if (problems.Count > 0)
		{
			return false;
		}
		var map = (IDictionary)value!;
		foreach (var path in excludePaths ?? [])
		{
			RemovePath(map, path.Split('.'));
		}
		var comments = _root.Children
			.Where(child => child is GroupSettingVm)
			.ToDictionary(child => child.Key, child => child.Node.Description);
		yaml = YamlEmitter.Emit(map, comments, header ?? "Конфігурація IndexAdvisor (збережено з форми IndexAdvisor GUI).\nПовний перелік параметрів з описами: New-IaConfigTemplate.");
		return true;
	}

	/// <summary>Записати значення в поле за шляхом (scope.databases.include). Невідомий шлях — виняток.</summary>
	public void Assign(string path, JsonNode? value)
	{
		if (Find(path) is not ScalarSettingVm field)
		{
			throw new ArgumentException($"Налаштування '{path}' немає в схемі конфігурації.", nameof(path));
		}
		field.Assign(value);
	}

	/// <summary>Сервери й бази для нової конфігурації з шаблону. Порожнє значення — як у шаблоні.</summary>
	public void SetTarget(string? servers, string? databases)
	{
		if (CommandLineBuilder.SplitList(servers) is { Length: > 0 } serverList)
		{
			Assign(ServersPath, ToArray(serverList));
		}
		if (CommandLineBuilder.SplitList(databases) is { Length: > 0 } databaseList)
		{
			Assign(DatabasesPath, ToArray(databaseList));
		}
	}

	/// <summary>
	/// Перенести перевизначення форми запуску в налаштування (та сама відповідність, що й у ConvertTo-IaCliOverrides).
	/// Небезпечні режими, -FromArchive і -Verbose не переносяться: це рішення окремого запуску. Повертає змінені ключі.
	/// </summary>
	public IReadOnlyList<string> ApplyRunOptions(RunOptions options)
	{
		var applied = new List<string>();
		void List(string path, string? text)
		{
			var items = CommandLineBuilder.SplitList(text);
			if (items.Length > 0)
			{
				Assign(path, ToArray(items));
				applied.Add(path);
			}
		}
		void Text(string path, string? text)
		{
			if (!string.IsNullOrWhiteSpace(text))
			{
				Assign(path, JsonValue.Create(text.Trim()));
				applied.Add(path);
			}
		}
		void Flag(string path, bool? value, bool invert = false)
		{
			if (value is bool flag)
			{
				Assign(path, JsonValue.Create(invert ? !flag : flag));
				applied.Add(path);
			}
		}

		List(ServersPath, options.Servers);
		List(DatabasesPath, options.Databases);
		List("scope.databases.exclude", options.ExcludeDatabases);
		List("scope.schemas.include", options.Schemas);
		List("scope.schemas.exclude", options.ExcludeSchemas);
		List("scope.tables.include", options.Tables);
		List("scope.tables.exclude", options.ExcludeTables);
		Text("module", options.Module);
		Text("llm.provider", options.Provider);
		Text("llm.model", options.Model);
		Text("llm.crossCheckProvider", options.CrossCheckProvider);
		if (options.AnalysisWindowDays is int days)
		{
			Assign("analysisWindow.days", JsonValue.Create(days));
			applied.Add("analysisWindow.days");
		}
		if (options.Datasets is not null)
		{
			foreach (var name in IaConstants.OptionalDatasets)
			{
				Assign("collector.datasets." + name, JsonValue.Create(options.Datasets.Contains(name, StringComparer.OrdinalIgnoreCase)));
			}
			applied.Add("collector.datasets");
		}
		Text("output.path", options.OutputPath);
		if (options.Formats is { Count: > 0 } formats)
		{
			Assign("output.formats", ToArray(formats));
			applied.Add("output.formats");
		}
		Flag("repository.enabled", options.NoRepository, invert: true);
		Flag("archive.enabled", options.NoArchive, invert: true);
		Flag("run.nonInteractive", options.NonInteractive);
		Flag("llm.autoApproveToolRequests", options.AutoApprove);
		Flag("llm.localOnly", options.LocalOnly);
		Flag("llm.maskNames", options.MaskNames);
		Flag("maintenance.enabled", options.Maintenance);
		return applied;
	}

	private static JsonArray ToArray(IEnumerable<string> items) => new(items.Select(item => (JsonNode?)JsonValue.Create(item)).ToArray());

	/// <summary>Видалити ключ із побудованої мапи; порожні батьківські мапи теж прибираються.</summary>
	private static void RemovePath(IDictionary map, ReadOnlySpan<string> parts)
	{
		if (parts.Length == 0 || !map.Contains(parts[0]))
		{
			return;
		}
		if (parts.Length == 1)
		{
			map.Remove(parts[0]);
			return;
		}
		if (map[parts[0]] is IDictionary child)
		{
			RemovePath(child, parts[1..]);
			if (child.Count == 0)
			{
				map.Remove(parts[0]);
			}
		}
	}

	/// <summary>Усі скалярні поля (для тестів і пошуку).</summary>
	public IEnumerable<ScalarSettingVm> AllScalars() => _root?.Scalars() ?? [];

	public SettingNodeVm? Find(string path)
	{
		if (_root is null)
		{
			return null;
		}
		SettingNodeVm current = _root;
		foreach (var part in path.Split('.'))
		{
			if (current is not GroupSettingVm group || group.Children.FirstOrDefault(child => child.Key == part) is not { } next)
			{
				return null;
			}
			current = next;
		}
		return current;
	}

	private void OnChanged()
	{
		IsDirty = true;
		Changed?.Invoke(this, EventArgs.Empty);
	}

	private void UpdateSearch()
	{
		OnPropertyChanged(nameof(IsSearching));
		if (!IsSearching || _root is null)
		{
			SearchResults = [];
			return;
		}
		var terms = _searchText!.Split(' ', StringSplitOptions.RemoveEmptyEntries);
		SearchResults = _root.Scalars()
			.Where(item => terms.All(term =>
				item.Path.Contains(term, StringComparison.CurrentCultureIgnoreCase)
				|| item.Label.Contains(term, StringComparison.CurrentCultureIgnoreCase)))
			.ToList();
	}
}
