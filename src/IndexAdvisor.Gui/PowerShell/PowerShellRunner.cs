using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using Microsoft.PowerShell;

namespace IndexAdvisor.Gui.PowerShell;

/// <summary>
/// Виконує скрипт у новому runspace з GuiHost у фоновому потоці. Кожна операція — окремий runspace,
/// тож стан модуля (script:-змінні) між запусками не переноситься.
/// </summary>
public sealed class PowerShellRunner
{
	private readonly IHostInteraction _interaction;

	public PowerShellRunner(IHostInteraction interaction)
	{
		_interaction = interaction;
	}

	/// <summary>
	/// Політика виконання для всіх runspace програми (параметри програми). Типово RemoteSigned:
	/// модуль і dbatools — локальні або підписані файли.
	/// </summary>
	public static ExecutionPolicy ProcessExecutionPolicy { get; set; } = ExecutionPolicy.RemoteSigned;

	public Task<Collection<PSObject>> InvokeAsync(
		string script,
		IReadOnlyDictionary<string, object?> parameters,
		string? workingDirectory,
		CancellationToken cancellationToken)
		=> Task.Factory.StartNew(
			() => Invoke(script, parameters, workingDirectory, cancellationToken),
			CancellationToken.None,
			TaskCreationOptions.LongRunning,
			TaskScheduler.Default);

	private Collection<PSObject> Invoke(
		string script,
		IReadOnlyDictionary<string, object?> parameters,
		string? workingDirectory,
		CancellationToken cancellationToken)
	{
		cancellationToken.ThrowIfCancellationRequested();
		System.Management.Automation.PowerShell? shell = null;
		// Зупинка з діалогу введення або кнопкою «Зупинити»; CancellationTokenSource — потокобезпечний прапорець.
		using var stopSource = new CancellationTokenSource();
		void RequestStop()
		{
			try
			{
				stopSource.Cancel();
				shell?.BeginStop(null, null);
			}
			catch (Exception)
			{
				// Конвеєр уже завершився або ресурси звільнено.
			}
		}

		var host = new GuiHost(_interaction, RequestStop);
		var state = InitialSessionState.CreateDefault();
		if (OperatingSystem.IsWindows())
		{
			state.ExecutionPolicy = ProcessExecutionPolicy;
		}
		using var runspace = RunspaceFactory.CreateRunspace(host, state);
		runspace.Open();
		using var ps = System.Management.Automation.PowerShell.Create(runspace);
		shell = ps;
		if (!string.IsNullOrWhiteSpace(workingDirectory) && Directory.Exists(workingDirectory))
		{
			// Відносні шляхи конфігурації (./out, ./archive) модуль розв'язує від поточної теки PowerShell.
			ps.AddCommand("Set-Location").AddParameter("LiteralPath", workingDirectory).Invoke();
			ps.Commands.Clear();
		}
		ps.AddScript(script);
		foreach (var (name, value) in parameters)
		{
			ps.AddParameter(name, value);
		}
		ps.Streams.Error.DataAdded += (_, e) =>
		{
			var record = ps.Streams.Error[e.Index];
			_interaction.Write(new HostLine(DateTime.Now, HostLineKind.Error, FormatError(record)));
		};
		using var registration = cancellationToken.Register(RequestStop);
		Collection<PSObject> output;
		try
		{
			output = ps.Invoke();
		}
		catch (Exception ex) when (ex is PipelineStoppedException or RuntimeException && stopSource.IsCancellationRequested)
		{
			throw new OperationCanceledException("Запуск зупинено користувачем.", ex, cancellationToken);
		}
		finally
		{
			host.UserInterface.Flush();
		}
		// Після BeginStop Invoke зазвичай повертається без винятку, зі станом Stopped.
		if (stopSource.IsCancellationRequested || ps.InvocationStateInfo.State == PSInvocationState.Stopped)
		{
			throw new OperationCanceledException("Запуск зупинено користувачем.", cancellationToken);
		}
		return output;
	}

	internal static string FormatError(ErrorRecord record)
	{
		var message = record.ErrorDetails?.Message;
		if (string.IsNullOrWhiteSpace(message))
		{
			message = record.Exception?.Message ?? record.ToString();
		}
		var id = record.FullyQualifiedErrorId ?? string.Empty;
		if (id.StartsWith("Ia", StringComparison.Ordinal))
		{
			var shortId = id.Split(',')[0];
			if (!message.Contains(shortId, StringComparison.Ordinal))
			{
				message = $"{message} [{shortId}]";
			}
		}
		return message;
	}
}
