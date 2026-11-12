namespace IndexAdvisor.Gui.Core;

/// <summary>
/// Модель у каталозі GUI. Ціни — USD за 1 млн токенів; null — ціна не перевірена, її вводять вручну
/// (0 у конфігурації означає «вартість не рахується», бюджет тоді не обмежує).
/// </summary>
/// <param name="Thinking">Модель міркує перед відповіддю: міркування входять у maxTokensPerRequest.</param>
public sealed record LlmModelPreset(
	string Id,
	string Note,
	double? InputPrice = null,
	double? OutputPrice = null,
	double? CacheReadPrice = null,
	bool Thinking = false)
{
	public string Display => string.IsNullOrEmpty(Note) ? Id : $"{Id} — {Note}";

	public override string ToString() => Id;
}

/// <summary>Готовий провайдер для llm.providers: тип, endpoint, посилання на ключ і моделі (перша — типова).</summary>
public sealed record LlmProviderPreset(
	string Key,
	string Title,
	string Type,
	string Endpoint,
	string? ApiKeyRef,
	bool IsLocal,
	string Note,
	IReadOnlyList<LlmModelPreset> Models,
	int? MaxContextTokens = null)
{
	public LlmModelPreset DefaultModel => Models[0];

	public string Display => $"{Title} — {DefaultModel.Id}";

	public override string ToString() => Display;
}

/// <summary>
/// Каталог поширених LLM-провайдерів і моделей для форми налаштувань: щоб вибирати, а не вписувати вручну.
/// Усе можна змінити у формі; модуль приймає будь-яку модель, яку підтримує провайдер.
/// </summary>
public static class LlmCatalog
{
	/// <summary>Коли перевірено ціни Anthropic, OpenAI, Google і Cohere.</summary>
	public const string PricesAsOf = "листопад 2026";

	/// <summary>Ліміт вихідних токенів для моделей, що міркують (README: 32000 або більше).</summary>
	public const int ThinkingMaxTokens = 32000;

	public const string GeminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";

	public static IReadOnlyList<LlmProviderPreset> Providers { get; } =
	[
		new("anthropic", "Anthropic (Claude)", "Anthropic", string.Empty, "secret:IndexAdvisor-anthropic", false,
			"Хмара Anthropic; ключ API — у SecretStore. Кешування промптів увімкнене за замовчуванням.",
			[
				new("claude-opus-5-5", "Claude Opus 5.5, найкраще співвідношення якості й ціни", 4, 20, 0.2, Thinking: true),
				new("claude-sonnet-5-5", "Claude Sonnet 5.5, швидша й дешевша", 2, 10, 0.1, Thinking: true),
				new("claude-haiku-5-5", "Claude Haiku 5.5, найдешевша", 0.1, 0.5, Thinking: true),
				new("claude-fable-5-2", "Claude Fable 5.2, найпотужніша й найдорожча", 8, 40, 0.2, Thinking: true),
			],
			MaxContextTokens: 150000),
		new("openai", "OpenAI", "OpenAI", string.Empty, "secret:IndexAdvisor-openai", false,
			"Хмара OpenAI; ключ API — у SecretStore.",
			[
				new("gpt-5", "GPT-5", 1.25, 10, 0.125, Thinking: true),
				new("gpt-5-mini", "GPT-5 mini, дешевша", 0.25, 2, 0.025, Thinking: true),
				new("gpt-4.1", "GPT-4.1, без міркувань", 2, 8, 0.5),
			]),
		new("azure", "Azure OpenAI", "AzureOpenAI", string.Empty, "secret:IndexAdvisor-azure-openai", false,
			"Ваш ресурс Azure OpenAI: endpoint https://<ресурс>.openai.azure.com, модель — ім'я розгортання. Ціни — за договором Azure.",
			[
				new("gpt-5", "ім'я розгортання", Thinking: true),
				new("gpt-5-mini", "ім'я розгортання", Thinking: true),
				new("gpt-4.1", "ім'я розгортання"),
			]),
		new("gemini", "Google Gemini", "OpenAICompatible", GeminiEndpoint, "secret:IndexAdvisor-gemini", false,
			"OpenAI-сумісний API Gemini; ключ API Google AI Studio — у SecretStore.",
			[
				new("gemini-2.5-pro", "Gemini 2.5 Pro (контекст до 200 тис. токенів)", 1.25, 10, Thinking: true),
				new("gemini-2.5-flash", "Gemini 2.5 Flash, дешевша", 0.3, 2.5, Thinking: true),
			]),
		new("mistral", "Mistral AI", "OpenAICompatible", "https://api.mistral.ai/v1", "secret:IndexAdvisor-mistral", false,
			"OpenAI-сумісний API Mistral; ціни вкажіть за тарифом.",
			[
				new("mistral-large-latest", "Mistral Large, остання версія"),
				new("mistral-medium-latest", "Mistral Medium, остання версія"),
			]),
		new("deepseek", "DeepSeek", "OpenAICompatible", "https://api.deepseek.com/v1", "secret:IndexAdvisor-deepseek", false,
			"OpenAI-сумісний API DeepSeek; ціни вкажіть за тарифом.",
			[
				new("deepseek-chat", "DeepSeek, без міркувань"),
				new("deepseek-reasoner", "DeepSeek з міркуваннями", Thinking: true),
			]),
		new("cohere", "Cohere", "Cohere", string.Empty, "secret:IndexAdvisor-cohere", false,
			"Хмара Cohere; ключ API — у SecretStore.",
			[
				new("command-a-03-2025", "Command A", 2.5, 10),
			]),
		new("ollama", "Ollama (локально: Llama, Qwen…)", "OpenAICompatible", "http://localhost:11434/v1", null, true,
			"Локальна модель на цьому комп'ютері чи в мережі: дані не виходять назовні, працює в режимі localOnly. Модель спершу завантажте (ollama pull) і дайте їй достатній контекст (OLLAMA_CONTEXT_LENGTH).",
			[
				new("qwen2.5-coder:32b", "Qwen 2.5 Coder 32B"),
				new("llama3.3:70b", "Llama 3.3 70B"),
				new("llama3.1:8b", "Llama 3.1 8B, для слабкого заліза"),
				new("qwen3:32b", "Qwen 3 32B"),
				new("gpt-oss:20b", "gpt-oss 20B"),
				new("gemma3:27b", "Gemma 3 27B"),
			],
			MaxContextTokens: 32000),
		new("vllm", "vLLM (локальний сервер)", "OpenAICompatible", "http://localhost:8000/v1", null, true,
			"Власний сервер vLLM з OpenAI-сумісним API: модель — ім'я, з яким її запущено (--served-model-name).",
			[
				new("Qwen/Qwen2.5-Coder-32B-Instruct", "Qwen 2.5 Coder 32B"),
				new("meta-llama/Llama-3.3-70B-Instruct", "Llama 3.3 70B"),
			],
			MaxContextTokens: 32000),
	];

	public static LlmProviderPreset? Find(string? key) =>
		Providers.FirstOrDefault(preset => string.Equals(preset.Key, key?.Trim(), StringComparison.OrdinalIgnoreCase));

	/// <summary>Готовий провайдер, якому відповідають тип і endpoint з конфігурації.</summary>
	public static LlmProviderPreset? Detect(string? type, string? endpoint)
	{
		var url = endpoint?.Trim() ?? string.Empty;
		return type switch
		{
			"Anthropic" => Find("anthropic"),
			"OpenAI" => Find("openai"),
			"AzureOpenAI" => Find("azure"),
			"Cohere" => Find("cohere"),
			"OpenAICompatible" when url.Contains("generativelanguage.googleapis.com", StringComparison.OrdinalIgnoreCase) => Find("gemini"),
			"OpenAICompatible" when url.Contains("mistral.ai", StringComparison.OrdinalIgnoreCase) => Find("mistral"),
			"OpenAICompatible" when url.Contains("deepseek.com", StringComparison.OrdinalIgnoreCase) => Find("deepseek"),
			"OpenAICompatible" when url.Contains(":11434", StringComparison.Ordinal) => Find("ollama"),
			"OpenAICompatible" when url.Contains(":8000", StringComparison.Ordinal) => Find("vllm"),
			_ => null,
		};
	}

	/// <summary>Моделі для типу й endpoint; для невідомого OpenAI-сумісного сервера — локальні моделі.</summary>
	public static IReadOnlyList<LlmModelPreset> ModelsFor(string? type, string? endpoint)
	{
		if (Detect(type, endpoint) is { } preset)
		{
			return preset.Models;
		}
		return type == "OpenAICompatible"
			? [.. Find("ollama")!.Models, .. Find("vllm")!.Models]
			: [];
	}

	/// <summary>Типові endpoint для типу провайдера (порожньо — стандартний endpoint модуля).</summary>
	public static IReadOnlyList<string> EndpointsFor(string? type) => type switch
	{
		"OpenAI" => ["https://api.openai.com/v1"],
		"Anthropic" => ["https://api.anthropic.com"],
		"Cohere" => ["https://api.cohere.com"],
		"AzureOpenAI" => ["https://<ресурс>.openai.azure.com"],
		"OpenAICompatible" => Providers.Where(preset => preset.Type == "OpenAICompatible").Select(preset => preset.Endpoint).ToList(),
		_ => [],
	};

	/// <summary>Модель каталогу за ідентифікатором (для цін і ліміту токенів).</summary>
	public static LlmModelPreset? FindModel(string? type, string? endpoint, string? id)
	{
		if (string.IsNullOrWhiteSpace(id))
		{
			return null;
		}
		var models = Detect(type, endpoint)?.Models ?? ModelsFor(type, endpoint);
		return models.FirstOrDefault(model => string.Equals(model.Id, id.Trim(), StringComparison.OrdinalIgnoreCase));
	}

	/// <summary>Вільне ім'я в мапі провайдерів: anthropic, anthropic-2…</summary>
	public static string UniqueKey(string key, IEnumerable<string> existing)
	{
		var taken = existing.Select(item => item.Trim()).ToHashSet(StringComparer.OrdinalIgnoreCase);
		if (!taken.Contains(key))
		{
			return key;
		}
		for (var index = 2; ; index++)
		{
			var candidate = $"{key}-{index}";
			if (!taken.Contains(candidate))
			{
				return candidate;
			}
		}
	}
}
