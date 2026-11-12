using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Tests;

/// <summary>Файли, завантажені з Інтернету (Mark of the Web): виявлення, розблокування, зрозуміла помилка модуля.</summary>
public sealed class DownloadMarkTests : IDisposable
{
	private readonly string _directory = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));

	public DownloadMarkTests()
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

	private static void Mark(string path, int zone)
		=> File.WriteAllText(path + ":Zone.Identifier", $"[ZoneTransfer]\r\nZoneId={zone}\r\nHostUrl=https://github.com/\r\n");

	private string Create(string relative, int? zone)
	{
		var path = Path.Combine(_directory, relative);
		Directory.CreateDirectory(Path.GetDirectoryName(path)!);
		File.WriteAllText(path, "# test");
		if (zone is int value)
		{
			Mark(path, value);
		}
		return path;
	}

	[Fact]
	public void FindMarked_ReturnsOnlyInternetAndRestrictedZones()
	{
		var internet = Create("a.ps1", 3);
		Create("b.psm1", 2);
		Create("c.txt", null);
		var restricted = Create(Path.Combine("sub", "d.psd1"), 4);

		var marked = DownloadMark.FindMarked(_directory);

		Assert.Equal(new[] { internet, restricted }.Order(), marked.Order());
	}

	[Fact]
	public void Unblock_RemovesMarkAndKeepsContent()
	{
		var path = Create("module.psm1", 3);

		var failed = DownloadMark.Unblock(DownloadMark.FindMarked(_directory));

		Assert.Empty(failed);
		Assert.False(DownloadMark.IsFromInternet(path));
		Assert.Equal("# test", File.ReadAllText(path));
		Assert.Empty(DownloadMark.FindMarked(_directory));
	}

	[Fact]
	public void FindMarked_MissingFolder_ReturnsEmpty()
	{
		Assert.Empty(DownloadMark.FindMarked(Path.Combine(_directory, "missing")));
	}

	[Theory]
	[InlineData("File C:\\m\\IndexAdvisor.psm1 cannot be loaded. The file is not digitally signed.", true)]
	[InlineData("cannot be loaded because running scripts is disabled on this system.", true)]
	[InlineData("Test-IaConfig: unknown key", false)]
	public void WithHint_AddsUnblockAdviceOnlyForPolicyErrors(string message, bool expected)
	{
		var result = DownloadMark.WithHint(message);

		Assert.Equal(expected, result.Contains(DownloadMark.BlockedHint, StringComparison.Ordinal));
		Assert.Equal(result, DownloadMark.WithHint(result));
	}

	/// <summary>Справжній модуль, позначений як завантажений: замість порожньої «помилки конфігурації» — причина й порада.</summary>
	[Fact]
	public async Task MarkedModule_FailsWithHint_AndWorksAfterUnblock()
	{
		var source = Path.GetDirectoryName(ModuleLocator.Resolve(null))!;
		var copy = Path.Combine(_directory, "IndexAdvisor");
		foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
		{
			var target = Path.Combine(copy, Path.GetRelativePath(source, file));
			Directory.CreateDirectory(Path.GetDirectoryName(target)!);
			File.Copy(file, target);
		}
		var modulePath = Path.Combine(copy, ModuleLocator.ManifestName);
		Mark(Path.Combine(copy, "IndexAdvisor.psm1"), 3);
		var config = Path.Combine(_directory, "run.yaml");
		File.WriteAllText(config, "version: 1\n");
		var service = new IndexAdvisorService(new PowerShellRunner(new FakeInteraction()), () => modulePath);

		var error = await Assert.ThrowsAnyAsync<Exception>(() => service.TestConfigAsync(config));
		Assert.Contains("IndexAdvisor", error.Message);
		Assert.Contains(DownloadMark.BlockedHint, error.Message);

		Assert.Empty(DownloadMark.Unblock(DownloadMark.FindMarked(copy)));
		var result = await service.TestConfigAsync(config);
		Assert.True(result.IsValid);
	}
}
