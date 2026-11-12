using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Infrastructure;

/// <summary>Рядок статусу (Succeeded, Passed, High, Severity…) → пензель.</summary>
public sealed class StatusBrushConverter : IValueConverter
{
	public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
	{
		Severity severity => severity switch
		{
			Severity.Success => ThemePalette.Success,
			Severity.Warning => ThemePalette.Warning,
			Severity.Error => ThemePalette.Error,
			_ => ThemePalette.Neutral,
		},
		int exitCode => ThemePalette.ForStatus(ExitCodes.GetSeverity(exitCode).ToString()),
		_ => ThemePalette.ForStatus(value?.ToString()),
	};

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>Колір рядка журналу: за видом рядка або кольором Write-Host (у кольорах поточної теми).</summary>
public sealed class HostLineBrushConverter : IValueConverter
{
	private static SolidColorBrush? ForConsoleColor(ConsoleColor color) => color switch
	{
		ConsoleColor.Red or ConsoleColor.DarkRed => ThemePalette.Error,
		ConsoleColor.Yellow or ConsoleColor.DarkYellow => ThemePalette.Warning,
		ConsoleColor.Green or ConsoleColor.DarkGreen => ThemePalette.Success,
		ConsoleColor.Cyan or ConsoleColor.DarkCyan or ConsoleColor.Blue or ConsoleColor.DarkBlue => ThemePalette.Info,
		ConsoleColor.Magenta or ConsoleColor.DarkMagenta => ThemePalette.Accent2,
		ConsoleColor.Gray or ConsoleColor.DarkGray => ThemePalette.Neutral,
		_ => null,
	};

	public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
	{
		if (value is not HostLine line)
		{
			return DependencyProperty.UnsetValue;
		}
		return line.Kind switch
		{
			HostLineKind.Error => ThemePalette.Error,
			HostLineKind.Warning => ThemePalette.Warning,
			HostLineKind.Verbose or HostLineKind.Debug => ThemePalette.Neutral,
			HostLineKind.Prompt or HostLineKind.System => ThemePalette.Info,
			_ when line.Color is ConsoleColor color && ForConsoleColor(color) is { } brush => brush,
			_ => DependencyProperty.UnsetValue,
		};
	}

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
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

/// <summary>bool → одне з двох значень (TrueValue/FalseValue), наприклад TextWrapping або видимість прокрутки.</summary>
public sealed class BoolToValueConverter : IValueConverter
{
	public object? TrueValue { get; set; }

	public object? FalseValue { get; set; }

	public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is true ? TrueValue : FalseValue;

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}
