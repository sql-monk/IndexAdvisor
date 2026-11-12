using System.Windows.Input;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>Синхронна команда з необов'язковою умовою виконання.</summary>
public sealed class RelayCommand : ICommand
{
	private readonly Action<object?> _execute;
	private readonly Func<object?, bool>? _canExecute;

	public RelayCommand(Action execute, Func<bool>? canExecute = null)
		: this(_ => execute(), canExecute is null ? null : _ => canExecute())
	{
	}

	public RelayCommand(Action<object?> execute, Func<object?, bool>? canExecute = null)
	{
		_execute = execute;
		_canExecute = canExecute;
	}

	public event EventHandler? CanExecuteChanged
	{
		add => CommandManager.RequerySuggested += value;
		remove => CommandManager.RequerySuggested -= value;
	}

	public bool CanExecute(object? parameter) => _canExecute?.Invoke(parameter) ?? true;

	public void Execute(object? parameter) => _execute(parameter);
}

/// <summary>Асинхронна команда: недоступна, поки попередній виклик не завершився.</summary>
public sealed class AsyncRelayCommand : ICommand
{
	private readonly Func<Task> _execute;
	private readonly Func<bool>? _canExecute;
	private bool _isRunning;

	public AsyncRelayCommand(Func<Task> execute, Func<bool>? canExecute = null)
	{
		_execute = execute;
		_canExecute = canExecute;
	}

	public event EventHandler? CanExecuteChanged
	{
		add => CommandManager.RequerySuggested += value;
		remove => CommandManager.RequerySuggested -= value;
	}

	public bool CanExecute(object? parameter) => !_isRunning && (_canExecute?.Invoke() ?? true);

	public async void Execute(object? parameter)
	{
		if (!CanExecute(parameter))
		{
			return;
		}
		_isRunning = true;
		CommandManager.InvalidateRequerySuggested();
		try
		{
			await _execute();
		}
		catch (Exception ex)
		{
			App.ShowError(ex);
		}
		finally
		{
			_isRunning = false;
			CommandManager.InvalidateRequerySuggested();
		}
	}
}
