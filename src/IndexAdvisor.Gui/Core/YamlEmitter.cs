using System.Collections;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace IndexAdvisor.Gui.Core;

/// <summary>
/// Мінімальний генератор YAML для конфігурації: вкладені мапи (IDictionary з порядком вставки),
/// списки скалярів у потоковому стилі, списки мап — блоком. Рядки, які можна прочитати як інший тип
/// (true, 01:00, шляхи, посилання secret:...), беруться в одинарні лапки.
/// </summary>
public static partial class YamlEmitter
{
	private const string Indent = "  ";

	private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
	{
		"true", "false", "yes", "no", "on", "off", "y", "n", "null", "~",
	};

	[GeneratedRegex(@"^[A-Za-z_][A-Za-z0-9_.\-]*$")]
	private static partial Regex PlainPattern();

	/// <param name="comments">Коментарі перед ключами верхнього рівня (# опис).</param>
	public static string Emit(IDictionary root, IReadOnlyDictionary<string, string>? comments = null, string? header = null)
	{
		var text = new StringBuilder();
		if (!string.IsNullOrWhiteSpace(header))
		{
			foreach (var line in header.Split('\n'))
			{
				text.Append("# ").AppendLine(line.TrimEnd());
			}
		}
		var first = true;
		foreach (DictionaryEntry entry in root)
		{
			var key = Convert.ToString(entry.Key, CultureInfo.InvariantCulture)!;
			if (comments is not null && comments.TryGetValue(key, out var comment) && !string.IsNullOrWhiteSpace(comment))
			{
				if (!first)
				{
					text.AppendLine();
				}
				text.Append("# ").AppendLine(comment.Replace('\n', ' ').Trim());
			}
			WriteEntry(text, key, entry.Value, 0);
			first = false;
		}
		return text.ToString();
	}

	public static string Scalar(object? value) => value switch
	{
		null => "null",
		bool flag => flag ? "true" : "false",
		int or long or short or byte => Convert.ToString(value, CultureInfo.InvariantCulture)!,
		double number => FormatDouble(number),
		float number => FormatDouble(number),
		decimal number => number.ToString(CultureInfo.InvariantCulture),
		_ => QuoteString(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty),
	};

	public static string Key(string key) => QuoteString(key);

	private static string QuoteString(string value)
	{
		if (value.Length > 0 && PlainPattern().IsMatch(value) && !Reserved.Contains(value) && !LooksNumeric(value))
		{
			return value;
		}
		return "'" + value.Replace("'", "''") + "'";
	}

	private static bool LooksNumeric(string value)
		=> double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _)
			|| value.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
			|| value.StartsWith('.');

	private static string FormatDouble(double value)
	{
		var text = value.ToString("R", CultureInfo.InvariantCulture);
		return text.Contains('E') && !text.Contains('.') ? value.ToString("0.0###############", CultureInfo.InvariantCulture) : text;
	}

	private static void WriteEntry(StringBuilder text, string key, object? value, int depth)
	{
		var prefix = string.Concat(Enumerable.Repeat(Indent, depth));
		switch (value)
		{
			case IDictionary map when map.Count == 0:
				text.Append(prefix).Append(Key(key)).AppendLine(": {}");
				break;
			case IDictionary map:
				text.Append(prefix).Append(Key(key)).AppendLine(":");
				foreach (DictionaryEntry entry in map)
				{
					WriteEntry(text, Convert.ToString(entry.Key, CultureInfo.InvariantCulture)!, entry.Value, depth + 1);
				}
				break;
			case IList list when list.Cast<object?>().Any(item => item is IDictionary):
				text.Append(prefix).Append(Key(key)).AppendLine(":");
				foreach (var item in list)
				{
					WriteListItem(text, item, depth + 1);
				}
				break;
			case IList list:
				text.Append(prefix).Append(Key(key)).Append(": [")
					.Append(string.Join(", ", list.Cast<object?>().Select(Scalar)))
					.AppendLine("]");
				break;
			default:
				text.Append(prefix).Append(Key(key)).Append(": ").AppendLine(Scalar(value));
				break;
		}
	}

	private static void WriteListItem(StringBuilder text, object? item, int depth)
	{
		var prefix = string.Concat(Enumerable.Repeat(Indent, depth));
		if (item is not IDictionary map || map.Count == 0)
		{
			text.Append(prefix).Append("- ").AppendLine(item is IDictionary ? "{}" : Scalar(item));
			return;
		}
		// Перший ключ — у рядку з «- », решта — з відступом на ширину «- ».
		var nested = new StringBuilder();
		foreach (DictionaryEntry entry in map)
		{
			WriteEntry(nested, Convert.ToString(entry.Key, CultureInfo.InvariantCulture)!, entry.Value, depth + 1);
		}
		var lines = nested.ToString().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
		var inner = prefix + Indent;
		for (var i = 0; i < lines.Length; i++)
		{
			var line = lines[i].StartsWith(inner, StringComparison.Ordinal) ? lines[i][inner.Length..] : lines[i].TrimStart();
			text.Append(prefix).Append(i == 0 ? "- " : Indent).AppendLine(line);
		}
	}
}
