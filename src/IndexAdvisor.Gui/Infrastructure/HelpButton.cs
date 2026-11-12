using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using IndexAdvisor.Gui.Help;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>
/// Кнопка «?» біля параметра: наведення показує підказку, клацання (або пробіл) — закріплену панель з тим самим
/// текстом, Esc чи клацання поза нею закриває. Вміст — Help (з прив'язки) або Topic («Run:Servers», «Tools:LoginMode»…).
/// Вигляд — стиль HelpButton в App.xaml.
/// </summary>
public sealed class HelpButton : ToggleButton
{
	public static readonly DependencyProperty HelpProperty = DependencyProperty.Register(
		nameof(Help), typeof(HelpInfo), typeof(HelpButton), new PropertyMetadata(null, OnHelpChanged));

	public static readonly DependencyProperty TopicProperty = DependencyProperty.Register(
		nameof(Topic), typeof(string), typeof(HelpButton), new PropertyMetadata(null, OnTopicChanged));

	public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(
		nameof(Title), typeof(string), typeof(HelpButton), new PropertyMetadata(null, OnTopicChanged));

	private readonly ToolTip _toolTip = new();

	public HelpButton()
	{
		// Власний ToolTip, щоб закрити його, коли відкривається панель (інакше підказка, показана при фокусі, лишається поверх).
		_toolTip.SetBinding(ContentControl.ContentProperty, new Binding(nameof(Help)) { Source = this });
		ToolTip = _toolTip;
	}

	protected override void OnChecked(RoutedEventArgs e)
	{
		_toolTip.IsOpen = false;
		base.OnChecked(e);
	}

	public HelpInfo? Help
	{
		get => (HelpInfo?)GetValue(HelpProperty);
		set => SetValue(HelpProperty, value);
	}

	public string? Topic
	{
		get => (string?)GetValue(TopicProperty);
		set => SetValue(TopicProperty, value);
	}

	/// <summary>Заголовок довідки для Topic (підпис поля).</summary>
	public string? Title
	{
		get => (string?)GetValue(TitleProperty);
		set => SetValue(TitleProperty, value);
	}

	protected override void OnKeyDown(KeyEventArgs e)
	{
		if (e.Key == Key.Escape && IsChecked == true)
		{
			IsChecked = false;
			e.Handled = true;
			return;
		}
		base.OnKeyDown(e);
	}

	private static void OnTopicChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e)
	{
		if (sender is HelpButton button && !string.IsNullOrWhiteSpace(button.Topic))
		{
			button.Help = HelpCatalog.ForTopic(button.Topic, button.Title);
		}
	}

	private static void OnHelpChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e)
	{
		if (sender is HelpButton button)
		{
			var help = e.NewValue as HelpInfo;
			AutomationProperties.SetName(button, help is null ? "Довідка" : "Довідка: " + help.Title);
			AutomationProperties.SetHelpText(button, help?.AccessibleText ?? string.Empty);
		}
	}
}
