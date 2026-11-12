using System.Windows.Media;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels;

namespace IndexAdvisor.Gui.Tests;

public class ToolsViewModelTests
{
	private static ToolsViewModel Create(out ConfigStateViewModel config)
	{
		var log = new LogViewModel();
		var service = new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => ModuleLocator.Resolve(null));
		config = new ConfigStateViewModel(service, log);
		return new ToolsViewModel(service, log, config);
	}

	[Fact]
	public void Maintenance_UsesRunConfigWhenNotSet()
	{
		var tools = Create(out var config);
		config.Path = @"D:\IndexAdvisor\run.yaml";
		tools.MaintenanceArchive = @"D:\IndexAdvisor\archive\run.zip";
		tools.MaintenanceResult = @"D:\IndexAdvisor\out\x\result.json";

		Assert.Equal(
			@"New-IaIndexMaintenance -FromArchive 'D:\IndexAdvisor\archive\run.zip' -Config 'D:\IndexAdvisor\run.yaml' -ResultPath 'D:\IndexAdvisor\out\x\result.json'",
			tools.MaintenanceCommand);
	}

	[Fact]
	public void ServiceLogin_BuildsAllParameters()
	{
		var tools = Create(out _);
		tools.LoginServers = "SQL01, SQL02";
		tools.LoginMode = "AddDatabase";
		tools.LoginDatabases = "Sales;DWH";
		tools.LoginName = @"CONTOSO\svc-ia";
		tools.WindowsLogin = true;
		tools.Vault = "IndexAdvisor";
		tools.AskCredential = true;

		Assert.Equal(
			@"Install-IaServiceLogin -SqlInstance SQL01,SQL02 -Mode AddDatabase -Database Sales,DWH -LoginName 'CONTOSO\svc-ia' -WindowsLogin -Vault IndexAdvisor -SqlCredential (Get-Credential)",
			tools.LoginCommand);
	}

	[Fact]
	public void ServiceLogin_DefaultsToReadOnlyVerify()
	{
		var tools = Create(out _);

		Assert.Equal("Verify", tools.LoginMode);
		Assert.Equal("Install-IaServiceLogin -Mode Verify", tools.LoginCommand);
	}
}

public class ThemeTests
{
	[Theory]
	[InlineData(0x00, 0x00, 0xFF)]
	[InlineData(0x00, 0x80, 0x00)]
	[InlineData(0x80, 0x00, 0x00)]
	[InlineData(0x40, 0x40, 0x40)]
	public void ForDarkBackground_LightensDarkColorsKeepingHue(byte r, byte g, byte b)
	{
		var source = Color.FromRgb(r, g, b);

		var result = ColorMath.ForDarkBackground(source);

		var (h1, _, _) = ColorMath.ToHsl(source);
		var (h2, _, l2) = ColorMath.ToHsl(result);
		Assert.True(l2 >= 0.7, $"lightness {l2}");
		Assert.Equal(h1, h2, 2);
	}

	[Fact]
	public void ForDarkBackground_KeepsLightColors()
	{
		var light = Color.FromRgb(0xE0, 0xE0, 0x90);

		Assert.Equal(light, ColorMath.ForDarkBackground(light));
	}

	[Theory]
	[InlineData("TSQL")]
	[InlineData("JavaScript")]
	[InlineData("YAML")]
	public void HighlightingDefinitions_AreFound(string name)
	{
		Assert.NotNull(HighlightingProvider.Get(name));
	}
}
