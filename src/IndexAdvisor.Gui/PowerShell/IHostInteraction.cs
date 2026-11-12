using System.Management.Automation;
using System.Security;
using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.PowerShell;

public enum HostLineKind
{
	Host,
	Warning,
	Error,
	Verbose,
	Debug,
	Prompt,
	System,
}

/// <summary>Рядок журналу запуску.</summary>
public sealed record HostLine(DateTime Time, HostLineKind Kind, string Text, ConsoleColor? Color = null)
{
	public static HostLine System(string text) => new(DateTime.Now, HostLineKind.System, text);

	public override string ToString()
	{
		var prefix = Kind switch
		{
			HostLineKind.Warning => "ПОПЕРЕДЖЕННЯ: ",
			HostLineKind.Error => "ПОМИЛКА: ",
			HostLineKind.Verbose => "VERBOSE: ",
			HostLineKind.Debug => "DEBUG: ",
			_ => string.Empty,
		};
		return $"{Time:HH:mm:ss} {prefix}{Text}";
	}
}

/// <summary>Запит введення від PowerShell (Read-Host, пароль SecretStore, облікові дані).</summary>
/// <param name="Context">Останні рядки журналу, до яких належить запит (наприклад, опис дозапиту моделі).</param>
public sealed record PromptRequest(
	string Caption,
	string Message,
	string Label,
	string Context,
	bool IsSecure,
	bool AskUserName = false,
	string? UserName = null);

public sealed record PromptResponse(string? Text, SecureString? Secure = null, string? UserName = null);

/// <summary>
/// Зв'язок хоста PowerShell з інтерфейсом. Методи викликаються з потоку конвеєра PowerShell;
/// Write і Progress не блокують, Prompt і PromptForChoice чекають на відповідь користувача.
/// null у відповіді — користувач зупинив запуск.
/// </summary>
public interface IHostInteraction
{
	void Write(HostLine line);

	void Progress(ProgressRecord record);

	PromptResponse? Prompt(PromptRequest request);

	int? PromptForChoice(string caption, string message, string context, IReadOnlyList<PromptChoice> choices, int defaultChoice);
}
