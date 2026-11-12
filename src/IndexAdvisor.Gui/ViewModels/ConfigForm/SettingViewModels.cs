using System.Collections;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Input;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Help;
using IndexAdvisor.Gui.Infrastructure;

namespace IndexAdvisor.Gui.ViewModels.ConfigForm;

/// <summary>Варіант для поля з вибором (модель, endpoint, провайдер): значення й пояснення.</summary>
public sealed record SuggestionItem(string Value, string Note)
{
	public override string ToString() => Value;
}

/// <summary>
/// Вузол форми налаштувань, побудований зі схеми. Значення завантажуються з розібраного YAML (JSON),
/// а назад збираються в упорядковані мапи для YamlEmitter. «Не задано» означає: ключа немає у файлі,
/// діє значення за замовчуванням зі схеми.
/// </summary>
public abstract class SettingNodeVm : ObservableObject
{
	private readonly Action _changed;
	private HelpInfo? _help;

	protected SettingNodeVm(SchemaNode node, string path, Action changed)
	{
		Node = node;
		Path = path;
		_changed = changed;
	}

	public SchemaNode Node { get; }

	public string Path { get; }

	public string Key => Node.Name;

	public string Label => string.IsNullOrWhiteSpace(Node.Description) ? Node.Name : Node.Description;

	/// <summary>Довідка «?»: що робить параметр, типове значення, межі.</summary>
	public HelpInfo Help => _help ??= HelpCatalog.ForSetting(this);

	protected bool IsLoading { get; set; }

	protected void NotifyChanged()
	{
		if (!IsLoading)
		{
			_changed();
		}
	}

	/// <summary>Завантажити значення; ключі, яких немає в схемі, — у unknownKeys.</summary>
	public abstract void Load(JsonNode? value, bool present, List<string> unknownKeys);

	/// <summary>Значення для запису або false, якщо ключ не записується. Помилки — у errors.</summary>
	public abstract bool TryBuild(out object? value, List<string> errors);

	public virtual IEnumerable<ScalarSettingVm> Scalars() => [];

	internal static SettingNodeVm Create(SchemaNode node, string path, Action changed) => node.Type switch
	{
		SchemaType.Object => new GroupSettingVm(node, path, changed),
		SchemaType.Bool => new BoolSettingVm(node, path, changed),
		SchemaType.String when node.Enum is { Count: > 0 } => new EnumSettingVm(node, path, changed),
		SchemaType.Array when node.ItemNode is not null => new ListSettingVm(node, path, changed),
		SchemaType.Array when node.Enum is { Count: > 0 } => new EnumListSettingVm(node, path, changed),
		SchemaType.Array => new StringListSettingVm(node, path, changed),
		SchemaType.Map => new MapSettingVm(node, path, changed),
		_ => new TextSettingVm(node, path, changed),
	};

	internal static string Join(string parent, string name) => string.IsNullOrEmpty(parent) ? name : parent + "." + name;
}

/// <summary>Об'єкт схеми: набір дочірніх налаштувань.</summary>
public sealed class GroupSettingVm : SettingNodeVm
{
	public GroupSettingVm(SchemaNode node, string path, Action changed)
		: base(node, path, changed)
	{
		Children = node.Properties.Select(child => Create(child, Join(path, child.Name), changed)).ToList();
	}

	public IReadOnlyList<SettingNodeVm> Children { get; }

	public override void Load(JsonNode? value, bool present, List<string> unknownKeys)
	{
		var map = value as JsonObject;
		if (map is not null)
		{
			foreach (var (name, _) in map)
			{
				if (Node.Find(name) is null)
				{
					unknownKeys.Add(Join(Path, name));
				}
			}
		}
		foreach (var child in Children)
		{
			JsonNode? childValue = null;
			var childPresent = map is not null && map.TryGetPropertyValue(child.Key, out childValue);
			child.Load(childValue, childPresent, unknownKeys);
		}
	}

	public override bool TryBuild(out object? value, List<string> errors)
	{
		var map = new OrderedDictionary();
		foreach (var child in Children)
		{
			if (child.TryBuild(out var childValue, errors))
			{
				map[child.Key] = childValue;
			}
		}
		value = map;
		return map.Count > 0;
	}

	public override IEnumerable<ScalarSettingVm> Scalars() => Children.SelectMany(child => child.Scalars());
}

/// <summary>Скалярне налаштування або список скалярів.</summary>
public abstract class ScalarSettingVm : SettingNodeVm
{
	private bool _isSet;
	private string? _error;

	protected ScalarSettingVm(SchemaNode node, string path, Action changed)
		: base(node, path, changed)
	{
		ResetCommand = new RelayCommand(Reset, () => IsSet);
	}

	/// <summary>Ключ є у файлі (або змінений у формі) і буде записаний.</summary>
	public bool IsSet
	{
		get => _isSet;
		protected set => SetProperty(ref _isSet, value);
	}

	public string? Error
	{
		get => _error;
		protected set => SetProperty(ref _error, value);
	}

	public ICommand ResetCommand { get; }

	public string DefaultText => Node.Required && Node.Default is null
		? "обов'язковий"
		: "типово: " + FormatDefault(Node.Default);

	public string? Hint
	{
		get
		{
			var parts = new List<string>();
			if (Node.Secret)
			{
				parts.Add("лише посилання: secret:Сховище/Секрет, secret:Секрет або env:ЗМІННА — не сам пароль чи ключ");
			}
			if (Node.Min is not null || Node.Max is not null)
			{
				parts.Add($"від {Node.Min?.ToString(CultureInfo.InvariantCulture) ?? "—"} до {Node.Max?.ToString(CultureInfo.InvariantCulture) ?? "—"}");
			}
			if (this is StringListSettingVm)
			{
				parts.Add("кілька значень — через кому");
			}
			return parts.Count > 0 ? string.Join("; ", parts) : null;
		}
	}

	public override IEnumerable<ScalarSettingVm> Scalars() => [this];

	public override void Load(JsonNode? value, bool present, List<string> unknownKeys)
	{
		IsLoading = true;
		try
		{
			if (present)
			{
				SetFromJson(value);
			}
			else
			{
				ApplyDefault();
			}
			IsSet = present;
			Error = Validate();
		}
		finally
		{
			IsLoading = false;
		}
	}

	public override bool TryBuild(out object? value, List<string> errors)
	{
		value = null;
		if (!IsSet && !Node.Required)
		{
			return false;
		}
		Error = Validate();
		if (Error is not null)
		{
			errors.Add($"{Path}: {Error}");
			return false;
		}
		value = GetValue();
		return true;
	}

	/// <summary>Задати значення програмно (з форми запуску, шаблону): ключ записується у файл.</summary>
	public void Assign(JsonNode? value)
	{
		IsLoading = true;
		try
		{
			SetFromJson(value);
			IsSet = true;
			Error = Validate();
		}
		finally
		{
			IsLoading = false;
		}
		NotifyChanged();
	}

	/// <summary>Повернути значення за замовчуванням: ключ не записується.</summary>
	public void Reset()
	{
		IsLoading = true;
		try
		{
			ApplyDefault();
			IsSet = false;
			Error = Validate();
		}
		finally
		{
			IsLoading = false;
		}
		NotifyChanged();
	}

	/// <summary>Користувач змінив значення.</summary>
	protected void MarkEdited()
	{
		if (IsLoading)
		{
			return;
		}
		IsSet = true;
		Error = Validate();
		NotifyChanged();
	}

	protected abstract void ApplyDefault();

	protected abstract void SetFromJson(JsonNode? value);

	protected abstract string? Validate();

	protected abstract object? GetValue();

	internal static string JsonText(JsonNode? value) => value switch
	{
		null => string.Empty,
		JsonValue scalar when scalar.GetValueKind() == JsonValueKind.String => scalar.GetValue<string>(),
		_ => value.ToJsonString(),
	};

	internal static string FormatDefault(object? value) => value switch
	{
		null => "—",
		"" => "порожньо",
		bool flag => flag ? "так" : "ні",
		IEnumerable<object?> items when !items.Any() => "порожньо",
		IEnumerable<object?> items => string.Join(", ", items.Select(item => Convert.ToString(item, CultureInfo.InvariantCulture))),
		double number => number.ToString(CultureInfo.InvariantCulture),
		_ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty,
	};
}

public sealed class BoolSettingVm : ScalarSettingVm
{
	private bool _value;
	private string? _invalidText;

	public BoolSettingVm(SchemaNode node, string path, Action changed)
		: base(node, path, changed)
	{
		ApplyDefault();
	}

	public bool Value
	{
		get => _value;
		set
		{
			if (SetProperty(ref _value, value))
			{
				_invalidText = null;
				MarkEdited();
			}
		}
	}

	protected override void ApplyDefault()
	{
		_invalidText = null;
		SetProperty(ref _value, Node.Default is true, nameof(Value));
	}

	protected override void SetFromJson(JsonNode? value)
	{
		_invalidText = null;
		if (value is JsonValue scalar && scalar.GetValueKind() is JsonValueKind.True or JsonValueKind.False)
		{
			SetProperty(ref _value, scalar.GetValue<bool>(), nameof(Value));
		}
		else
		{
			_invalidText = JsonText(value);
			SetProperty(ref _value, false, nameof(Value));
		}
	}

	protected override string? Validate() => _invalidText is null ? null : $"у файлі не логічне значення: '{_invalidText}'";

	protected override object? GetValue() => _value;
}

/// <summary>Рядок, ціле число, число або посилання на секрет.</summary>
public sealed class TextSettingVm : ScalarSettingVm
{
	private string _text = string.Empty;

	public TextSettingVm(SchemaNode node, string path, Action changed)
		: base(node, path, changed)
	{
		ApplyDefault();
	}

	public string Text
	{
		get => _text;
		set
		{
			if (SetProperty(ref _text, value ?? string.Empty))
			{
				MarkEdited();
			}
		}
	}

	public bool IsNumeric => Node.Type is SchemaType.Int or SchemaType.Number;

	/// <summary>Готові значення для вибору (моделі, endpoint, провайдери); можна ввести й своє.</summary>
	public ObservableCollection<SuggestionItem> Suggestions { get; } = [];

	public bool HasSuggestions => Suggestions.Count > 0;

	public void SetSuggestions(IEnumerable<SuggestionItem> items)
	{
		var list = items.ToList();
		if (list.Count == Suggestions.Count && list.SequenceEqual(Suggestions))
		{
			return;
		}
		var hadSuggestions = HasSuggestions;
		Suggestions.Clear();
		foreach (var item in list)
		{
			Suggestions.Add(item);
		}
		if (hadSuggestions != HasSuggestions)
		{
			OnPropertyChanged(nameof(HasSuggestions));
		}
	}

	/// <summary>Числове значення поля (null — порожньо або не число).</summary>
	public double? Number => double.TryParse(_text.Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;

	protected override void ApplyDefault() => SetProperty(ref _text, Node.Default is null ? string.Empty : FormatScalar(Node.Default), nameof(Text));

	protected override void SetFromJson(JsonNode? value) => SetProperty(ref _text, JsonText(value), nameof(Text));

	protected override string? Validate()
	{
		var text = _text.Trim();
		if (text.Length == 0)
		{
			return Node.Required ? "обов'язковий параметр" : Node.Type is SchemaType.Int or SchemaType.Number ? "введіть число" : null;
		}
		switch (Node.Type)
		{
			case SchemaType.Int:
				if (!long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var whole))
				{
					return "ціле число";
				}
				return RangeError(whole);
			case SchemaType.Number:
				if (!TryParseNumber(text, out var number))
				{
					return "число (крапка як десятковий роздільник)";
				}
				return RangeError(number);
			default:
				if (Node.Secret && !(text.StartsWith("secret:", StringComparison.Ordinal) || text.StartsWith("env:", StringComparison.Ordinal)))
				{
					return "лише посилання secret:… або env:…; пароль чи ключ у YAML не зберігається";
				}
				return null;
		}
	}

	protected override object? GetValue()
	{
		var text = _text.Trim();
		return Node.Type switch
		{
			SchemaType.Int => long.Parse(text, CultureInfo.InvariantCulture),
			SchemaType.Number => TryParseNumber(text, out var number) ? number : 0d,
			_ => _text,
		};
	}

	private string? RangeError(double value)
	{
		if (Node.Min is double min && value < min)
		{
			return $"не менше {min.ToString(CultureInfo.InvariantCulture)}";
		}
		if (Node.Max is double max && value > max)
		{
			return $"не більше {max.ToString(CultureInfo.InvariantCulture)}";
		}
		return null;
	}

	private static bool TryParseNumber(string text, out double value)
		=> double.TryParse(text.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out value);

	private static string FormatScalar(object value) => value switch
	{
		double number => number.ToString(CultureInfo.InvariantCulture),
		_ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty,
	};
}

/// <summary>Рядок із переліку (Enum).</summary>
public sealed class EnumSettingVm : ScalarSettingVm
{
	private string? _selected;
	private string? _invalidText;

	public EnumSettingVm(SchemaNode node, string path, Action changed)
		: base(node, path, changed)
	{
		Options = node.Enum!;
		ApplyDefault();
	}

	public IReadOnlyList<string> Options { get; }

	public string? Selected
	{
		get => _selected;
		set
		{
			if (SetProperty(ref _selected, value))
			{
				_invalidText = null;
				MarkEdited();
			}
		}
	}

	protected override void ApplyDefault()
	{
		_invalidText = null;
		SetProperty(ref _selected, Node.Default as string, nameof(Selected));
	}

	protected override void SetFromJson(JsonNode? value)
	{
		var text = JsonText(value);
		var match = Options.FirstOrDefault(option => string.Equals(option, text, StringComparison.OrdinalIgnoreCase));
		_invalidText = match is null ? text : null;
		SetProperty(ref _selected, match, nameof(Selected));
	}

	protected override string? Validate()
	{
		if (_invalidText is not null)
		{
			return $"у файлі недопустиме значення '{_invalidText}'";
		}
		return string.IsNullOrEmpty(_selected) && (Node.Required || IsSet) ? "виберіть значення" : null;
	}

	protected override object? GetValue() => _selected;
}

/// <summary>Список рядків (через кому).</summary>
public sealed class StringListSettingVm : ScalarSettingVm
{
	private string _text = string.Empty;

	public StringListSettingVm(SchemaNode node, string path, Action changed)
		: base(node, path, changed)
	{
		ApplyDefault();
	}

	public string Text
	{
		get => _text;
		set
		{
			if (SetProperty(ref _text, value ?? string.Empty))
			{
				MarkEdited();
			}
		}
	}

	protected override void ApplyDefault()
		=> SetProperty(ref _text, string.Join(", ", (Node.Default as IEnumerable<object?> ?? []).Select(item => Convert.ToString(item, CultureInfo.InvariantCulture))), nameof(Text));

	protected override void SetFromJson(JsonNode? value)
	{
		var items = value switch
		{
			JsonArray array => array.Select(JsonText),
			null => [],
			_ => [JsonText(value)],
		};
		SetProperty(ref _text, string.Join(", ", items), nameof(Text));
	}

	protected override string? Validate() => null;

	protected override object? GetValue() => CommandLineBuilder.SplitList(_text).Cast<object?>().ToList();
}

/// <summary>Список значень із переліку (дні тижня, формати).</summary>
public sealed class EnumListSettingVm : ScalarSettingVm
{
	private List<string> _invalid = [];

	public EnumListSettingVm(SchemaNode node, string path, Action changed)
		: base(node, path, changed)
	{
		Items = new ObservableCollection<CheckItem>(node.Enum!.Select(option => new CheckItem(option, option, isChecked: false)));
		foreach (var item in Items)
		{
			item.PropertyChanged += (_, _) => MarkEdited();
		}
		ApplyDefault();
	}

	public ObservableCollection<CheckItem> Items { get; }

	protected override void ApplyDefault()
	{
		_invalid = [];
		SetChecked(Node.Default as IEnumerable<object?> ?? []);
	}

	protected override void SetFromJson(JsonNode? value)
	{
		var values = value switch
		{
			JsonArray array => array.Select(JsonText).ToList(),
			null => [],
			_ => [JsonText(value)],
		};
		_invalid = values.Where(text => !Items.Any(item => string.Equals(item.Name, text, StringComparison.OrdinalIgnoreCase))).ToList();
		SetChecked(values);
	}

	protected override string? Validate() => _invalid.Count > 0 ? "у файлі недопустимі значення: " + string.Join(", ", _invalid) : null;

	protected override object? GetValue() => Items.Where(item => item.IsChecked).Select(item => (object?)item.Name).ToList();

	private void SetChecked(IEnumerable<object?> values)
	{
		var set = values.Select(value => Convert.ToString(value, CultureInfo.InvariantCulture)).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var wasLoading = IsLoading;
		IsLoading = true;
		foreach (var item in Items)
		{
			item.IsChecked = set.Contains(item.Name);
		}
		IsLoading = wasLoading;
	}
}

/// <summary>Елемент списку об'єктів або значення мапи: власні поля за схемою елемента.</summary>
public sealed class CollectionItemVm : ObservableObject
{
	private readonly Action _changed;
	private string _key = string.Empty;

	public CollectionItemVm(SchemaNode itemNode, string path, bool hasKey, Action changed, Action<CollectionItemVm> remove)
	{
		HasKey = hasKey;
		_changed = changed;
		Group = new GroupSettingVm(itemNode, path, changed);
		RemoveCommand = new RelayCommand(() => remove(this));
	}

	public bool HasKey { get; }

	/// <summary>Ім'я в мапі (наприклад, ім'я провайдера LLM).</summary>
	public string Key
	{
		get => _key;
		set
		{
			if (SetProperty(ref _key, value ?? string.Empty))
			{
				_changed();
			}
		}
	}

	public GroupSettingVm Group { get; }

	public IReadOnlyList<SettingNodeVm> Children => Group.Children;

	/// <summary>Поле елемента за ключем схеми (type, model…).</summary>
	public T? Field<T>(string key) where T : SettingNodeVm => Group.Children.FirstOrDefault(child => child.Key == key) as T;

	public ICommand RemoveCommand { get; }

	public void LoadKey(string key) => SetProperty(ref _key, key, nameof(Key));

	public OrderedDictionary Build(List<string> errors)
	{
		Group.TryBuild(out var value, errors);
		return (OrderedDictionary)value!;
	}
}

/// <summary>Спільне для списку об'єктів і мапи об'єктів.</summary>
public abstract class CollectionSettingVm : SettingNodeVm
{
	private bool _isSet;

	protected CollectionSettingVm(SchemaNode node, SchemaNode itemNode, string path, Action changed)
		: base(node, path, changed)
	{
		ItemNode = itemNode;
		AddCommand = new RelayCommand(() =>
		{
			Items.Add(NewItem());
			IsSet = true;
			NotifyChanged();
		});
	}

	public SchemaNode ItemNode { get; }

	public ObservableCollection<CollectionItemVm> Items { get; } = [];

	public ICommand AddCommand { get; }

	public bool IsSet
	{
		get => _isSet;
		protected set => SetProperty(ref _isSet, value);
	}

	public abstract bool HasKeys { get; }

	public string AddText => HasKeys ? "Додати" : "Додати елемент";

	protected CollectionItemVm NewItem(string? key = null)
	{
		var index = Items.Count;
		var item = new CollectionItemVm(ItemNode, $"{Path}[{key ?? index.ToString(CultureInfo.InvariantCulture)}]", HasKeys, NotifyChanged, Remove);
		if (key is not null)
		{
			item.LoadKey(key);
		}
		return item;
	}

	private void Remove(CollectionItemVm item)
	{
		Items.Remove(item);
		IsSet = true;
		NotifyChanged();
	}
}

/// <summary>Масив об'єктів (rules.observationOverrides).</summary>
public sealed class ListSettingVm : CollectionSettingVm
{
	public ListSettingVm(SchemaNode node, string path, Action changed)
		: base(node, node.ItemNode!, path, changed)
	{
	}

	public override bool HasKeys => false;

	public override void Load(JsonNode? value, bool present, List<string> unknownKeys)
	{
		IsLoading = true;
		try
		{
			Items.Clear();
			if (value is JsonArray array)
			{
				foreach (var element in array)
				{
					var item = NewItem();
					item.Group.Load(element, true, unknownKeys);
					Items.Add(item);
				}
			}
			IsSet = present;
		}
		finally
		{
			IsLoading = false;
		}
	}

	public override bool TryBuild(out object? value, List<string> errors)
	{
		value = Items.Select(item => (object?)item.Build(errors)).ToList();
		return IsSet || Items.Count > 0;
	}
}

/// <summary>Мапа об'єктів за іменами (llm.providers).</summary>
public sealed class MapSettingVm : CollectionSettingVm
{
	private IReadOnlyList<LlmProviderPreset> _presets = [];

	public MapSettingVm(SchemaNode node, string path, Action changed)
		: base(node, node.Values!, path, changed)
	{
		AddPresetCommand = new RelayCommand(parameter =>
		{
			if (parameter is LlmProviderPreset preset)
			{
				AddPreset(preset);
			}
		});
	}

	public override bool HasKeys => true;

	/// <summary>Готові елементи для «Додати готовий…» (провайдери LLM); порожньо — лише «Додати».</summary>
	public IReadOnlyList<LlmProviderPreset> Presets
	{
		get => _presets;
		set
		{
			if (SetProperty(ref _presets, value))
			{
				OnPropertyChanged(nameof(HasPresets));
			}
		}
	}

	public bool HasPresets => _presets.Count > 0;

	public ICommand AddPresetCommand { get; }

	public IEnumerable<string> Keys => Items.Select(item => item.Key.Trim()).Where(key => key.Length > 0);

	public CollectionItemVm? FindItem(string? key) =>
		string.IsNullOrWhiteSpace(key) ? null : Items.FirstOrDefault(item => string.Equals(item.Key.Trim(), key.Trim(), StringComparison.Ordinal));

	/// <summary>Додати провайдера з каталогу з типовою моделлю; ім'я — вільне (anthropic, anthropic-2…), якщо не задано.</summary>
	public CollectionItemVm AddPreset(LlmProviderPreset preset, string? key = null)
	{
		var item = NewItem(LlmCatalog.UniqueKey(string.IsNullOrWhiteSpace(key) ? preset.Key : key.Trim(), Keys));
		LlmPresetApplier.ApplyPreset(item, preset);
		Items.Add(item);
		IsSet = true;
		NotifyChanged();
		return item;
	}

	public override void Load(JsonNode? value, bool present, List<string> unknownKeys)
	{
		IsLoading = true;
		try
		{
			Items.Clear();
			if (value is JsonObject map)
			{
				foreach (var (key, element) in map)
				{
					var item = NewItem(key);
					item.Group.Load(element, true, unknownKeys);
					Items.Add(item);
				}
			}
			IsSet = present;
		}
		finally
		{
			IsLoading = false;
		}
	}

	public override bool TryBuild(out object? value, List<string> errors)
	{
		var map = new OrderedDictionary();
		foreach (var item in Items)
		{
			var key = item.Key.Trim();
			if (key.Length == 0)
			{
				errors.Add($"{Path}: вкажіть ім'я");
				continue;
			}
			if (map.Contains(key))
			{
				errors.Add($"{Path}: ім'я '{key}' повторюється");
				continue;
			}
			map[key] = item.Build(errors);
		}
		value = map;
		return map.Count > 0 || IsSet && Items.Count > 0;
	}
}
