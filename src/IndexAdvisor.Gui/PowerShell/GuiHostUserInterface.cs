using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;
using System.Text;
using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.PowerShell;

/// <summary>
/// Перетворює виклики хоста на рядки журналу й діалоги. Write-Host приходить частинами (Write без нового рядка),
/// тому текст накопичується до символу нового рядка. Останні рядки зберігаються як контекст для запитів:
/// Show-IaToolRequest друкує опис дозапиту через Write-Host перед Read-Host.
/// </summary>
internal sealed class GuiHostUserInterface : PSHostUserInterface
{
	private const int RecentCapacity = 120;
	private const int ContextMaxLines = 60;
	private const int FallbackContextLines = 8;

	private readonly IHostInteraction _interaction;
	private readonly Action? _stopRequested;
	private readonly GuiRawUserInterface _raw = new();
	private readonly StringBuilder _pending = new();
	private readonly LinkedList<string> _recent = new();
	private readonly Lock _sync = new();
	private ConsoleColor? _pendingColor;

	public GuiHostUserInterface(IHostInteraction interaction, Action? stopRequested)
	{
		_interaction = interaction;
		_stopRequested = stopRequested;
	}

	public override PSHostRawUserInterface RawUI => _raw;

	public override void Write(string value) => Append(value, null);

	public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value)
		=> Append(value, foregroundColor == _raw.ForegroundColor ? null : foregroundColor);

	public override void WriteLine(string value) => Append(value + "\n", null);

	public override void WriteLine(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value)
		=> Append(value + "\n", foregroundColor == _raw.ForegroundColor ? null : foregroundColor);

	public override void WriteErrorLine(string value) => EmitSeparate(HostLineKind.Error, value);

	public override void WriteWarningLine(string message) => EmitSeparate(HostLineKind.Warning, message);

	public override void WriteVerboseLine(string message) => EmitSeparate(HostLineKind.Verbose, message);

	public override void WriteDebugLine(string message) => EmitSeparate(HostLineKind.Debug, message);

	public override void WriteProgress(long sourceId, ProgressRecord record) => _interaction.Progress(record);

	public override string ReadLine()
	{
		var response = Ask(new PromptRequest(string.Empty, string.Empty, "Введіть значення", TakeContext(), IsSecure: false));
		Echo("Введення", response.Text);
		return response.Text ?? string.Empty;
	}

	public override SecureString ReadLineAsSecureString()
	{
		var response = Ask(new PromptRequest(string.Empty, string.Empty, "Введіть значення", TakeContext(), IsSecure: true));
		Echo("Введення", "********");
		return response.Secure ?? new SecureString();
	}

	public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions)
	{
		var result = new Dictionary<string, PSObject>(StringComparer.OrdinalIgnoreCase);
		foreach (var field in descriptions)
		{
			var label = string.IsNullOrEmpty(field.Label) ? field.Name : field.Label.Replace("&", string.Empty, StringComparison.Ordinal);
			var typeName = field.ParameterTypeFullName ?? string.Empty;
			if (typeName == typeof(PSCredential).FullName)
			{
				result[field.Name] = new PSObject(PromptForCredential(caption ?? string.Empty, message ?? string.Empty, string.Empty, string.Empty));
				continue;
			}
			var isSecure = typeName == typeof(SecureString).FullName;
			var response = Ask(new PromptRequest(caption ?? string.Empty, message ?? string.Empty, label, TakeContext(), isSecure));
			if (isSecure)
			{
				Echo(label, "********");
				result[field.Name] = new PSObject(response.Secure ?? new SecureString());
			}
			else
			{
				Echo(label, response.Text);
				result[field.Name] = new PSObject(response.Text ?? string.Empty);
			}
		}
		return result;
	}

	public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
	{
		var items = choices
			.Select(choice => new PromptChoice(choice.Label.Replace("&", string.Empty, StringComparison.Ordinal), choice.HelpMessage ?? string.Empty))
			.ToList();
		var answer = _interaction.PromptForChoice(caption ?? string.Empty, message ?? string.Empty, TakeContext(), items, defaultChoice);
		if (answer is null)
		{
			Stop();
		}
		var index = answer!.Value;
		Echo(message ?? caption ?? "Вибір", index >= 0 && index < items.Count ? items[index].Label : index.ToString());
		return index;
	}

	public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
		=> PromptForCredential(caption, message, userName, targetName, PSCredentialTypes.Default, PSCredentialUIOptions.Default);

	public override PSCredential PromptForCredential(
		string caption,
		string message,
		string userName,
		string targetName,
		PSCredentialTypes allowedCredentialTypes,
		PSCredentialUIOptions options)
	{
		var label = string.IsNullOrEmpty(targetName) ? "Облікові дані" : $"Облікові дані для {targetName}";
		var response = Ask(new PromptRequest(caption ?? string.Empty, message ?? string.Empty, label, TakeContext(), IsSecure: true, AskUserName: true, UserName: userName));
		Echo(label, response.UserName);
		return new PSCredential(response.UserName ?? string.Empty, response.Secure ?? new SecureString());
	}

	/// <summary>Виводить незавершений рядок (Write-Host -NoNewline наприкінці запуску).</summary>
	public void Flush()
	{
		lock (_sync)
		{
			FlushPendingLocked();
		}
	}

	private PromptResponse Ask(PromptRequest request)
	{
		var response = _interaction.Prompt(request);
		if (response is null)
		{
			Stop();
		}
		return response!;
	}

	private void Stop()
	{
		_interaction.Write(HostLine.System("Запуск зупинено користувачем у діалозі введення."));
		_stopRequested?.Invoke();
		throw new PipelineStoppedException();
	}

	private void Echo(string label, string? value)
	{
		var text = $"> {label}: {value}";
		lock (_sync)
		{
			Remember(text);
		}
		_interaction.Write(new HostLine(DateTime.Now, HostLineKind.Prompt, text));
	}

	private void Append(string value, ConsoleColor? color)
	{
		if (string.IsNullOrEmpty(value))
		{
			return;
		}
		var lines = new List<HostLine>();
		lock (_sync)
		{
			var parts = value.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n');
			for (var i = 0; i < parts.Length; i++)
			{
				if (parts[i].Length > 0)
				{
					if (_pending.Length == 0)
					{
						_pendingColor = color;
					}
					_pending.Append(parts[i]);
				}
				if (i < parts.Length - 1)
				{
					lines.Add(TakePendingLocked());
				}
			}
		}
		foreach (var line in lines)
		{
			_interaction.Write(line);
		}
	}

	private void EmitSeparate(HostLineKind kind, string text)
	{
		lock (_sync)
		{
			FlushPendingLocked();
		}
		foreach (var line in (text ?? string.Empty).Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
		{
			_interaction.Write(new HostLine(DateTime.Now, kind, line));
		}
	}

	private void FlushPendingLocked()
	{
		if (_pending.Length > 0)
		{
			_interaction.Write(TakePendingLocked());
		}
	}

	private HostLine TakePendingLocked()
	{
		var text = _pending.ToString();
		_pending.Clear();
		var line = new HostLine(DateTime.Now, HostLineKind.Host, text, _pendingColor);
		_pendingColor = null;
		Remember(text);
		return line;
	}

	private void Remember(string text)
	{
		_recent.AddLast(text);
		while (_recent.Count > RecentCapacity)
		{
			_recent.RemoveFirst();
		}
	}

	/// <summary>
	/// Контекст запиту: рядки від останнього заголовка «=== ... ===» (опис дозапиту моделі), якщо він недалеко,
	/// інакше — кілька останніх рядків.
	/// </summary>
	private string TakeContext()
	{
		lock (_sync)
		{
			FlushPendingLocked();
			var lines = _recent.ToList();
			var header = lines.FindLastIndex(line => line.StartsWith("===", StringComparison.Ordinal));
			var start = header >= 0 && lines.Count - header <= ContextMaxLines
				? header
				: Math.Max(0, lines.Count - FallbackContextLines);
			return string.Join(Environment.NewLine, lines.Skip(start)).Trim('\r', '\n');
		}
	}
}
