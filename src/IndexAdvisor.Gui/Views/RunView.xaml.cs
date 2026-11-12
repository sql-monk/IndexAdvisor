using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels;

namespace IndexAdvisor.Gui.Views;

public partial class RunView : UserControl
{
	private LogViewModel? _log;

	public RunView()
	{
		InitializeComponent();
		DataContextChanged += (_, _) => Attach((DataContext as MainViewModel)?.Log);
		LogList.CommandBindings.Add(new CommandBinding(ApplicationCommands.Copy, CopySelection));
	}

	private void Attach(LogViewModel? log)
	{
		if (_log is not null)
		{
			_log.LinesAdded -= OnLinesAdded;
		}
		_log = log;
		if (_log is not null)
		{
			_log.LinesAdded += OnLinesAdded;
		}
	}

	private void OnLinesAdded(object? sender, EventArgs e)
	{
		if (AutoScroll.IsChecked == true && LogList.Items.Count > 0)
		{
			LogList.ScrollIntoView(LogList.Items[^1]);
		}
	}

	/// <summary>Ctrl+C у журналі копіює виділені рядки в порядку журналу.</summary>
	private void CopySelection(object sender, ExecutedRoutedEventArgs e)
	{
		if (_log is null || LogList.SelectedItems.Count == 0)
		{
			return;
		}
		var selected = LogList.SelectedItems.Cast<HostLine>().OrderBy(line => LogList.Items.IndexOf(line));
		Clipboard.SetText(_log.GetText(selected));
		e.Handled = true;
	}
}
