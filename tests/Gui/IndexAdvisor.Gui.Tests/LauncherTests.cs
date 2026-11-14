using System.IO.Compression;
using System.Text;
using IndexAdvisor.Launcher;

namespace IndexAdvisor.Gui.Tests;

/// <summary>Лаунчер одиночного exe: встановлення в app\&lt;версія&gt;, повторні запуски, заміна збірки, прибирання.</summary>
public sealed class LauncherTests : IDisposable
{
	private readonly string _root = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));

	public LauncherTests()
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

	private string Apps => Path.Combine(_root, "app");

	/// <summary>Архів програми, як його пакує build.ps1: вміст теки SelfContained без кореневої теки.</summary>
	private static Func<Stream> Payload(string marker, bool withExe = true)
	{
		var buffer = new MemoryStream();
		using (var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true))
		{
			void Add(string name, string text)
			{
				using var writer = new StreamWriter(zip.CreateEntry(name).Open(), Encoding.UTF8);
				writer.Write(text);
			}
			if (withExe)
			{
				Add(AppInstaller.AppExeName, "exe");
			}
			Add("Modules/IndexAdvisor/IndexAdvisor.psd1", "@{ ModuleVersion = '0.1.0' }");
			Add($"marker-{marker}.txt", marker);
		}
		var bytes = buffer.ToArray();
		return () => new MemoryStream(bytes);
	}

	private void AssertNoStaging() =>
		Assert.DoesNotContain(Directory.GetDirectories(Apps), directory => Path.GetFileName(directory).StartsWith('.'));

	[Fact]
	public void FirstRun_InstallsIntoVersionFolder()
	{
		var result = AppInstaller.EnsureInstalled(Apps, "0.3.0", "aaaa", Payload("a"));

		var target = Path.Combine(Apps, "0.3.0");
		Assert.Equal(new InstallResult(target, Installed: true), result);
		Assert.True(File.Exists(Path.Combine(target, AppInstaller.AppExeName)));
		Assert.True(File.Exists(Path.Combine(target, "Modules", "IndexAdvisor", "IndexAdvisor.psd1")));
		Assert.Equal("aaaa", File.ReadAllText(Path.Combine(target, AppInstaller.PayloadIdFileName)));
		AssertNoStaging();
	}

	[Fact]
	public void SameBuild_IsNotExtractedAgain()
	{
		AppInstaller.EnsureInstalled(Apps, "0.3.0", "aaaa", Payload("a"));

		var second = AppInstaller.EnsureInstalled(Apps, "0.3.0", "AAAA", () => throw new InvalidOperationException("архів не має читатися"));

		Assert.False(second.Installed);
	}

	[Fact]
	public void OtherBuildOfSameVersion_ReplacesFolder()
	{
		AppInstaller.EnsureInstalled(Apps, "0.3.0", "aaaa", Payload("a"));

		var result = AppInstaller.EnsureInstalled(Apps, "0.3.0", "bbbb", Payload("b"));

		Assert.True(result.Installed);
		Assert.False(File.Exists(Path.Combine(result.Directory, "marker-a.txt")));
		Assert.True(File.Exists(Path.Combine(result.Directory, "marker-b.txt")));
		Assert.Equal("bbbb", File.ReadAllText(Path.Combine(result.Directory, AppInstaller.PayloadIdFileName)));
		AssertNoStaging();
	}

	[Fact]
	public void FolderInUse_IsNotReplaced_AndErrorExplains()
	{
		var first = AppInstaller.EnsureInstalled(Apps, "0.3.0", "aaaa", Payload("a"));
		// Відкритий файл, як завантажена збірка запущеної програми: теку не перейменувати.
		using (File.Open(Path.Combine(first.Directory, AppInstaller.AppExeName), FileMode.Open, FileAccess.Read, FileShare.Read))
		{
			var error = Assert.Throws<InstallException>(() => AppInstaller.EnsureInstalled(Apps, "0.3.0", "bbbb", Payload("b")));
			Assert.Contains("зайнята", error.Message);
		}

		Assert.True(File.Exists(Path.Combine(first.Directory, "marker-a.txt")));
		Assert.True(AppInstaller.IsInstalled(first.Directory, "aaaa"));
		AssertNoStaging();
	}

	[Fact]
	public void PayloadWithoutApp_InstallsNothing()
	{
		Assert.Throws<InstallException>(() => AppInstaller.EnsureInstalled(Apps, "0.3.0", "aaaa", Payload("a", withExe: false)));

		Assert.False(Directory.Exists(Path.Combine(Apps, "0.3.0")));
		AssertNoStaging();
	}

	[Theory]
	[InlineData("")]
	[InlineData(".hidden")]
	[InlineData("0.3.0/../x")]
	public void InvalidVersion_IsRejected(string version)
	{
		Assert.Throws<ArgumentException>(() => AppInstaller.EnsureInstalled(Apps, version, "aaaa", Payload("a")));
	}

	[Fact]
	public void OtherVersions_AreRemoved_ExceptRunningOne()
	{
		var current = AppInstaller.EnsureInstalled(Apps, "0.3.1", "cccc", Payload("c")).Directory;
		var old = AppInstaller.EnsureInstalled(Apps, "0.3.0", "aaaa", Payload("a")).Directory;
		var running = AppInstaller.EnsureInstalled(Apps, "0.2.9", "dddd", Payload("d")).Directory;
		var leftover = Directory.CreateDirectory(Path.Combine(Apps, ".remove-0123")).FullName;

		IReadOnlyList<string> removed;
		using (File.Open(Path.Combine(running, AppInstaller.AppExeName), FileMode.Open, FileAccess.Read, FileShare.Read))
		{
			removed = AppInstaller.RemoveOtherVersions(Apps, current);
		}

		Assert.Equal([leftover, old], removed.Order(StringComparer.Ordinal));
		Assert.True(Directory.Exists(current));
		Assert.True(Directory.Exists(running));
		Assert.False(Directory.Exists(old));
		AssertNoStaging();
	}

	[Fact]
	public void LegacyTempExtraction_OnlyIndexAdvisorIsRemoved()
	{
		var bundleRoot = Path.Combine(_root, ".net");
		string Extracted(string app, string hash, string file)
		{
			var directory = Directory.CreateDirectory(Path.Combine(bundleRoot, app, hash)).FullName;
			File.WriteAllText(Path.Combine(directory, file), "x");
			return Path.Combine(bundleRoot, app);
		}
		var legacy = Extracted("IndexAdvisor-0.2.0-win-x64", "JRQeBEbMZ1R6", "IndexAdvisor.Gui.dll");
		Extracted("IndexAdvisor-0.1.1-win-x64", "abc", "IndexAdvisor.Gui.dll");
		var older = Extracted("IndexAdvisor-0.1.1-win-x64", "def", "IndexAdvisor.Gui.dll");
		var foreign = Extracted("IndexAdvisorTools", "xyz", "Other.dll");
		var unrelated = Extracted("SomethingElse", "q", "IndexAdvisor.Gui.dll");

		var removed = AppInstaller.RemoveLegacyExtractions(bundleRoot);

		Assert.Equal([older, legacy], removed.Order(StringComparer.Ordinal));
		Assert.False(Directory.Exists(legacy));
		Assert.True(Directory.Exists(foreign));
		Assert.True(Directory.Exists(unrelated));
		Assert.Empty(AppInstaller.RemoveLegacyExtractions(Path.Combine(_root, "missing")));
	}
}
