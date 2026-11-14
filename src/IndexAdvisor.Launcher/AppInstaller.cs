using System.IO.Compression;

namespace IndexAdvisor.Launcher;

internal sealed record InstallResult(string Directory, bool Installed);

internal sealed class InstallException(string message, Exception? innerException = null) : Exception(message, innerException);

/// <summary>
/// Встановлення програми з архіву, вбудованого в одиночний exe, у app\&lt;версія&gt; (InstallLayout.AppsRoot).
/// Архів розпаковується в тимчасову теку поруч і лише потім перейменовується на app\&lt;версія&gt;, тож перерване
/// встановлення не лишає напівготової програми. Збірку визначає ідентифікатор архіву (.payload-id): та сама збірка
/// не розпаковується вдруге, інша збірка тієї самої версії замінює теку.
/// </summary>
internal static class AppInstaller
{
	public const string AppExeName = "IndexAdvisor.Gui.exe";
	public const string PayloadIdFileName = ".payload-id";

	public static InstallResult EnsureInstalled(string appsRoot, string version, string payloadId, Func<Stream> openPayload)
	{
		if (string.IsNullOrWhiteSpace(version) || version.StartsWith('.') || version.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
		{
			throw new ArgumentException($"Неприпустима версія програми: '{version}'.", nameof(version));
		}
		var target = Path.Combine(appsRoot, version);
		if (IsInstalled(target, payloadId))
		{
			return new InstallResult(target, Installed: false);
		}
		Directory.CreateDirectory(appsRoot);
		var staging = Path.Combine(appsRoot, $".install-{Guid.NewGuid():N}");
		try
		{
			using (var payload = openPayload())
			{
				ZipFile.ExtractToDirectory(payload, staging);
			}
			if (!File.Exists(Path.Combine(staging, AppExeName)))
			{
				throw new InstallException($"В архіві програми немає {AppExeName}.");
			}
			File.WriteAllText(Path.Combine(staging, PayloadIdFileName), payloadId);
			if (Directory.Exists(target) && !TryRemove(target))
			{
				throw new InstallException(
					$"Тека {target} зайнята: з неї запущено іншу збірку IndexAdvisor {version}. Закрийте програму й запустіть exe ще раз.");
			}
			Directory.Move(staging, target);
			return new InstallResult(target, Installed: true);
		}
		finally
		{
			if (Directory.Exists(staging))
			{
				TryDelete(staging);
			}
		}
	}

	internal static bool IsInstalled(string directory, string payloadId)
	{
		try
		{
			var idFile = Path.Combine(directory, PayloadIdFileName);
			return File.Exists(Path.Combine(directory, AppExeName))
				&& File.Exists(idFile)
				&& string.Equals(File.ReadAllText(idFile).Trim(), payloadId, StringComparison.OrdinalIgnoreCase);
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			return false;
		}
	}

	/// <summary>
	/// Інші версії в app і залишки перерваних встановлень. Теку, з якої зараз працює програма, Windows не дає
	/// перейменувати — вона лишається до наступного запуску.
	/// </summary>
	public static IReadOnlyList<string> RemoveOtherVersions(string appsRoot, string keep)
	{
		var removed = new List<string>();
		if (!Directory.Exists(appsRoot))
		{
			return removed;
		}
		var keepPath = Path.GetFullPath(keep).TrimEnd(Path.DirectorySeparatorChar);
		foreach (var directory in Directory.GetDirectories(appsRoot))
		{
			if (string.Equals(Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar), keepPath, StringComparison.OrdinalIgnoreCase))
			{
				continue;
			}
			if (Path.GetFileName(directory).StartsWith(".remove-", StringComparison.Ordinal))
			{
				TryDelete(directory);
				if (!Directory.Exists(directory))
				{
					removed.Add(directory);
				}
			}
			else if (TryRemove(directory))
			{
				removed.Add(directory);
			}
		}
		return removed;
	}

	/// <summary>
	/// Розпакування exe версій до 0.3.0: %TEMP%\.net\IndexAdvisor*\&lt;хеш&gt;. Видаляється лише тека, де кожна
	/// підтека — розпакована програма IndexAdvisor (є IndexAdvisor.Gui.dll).
	/// </summary>
	public static IReadOnlyList<string> RemoveLegacyExtractions(string bundleRoot)
	{
		var removed = new List<string>();
		if (!Directory.Exists(bundleRoot))
		{
			return removed;
		}
		foreach (var directory in Directory.GetDirectories(bundleRoot, "IndexAdvisor*"))
		{
			try
			{
				var children = Directory.GetDirectories(directory);
				if (children.Length == 0
					|| Directory.EnumerateFiles(directory).Any()
					|| children.Any(child => !File.Exists(Path.Combine(child, "IndexAdvisor.Gui.dll"))))
				{
					continue;
				}
			}
			catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
			{
				continue;
			}
			if (TryRemove(directory))
			{
				removed.Add(directory);
			}
		}
		return removed;
	}

	/// <summary>
	/// Спершу перейменування, потім видалення: теку з відкритими файлами (запущена програма) Windows не перейменовує,
	/// тож видаляється лише вільна тека й цілком.
	/// </summary>
	internal static bool TryRemove(string directory)
	{
		var doomed = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar))!, $".remove-{Guid.NewGuid():N}");
		try
		{
			Directory.Move(directory, doomed);
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			return false;
		}
		TryDelete(doomed);
		return true;
	}

	private static void TryDelete(string directory)
	{
		try
		{
			Directory.Delete(directory, recursive: true);
		}
		catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
		{
			// Залишок .remove-* прибере наступне встановлення.
		}
	}
}
