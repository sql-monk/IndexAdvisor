using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.Tests;

public class CommandLineBuilderTests
{
	[Fact]
	public void SplitList_SplitsOnCommaSemicolonAndNewLine_WithoutDuplicates()
	{
		var items = CommandLineBuilder.SplitList(" SQL01, sql01;SQL02\r\nSQL03 ,, ");

		Assert.Equal(["SQL01", "SQL02", "SQL03"], items);
	}

	[Fact]
	public void BuildParameters_EmptyOptions_PassesNothing()
	{
		Assert.Empty(CommandLineBuilder.BuildParameters(new RunOptions()));
	}

	[Fact]
	public void BuildParameters_TriStateSwitches_PassTrueFalseOrNothing()
	{
		var options = new RunOptions { MaskNames = false, NoRepository = true, AutoApprove = null };

		var parameters = CommandLineBuilder.BuildParameters(options).ToDictionary(p => p.Name, p => p.Value);

		Assert.Equal(false, parameters["MaskNames"]);
		Assert.Equal(true, parameters["NoRepository"]);
		Assert.False(parameters.ContainsKey("AutoApprove"));
	}

	[Fact]
	public void BuildParameters_UnsafeFlags_OnlyWhenEnabled()
	{
		var parameters = CommandLineBuilder.BuildParameters(new RunOptions { UnsafeDisableMaxdop = true })
			.Select(p => p.Name)
			.ToList();

		Assert.Contains("UnsafeDisableMaxdop", parameters);
		Assert.DoesNotContain("UnsafeDisableSelectCheck", parameters);
		Assert.DoesNotContain("AllowNonStandardLogin", parameters);
	}

	[Fact]
	public void BuildParameters_ExplicitDatasets_IncludeMandatoryAndDropUnknown()
	{
		var options = new RunOptions { Datasets = ["queryStore", "noSuchDataset"] };

		var datasets = (string[])CommandLineBuilder.BuildParameters(options).Single(p => p.Name == "Dataset").Value;

		Assert.Equal(["indexStructure", "instanceStartTime", "queryStore"], datasets);
	}

	[Fact]
	public void BuildParameters_EmptyExplicitDatasets_StillExpressible()
	{
		var datasets = (string[])CommandLineBuilder.BuildParameters(new RunOptions { Datasets = [] }).Single(p => p.Name == "Dataset").Value;

		Assert.Equal(IaConstants.MandatoryDatasets, datasets);
	}

	[Fact]
	public void BuildParameters_EmptyFormatList_IsNotPassed()
	{
		Assert.DoesNotContain(CommandLineBuilder.BuildParameters(new RunOptions { Formats = [] }), p => p.Name == "Format");
	}

	[Fact]
	public void FormatPowerShell_QuotesPathsAndListsAndFalseSwitches()
	{
		var options = new RunOptions
		{
			ConfigPath = @"C:\Ops\O'Brien\run.yaml",
			Servers = "SQL01, AGL-SALES",
			Module = "Both",
			AnalysisWindowDays = 45,
			MaskNames = false,
			NoRepository = true,
			Verbose = true,
		};

		var command = CommandLineBuilder.FormatPowerShell(options);

		Assert.Equal(
			@"Invoke-IndexAdvisor -Config 'C:\Ops\O''Brien\run.yaml' -Server SQL01,AGL-SALES -Module Both -AnalysisWindowDays 45 -NoRepository -MaskNames:$false -Verbose",
			command);
	}

	[Fact]
	public void FormatPwshFile_AddsNonInteractiveWhenNotSet()
	{
		var options = new RunOptions { ConfigPath = @"D:\Index Advisor\run.yaml", Servers = "SQL01;SQL02" };

		var command = CommandLineBuilder.FormatPwshFile(options, @"C:\IndexAdvisor\bin\IndexAdvisor.ps1");

		Assert.Equal(
			@"pwsh -NoProfile -File C:\IndexAdvisor\bin\IndexAdvisor.ps1 -Config ""D:\Index Advisor\run.yaml"" -Server SQL01,SQL02 -NonInteractive",
			command);
	}

	[Fact]
	public void FormatPwshFile_RespectsExplicitInteractiveMode()
	{
		var command = CommandLineBuilder.FormatPwshFile(new RunOptions { NonInteractive = false }, "IndexAdvisor.ps1");

		Assert.EndsWith("-NonInteractive:$false", command);
		Assert.Single(System.Text.RegularExpressions.Regex.Matches(command, "-NonInteractive"));
	}

	[Fact]
	public void ToHashtable_AddsVerboseForSplatting()
	{
		var table = CommandLineBuilder.ToHashtable(CommandLineBuilder.BuildParameters(new RunOptions { Provider = "local" }), verbose: true);

		Assert.Equal("local", table["provider"]);
		Assert.Equal(true, table["Verbose"]);
	}

	[Fact]
	public void Clone_CopiesListsIndependently()
	{
		var original = new RunOptions { Formats = ["Json"], Datasets = ["queryStore"] };

		var copy = original.Clone();
		copy.Formats!.Add("Html");

		Assert.Equal(["Json"], original.Formats);
		Assert.Equal(["queryStore"], copy.Datasets);
	}
}
