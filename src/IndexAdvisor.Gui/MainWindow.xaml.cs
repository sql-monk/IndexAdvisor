using System.ComponentModel;
using System.Windows;
using IndexAdvisor.Gui.ViewModels;

namespace IndexAdvisor.Gui;

public partial class MainWindow : Window
{
	public MainWindow()
	{
		InitializeComponent();
		Loaded += async (_, _) =>
		{
			if (DataContext is MainViewModel viewModel)
			{
				await viewModel.InitializeAsync(Environment.GetCommandLineArgs().Skip(1).ToArray());
			}
		};
	}

	protected override void OnClosing(CancelEventArgs e)
	{
		if (DataContext is MainViewModel viewModel && !viewModel.ConfirmClose())
		{
			e.Cancel = true;
		}
		base.OnClosing(e);
	}
}
