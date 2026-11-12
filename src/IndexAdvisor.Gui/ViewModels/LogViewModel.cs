using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>
/// Журнал виводу PowerShell. Рядки приходять з потоку конвеєра в чергу й переносяться в колекцію
/// таймером інтерфейсу пачками, щоб частий Write-Host не блокував вікно.
/// </summary>
public sealed class LogViewModel : ObservableObject
{

	private readonly ConcurrentQueue<HostLine> _queue = new();
	private string? _progressText;
	private int _maxLines = 20000;
	private bool _wordWrap = true;
	private double _fontSize = 12.5;
	private int _warningCount;
	private int _errorCount;

	public LogViewModel()
	{
		var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(120) };
		timer.Tick += (_, _) => Flush();
		timer.Start();
		CopyCommand = new RelayCommand(Copy, () => Lines.Count > 0);
		ClearCommand = new RelayCommand(Clear, () => Lines.Count > 0);
	}

	public ObservableCollection<HostLine> Lines { get; } = [];

	public int MaxLines
	{
		get => _maxLines;
		set => SetProperty(ref _maxLines, Math.Clamp(value, 1000, 500000));
	}

	public bool WordWrap
	{
		get => _wordWrap;
		set => SetProperty(ref _wordWrap, value);
	}

	public double FontSize
	{
		get => _fontSize;
		set => SetProperty(ref _fontSize, value);
	}

	/// <summary>Нові рядки додано (для автопрокрутки).</summary>
	public event EventHandler? LinesAdded;

	public string? ProgressText
	{
		get => _progressText;
		set => SetProperty(ref _progressText, value);
	}

	public int WarningCount
	{
		get => _warningCount;
		private set => SetProperty(ref _warningCount, value);
	}

	public int ErrorCount
	{
		get => _errorCount;
		private set => SetProperty(ref _errorCount, value);
	}

	public ICommand CopyCommand { get; }

	public ICommand ClearCommand { get; }

	/// <summary>Потокобезпечно.</summary>
	public void Enqueue(HostLine line) => _queue.Enqueue(line);

	public void ResetCounters()
	{
		Flush();
		WarningCount = 0;
		ErrorCount = 0;
	}

	public void Flush()
	{
		if (_queue.IsEmpty)
		{
			return;
		}
		var added = false;
		while (_queue.TryDequeue(out var line))
		{
			Lines.Add(line);
			if (line.Kind == HostLineKind.Warning)
			{
				WarningCount++;
			}
			else if (line.Kind == HostLineKind.Error)
			{
				ErrorCount++;
			}
			added = true;
		}
		while (Lines.Count > _maxLines)
		{
			Lines.RemoveAt(0);
		}
		if (added)
		{
			LinesAdded?.Invoke(this, EventArgs.Empty);
		}
	}

	public string GetText(IEnumerable<HostLine>? lines = null)
		=> string.Join(Environment.NewLine, (lines ?? Lines).Select(line => line.ToString()));

	private void Copy()
	{
		Flush();
		Clipboard.SetText(GetText());
	}

	private void Clear()
	{
		Lines.Clear();
		WarningCount = 0;
		ErrorCount = 0;
	}
}
