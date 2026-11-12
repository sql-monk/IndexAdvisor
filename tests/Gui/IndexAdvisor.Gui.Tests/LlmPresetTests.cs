using System.Text.Json.Nodes;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels.ConfigForm;

namespace IndexAdvisor.Gui.Tests;

/// <summary>Готові провайдери LLM у формі: додавання, вибір моделі, ціни, перевірка справжнім Test-IaConfig.</summary>
public sealed class LlmPresetTests : IDisposable
{
	private readonly string _directory = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));
	private readonly string _modulePath = ModuleLocator.Resolve(null);

	public LlmPresetTests()
	{
		Directory.CreateDirectory(_directory);
	}

	public void Dispose()
	{
		try
		{
			Directory.Delete(_directory, recursive: true);
		}
		catch (IOException)
		{
		}
	}

	private ConfigFormViewModel NewForm(JsonObject? values = null)
	{
		var form = new ConfigFormViewModel();
		form.Initialize(ConfigSchemaLoader.Load(ConfigSchemaLoader.FindSchemaPath(_modulePath)!));
		form.Load(values ?? new JsonObject { ["version"] = 1, ["servers"] = new JsonArray("SQL01") });
		return form;
	}

	private static MapSettingVm Providers(ConfigFormViewModel form) => (MapSettingVm)form.Find("llm.providers")!;

	private static TextSettingVm Text(CollectionItemVm item, string key) => item.Field<TextSettingVm>(key)!;

	private async Task AssertValidAsync(string yaml)
	{
		var path = Path.Combine(_directory, Guid.NewGuid().ToString("N") + ".yaml");
		File.WriteAllText(path, yaml);
		var result = await new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => _modulePath).TestConfigAsync(path);
		Assert.True(result.IsValid, string.Join("; ", result.Errors.Select(error => $"{error.Location} {error.Path} {error.Message}")) + Environment.NewLine + yaml);
	}

	[Fact]
	public void Catalog_ProviderTypesExistInSchema_AndKeysAreUnique()
	{
		var form = NewForm();
		var typeOptions = Providers(form).ItemNode.Find("type")!.Enum!;

		Assert.All(LlmCatalog.Providers, preset => Assert.Contains(preset.Type, typeOptions));
		Assert.Equal(LlmCatalog.Providers.Count, LlmCatalog.Providers.Select(preset => preset.Key).Distinct().Count());
		Assert.All(LlmCatalog.Providers, preset => Assert.NotEmpty(preset.Models));
	}

	[Theory]
	[InlineData("Anthropic", "", "anthropic")]
	[InlineData("OpenAICompatible", "http://localhost:11434/v1", "ollama")]
	[InlineData("OpenAICompatible", LlmCatalog.GeminiEndpoint, "gemini")]
	[InlineData("OpenAICompatible", "https://api.mistral.ai/v1", "mistral")]
	[InlineData("AzureOpenAI", "https://contoso.openai.azure.com", "azure")]
	public void Detect_ByTypeAndEndpoint(string type, string endpoint, string expected)
	{
		Assert.Equal(expected, LlmCatalog.Detect(type, endpoint)?.Key);
	}

	[Fact]
	public void UnknownCompatibleServer_SuggestsLocalModels()
	{
		var models = LlmCatalog.ModelsFor("OpenAICompatible", "http://gpu01:9000/v1").Select(model => model.Id).ToList();

		Assert.Contains("llama3.3:70b", models);
		Assert.Contains("meta-llama/Llama-3.3-70B-Instruct", models);
	}

	[Fact]
	public async Task AddPreset_FillsProvider_AndConfigIsValid()
	{
		var form = NewForm();
		var providers = Providers(form);

		var anthropic = providers.AddPreset(LlmCatalog.Find("anthropic")!);
		var ollama = providers.AddPreset(LlmCatalog.Find("ollama")!);
		var second = providers.AddPreset(LlmCatalog.Find("anthropic")!);

		Assert.Equal("anthropic", anthropic.Key);
		Assert.Equal("anthropic-2", second.Key);
		Assert.Equal("Anthropic", anthropic.Field<EnumSettingVm>("type")!.Selected);
		Assert.Equal("claude-opus-5-5", Text(anthropic, "model").Text);
		Assert.Equal("4", Text(anthropic, LlmPresetApplier.InputPrice).Text);
		Assert.Equal("20", Text(anthropic, LlmPresetApplier.OutputPrice).Text);
		Assert.Equal("0.2", Text(anthropic, LlmPresetApplier.CacheReadPrice).Text);
		Assert.Equal("32000", Text(anthropic, LlmPresetApplier.MaxTokens).Text);
		Assert.Equal("secret:IndexAdvisor-anthropic", Text(anthropic, "apiKeyRef").Text);
		Assert.True(ollama.Field<BoolSettingVm>("isLocal")!.Value);
		Assert.Equal("http://localhost:11434/v1", Text(ollama, "endpoint").Text);
		Assert.False(Text(ollama, LlmPresetApplier.InputPrice).IsSet);
		Assert.Contains(Text(anthropic, "model").Suggestions, item => item.Value == "claude-sonnet-5-5");

		form.Assign("llm.provider", JsonValue.Create("anthropic"));
		Assert.True(form.TryBuildYaml(out var yaml, out var errors), string.Join("; ", errors));
		Assert.Contains("model: claude-opus-5-5", yaml);
		await AssertValidAsync(yaml);
	}

	[Fact]
	public void ChangingModel_UpdatesAutomaticPrices_KeepsManualOnes()
	{
		var form = NewForm();
		var item = Providers(form).AddPreset(LlmCatalog.Find("anthropic")!);

		Text(item, "model").Text = "claude-sonnet-5-5";
		Assert.Equal("2", Text(item, LlmPresetApplier.InputPrice).Text);
		Assert.Equal("0.1", Text(item, LlmPresetApplier.CacheReadPrice).Text);

		Text(item, LlmPresetApplier.OutputPrice).Text = "12.5";
		Text(item, "model").Text = "claude-opus-5-5";
		Assert.Equal("4", Text(item, LlmPresetApplier.InputPrice).Text);
		Assert.Equal("12.5", Text(item, LlmPresetApplier.OutputPrice).Text);

		// Модель поза каталогом: ціни не чіпаються.
		Text(item, "model").Text = "my-finetune";
		Assert.Equal("4", Text(item, LlmPresetApplier.InputPrice).Text);
	}

	[Fact]
	public void ChoosingPresetAsProvider_AddsItToProviders()
	{
		var form = NewForm();
		var provider = (TextSettingVm)form.Find("llm.provider")!;

		Assert.Contains(provider.Suggestions, item => item.Value == "openai");
		provider.Text = "openai";
		Assert.True(form.TryBuildYaml(out var yaml, out var errors), string.Join("; ", errors));

		var added = Assert.Single(Providers(form).Items);
		Assert.Equal("openai", added.Key);
		Assert.Equal("gpt-5", Text(added, "model").Text);
		Assert.Contains("provider: openai", yaml);
		Assert.Contains(provider.Suggestions, item => item.Value == "openai" && !item.Note.Contains("буде додано"));
	}

	[Fact]
	public void LoadingYaml_DoesNotChangeValuesOrAddProviders()
	{
		var form = NewForm(new JsonObject
		{
			["version"] = 1,
			["llm"] = new JsonObject
			{
				["provider"] = "anthropic",
				["providers"] = new JsonObject
				{
					["local"] = new JsonObject { ["type"] = "OpenAICompatible", ["endpoint"] = "http://localhost:11434/v1", ["model"] = "llama3.1:8b", ["isLocal"] = true },
				},
			},
		});

		var item = Assert.Single(Providers(form).Items);
		Assert.Equal("local", item.Key);
		Assert.False(form.IsDirty);
		Assert.False(Text(item, LlmPresetApplier.MaxTokens).IsSet);
		Assert.Contains(Text(item, "model").Suggestions, suggestion => suggestion.Value == "qwen2.5-coder:32b");
		var modelOverride = (TextSettingVm)form.Find("llm.model")!;
		Assert.False(modelOverride.HasSuggestions);
	}
}
