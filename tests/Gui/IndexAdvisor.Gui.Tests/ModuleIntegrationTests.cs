using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Tests;

/// <summary>
/// Справжній модуль IndexAdvisor у хості GUI (потрібні powershell-yaml і SecretManagement, як і для Pester-тестів).
/// Без SQL-серверів і моделі.
/// </summary>
public sealed class ModuleIntegrationTests : IDisposable
{
	private readonly string _directory = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));
	private readonly string _modulePath = ModuleLocator.Resolve(null);

	public ModuleIntegrationTests()
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

	[Fact]
	public void ModuleLocator_FindsRepositorySource()
	{
		Assert.EndsWith(Path.Combine("src", "IndexAdvisor", "IndexAdvisor.psd1"), _modulePath, StringComparison.OrdinalIgnoreCase);
		Assert.NotNull(ModuleLocator.FindCliScript(_modulePath));
	}

	[Fact]
	public async Task TemplateConfig_IsCreatedAndValid_WithSummary()
	{
		var service = new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => _modulePath);
		var path = Path.Combine(_directory, "run.yaml");

		await service.NewConfigTemplateAsync(path);
		var result = await service.TestConfigAsync(path);

		Assert.True(result.IsValid, string.Join("; ", result.Errors.Select(error => $"{error.Location} {error.Message}")));
		Assert.NotNull(result.Summary);
		Assert.Equal(Path.Combine(_directory, "out"), result.Summary!.OutputPath, ignoreCase: true);
		Assert.Contains("Markdown", result.Summary.Formats);
	}

	[Fact]
	public async Task InvalidConfig_ReturnsErrorsWithLineNumbers()
	{
		var service = new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => _modulePath);
		var path = Path.Combine(_directory, "bad.yaml");
		File.WriteAllText(path, "version: 1\nmodule: Everything\nunknownKey: 1\n");

		var result = await service.TestConfigAsync(path);

		Assert.False(result.IsValid);
		Assert.Contains(result.Errors, error => error.Line == 2);
		Assert.Contains(result.Errors, error => error.Line == 3);
		Assert.Null(result.Summary);
	}

	[Fact]
	public async Task ToolApproval_RejectedThroughHostDialog()
	{
		var interaction = new FakeInteraction("в", "перевірка GUI");
		const string script = """
			param([string]$ModulePath)
			Import-Module -Name $ModulePath -Force -ErrorAction Stop
			& (Get-Module IndexAdvisor) {
				$config = Get-IaDefaultConfig
				$tools = Import-IaToolDefinitions -Config $config
				$request = [ordered]@{
					tool = 'index_usage_stats'; server = 'SQL01'; database = 'Sales'
					arguments = [ordered]@{ SchemaName = 'dbo'; TableName = 'Orders' }
					reason = 'Перевірка діалогу GUI'
				}
				$result = Request-IaToolApproval -ToolRequest $request -Tools $tools -Config $config
				"$($result.decision)|$($result.reason)"
			}
			""";

		var output = await new PowerShellRunner(interaction)
			.InvokeAsync(script, new Dictionary<string, object?> { ["ModulePath"] = _modulePath }, null, CancellationToken.None);

		Assert.Equal("Rejected|Відхилено користувачем: перевірка GUI", output.Single().BaseObject);
		Assert.Equal(2, interaction.Prompts.Count);
		var approval = interaction.Prompts[0];
		Assert.True(ChoicePromptParser.TryParse(approval.Label, out _, out var choices));
		Assert.Equal(["П", "З", "В"], choices.Select(choice => choice.Answer));
		Assert.StartsWith("=== Модель просить додаткові дані ===", approval.Context);
		Assert.Contains("Перевірка діалогу GUI", approval.Context);
		Assert.Contains("Причина відхилення", interaction.Prompts[1].Label);
	}
}
