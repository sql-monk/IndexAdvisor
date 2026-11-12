using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Dialogs;

/// <summary>
/// Діалог для Read-Host, паролів і PromptForChoice. Якщо текст запиту містить варіанти «[П]ідтвердити / [В]ідхилити»,
/// показуються кнопки; натискання літери варіанта на клавіатурі теж обирає його.
/// </summary>
public partial class PromptDialog : Window
{
	/// <summary>Блимати кнопкою на панелі завдань, якщо вікно неактивне (параметри програми).</summary>
	public static bool FlashTaskbar { get; set; } = true;

	private IReadOnlyList<PromptChoice> _choices = [];
	private int? _selectedChoice;
	private bool _stopped;
	private bool _confirmed;

	private PromptDialog()
	{
		InitializeComponent();
		Loaded += OnLoaded;
	}

	/// <summary>Read-Host / пароль / облікові дані. null — користувач зупинив запуск.</summary>
	public static PromptResponse? ShowPrompt(Window? owner, PromptRequest request)
	{
		var dialog = Create(owner, request.Caption, request.Message, request.Context);
		if (!request.IsSecure && !request.AskUserName && ChoicePromptParser.TryParse(request.Label, out var question, out var choices))
		{
			dialog.ConfigureChoices(question, choices, defaultChoice: null);
			dialog.ShowDialog();
			if (dialog._stopped)
			{
				return null;
			}
			return new PromptResponse(dialog._selectedChoice is int index ? choices[index].Answer : string.Empty);
		}

		dialog.ConfigureInput(request);
		dialog.ShowDialog();
		if (dialog._stopped)
		{
			return null;
		}
		if (request.IsSecure)
		{
			var secure = dialog._confirmed ? dialog.PasswordInput.SecurePassword : new System.Security.SecureString();
			secure.MakeReadOnly();
			return new PromptResponse(null, secure, request.AskUserName ? dialog.UserNameBox.Text : null);
		}
		return new PromptResponse(dialog._confirmed ? dialog.InputBox.Text : string.Empty);
	}

	/// <summary>PromptForChoice ($PSCmdlet.ShouldContinue тощо). null — користувач зупинив запуск.</summary>
	public static int? ShowChoice(Window? owner, string caption, string message, string context, IReadOnlyList<PromptChoice> choices, int defaultChoice)
	{
		var dialog = Create(owner, caption, string.Empty, context);
		dialog.ConfigureChoices(message, choices, defaultChoice >= 0 && defaultChoice < choices.Count ? defaultChoice : null);
		dialog.ShowDialog();
		if (dialog._stopped)
		{
			return null;
		}
		return dialog._selectedChoice ?? Math.Max(0, defaultChoice);
	}

	private static PromptDialog Create(Window? owner, string caption, string message, string context)
	{
		var dialog = new PromptDialog();
		if (owner is { IsLoaded: true })
		{
			dialog.Owner = owner;
		}
		else
		{
			dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
		}

		// Show-IaToolRequest починає опис із «=== Модель просить додаткові дані ===» — він стає заголовком.
		var lines = (context ?? string.Empty).Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').ToList();
		var heading = string.IsNullOrWhiteSpace(caption) ? "Потрібна відповідь" : caption;
		if (lines.Count > 0 && lines[0].StartsWith("===", StringComparison.Ordinal))
		{
			heading = lines[0].Trim('=', ' ');
			lines.RemoveAt(0);
		}
		var body = string.Join(Environment.NewLine, lines).Trim();
		if (!string.IsNullOrWhiteSpace(message))
		{
			body = string.IsNullOrWhiteSpace(body) ? message : body + Environment.NewLine + Environment.NewLine + message;
		}
		dialog.HeadingText.Text = heading;
		dialog.ContextBox.Text = body;
		dialog.ContextBox.Visibility = string.IsNullOrWhiteSpace(body) ? Visibility.Collapsed : Visibility.Visible;
		return dialog;
	}

	private void ConfigureChoices(string question, IReadOnlyList<PromptChoice> choices, int? defaultChoice)
	{
		_choices = choices;
		QuestionText.Text = question;
		QuestionText.Visibility = string.IsNullOrWhiteSpace(question) ? Visibility.Collapsed : Visibility.Visible;
		InputPanel.Visibility = Visibility.Collapsed;
		OkButton.Visibility = Visibility.Collapsed;
		OkButton.IsDefault = false;
		for (var i = 0; i < choices.Count; i++)
		{
			var index = i;
			var choice = choices[i];
			var button = new Button
			{
				Content = choice.Label,
				MinWidth = 110,
				Margin = new Thickness(8, 0, 0, 0),
				IsDefault = defaultChoice == i,
				ToolTip = choice.Answer.Length > 3 ? choice.Answer : $"Клавіша {choice.Answer}",
			};
			if (i == 0 && Application.Current.TryFindResource("AccentButtonStyle") is Style accent)
			{
				button.Style = accent;
			}
			System.Windows.Automation.AutomationProperties.SetAutomationId(button, $"Choice{i}");
			button.Click += (_, _) => Choose(index);
			ChoicePanel.Children.Add(button);
		}
		PreviewTextInput += OnChoiceKey;
	}

	private void ConfigureInput(PromptRequest request)
	{
		QuestionText.Text = request.Label;
		ChoicePanel.Visibility = Visibility.Collapsed;
		UserNameLabel.Visibility = request.AskUserName ? Visibility.Visible : Visibility.Collapsed;
		UserNameBox.Visibility = request.AskUserName ? Visibility.Visible : Visibility.Collapsed;
		UserNameBox.Text = request.UserName ?? string.Empty;
		PasswordLabel.Visibility = request.AskUserName ? Visibility.Visible : Visibility.Collapsed;
		InputBox.Visibility = request.IsSecure ? Visibility.Collapsed : Visibility.Visible;
		PasswordInput.Visibility = request.IsSecure ? Visibility.Visible : Visibility.Collapsed;
		InputHint.Visibility = request.IsSecure ? Visibility.Collapsed : Visibility.Visible;
	}

	private void OnChoiceKey(object sender, TextCompositionEventArgs e)
	{
		var match = _choices
			.Select((choice, index) => (choice, index))
			.FirstOrDefault(item => item.choice.Answer.Length <= 3 && string.Equals(item.choice.Answer, e.Text, StringComparison.CurrentCultureIgnoreCase));
		if (match.choice is not null)
		{
			e.Handled = true;
			Choose(match.index);
		}
	}

	private void Choose(int index)
	{
		_selectedChoice = index;
		_confirmed = true;
		DialogResult = true;
	}

	private void OnOk(object sender, RoutedEventArgs e)
	{
		_confirmed = true;
		DialogResult = true;
	}

	private void OnStop(object sender, RoutedEventArgs e)
	{
		if (MessageBox.Show(this, "Зупинити аналіз? Уже зібрані дані не буде проаналізовано.", "Зупинити запуск",
				MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
		{
			_stopped = true;
			DialogResult = false;
		}
	}

	private void OnLoaded(object sender, RoutedEventArgs e)
	{
		if (InputBox.IsVisible)
		{
			InputBox.Focus();
		}
		else if (PasswordInput.IsVisible)
		{
			if (UserNameBox.IsVisible && string.IsNullOrEmpty(UserNameBox.Text))
			{
				UserNameBox.Focus();
			}
			else
			{
				PasswordInput.Focus();
			}
		}
		else if (ChoicePanel.Children.Count > 0)
		{
			((UIElement)ChoicePanel.Children[0]).Focus();
		}
		if (FlashTaskbar && Owner is { IsActive: false } owner)
		{
			Flash(owner);
		}
	}

	/// <summary>Блимання кнопки на панелі завдань: запит міг з'явитися, поки користувач працював в іншому вікні.</summary>
	private static void Flash(Window window)
	{
		var handle = new WindowInteropHelper(window).Handle;
		if (handle == IntPtr.Zero)
		{
			return;
		}
		var info = new FlashInfo
		{
			Size = (uint)Marshal.SizeOf<FlashInfo>(),
			Window = handle,
			Flags = FlashAll | FlashUntilForeground,
			Count = uint.MaxValue,
			Timeout = 0,
		};
		FlashWindowEx(ref info);
	}

	private const uint FlashAll = 3;
	private const uint FlashUntilForeground = 12;

	[StructLayout(LayoutKind.Sequential)]
	private struct FlashInfo
	{
		public uint Size;
		public IntPtr Window;
		public uint Flags;
		public uint Count;
		public uint Timeout;
	}

	[DllImport("user32.dll")]
	[return: MarshalAs(UnmanagedType.Bool)]
	private static extern bool FlashWindowEx(ref FlashInfo info);
}
