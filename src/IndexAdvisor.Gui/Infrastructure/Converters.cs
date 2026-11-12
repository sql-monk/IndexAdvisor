using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>Семантичні кольори статусів (однакові для світлої й темної теми).</summary>
public static class StatusBrushes
{
	public static readonly SolidColorBrush Success = Freeze(Color.FromRgb(0x1E, 0x8E, 0x3E));
	public static readonly SolidColorBrush Warning = Freeze(Color.FromRgb(0xC2, 0x7C, 0x0E));
	public static readonly SolidColorBrush Error = Freeze(Color.FromRgb(0xC4, 0x2B, 0x1C));
	public static readonly SolidColorBrush Info = Freeze(Color.FromRgb(0x0F, 0x6C, 0xBD));
	public static readonly SolidColorBrush Neutral = Freeze(Color.FromRgb(0x6E, 0x6E, 0x6E));

	private static SolidColorBrush Freeze(Color color)
	{
		var brush = new SolidColorBrush(color);
		brush.Freeze();
		return brush;
	}

	public static SolidColorBrush ForStatus(string? status) => status switch
	{
		"Succeeded" or "Passed" or "Low" or "Agree" or "Approved" or "AutoApproved" or "Modified" or "Success" => Success,
		"Partial" or "Warning" or "Medium" or "Uncertain" => Warning,
		"Failed" or "High" or "Disagree" or "Rejected" or "Blocked" or "Error" => Error,
		"Info" => Info,
		_ => Neutral,
	};
}

/// <summary>Рядок статусу (Succeeded, Passed, High, Severity…) → пензель.</summary>
public sealed class StatusBrushConverter : IValueConverter
{
	public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
	{
		Severity severity => severity switch
		{
			Severity.Success => StatusBrushes.Success,
			Severity.Warning => StatusBrushes.Warning,
			Severity.Error => StatusBrushes.Error,
			_ => StatusBrushes.Neutral,
		},
		int exitCode => StatusBrushes.ForStatus(ExitCodes.GetSeverity(exitCode).ToString()),
		_ => StatusBrushes.ForStatus(value?.ToString()),
	};

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>Колір рядка журналу: за видом рядка або кольором Write-Host (затемненим для світлого фону).</summary>
public sealed class HostLineBrushConverter : IValueConverter
{
	private static readonly Dictionary<ConsoleColor, SolidColorBrush> ConsoleBrushes = new()
	{
		[ConsoleColor.Red] = StatusBrushes.Error,
		[ConsoleColor.DarkRed] = StatusBrushes.Error,
		[ConsoleColor.Yellow] = StatusBrushes.Warning,
		[ConsoleColor.DarkYellow] = StatusBrushes.Warning,
		[ConsoleColor.Green] = StatusBrushes.Success,
		[ConsoleColor.DarkGreen] = StatusBrushes.Success,
		[ConsoleColor.Cyan] = StatusBrushes.Info,
		[ConsoleColor.DarkCyan] = StatusBrushes.Info,
		[ConsoleColor.Blue] = StatusBrushes.Info,
		[ConsoleColor.DarkBlue] = StatusBrushes.Info,
		[ConsoleColor.Magenta] = Brush(0x8E, 0x2C, 0x9A),
		[ConsoleColor.DarkMagenta] = Brush(0x8E, 0x2C, 0x9A),
		[ConsoleColor.Gray] = StatusBrushes.Neutral,
		[ConsoleColor.DarkGray] = StatusBrushes.Neutral,
	};

	public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
	{
		if (value is not HostLine line)
		{
			return DependencyProperty.UnsetValue;
		}
		return line.Kind switch
		{
			HostLineKind.Error => StatusBrushes.Error,
			HostLineKind.Warning => StatusBrushes.Warning,
			HostLineKind.Verbose or HostLineKind.Debug => StatusBrushes.Neutral,
			HostLineKind.Prompt or HostLineKind.System => StatusBrushes.Info,
			_ when line.Color is ConsoleColor color && ConsoleBrushes.TryGetValue(color, out var brush) => brush,
			_ => DependencyProperty.UnsetValue,
		};
	}

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;

	private static SolidColorBrush Brush(byte r, byte g, byte b)
	{
		var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
		brush.Freeze();
		return brush;
	}
}

/// <summary>Порожній рядок, null, порожня колекція або 0 → Visible (для підказки в порожньому полі), інакше Collapsed. ConverterParameter=Invert — навпаки.</summary>
public sealed class EmptyToVisibleConverter : IValueConverter
{
	public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
	{
		var empty = value is null || value is string text && string.IsNullOrEmpty(text)
			|| value is System.Collections.ICollection { Count: 0 } || value is 0;
		if (parameter is "Invert")
		{
			empty = !empty;
		}
		return empty ? Visibility.Visible : Visibility.Collapsed;
	}

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>bool → Visibility; ConverterParameter=Invert — навпаки.</summary>
public sealed class BoolToVisibilityConverter : IValueConverter
{
	public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
	{
		var flag = value is true;
		if (parameter is "Invert")
		{
			flag = !flag;
		}
		return flag ? Visibility.Visible : Visibility.Collapsed;
	}

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class InverseBoolConverter : IValueConverter
{
	public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is not true;

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => value is not true;
}
