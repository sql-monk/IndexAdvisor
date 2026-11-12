using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.ViewModels.ConfigForm;

/// <summary>Заповнення полів провайдера LLM з каталогу: тип, endpoint, ключ, модель, ціни, ліміти токенів.</summary>
public static class LlmPresetApplier
{
	public const string InputPrice = "inputPricePer1MTokensUsd";
	public const string OutputPrice = "outputPricePer1MTokensUsd";
	public const string CacheReadPrice = "cacheReadPricePer1MTokensUsd";
	public const string MaxTokens = "maxTokensPerRequest";

	public static void ApplyPreset(CollectionItemVm item, LlmProviderPreset preset)
	{
		Set(item, "type", JsonValue.Create(preset.Type));
		if (preset.Endpoint.Length > 0)
		{
			Set(item, "endpoint", JsonValue.Create(preset.Endpoint));
		}
		Set(item, "model", JsonValue.Create(preset.DefaultModel.Id));
		if (preset.ApiKeyRef is not null)
		{
			Set(item, "apiKeyRef", JsonValue.Create(preset.ApiKeyRef));
		}
		if (preset.IsLocal)
		{
			Set(item, "isLocal", JsonValue.Create(true));
		}
		if (preset.MaxContextTokens is int context)
		{
			Set(item, "maxContextTokens", JsonValue.Create(context));
		}
		ApplyModel(item, preset.DefaultModel, previous: null);
	}

	/// <summary>
	/// Ціни й ліміт токенів для моделі каталогу. Поле змінюється, лише якщо його не задано, воно нульове
	/// або містить ціну попередньої моделі каталогу (тобто заповнене автоматично): ручні значення лишаються.
	/// </summary>
	public static void ApplyModel(CollectionItemVm item, LlmModelPreset model, LlmModelPreset? previous)
	{
		Price(item, InputPrice, model.InputPrice, previous?.InputPrice);
		Price(item, OutputPrice, model.OutputPrice, previous?.OutputPrice);
		Price(item, CacheReadPrice, model.CacheReadPrice, previous?.CacheReadPrice);
		if (model.Thinking && item.Field<TextSettingVm>(MaxTokens) is { } maxTokens
			&& (maxTokens.Number ?? 0) < LlmCatalog.ThinkingMaxTokens)
		{
			maxTokens.Assign(JsonValue.Create(LlmCatalog.ThinkingMaxTokens));
		}
	}

	private static void Price(CollectionItemVm item, string key, double? price, double? previousPrice)
	{
		if (item.Field<TextSettingVm>(key) is not { } field)
		{
			return;
		}
		var current = field.Number ?? 0;
		var automatic = !field.IsSet || current == 0 || previousPrice is double old && Math.Abs(current - old) < 1e-9;
		if (!automatic)
		{
			return;
		}
		if (price is double value)
		{
			field.Assign(JsonValue.Create(value));
		}
		else if (field.IsSet)
		{
			field.Reset();
		}
	}

	private static void Set(CollectionItemVm item, string key, JsonNode? value)
	{
		if (item.Field<ScalarSettingVm>(key) is { } field)
		{
			field.Assign(value);
		}
	}

	internal static string Format(double value) => value.ToString(CultureInfo.InvariantCulture);
}

/// <summary>
/// Зв'язки між полями LLM у формі: вибір провайдера (llm.provider, llm.crossCheckProvider) з готових і доданих,
/// моделі й endpoint з каталогу для типу провайдера, ціни моделі. Під час завантаження YAML нічого не змінює.
/// </summary>
public sealed class LlmFormBinder
{
	private readonly MapSettingVm _providers;
	private readonly TextSettingVm? _provider;
	private readonly TextSettingVm? _crossCheck;
	private readonly TextSettingVm? _modelOverride;
	private readonly Dictionary<CollectionItemVm, ItemState> _items = [];
	private readonly HashSet<TextSettingVm> _pending = [];
	private bool _suspended;

	private LlmFormBinder(MapSettingVm providers, TextSettingVm? provider, TextSettingVm? crossCheck, TextSettingVm? modelOverride)
	{
		_providers = providers;
		_provider = provider;
		_crossCheck = crossCheck;
		_modelOverride = modelOverride;
		_providers.Presets = LlmCatalog.Providers;
		_providers.Items.CollectionChanged += OnItemsChanged;
		foreach (var field in new[] { _provider, _crossCheck })
		{
			if (field is not null)
			{
				field.PropertyChanged += OnProviderChoiceChanged;
			}
		}
		Refresh();
	}

	/// <summary>null — у схемі немає llm.providers.</summary>
	public static LlmFormBinder? Attach(ConfigFormViewModel form) =>
		form.Find("llm.providers") is MapSettingVm providers
			? new LlmFormBinder(
				providers,
				form.Find("llm.provider") as TextSettingVm,
				form.Find("llm.crossCheckProvider") as TextSettingVm,
				form.Find("llm.model") as TextSettingVm)
			: null;

	/// <summary>Завантаження YAML: значення не змінюються, підказки оновлюються після.</summary>
	public void Suspend() => _suspended = true;

	public void Resume()
	{
		_suspended = false;
		_pending.Clear();
		Refresh();
	}

	private void Refresh()
	{
		foreach (var item in _items.Keys.Except(_providers.Items).ToList())
		{
			Detach(item);
		}
		foreach (var item in _providers.Items)
		{
			if (!_items.ContainsKey(item))
			{
				AttachItem(item);
			}
			UpdateItemSuggestions(item);
		}
		UpdateProviderSuggestions();
	}

	private void OnItemsChanged(object? sender, NotifyCollectionChangedEventArgs e)
	{
		if (e.Action == NotifyCollectionChangedAction.Reset)
		{
			foreach (var item in _items.Keys.ToList())
			{
				Detach(item);
			}
		}
		foreach (var item in e.OldItems?.OfType<CollectionItemVm>() ?? [])
		{
			Detach(item);
		}
		foreach (var item in e.NewItems?.OfType<CollectionItemVm>() ?? [])
		{
			AttachItem(item);
			UpdateItemSuggestions(item);
		}
		UpdateProviderSuggestions();
	}

	private void AttachItem(CollectionItemVm item)
	{
		var state = new ItemState(item, ModelOf(item));
		state.Handler = (_, e) => OnItemFieldChanged(state, e);
		item.PropertyChanged += state.Handler;
		foreach (var key in new[] { "type", "endpoint", "model" })
		{
			if (item.Field<SettingNodeVm>(key) is { } field)
			{
				field.PropertyChanged += state.Handler;
			}
		}
		_items[item] = state;
	}

	private void Detach(CollectionItemVm item)
	{
		if (!_items.Remove(item, out var state) || state.Handler is null)
		{
			return;
		}
		item.PropertyChanged -= state.Handler;
		foreach (var key in new[] { "type", "endpoint", "model" })
		{
			if (item.Field<SettingNodeVm>(key) is { } field)
			{
				field.PropertyChanged -= state.Handler;
			}
		}
	}

	private void OnItemFieldChanged(ItemState state, PropertyChangedEventArgs e)
	{
		switch (e.PropertyName)
		{
			case nameof(CollectionItemVm.Key):
				UpdateProviderSuggestions();
				return;
			case nameof(EnumSettingVm.Selected):
			case nameof(TextSettingVm.Text):
				break;
			default:
				return;
		}
		UpdateItemSuggestions(state.Item);
		UpdateProviderSuggestions();
		var model = ModelOf(state.Item);
		if (!_suspended && model is not null && !ReferenceEquals(model, state.Model))
		{
			LlmPresetApplier.ApplyModel(state.Item, model, state.Model);
		}
		state.Model = model;
	}

	private void OnProviderChoiceChanged(object? sender, PropertyChangedEventArgs e)
	{
		if (e.PropertyName != nameof(TextSettingVm.Text) || sender is not TextSettingVm field)
		{
			return;
		}
		if (ReferenceEquals(field, _provider))
		{
			UpdateModelOverrideSuggestions();
		}
		if (_suspended)
		{
			return;
		}
		// Готового провайдера додаємо після паузи: поки ім'я вводять з клавіатури («openai» → «openai-prod»), нічого не додається.
		_pending.Add(field);
		_addTimer ??= CreateAddTimer();
		_addTimer.Stop();
		_addTimer.Start();
	}

	private DispatcherTimer? _addTimer;

	private DispatcherTimer CreateAddTimer()
	{
		var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(700) };
		timer.Tick += (_, _) =>
		{
			timer.Stop();
			AddChosenPresets();
		};
		return timer;
	}

	/// <summary>
	/// У llm.provider чи llm.crossCheckProvider користувач вибрав готового провайдера, якого ще немає в llm.providers, —
	/// додати його з типовою моделлю. Викликається після паузи у введенні й перед збиранням YAML.
	/// Значення, завантажені з файлу, не чіпаються: посилання на відсутнього провайдера покаже Test-IaConfig.
	/// </summary>
	public void AddChosenPresets()
	{
		_addTimer?.Stop();
		if (_suspended)
		{
			return;
		}
		var fields = _pending.ToList();
		_pending.Clear();
		foreach (var field in fields)
		{
			var name = field.Text.Trim();
			if (name.Length > 0 && _providers.FindItem(name) is null && LlmCatalog.Find(name) is { } preset)
			{
				_providers.AddPreset(preset, name);
			}
		}
	}

	private void UpdateItemSuggestions(CollectionItemVm item)
	{
		var type = TypeOf(item);
		var endpoint = EndpointOf(item);
		item.Field<TextSettingVm>("model")?.SetSuggestions(
			LlmCatalog.ModelsFor(type, endpoint).Select(model => new SuggestionItem(model.Id, ModelNote(model))));
		item.Field<TextSettingVm>("endpoint")?.SetSuggestions(
			LlmCatalog.EndpointsFor(type).Select(url => new SuggestionItem(url, EndpointNote(type, url))));
	}

	private void UpdateProviderSuggestions()
	{
		var items = new List<SuggestionItem>();
		foreach (var item in _providers.Items.Where(item => item.Key.Trim().Length > 0))
		{
			var model = item.Field<TextSettingVm>("model")?.Text.Trim();
			items.Add(new SuggestionItem(item.Key.Trim(), $"{TypeOf(item) ?? "тип не задано"}, {(string.IsNullOrEmpty(model) ? "модель не задано" : model)}"));
		}
		foreach (var preset in LlmCatalog.Providers.Where(preset => _providers.FindItem(preset.Key) is null))
		{
			items.Add(new SuggestionItem(preset.Key, $"{preset.Display} — буде додано до провайдерів"));
		}
		_provider?.SetSuggestions(items);
		_crossCheck?.SetSuggestions(items);
		UpdateModelOverrideSuggestions();
	}

	private void UpdateModelOverrideSuggestions()
	{
		if (_modelOverride is null)
		{
			return;
		}
		var item = _providers.FindItem(_provider?.Text);
		var models = item is null ? [] : LlmCatalog.ModelsFor(TypeOf(item), EndpointOf(item));
		_modelOverride.SetSuggestions(models.Select(model => new SuggestionItem(model.Id, ModelNote(model))));
	}

	private static string? TypeOf(CollectionItemVm item) => item.Field<EnumSettingVm>("type")?.Selected;

	private static string? EndpointOf(CollectionItemVm item) => item.Field<TextSettingVm>("endpoint")?.Text;

	private static LlmModelPreset? ModelOf(CollectionItemVm item) =>
		LlmCatalog.FindModel(TypeOf(item), EndpointOf(item), item.Field<TextSettingVm>("model")?.Text);

	internal static string ModelNote(LlmModelPreset model)
	{
		var parts = new List<string>();
		if (!string.IsNullOrEmpty(model.Note))
		{
			parts.Add(model.Note);
		}
		if (model.InputPrice is double input && model.OutputPrice is double output)
		{
			parts.Add($"${LlmPresetApplier.Format(input)} / ${LlmPresetApplier.Format(output)} за 1 млн токенів");
		}
		if (model.Thinking)
		{
			parts.Add("міркує");
		}
		return string.Join(" · ", parts);
	}

	private static string EndpointNote(string? type, string url) => type switch
	{
		"OpenAICompatible" => LlmCatalog.Providers.FirstOrDefault(preset => preset.Endpoint == url)?.Title ?? string.Empty,
		"AzureOpenAI" => "замініть <ресурс> на ім'я свого ресурсу",
		_ => "стандартний; порожньо — те саме",
	};

	private sealed class ItemState(CollectionItemVm item, LlmModelPreset? model)
	{
		public CollectionItemVm Item { get; } = item;

		public LlmModelPreset? Model { get; set; } = model;

		public PropertyChangedEventHandler? Handler { get; set; }
	}
}
