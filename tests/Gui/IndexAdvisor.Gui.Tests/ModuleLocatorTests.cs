using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Tests;

/// <summary>Пошук модуля IndexAdvisor: одне правило без пошуку вгору по теках і без підміни вибраного шляху.</summary>
public sealed class ModuleLocatorTests : IDisposable
{
	private readonly string _directory = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));

	public ModuleLocatorTests()
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

	private string Manifest(string folder)
	{
		var directory = Path.Combine(_directory, folder);
		Directory.CreateDirectory(directory);
		var path = Path.Combine(directory, ModuleLocator.ManifestName);
		File.WriteAllText(path, "@{ ModuleVersion = '9.8.7' }");
		return path;
	}

	[Fact]
	public void DevelopmentBuild_UsesRepositorySource()
	{
		var location = ModuleLocator.Locate(null);

		Assert.Equal(ModuleSource.Repository, location.Source);
		Assert.Equal(ModuleLocator.RepositoryPath, location.Path);
		Assert.EndsWith(Path.Combine("src", "IndexAdvisor", "IndexAdvisor.psd1"), location.Path, StringComparison.OrdinalIgnoreCase);
		Assert.Equal("з репозиторію (збірка для розробки)", location.SourceText);
	}

	[Fact]
	public void BundledCopy_IsInModulesFolderOfApplication()
	{
		Assert.Equal(Path.Combine(AppContext.BaseDirectory, "Modules", "IndexAdvisor", "IndexAdvisor.psd1"), ModuleLocator.BundledPath);
		Assert.True(File.Exists(ModuleLocator.BundledPath), "Збірка копіює модуль у Modules\\IndexAdvisor.");
	}

	[Fact]
	public void Configured_FileOrFolder_WinsOverEverything()
	{
		var configured = Manifest("custom");
		var repository = Manifest("repo");
		var bundled = Manifest("bundled");

		var byFile = ModuleLocator.Locate($"  \"{configured}\" ", repository, bundled);
		var byFolder = ModuleLocator.Locate(Path.GetDirectoryName(configured), repository, bundled);

		Assert.Equal(new ModuleLocation(configured, ModuleSource.Configured, configured), byFile);
		Assert.Equal(byFile, byFolder);
		Assert.Equal("вибраний у «Параметрах»", byFile.SourceText);
	}

	[Fact]
	public void Configured_Missing_IsReported_WithoutFallback()
	{
		var bundled = Manifest("bundled");
		var gone = Path.Combine(_directory, "gone", ModuleLocator.ManifestName);

		var location = ModuleLocator.Locate(gone, Manifest("repo"), bundled);

		Assert.Equal(ModuleSource.Missing, location.Source);
		Assert.False(location.Exists);
		Assert.Equal(gone, location.Path);
		Assert.Equal(gone, location.Configured);
		Assert.Equal("вибраний у «Параметрах» не знайдено", location.SourceText);
	}

	[Fact]
	public void PublishedApp_UsesBundledCopy_EvenInsideRepository()
	{
		// Опублікована програма не має шляху до репозиторію; пошуку src\IndexAdvisor вгору по теках немає.
		var bundled = Manifest(Path.Combine("repo-root", "dist", "app", "Modules", "IndexAdvisor"));
		Manifest(Path.Combine("repo-root", "src", "IndexAdvisor"));

		var location = ModuleLocator.Locate(null, repositoryPath: null, bundled);

		Assert.Equal(new ModuleLocation(bundled, ModuleSource.Bundled, null), location);
		Assert.Equal("вбудований у програму", location.SourceText);
	}

	[Fact]
	public void RepositoryPath_FromAnotherMachine_FallsBackToBundled()
	{
		var bundled = Manifest("bundled");

		var location = ModuleLocator.Locate(null, Path.Combine(_directory, "no-repo", ModuleLocator.ManifestName), bundled);

		Assert.Equal(ModuleSource.Bundled, location.Source);
	}

	[Fact]
	public void NothingFound_IsMissing_AtBundledPath_NotPSModulePath()
	{
		var bundled = Path.Combine(_directory, "app", "Modules", "IndexAdvisor", ModuleLocator.ManifestName);

		var location = ModuleLocator.Locate(null, null, bundled);

		Assert.Equal(new ModuleLocation(bundled, ModuleSource.Missing, null), location);
		Assert.Equal("не знайдено", location.SourceText);
	}

	[Fact]
	public void ParseModuleVersion_ReadsManifest()
	{
		Assert.Equal("2026.5.3", ModuleLocator.ParseModuleVersion("@{\n\tModuleVersion = '2026.5.3'\n\tGUID = 'x' }"));
		Assert.Null(ModuleLocator.ParseModuleVersion("@{ RootModule = 'x.psm1' }"));
	}
}
