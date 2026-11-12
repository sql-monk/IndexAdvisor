using System.Windows;
using System.Windows.Media;
using System.Xml;
using ICSharpCode.AvalonEdit;
using ICSharpCode.AvalonEdit.Highlighting;
using ICSharpCode.AvalonEdit.Highlighting.Xshd;
using Microsoft.Win32;

namespace IndexAdvisor.Gui.Infrastructure;

public enum AppTheme
{
	System,
	Light,
	Dark,
}

/// <summary>
/// Тема застосунку: Fluent ThemeMode WPF, семантичні кольори статусів, кольори редакторів і підсвітки синтаксису.
/// Перемикається без перезапуску; у режимі System стежить за темою Windows.
/// </summary>
public static class ThemeManager
{
	private static bool _subscribed;

	public static AppTheme Current { get; private set; } = AppTheme.System;

	public static bool IsDark { get; private set; }

	/// <summary>Після зміни теми (у потоці інтерфейсу).</summary>
	public static event EventHandler? ThemeChanged;

	public static void Apply(AppTheme theme)
	{
		Current = theme;
		var app = Application.Current;
		if (app is null)
		{
			return;
		}
#pragma warning disable WPF0001 // ThemeMode — експериментальний API WPF.
		app.ThemeMode = theme switch
		{
			AppTheme.Light => ThemeMode.Light,
			AppTheme.Dark => ThemeMode.Dark,
			_ => ThemeMode.System,
		};
#pragma warning restore WPF0001
		IsDark = theme == AppTheme.Dark || theme == AppTheme.System && SystemUsesDarkTheme();
		ThemePalette.Apply(IsDark);
		ThemePalette.Register(app.Resources);
		if (!_subscribed)
		{
			_subscribed = true;
			SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
		}
		ThemeChanged?.Invoke(null, EventArgs.Empty);
	}

	/// <summary>Тема застосунків Windows: HKCU\...\Themes\Personalize\AppsUseLightTheme = 0 — темна.</summary>
	public static bool SystemUsesDarkTheme()
	{
		try
		{
			using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
			return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
		}
		catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
		{
			return false;
		}
	}

	private static void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
	{
		if (Current != AppTheme.System || e.Category is not (UserPreferenceCategory.General or UserPreferenceCategory.VisualStyle or UserPreferenceCategory.Color))
		{
			return;
		}
		Application.Current?.Dispatcher.BeginInvoke(() =>
		{
			if (Current == AppTheme.System && IsDark != SystemUsesDarkTheme())
			{
				Apply(AppTheme.System);
			}
		});
	}
}

/// <summary>
/// Пензлі статусів, журналу й редакторів поточної теми. Пензлі заморожені (Application.Resources заморожує Freezable),
/// тож на кожну тему створюються нові екземпляри й замінюються ресурси застосунку: XAML бере їх через DynamicResource,
/// а значення перетворювачів перераховуються після ThemeManager.ThemeChanged.
/// </summary>
public static class ThemePalette
{
	public static SolidColorBrush Success { get; private set; } = Brushes.Green;
	public static SolidColorBrush Warning { get; private set; } = Brushes.DarkGoldenrod;
	public static SolidColorBrush Error { get; private set; } = Brushes.Firebrick;
	public static SolidColorBrush Info { get; private set; } = Brushes.SteelBlue;
	public static SolidColorBrush Neutral { get; private set; } = Brushes.Gray;
	public static SolidColorBrush Accent2 { get; private set; } = Brushes.Purple;

	/// <summary>Текст на кольоровій мітці статусу.</summary>
	public static SolidColorBrush BadgeForeground { get; private set; } = Brushes.White;

	public static SolidColorBrush EditorBackground { get; private set; } = Brushes.White;
	public static SolidColorBrush EditorForeground { get; private set; } = Brushes.Black;
	public static SolidColorBrush EditorLineNumbers { get; private set; } = Brushes.Gray;
	public static SolidColorBrush EditorCurrentLine { get; private set; } = Brushes.Transparent;

	public static void Apply(bool dark)
	{
		Success = Brush(dark ? Rgb(0x6C, 0xCB, 0x5F) : Rgb(0x1E, 0x8E, 0x3E));
		Warning = Brush(dark ? Rgb(0xF0, 0xB4, 0x4C) : Rgb(0xB0, 0x6A, 0x00));
		Error = Brush(dark ? Rgb(0xFF, 0x8A, 0x80) : Rgb(0xC4, 0x2B, 0x1C));
		Info = Brush(dark ? Rgb(0x60, 0xCD, 0xFF) : Rgb(0x0F, 0x6C, 0xBD));
		Neutral = Brush(dark ? Rgb(0xA6, 0xA6, 0xA6) : Rgb(0x6E, 0x6E, 0x6E));
		Accent2 = Brush(dark ? Rgb(0xD6, 0x9C, 0xF0) : Rgb(0x8E, 0x2C, 0x9A));
		BadgeForeground = Brush(dark ? Rgb(0x14, 0x14, 0x14) : Colors.White);
		EditorBackground = Brush(dark ? Rgb(0x1E, 0x1E, 0x1E) : Colors.White);
		EditorForeground = Brush(dark ? Rgb(0xE4, 0xE4, 0xE4) : Rgb(0x1B, 0x1B, 0x1B));
		EditorLineNumbers = Brush(dark ? Rgb(0x85, 0x85, 0x85) : Rgb(0x8A, 0x8A, 0x8A));
		EditorCurrentLine = Brush(dark ? Color.FromArgb(0x40, 0x5A, 0x5A, 0x5A) : Color.FromArgb(0x30, 0xC8, 0xDC, 0xF0));
	}

	/// <summary>Ключі ресурсів застосунку для XAML: {DynamicResource StatusErrorBrush}.</summary>
	public static void Register(ResourceDictionary resources)
	{
		resources["StatusSuccessBrush"] = Success;
		resources["StatusWarningBrush"] = Warning;
		resources["StatusErrorBrush"] = Error;
		resources["StatusInfoBrush"] = Info;
		resources["StatusNeutralBrush"] = Neutral;
		resources["BadgeForegroundBrush"] = BadgeForeground;
		resources["EditorBackgroundBrush"] = EditorBackground;
		resources["EditorForegroundBrush"] = EditorForeground;
	}

	public static SolidColorBrush ForStatus(string? status) => status switch
	{
		"Succeeded" or "Passed" or "Low" or "Agree" or "Approved" or "AutoApproved" or "Modified" or "Success" => Success,
		"Partial" or "Warning" or "Medium" or "Uncertain" => Warning,
		"Failed" or "High" or "Disagree" or "Rejected" or "Blocked" or "Error" => Error,
		"Info" => Info,
		_ => Neutral,
	};

	private static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);

	private static SolidColorBrush Brush(Color color)
	{
		var brush = new SolidColorBrush(color);
		brush.Freeze();
		return brush;
	}
}

/// <summary>
/// Підсвітка синтаксису для світлої й темної теми. Темний варіант будується з того самого xshd:
/// темні кольори висвітлюються зі збереженням відтінку.
/// </summary>
public static class HighlightingProvider
{
	private static readonly Dictionary<(string Name, bool Dark), IHighlightingDefinition?> Cache = [];

	public static IHighlightingDefinition? Get(string? name)
	{
		if (string.IsNullOrWhiteSpace(name))
		{
			return null;
		}
		var key = (name, ThemeManager.IsDark);
		if (!Cache.TryGetValue(key, out var definition))
		{
			definition = Load(name, ThemeManager.IsDark);
			Cache[key] = definition;
		}
		return definition;
	}

	private static IHighlightingDefinition? Load(string name, bool dark)
	{
		using var stream = OpenXshd(name);
		if (stream is null)
		{
			return HighlightingManager.Instance.GetDefinition(name);
		}
		using var reader = XmlReader.Create(stream);
		var xshd = HighlightingLoader.LoadXshd(reader);
		if (dark)
		{
			foreach (var color in xshd.Elements.OfType<XshdColor>())
			{
				if (color.Foreground?.GetColor(null) is Color foreground)
				{
					color.Foreground = new SimpleHighlightingBrush(ColorMath.ForDarkBackground(foreground));
				}
				color.Background = null;
			}
		}
		return HighlightingLoader.Load(xshd, HighlightingManager.Instance);
	}

	private static Stream? OpenXshd(string name)
	{
		if (string.Equals(name, "YAML", StringComparison.OrdinalIgnoreCase))
		{
			return typeof(HighlightingProvider).Assembly.GetManifestResourceStream("IndexAdvisor.Gui.Views.Yaml.xshd");
		}
		// Вбудовані визначення AvalonEdit: ресурси *.<Name>-Mode.xshd.
		var assembly = typeof(HighlightingManager).Assembly;
		var resource = assembly.GetManifestResourceNames()
			.FirstOrDefault(item => item.EndsWith("." + name + "-Mode.xshd", StringComparison.OrdinalIgnoreCase));
		return resource is null ? null : assembly.GetManifestResourceStream(resource);
	}
}

public static class ColorMath
{
	/// <summary>Колір тексту, читабельний на темному фоні: світлість не менше 0,7, відтінок зберігається.</summary>
	public static Color ForDarkBackground(Color color)
	{
		var (h, s, l) = ToHsl(color);
		if (l >= 0.62)
		{
			return color;
		}
		var target = s < 0.08 ? Math.Max(0.78, 1 - l) : 0.72;
		return FromHsl(h, Math.Min(s, 0.85), target, color.A);
	}

	public static (double H, double S, double L) ToHsl(Color color)
	{
		double r = color.R / 255.0, g = color.G / 255.0, b = color.B / 255.0;
		var max = Math.Max(r, Math.Max(g, b));
		var min = Math.Min(r, Math.Min(g, b));
		var l = (max + min) / 2;
		if (max - min < 1e-9)
		{
			return (0, 0, l);
		}
		var d = max - min;
		var s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
		double h;
		if (max == r)
		{
			h = (g - b) / d + (g < b ? 6 : 0);
		}
		else if (max == g)
		{
			h = (b - r) / d + 2;
		}
		else
		{
			h = (r - g) / d + 4;
		}
		return (h / 6, s, l);
	}

	public static Color FromHsl(double h, double s, double l, byte alpha = 255)
	{
		if (s < 1e-9)
		{
			var gray = (byte)Math.Round(l * 255);
			return Color.FromArgb(alpha, gray, gray, gray);
		}
		var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
		var p = 2 * l - q;
		static double Hue(double p, double q, double t)
		{
			if (t < 0)
			{
				t += 1;
			}
			if (t > 1)
			{
				t -= 1;
			}
			return t < 1.0 / 6 ? p + (q - p) * 6 * t
				: t < 0.5 ? q
				: t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6
				: p;
		}
		return Color.FromArgb(
			alpha,
			(byte)Math.Round(Hue(p, q, h + 1.0 / 3) * 255),
			(byte)Math.Round(Hue(p, q, h) * 255),
			(byte)Math.Round(Hue(p, q, h - 1.0 / 3) * 255));
	}
}

/// <summary>
/// Приєднана властивість для AvalonEdit: підсвітка за назвою та кольори редактора поточної теми,
/// оновлюються при зміні теми й розміру шрифту в параметрах програми.
/// &lt;avalonEdit:TextEditor infra:EditorTheming.Highlighting="TSQL" /&gt;
/// </summary>
public static class EditorTheming
{
	public static readonly DependencyProperty HighlightingProperty = DependencyProperty.RegisterAttached(
		"Highlighting",
		typeof(string),
		typeof(EditorTheming),
		new PropertyMetadata(null, OnHighlightingChanged));

	/// <summary>Розмір шрифту редакторів і журналу (параметри програми).</summary>
	public static double FontSize { get; private set; } = 13;

	public static event EventHandler? FontSizeChanged;

	public static string? GetHighlighting(DependencyObject element) => (string?)element.GetValue(HighlightingProperty);

	public static void SetHighlighting(DependencyObject element, string? value) => element.SetValue(HighlightingProperty, value);

	public static void SetFontSize(double size)
	{
		FontSize = Math.Clamp(size, 9, 24);
		FontSizeChanged?.Invoke(null, EventArgs.Empty);
	}

	private static void OnHighlightingChanged(DependencyObject element, DependencyPropertyChangedEventArgs e)
	{
		if (element is not TextEditor editor)
		{
			return;
		}
		Apply(editor);
		if (e.OldValue is null)
		{
			EventHandler themeHandler = (_, _) => Apply(editor);
			EventHandler fontHandler = (_, _) => editor.FontSize = FontSize;
			editor.Loaded += (_, _) =>
			{
				ThemeManager.ThemeChanged -= themeHandler;
				FontSizeChanged -= fontHandler;
				ThemeManager.ThemeChanged += themeHandler;
				FontSizeChanged += fontHandler;
				Apply(editor);
			};
			editor.Unloaded += (_, _) =>
			{
				ThemeManager.ThemeChanged -= themeHandler;
				FontSizeChanged -= fontHandler;
			};
		}
	}

	public static void Apply(TextEditor editor)
	{
		editor.SyntaxHighlighting = HighlightingProvider.Get(GetHighlighting(editor));
		editor.Background = ThemePalette.EditorBackground;
		editor.Foreground = ThemePalette.EditorForeground;
		editor.LineNumbersForeground = ThemePalette.EditorLineNumbers;
		editor.TextArea.TextView.CurrentLineBackground = ThemePalette.EditorCurrentLine;
		editor.TextArea.TextView.CurrentLineBorder = new Pen(Brushes.Transparent, 0);
		editor.TextArea.Caret.CaretBrush = ThemePalette.EditorForeground;
		editor.FontSize = FontSize;
	}
}
