using System.Collections.Specialized;
using System.Text.Json.Nodes;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels.ConfigForm;

namespace IndexAdvisor.Gui.Tests;

public class YamlEmitterTests
{
	[Theory]
	[InlineData("Both", "Both")]
	[InlineData("index-advisor", "index-advisor")]
	[InlineData("01:00", "'01:00'")]
	[InlineData("true", "'true'")]
	[InlineData("no", "'no'")]
	[InlineData("42", "'42'")]
	[InlineData("secret:IndexAdvisor/openai-key", "'secret:IndexAdvisor/openai-key'")]
	[InlineData(@"D:\IndexAdvisor\out", @"'D:\IndexAdvisor\out'")]
	[InlineData("O'Brien", "'O''Brien'")]
	[InlineData("dbo.Log*", "'dbo.Log*'")]
	[InlineData("", "''")]
	[InlineData("Продажі", "'Продажі'")]
	public void Scalar_QuotesOnlyWhenNeeded(string value, string expected)
	{
		Assert.Equal(expected, YamlEmitter.Scalar(value));
	}

	[Fact]
	public void Scalar_NumbersAndBooleans()
	{
		Assert.Equal("30", YamlEmitter.Scalar(30L));
		Assert.Equal("0.6", YamlEmitter.Scalar(0.6));
		Assert.Equal("true", YamlEmitter.Scalar(true));
	}

	[Fact]
	public void Emit_NestedMapsListsAndListOfMaps()
	{
		var root = new OrderedDictionary
		{
			["version"] = 1L,
			["servers"] = new List<object?> { "SQL01", "AGL-SALES" },
			["rules"] = new OrderedDictionary
			{
				["observationOverrides"] = new List<object?>
				{
					new OrderedDictionary { ["server"] = "AG1", ["database"] = "Sales", ["minUptimeDays"] = 30L },
				},
			},
			["llm"] = new OrderedDictionary
			{
				["providers"] = new OrderedDictionary
				{
					["local"] = new OrderedDictionary { ["type"] = "OpenAICompatible", ["isLocal"] = true },
				},
			},
		};

		var yaml = YamlEmitter.Emit(root, new Dictionary<string, string> { ["rules"] = "Правила" });

		Assert.Equal(
			"""
			version: 1
			servers: [SQL01, AGL-SALES]

			# Правила
			rules:
			  observationOverrides:
			    - server: AG1
			      database: Sales
			      minUptimeDays: 30
			llm:
			  providers:
			    local:
			      type: OpenAICompatible
			      isLocal: true

			""".Replace("\r\n", "\n"),
			yaml.Replace("\r\n", "\n"));
	}
}

public class ConfigSchemaTests
{
	private static SchemaNode LoadSchema()
		=> ConfigSchemaLoader.Load(ConfigSchemaLoader.FindSchemaPath(ModuleLocator.Resolve(null))!);

	[Fact]
	public void Load_ReadsNestedObjectsMapsAndLists()
	{
		var schema = LoadSchema();

		Assert.Equal(SchemaType.Object, schema.Type);
		Assert.Equal(["Indexes", "Partitioning", "Both"], schema.Find("module")!.Enum);
		var providers = schema.Find("llm")!.Find("providers")!;
		Assert.Equal(SchemaType.Map, providers.Type);
		Assert.True(providers.Values!.Find("apiKeyRef")!.Secret);
		Assert.True(providers.Values.Find("type")!.Required);
		var overrides = schema.Find("rules")!.Find("observationOverrides")!;
		Assert.Equal(SchemaType.Array, overrides.Type);
		Assert.NotNull(overrides.ItemNode);
		Assert.Equal(14, overrides.ItemNode!.Find("minUptimeDays")!.Min);
		Assert.Equal(7, schema.Find("maintenance")!.Find("scheduleDays")!.Enum!.Count);
		Assert.Equal(0.6, schema.Find("partitioning")!.Find("minDateFilterShare")!.Default);
	}

	[Fact]
	public void Form_CoversEverySchemaScalar()
	{
		var schema = LoadSchema();
		var form = new ConfigFormViewModel();
		form.Initialize(schema);

		static IEnumerable<string> SchemaScalars(SchemaNode node, string path) => node.Type switch
		{
			SchemaType.Object => node.Properties.SelectMany(child => SchemaScalars(child, path.Length == 0 ? child.Name : path + "." + child.Name)),
			SchemaType.Map => [],
			SchemaType.Array when node.ItemNode is not null => [],
			_ => [path],
		};

		Assert.Equal(SchemaScalars(schema, string.Empty).Order(), form.AllScalars().Select(item => item.Path).Order());
		Assert.True(form.Sections.Count >= 15);
	}
}

/// <summary>Повний цикл зі справжнім модулем: YAML → форма → YAML → Test-IaConfig.</summary>
public sealed class ConfigFormRoundTripTests : IDisposable
{
	private readonly string _directory = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));
	private readonly string _modulePath = ModuleLocator.Resolve(null);

	public ConfigFormRoundTripTests()
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

	private ConfigFormViewModel NewForm()
	{
		var form = new ConfigFormViewModel();
		form.Initialize(ConfigSchemaLoader.Load(ConfigSchemaLoader.FindSchemaPath(_modulePath)!));
		return form;
	}

	private async Task<(bool IsValid, string Errors)> ValidateAsync(string yaml)
	{
		var path = Path.Combine(_directory, Guid.NewGuid().ToString("N") + ".yaml");
		File.WriteAllText(path, yaml);
		var result = await new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => _modulePath).TestConfigAsync(path);
		return (result.IsValid, string.Join("; ", result.Errors.Select(error => $"{error.Location} {error.Path} {error.Message}")));
	}

	[Fact]
	public async Task Template_RoundTripsThroughForm_AndStaysValid()
	{
		var templatePath = Path.Combine(_directory, "template.yaml");
		await new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => _modulePath).NewConfigTemplateAsync(templatePath);
		var parsed = await new YamlService().ParseAsync(File.ReadAllText(templatePath));
		Assert.Null(parsed.Error);
		var form = NewForm();

		form.Load(parsed.Values);
		Assert.Null(form.StatusText);
		Assert.True(form.TryBuildYaml(out var yaml, out var errors), string.Join("; ", errors));

		var validation = await ValidateAsync(yaml);
		Assert.True(validation.IsValid, validation.Errors + Environment.NewLine + yaml);
	}

	[Fact]
	public async Task EditedForm_WritesOnlySetKeys_AndModuleAcceptsIt()
	{
		const string source = """
			version: 1
			servers: [SQL01]
			module: Both
			unknownKey: 5
			llm:
			  provider: local
			  providers:
			    local:
			      type: OpenAICompatible
			      endpoint: http://localhost:11434/v1
			      model: qwen2.5-coder:32b
			      isLocal: true
			""";
		var parsed = await new YamlService().ParseAsync(source);
		var form = NewForm();
		form.Load(parsed.Values);
		Assert.Contains("unknownKey", form.StatusText);

		((TextSettingVm)form.Find("analysisWindow.days")!).Text = "45";
		((BoolSettingVm)form.Find("llm.maskNames")!).Value = true;
		((EnumListSettingVm)form.Find("maintenance.scheduleDays")!).Items.First(item => item.Name == "Sunday").IsChecked = false;
		var overrides = (ListSettingVm)form.Find("rules.observationOverrides")!;
		overrides.AddCommand.Execute(null);
		((TextSettingVm)overrides.Items[0].Children.First(child => child.Key == "server")).Text = "AG1";
		((TextSettingVm)overrides.Items[0].Children.First(child => child.Key == "minUptimeDays")).Text = "30";
		Assert.True(form.IsDirty);

		Assert.True(form.TryBuildYaml(out var yaml, out var errors), string.Join("; ", errors));

		Assert.Contains("days: 45", yaml);
		Assert.Contains("maskNames: true", yaml);
		Assert.Contains("endpoint: 'http://localhost:11434/v1'", yaml);
		Assert.DoesNotContain("unknownKey", yaml);
		Assert.DoesNotContain("Sunday", yaml);
		Assert.DoesNotContain("connection:", yaml);
		var validation = await ValidateAsync(yaml);
		Assert.True(validation.IsValid, validation.Errors + Environment.NewLine + yaml);

		var reparsed = await new YamlService().ParseAsync(yaml);
		var again = NewForm();
		again.Load(reparsed.Values);
		Assert.Equal("45", ((TextSettingVm)again.Find("analysisWindow.days")!).Text);
		Assert.Single(((ListSettingVm)again.Find("rules.observationOverrides")!).Items);
		Assert.Equal("local", ((MapSettingVm)again.Find("llm.providers")!).Items.Single().Key);
	}

	[Fact]
	public void PlainSecret_IsRejectedByForm()
	{
		var form = NewForm();
		form.Load(new JsonObject());
		var password = (TextSettingVm)form.Find("connection.passwordRef")!;

		password.Text = "P@ssw0rd";

		Assert.NotNull(password.Error);
		Assert.False(form.TryBuildYaml(out _, out var errors));
		Assert.Contains(errors, error => error.StartsWith("connection.passwordRef", StringComparison.Ordinal));
		password.Text = "env:IA_SQL_PASSWORD";
		Assert.Null(password.Error);
	}

	[Fact]
	public void RangeAndTypeErrors_AreReported()
	{
		var form = NewForm();
		form.Load(new JsonObject());
		var days = (TextSettingVm)form.Find("analysisWindow.days")!;
		var share = (TextSettingVm)form.Find("partitioning.minDateFilterShare")!;

		days.Text = "0";
		share.Text = "0,75";

		Assert.Equal("не менше 1", days.Error);
		Assert.Null(share.Error);
		days.Reset();
		Assert.False(days.IsSet);
		Assert.Equal("30", days.Text);
	}

	[Fact]
	public async Task InvalidYaml_ReturnsParseError()
	{
		var result = await new YamlService().ParseAsync("version: 1\nservers: [SQL01\n");

		Assert.Null(result.Values);
		Assert.False(string.IsNullOrWhiteSpace(result.Error));
	}
}
