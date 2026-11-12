using System.Text.RegularExpressions;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>
/// Позначка Windows «завантажено з Інтернету» (потік NTFS Zone.Identifier, Mark of the Web). Браузер ставить її на ZIP,
/// Провідник переносить на розпаковані файли, і PowerShell з політикою RemoteSigned або AllSigned не завантажує такі
/// непідписані скрипти. Unblock тут — те саме, що Unblock-File: видаляється лише позначка, вміст файлів не змінюється.
/// </summary>
public static partial class DownloadMark
{
	private const string StreamSuffix = ":Zone.Identifier";

	[GeneratedRegex(@"^\s*ZoneId\s*=\s*(?<zone>\d+)", RegexOptions.Multiline)]
	private static partial Regex ZonePattern();

	/// <summary>Файли теки (з підтеками) із позначкою зони Інтернету (3) або обмежених сайтів (4).</summary>
	public static IReadOnlyList<string> FindMarked(string directory)
	{
		if (!Directory.Exists(directory))
		{
			return [];
		}
		var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
		return Directory.EnumerateFiles(directory, "*", options).Where(IsFromInternet).ToList();
	}

	/// <summary>ZoneId 3 (Internet) або 4 (Restricted): саме такі файли RemoteSigned вважає віддаленими.</summary>
	public static bool IsFromInternet(string path)
	{
		try
		{
			var match = ZonePattern().Match(File.ReadAllText(path + StreamSuffix));
			return match.Success && int.Parse(match.Groups["zone"].Value, System.Globalization.CultureInfo.InvariantCulture) >= 3;
		}
		catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException or IOException or UnauthorizedAccessException or NotSupportedException)
		{
			return false;
		}
	}

	/// <summary>Зняти позначку. Повертає файли, з яких її зняти не вдалося.</summary>
	public static IReadOnlyList<string> Unblock(IEnumerable<string> paths)
	{
		var failed = new List<string>();
		foreach (var path in paths)
		{
			try
			{
				File.Delete(path + StreamSuffix);
			}
			catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
			{
				failed.Add(path);
			}
		}
		return failed;
	}

	/// <summary>Помилка PowerShell про заблокований чи непідписаний скрипт (будь-якою мовою інтерфейсу — за ідентифікаторами).</summary>
	public static bool IsScriptBlockedError(string? message)
		=> !string.IsNullOrEmpty(message)
			&& (message.Contains("is not digitally signed", StringComparison.OrdinalIgnoreCase)
				|| message.Contains("running scripts is disabled", StringComparison.OrdinalIgnoreCase)
				|| message.Contains("UnauthorizedAccess", StringComparison.Ordinal)
				|| message.Contains("about_Execution_Policies", StringComparison.OrdinalIgnoreCase));

	public const string BlockedHint =
		"Схоже, файли модуля позначено як завантажені з Інтернету або політика виконання забороняє скрипти. " +
		"Розблокуйте теку програми (Unblock-File або запит під час запуску IndexAdvisor GUI) " +
		"чи змініть політику виконання на вкладці «Параметри».";

	public static string WithHint(string message)
		=> IsScriptBlockedError(message) && !message.Contains(BlockedHint, StringComparison.Ordinal)
			? message + Environment.NewLine + BlockedHint
			: message;
}
