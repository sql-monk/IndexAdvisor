using System.Management.Automation;
using System.Windows;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels;

namespace IndexAdvisor.Gui.Dialogs;

/// <summary>
/// IHostInteraction для WPF: вивід — у журнал (без блокування), запити — модальні діалоги в потоці інтерфейсу,
/// поки потік конвеєра PowerShell чекає на відповідь.
/// </summary>
public sealed class InteractionService : IHostInteraction
{
	private readonly LogViewModel _log;

	public InteractionService(LogViewModel log)
	{
		_log = log;
	}

	public void Write(HostLine line) => _log.Enqueue(line);

	public void Progress(ProgressRecord record)
	{
		var text = record.RecordType == ProgressRecordType.Completed
			? null
			: string.IsNullOrWhiteSpace(record.StatusDescription)
				? record.Activity
				: $"{record.Activity}: {record.StatusDescription}{(record.PercentComplete >= 0 ? $" ({record.PercentComplete}%)" : string.Empty)}";
		Application.Current?.Dispatcher.BeginInvoke(() => _log.ProgressText = text);
	}

	public PromptResponse? Prompt(PromptRequest request)
		=> OnUiThread(() =>
		{
			_log.Flush();
			return PromptDialog.ShowPrompt(Application.Current.MainWindow, request);
		});

	public int? PromptForChoice(string caption, string message, string context, IReadOnlyList<PromptChoice> choices, int defaultChoice)
		=> OnUiThread(() =>
		{
			_log.Flush();
			return PromptDialog.ShowChoice(Application.Current.MainWindow, caption, message, context, choices, defaultChoice);
		});

	private static T OnUiThread<T>(Func<T> action)
	{
		var dispatcher = Application.Current?.Dispatcher
			?? throw new InvalidOperationException("Інтерфейс недоступний для діалогу введення.");
		return dispatcher.CheckAccess() ? action() : dispatcher.Invoke(action);
	}
}
