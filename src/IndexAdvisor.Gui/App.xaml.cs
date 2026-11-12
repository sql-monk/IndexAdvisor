using System.Windows;
using System.Windows.Threading;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.ViewModels;

namespace IndexAdvisor.Gui;

public partial class App : Application
{
	protected override void OnStartup(StartupEventArgs e)
	{
		base.OnStartup(e);
		DispatcherUnhandledException += OnDispatcherUnhandledException;

		var settings = AppSettings.Load();
		var viewModel = new MainViewModel(settings);
		var window = new MainWindow { DataContext = viewModel };
		MainWindow = window;
		window.Show();
	}

	public static void ShowError(Exception exception)
	{
		var owner = Current?.MainWindow;
		var text = exception.Message;
		if (owner is not null)
		{
			MessageBox.Show(owner, text, "IndexAdvisor", MessageBoxButton.OK, MessageBoxImage.Error);
		}
		else
		{
			MessageBox.Show(text, "IndexAdvisor", MessageBoxButton.OK, MessageBoxImage.Error);
		}
	}

	private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
	{
		ShowError(e.Exception);
		e.Handled = true;
	}
}
