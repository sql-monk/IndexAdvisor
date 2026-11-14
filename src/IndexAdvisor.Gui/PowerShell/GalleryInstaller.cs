using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Xml.Linq;

namespace IndexAdvisor.Gui.PowerShell;

/// <param name="Name">Ім'я модуля з .nuspec.</param>
/// <param name="Version">Тека версії (ModuleVersion маніфесту).</param>
/// <param name="Directory">Тека модуля: &lt;тека залежностей&gt;\&lt;ім'я&gt;\&lt;версія&gt;.</param>
/// <param name="AlreadyInstalled">Ця версія вже була в теці залежностей.</param>
public sealed record GalleryInstallResult(string Name, string Version, string Directory, bool AlreadyInstalled);

/// <summary>
/// Завантаження модулів з PowerShell Gallery в теку залежностей так само, як Save-Module: пакет .nupkg (zip)
/// розпаковується в &lt;тека&gt;\&lt;ім'я&gt;\&lt;версія&gt; без службових файлів NuGet. Не потребує PowerShellGet,
/// якого немає у вбудованому PowerShell. Проксі — системний, з обліковими даними Windows.
/// </summary>
public sealed class GalleryInstaller : IDisposable
{
	public static readonly Uri DefaultFeed = new("https://www.powershellgallery.com/api/v2/");

	private readonly HttpClient _http;
	private readonly Uri _feed;

	public GalleryInstaller(HttpMessageHandler? handler = null, Uri? feed = null)
	{
		_http = new HttpClient(handler ?? new HttpClientHandler { DefaultProxyCredentials = CredentialCache.DefaultCredentials })
		{
			Timeout = TimeSpan.FromMinutes(30),
		};
		_http.DefaultRequestHeaders.UserAgent.ParseAdd("IndexAdvisor-Gui");
		_feed = feed ?? DefaultFeed;
	}

	public void Dispose() => _http.Dispose();

	/// <summary>Найновіша стабільна версія пакета <paramref name="id"/>; наявна в теці версія не завантажується вдруге.</summary>
	public async Task<GalleryInstallResult> InstallAsync(string id, string targetRoot, IProgress<string>? progress, CancellationToken cancellationToken)
	{
		Directory.CreateDirectory(targetRoot);
		using var response = await _http.GetAsync(new Uri(_feed, $"package/{Uri.EscapeDataString(id)}"), HttpCompletionOption.ResponseHeadersRead, cancellationToken);
		if (!response.IsSuccessStatusCode)
		{
			throw new HttpRequestException($"{id}: {(int)response.StatusCode} {response.ReasonPhrase} ({response.RequestMessage?.RequestUri})", null, response.StatusCode);
		}
		// Gallery переадресовує на файл <id>.<версія>.nupkg — версію видно до завантаження.
		if (VersionFromPackageUri(response.RequestMessage?.RequestUri, id) is { } version
			&& Path.Combine(targetRoot, id, version) is var existing
			&& Directory.Exists(existing))
		{
			return new GalleryInstallResult(id, version, existing, AlreadyInstalled: true);
		}
		var download = Path.Combine(targetRoot, $".download-{Guid.NewGuid():N}.nupkg");
		try
		{
			await using (var file = File.Create(download))
			{
				await CopyAsync(response, file, id, progress, cancellationToken);
			}
			return ExtractPackage(download, targetRoot);
		}
		finally
		{
			TryDeleteFile(download);
		}
	}

	private static async Task CopyAsync(HttpResponseMessage response, Stream target, string id, IProgress<string>? progress, CancellationToken cancellationToken)
	{
		var total = response.Content.Headers.ContentLength;
		await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
		var buffer = new byte[1 << 16];
		long copied = 0;
		var reported = 0;
		int read;
		while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
		{
			await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
			copied += read;
			if (total is > 0 && progress is not null && copied * 4 / total.Value > reported)
			{
				reported = (int)(copied * 4 / total.Value);
				progress.Report($"{id}: завантажено {copied / (1024 * 1024)} з {total.Value / (1024 * 1024)} МБ");
			}
		}
	}

	/// <summary>.nupkg → &lt;targetRoot&gt;\&lt;ім'я&gt;\&lt;версія&gt; через тимчасову теку (перерване розпакування не лишає модуля).</summary>
	internal static GalleryInstallResult ExtractPackage(string package, string targetRoot)
	{
		using var archive = ZipFile.OpenRead(package);
		var entries = archive.Entries.Select(entry => (Entry: entry, Name: Uri.UnescapeDataString(entry.FullName).Replace('\\', '/'))).ToList();
		var nuspec = entries.FirstOrDefault(item => !item.Name.Contains('/') && item.Name.EndsWith(".nuspec", StringComparison.OrdinalIgnoreCase)).Entry
			?? throw new InvalidDataException($"У пакеті {Path.GetFileName(package)} немає .nuspec.");
		XElement metadata;
		using (var stream = nuspec.Open())
		{
			metadata = XDocument.Load(stream).Root?.Elements().FirstOrDefault(element => element.Name.LocalName == "metadata")
				?? throw new InvalidDataException($"{nuspec.FullName}: немає metadata.");
		}
		string? Field(string name) => metadata.Elements().FirstOrDefault(element => element.Name.LocalName == name)?.Value.Trim();
		var name = Field("id") is { Length: > 0 } id && id.IndexOfAny(Path.GetInvalidFileNameChars()) < 0 && !id.StartsWith('.')
			? id
			: throw new InvalidDataException($"{nuspec.FullName}: неприпустимий id.");
		var packageVersion = Field("version") ?? throw new InvalidDataException($"{nuspec.FullName}: немає version.");

		// Тека версії має збігатися з ModuleVersion маніфесту (NuGet скорочує 1.0.0.0 до 1.0.0 і додає -preview).
		var manifest = entries.FirstOrDefault(item => string.Equals(item.Name, name + ".psd1", StringComparison.OrdinalIgnoreCase)).Entry;
		string? moduleVersion = null;
		if (manifest is not null)
		{
			using var reader = new StreamReader(manifest.Open());
			moduleVersion = ModuleLocator.ParseModuleVersion(reader.ReadToEnd());
		}
		var version = moduleVersion ?? packageVersion.Split('-', '+')[0];
		if (!Version.TryParse(version, out _))
		{
			throw new InvalidDataException($"{name}: неприпустима версія '{version}'.");
		}

		var destination = Path.Combine(targetRoot, name, version);
		if (Directory.Exists(destination))
		{
			return new GalleryInstallResult(name, version, destination, AlreadyInstalled: true);
		}
		var staging = Path.GetFullPath(Path.Combine(targetRoot, $".install-{Guid.NewGuid():N}"));
		try
		{
			Directory.CreateDirectory(staging);
			foreach (var (entry, entryName) in entries)
			{
				if (IsPackageMetadata(entryName))
				{
					continue;
				}
				var path = Path.GetFullPath(Path.Combine(staging, entryName.Replace('/', Path.DirectorySeparatorChar)));
				if (!path.StartsWith(staging + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
				{
					throw new InvalidDataException($"{name}: шлях поза текою модуля: {entry.FullName}");
				}
				if (entryName.EndsWith('/'))
				{
					Directory.CreateDirectory(path);
					continue;
				}
				Directory.CreateDirectory(Path.GetDirectoryName(path)!);
				entry.ExtractToFile(path, overwrite: false);
			}
			Directory.CreateDirectory(Path.Combine(targetRoot, name));
			Directory.Move(staging, destination);
		}
		finally
		{
			if (Directory.Exists(staging))
			{
				try
				{
					Directory.Delete(staging, recursive: true);
				}
				catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
				{
				}
			}
		}
		return new GalleryInstallResult(name, version, destination, AlreadyInstalled: false);
	}

	/// <summary>Службові файли пакета NuGet, яких Save-Module теж не лишає.</summary>
	internal static bool IsPackageMetadata(string entryName) =>
		entryName.Equals("[Content_Types].xml", StringComparison.OrdinalIgnoreCase)
		|| entryName.StartsWith("_rels/", StringComparison.OrdinalIgnoreCase)
		|| entryName.StartsWith("package/", StringComparison.OrdinalIgnoreCase)
		|| (!entryName.Contains('/') && entryName.EndsWith(".nuspec", StringComparison.OrdinalIgnoreCase));

	/// <summary>.../dbatools.library.2026.5.3.nupkg → 2026.5.3; інша адреса — null.</summary>
	internal static string? VersionFromPackageUri(Uri? uri, string id)
	{
		var file = uri is null ? null : Uri.UnescapeDataString(uri.Segments.LastOrDefault() ?? string.Empty);
		if (file is null
			|| !file.StartsWith(id + ".", StringComparison.OrdinalIgnoreCase)
			|| !file.EndsWith(".nupkg", StringComparison.OrdinalIgnoreCase))
		{
			return null;
		}
		var version = file[(id.Length + 1)..^".nupkg".Length];
		return Version.TryParse(version, out _) ? version : null;
	}

	private static void TryDeleteFile(string path)
	{
		try
		{
			File.Delete(path);
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
		}
	}
}
