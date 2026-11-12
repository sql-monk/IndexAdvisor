using System.ComponentModel;
using System.Windows;
using IndexAdvisor.Gui.Infrastructure;
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
		ThemeManager.ThemeChanged += OnThemeChanged;
		Closed += (_, _) => ThemeManager.ThemeChanged -= OnThemeChanged;
	}

	protected override void OnClosing(CancelEventArgs e)
	{
		if (DataContext is MainViewModel viewModel && !viewModel.ConfirmClose())
		{
			e.Cancel = true;
		}
		base.OnClosing(e);
	}

	/// <summary>
	/// Кольори статусів приходять через перетворювачі прив'язок: після зміни теми подання перебудовуються
	/// з тих самих моделей (стан — у моделях подання, тож нічого не втрачається).
	/// </summary>
	private void OnThemeChanged(object? sender, EventArgs e)
	{
		var context = DataContext;
		DataContext = null;
		DataContext = context;
	}
}
