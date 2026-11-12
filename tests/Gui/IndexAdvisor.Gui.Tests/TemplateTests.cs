using System.Text.Json.Nodes;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels.ConfigForm;

namespace IndexAdvisor.Gui.Tests;

/// <summary>Збереження з GUI: поля форми запуску → YAML, шаблони без серверів і баз → нова конфігурація.</summary>
public sealed class TemplateTests : IDisposable
{
	private const string BaseConfig = """
		version: 1
		servers: [OLD01]
		module: Indexes
		scope:
		  databases:
		    include: [OldDb]
		llm:
		  provider: local
		  providers:
		    local:
		      type: OpenAICompatible
		      endpoint: http://localhost:11434/v1
		      model: qwen2.5-coder:32b
		      isLocal: true
		output:
		  path: ./out
		""";

	private readonly string _directory = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));
	private readonly string _modulePath = ModuleLocator.Resolve(null);

	public TemplateTests()
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

	private async Task<ConfigFormViewModel> LoadFormAsync(string yaml)
	{
		var form = new ConfigFormViewModel();
		form.Initialize(ConfigSchemaLoader.Load(ConfigSchemaLoader.FindSchemaPath(_modulePath)!));
		var parsed = await new YamlService().ParseAsync(yaml);
		Assert.Null(parsed.Error);
		form.Load(parsed.Values);
		return form;
	}

	private async Task AssertValidAsync(string yaml)
	{
		var path = Path.Combine(_directory, Guid.NewGuid().ToString("N") + ".yaml");
		File.WriteAllText(path, yaml);
		var result = await new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => _modulePath).TestConfigAsync(path);
		Assert.True(result.IsValid, string.Join("; ", result.Errors.Select(error => $"{error.Location} {error.Path} {error.Message}")) + Environment.NewLine + yaml);
	}

	[Fact]
	public async Task RunOptions_AreWrittenIntoConfig()
	{
		var form = await LoadFormAsync(BaseConfig);

		var applied = form.ApplyRunOptions(new RunOptions
		{
			Servers = "SQL01, SQL02",
			Databases = "Sales; DWH",
			ExcludeTables = "dbo.Log*",
			Module = "Both",
			AnalysisWindowDays = 45,
			Datasets = ["queryStore"],
			Formats = ["Html", "Json"],
			NoRepository = true,
			MaskNames = false,
			Maintenance = true,
			UnsafeAllowFreeQuery = true,
			FromArchive = @"D:\archive.zip",
		});

		Assert.True(form.TryBuildYaml(out var yaml, out var errors), string.Join("; ", errors));
		Assert.Contains("servers: [SQL01, SQL02]", yaml);
		Assert.Contains("include: [Sales, DWH]", yaml);
		Assert.Contains("exclude: ['dbo.Log*']", yaml);
		Assert.Contains("module: Both", yaml);
		Assert.Contains("days: 45", yaml);
		Assert.Contains("usageStats: false", yaml);
		Assert.Contains("queryStore: true", yaml);
		Assert.Contains("formats: [Html, Json]", yaml);
		Assert.Contains("maskNames: false", yaml);
		Assert.DoesNotContain("allowFreeQuery", yaml);
		Assert.DoesNotContain("archive.zip", yaml);
		Assert.Contains("repository.enabled", applied);
		await AssertValidAsync(yaml);
		var reloaded = await LoadFormAsync(yaml);
		Assert.False(((BoolSettingVm)reloaded.Find("repository.enabled")!).Value);
		Assert.True(((BoolSettingVm)reloaded.Find("maintenance.enabled")!).Value);
	}

	[Fact]
	public async Task Template_WithoutTarget_ThenNewConfigWithServerAndDatabase()
	{
		var form = await LoadFormAsync(BaseConfig);
		var header = TemplateStore.Header("DWH щоночі", "Партиціонування, локальна модель", withoutServers: true, withoutDatabases: true);

		Assert.True(form.TryBuildYaml(out var template, out var errors, [ConfigFormViewModel.ServersPath, ConfigFormViewModel.DatabasesPath], header), string.Join("; ", errors));

		Assert.DoesNotContain("OLD01", template);
		Assert.DoesNotContain("OldDb", template);
		Assert.DoesNotContain("scope:", template);
		Assert.Contains("# Опис: Партиціонування, локальна модель", template);
		var templatePath = TemplateStore.PathFor(_directory, "DWH щоночі");
		File.WriteAllText(templatePath, template);
		var listed = TemplateStore.List(_directory);
		Assert.True(listed[0].IsBuiltIn);
		var saved = Assert.Single(listed, item => !item.IsBuiltIn);
		Assert.Equal("DWH щоночі", saved.Name);
		Assert.Equal("Партиціонування, локальна модель", saved.Description);

		var fromTemplate = await LoadFormAsync(File.ReadAllText(templatePath));
		fromTemplate.SetTarget("SQL07", "Sales, Billing");
		Assert.True(fromTemplate.TryBuildYaml(out var config, out errors), string.Join("; ", errors));

		Assert.Contains("servers: [SQL07]", config);
		Assert.Contains("include: [Sales, Billing]", config);
		Assert.Contains("provider: local", config);
		await AssertValidAsync(config);
	}

	[Fact]
	public void SetTarget_EmptyValuesKeepTemplate()
	{
		var form = new ConfigFormViewModel();
		form.Initialize(ConfigSchemaLoader.Load(ConfigSchemaLoader.FindSchemaPath(_modulePath)!));
		form.Load(new JsonObject { ["servers"] = new JsonArray("SQL01") });

		form.SetTarget(null, " ");

		Assert.False(form.IsDirty);
		Assert.Equal("SQL01", ((StringListSettingVm)form.Find(ConfigFormViewModel.ServersPath)!).Text);
	}

	[Theory]
	[InlineData("DWH: нічний", "DWH_ нічний.yaml")]
	[InlineData("  ", "шаблон.yaml")]
	[InlineData("a/b", "a_b.yaml")]
	public void ToFileName_ReplacesInvalidCharacters(string name, string expected)
	{
		Assert.Equal(expected, TemplateStore.ToFileName(name));
	}
}
