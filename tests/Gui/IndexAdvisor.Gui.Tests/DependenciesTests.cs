using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Text;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels;

namespace IndexAdvisor.Gui.Tests;

/// <summary>
/// Залежності модуля: тека залежностей IndexAdvisor перша в PSModulePath, перевірка Get-Module -ListAvailable
/// і встановлення пакетів PowerShell Gallery (без мережі — підставний HTTP-обробник).
/// </summary>
public sealed class DependenciesTests : IDisposable
{
	private readonly string _root = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));

	public DependenciesTests()
	{
		Directory.CreateDirectory(_root);
	}

	public void Dispose()
	{
		try
		{
			Directory.Delete(_root, recursive: true);
		}
		catch (IOException)
		{
		}
	}

	/// <summary>Відповідає пакетом і вдає переадресацію Gallery на &lt;cdn&gt;/packages/&lt;файл&gt;.</summary>
	private sealed class FakeGallery(Func<HttpRequestMessage, (HttpStatusCode Status, byte[] Body, string? FinalUri)> respond) : HttpMessageHandler
	{
		public List<Uri> Requests { get; } = [];

		protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
		{
			Requests.Add(request.RequestUri!);
			var (status, body, finalUri) = respond(request);
			return Task.FromResult(new HttpResponseMessage(status)
			{
				Content = new ByteArrayContent(body),
				RequestMessage = finalUri is null ? request : new HttpRequestMessage(HttpMethod.Get, finalUri),
			});
		}
	}

	/// <summary>.nupkg як у PowerShell Gallery: службові файли NuGet і екрановані імена записів.</summary>
	private static byte[] Package(string id, string packageVersion, string? moduleVersion, params (string Name, string Text)[] extra)
	{
		var buffer = new MemoryStream();
		using (var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true))
		{
			void Add(string name, string text)
			{
				using var writer = new StreamWriter(zip.CreateEntry(name).Open(), Encoding.UTF8);
				writer.Write(text);
			}
			Add("[Content_Types].xml", "<Types />");
			Add("_rels/.rels", "<Relationships />");
			Add("package/services/metadata/core-properties/0123.psmdcp", "<coreProperties />");
			Add($"{id}.nuspec", $"""
				<?xml version="1.0" encoding="utf-8"?>
				<package xmlns="http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd">
				  <metadata><id>{id}</id><version>{packageVersion}</version><authors>x</authors></metadata>
				</package>
				""");
			if (moduleVersion is not null)
			{
				Add($"{id}.psd1", $"@{{ ModuleVersion = '{moduleVersion}'; RootModule = '{id}.psm1' }}");
			}
			Add($"{id}.psm1", "function Get-Probe { 1 }");
			foreach (var (name, text) in extra)
			{
				Add(name, text);
			}
		}
		return buffer.ToArray();
	}

	[Fact]
	public async Task Install_ExtractsLikeSaveModule()
	{
		var package = Package("Test.Module", "1.2.0", "1.2.0.0", ("lib/My%20File.ps1", "x"), ("en-US/about_Test.help.txt", "help"));
		var gallery = new FakeGallery(_ => (HttpStatusCode.OK, package, "https://cdn.example/packages/test.module.1.2.0.nupkg"));
		using var installer = new GalleryInstaller(gallery, new Uri("https://gallery.example/api/v2/"));
		var lines = new List<string>();

		var result = await installer.InstallAsync("Test.Module", _root, new Progress<string>(lines.Add), CancellationToken.None);

		var module = Path.Combine(_root, "Test.Module", "1.2.0.0");
		Assert.Equal(new GalleryInstallResult("Test.Module", "1.2.0.0", module, AlreadyInstalled: false), result);
		Assert.Equal(new Uri("https://gallery.example/api/v2/package/Test.Module"), Assert.Single(gallery.Requests));
		Assert.True(File.Exists(Path.Combine(module, "Test.Module.psd1")));
		Assert.True(File.Exists(Path.Combine(module, "lib", "My File.ps1")));
		Assert.True(File.Exists(Path.Combine(module, "en-US", "about_Test.help.txt")));
		Assert.False(File.Exists(Path.Combine(module, "[Content_Types].xml")));
		Assert.False(File.Exists(Path.Combine(module, "Test.Module.nuspec")));
		Assert.False(Directory.Exists(Path.Combine(module, "_rels")));
		Assert.False(Directory.Exists(Path.Combine(module, "package")));
		Assert.Equal(["Test.Module"], Directory.GetFileSystemEntries(_root).Select(Path.GetFileName));
	}

	[Fact]
	public async Task Install_KnownVersionFromRedirect_IsNotDownloadedAgain()
	{
		Directory.CreateDirectory(Path.Combine(_root, "dbatools", "2.9.1"));
		// Тіло — не zip: якби його розпаковували, був би виняток.
		var gallery = new FakeGallery(_ => (HttpStatusCode.OK, "not a package"u8.ToArray(), "https://cdn.example/packages/dbatools.2.9.1.nupkg"));
		using var installer = new GalleryInstaller(gallery);

		var result = await installer.InstallAsync("dbatools", _root, null, CancellationToken.None);

		Assert.True(result.AlreadyInstalled);
		Assert.Equal("2.9.1", result.Version);
	}

	[Fact]
	public async Task Install_SameModuleVersion_ReportsAlreadyInstalled()
	{
		var package = Package("powershell-yaml", "0.4.12", "0.4.12");
		var gallery = new FakeGallery(_ => (HttpStatusCode.OK, package, null));
		using var installer = new GalleryInstaller(gallery);

		var first = await installer.InstallAsync("powershell-yaml", _root, null, CancellationToken.None);
		var second = await installer.InstallAsync("powershell-yaml", _root, null, CancellationToken.None);

		Assert.False(first.AlreadyInstalled);
		Assert.True(second.AlreadyInstalled);
		Assert.Equal(first.Directory, second.Directory);
	}

	[Fact]
	public async Task Install_PrereleaseWithoutManifest_UsesNumericVersionFolder()
	{
		var package = Package("No.Manifest", "2.0.0-preview3", moduleVersion: null);
		using var installer = new GalleryInstaller(new FakeGallery(_ => (HttpStatusCode.OK, package, null)));

		var result = await installer.InstallAsync("No.Manifest", _root, null, CancellationToken.None);

		Assert.Equal(Path.Combine(_root, "No.Manifest", "2.0.0"), result.Directory);
	}

	[Fact]
	public async Task Install_PathOutsideModule_IsRejected()
	{
		var package = Package("Evil", "1.0.0", "1.0.0", ("..%2F..%2Fevil.ps1", "x"));
		using var installer = new GalleryInstaller(new FakeGallery(_ => (HttpStatusCode.OK, package, null)));

		await Assert.ThrowsAsync<InvalidDataException>(() => installer.InstallAsync("Evil", _root, null, CancellationToken.None));

		Assert.Empty(Directory.GetFileSystemEntries(_root));
		Assert.False(File.Exists(Path.Combine(Path.GetDirectoryName(_root)!, "evil.ps1")));
	}

	[Fact]
	public async Task Install_NotFound_ThrowsHttpError()
	{
		using var installer = new GalleryInstaller(new FakeGallery(_ => (HttpStatusCode.NotFound, [], null)));

		var error = await Assert.ThrowsAsync<HttpRequestException>(() => installer.InstallAsync("missing", _root, null, CancellationToken.None));

		Assert.Equal(HttpStatusCode.NotFound, error.StatusCode);
		Assert.Contains("missing", error.Message);
	}

	[Theory]
	[InlineData("https://cdn.powershellgallery.com/packages/dbatools.library.2026.9.14.nupkg", "dbatools.library", "2026.9.14")]
	[InlineData("https://cdn.powershellgallery.com/packages/Microsoft.PowerShell.SecretStore.1.0.6.nupkg?sv=1", "microsoft.powershell.secretstore", "1.0.6")]
	[InlineData("https://cdn.powershellgallery.com/packages/dbatools.library.2026.9.14.nupkg", "dbatools", null)]
	[InlineData("https://cdn.powershellgallery.com/packages/x.2.0.0-beta.nupkg", "x", null)]
	[InlineData("https://www.powershellgallery.com/api/v2/package/x", "x", null)]
	public void VersionFromPackageUri_ParsesGalleryFileName(string uri, string id, string? expected)
	{
		Assert.Equal(expected, GalleryInstaller.VersionFromPackageUri(new Uri(uri), id));
	}

	[Fact]
	public void SaveModuleCommand_CoversAllDependencies()
	{
		var command = Dependencies.SaveModuleCommand(@"C:\Users\o'neil\AppData\Local\IndexAdvisor\Modules");

		Assert.Contains("-Path 'C:\\Users\\o''neil\\AppData\\Local\\IndexAdvisor\\Modules'", command);
		Assert.All(Dependencies.All, item => Assert.Contains(item.Name, command));
		Assert.StartsWith("New-Item -ItemType Directory -Force", command);
		Assert.True(Dependencies.All.ToList().FindIndex(item => item.Name == "dbatools.library") < Dependencies.All.ToList().FindIndex(item => item.Name == "dbatools"));
	}

	[Fact]
	public void DependencyItems_ShowSourceAndProblems()
	{
		var modules = Path.Combine(_root, "Modules");
		var view = new DependenciesViewModel(new PowerShellRunner(new FakeInteraction()), new LogViewModel());
		var report = new DependencyReport
		{
			ModulePath = [PowerShellRunner.DependencyModulesPath, @"C:\Users\x\Documents\PowerShell\Modules"],
			Modules =
			[
				new DependencyModuleStatus { Name = "powershell-yaml", Version = "0.4.12", Path = Path.Combine(PowerShellRunner.DependencyModulesPath, "powershell-yaml", "0.4.12"), Copies = 2 },
				new DependencyModuleStatus { Name = "dbatools", Version = "2.9.1", Path = @"C:\Users\x\Documents\PowerShell\Modules\dbatools\2.9.1", Copies = 1 },
			],
		};

		view.Apply(report);

		Assert.Equal(Dependencies.All.Select(item => item.Name), view.Items.Select(item => item.Name));
		var yaml = view.Items.Single(item => item.Name == "powershell-yaml");
		Assert.True(yaml.InAppFolder);
		Assert.Contains("ще копій у PSModulePath: 1", yaml.Location);
		Assert.False(view.Items.Single(item => item.Name == "dbatools").InAppFolder);
		Assert.True(view.Items.Single(item => item.Name == "dbatools.library").IsProblem);
		Assert.False(view.Items.Single(item => item.Name == "Microsoft.PowerShell.SecretStore").IsProblem);
		Assert.True(view.HasProblems);
		Assert.Equal("Не знайдено модулі PowerShell: Microsoft.PowerShell.SecretManagement, dbatools.library.", view.Summary);
		Assert.Equal(report.ModulePath, view.SearchOrder);
		Assert.False(DependencyItem.IsUnder(modules + "Other", modules));
	}

	[Fact]
	public async Task Runspace_PutsDependencyFolderFirst_AndCheckFindsModulesThere()
	{
		// Окреме ім'я модуля: справжні залежності інших тестів (той самий процес) не підмінюються.
		var folder = Path.Combine(_root, "Modules");
		var probe = Directory.CreateDirectory(Path.Combine(folder, "IaDependencyProbe", "1.0.0")).FullName;
		File.WriteAllText(Path.Combine(probe, "IaDependencyProbe.psd1"), "@{ ModuleVersion = '1.0.0'; FunctionsToExport = @() }");
		var original = PowerShellRunner.DependencyModulesPath;
		PowerShellRunner.DependencyModulesPath = folder;
		try
		{
			var output = await new PowerShellRunner(new FakeInteraction()).InvokeAsync(
				Dependencies.CheckScript,
				new Dictionary<string, object?> { ["Names"] = new[] { "IaDependencyProbe", "IaDependencyMissing" } },
				null,
				CancellationToken.None);
			var report = System.Text.Json.JsonSerializer.Deserialize<DependencyReport>((string)output.Single().BaseObject, IndexAdvisorService.JsonOptions)!;

			Assert.Equal(folder, report.ModulePath[0], ignoreCase: true);
			var found = report.Modules.Single(item => item.Name == "IaDependencyProbe");
			Assert.Equal("1.0.0", found.Version);
			Assert.Equal(probe, found.Path, ignoreCase: true);
			Assert.Null(report.Modules.Single(item => item.Name == "IaDependencyMissing").Path);
			// PowerShell зберігає порядок наявних тек: тека лишається першою й після наступного Open.
			var again = await new PowerShellRunner(new FakeInteraction()).InvokeAsync("($env:PSModulePath -split [IO.Path]::PathSeparator)[0]", new Dictionary<string, object?>(), null, CancellationToken.None);
			Assert.Equal(folder, (string)again.Single().BaseObject, ignoreCase: true);
		}
		finally
		{
			PowerShellRunner.DependencyModulesPath = original;
		}
	}

	[Theory]
	[InlineData(@"C:\A;c:\deps\;C:\B", @"C:\Deps;C:\A;C:\B")]
	[InlineData(@"C:\Deps;C:\A", @"C:\Deps;C:\A")]
	[InlineData("", @"C:\Deps")]
	[InlineData(null, @"C:\Deps")]
	public void WithFirst_MovesExistingEntry_WithoutDuplicates(string? modulePath, string expected)
	{
		Assert.Equal(expected, PowerShellRunner.WithFirst(modulePath, @"C:\Deps\"));
	}
}
