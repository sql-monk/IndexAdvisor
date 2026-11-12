using System.Text.RegularExpressions;

namespace IndexAdvisor.Gui.Core;

/// <summary>Варіант відповіді: напис кнопки й текст, який повертається в Read-Host.</summary>
public sealed record PromptChoice(string Label, string Answer);

/// <summary>
/// Розпізнає в тексті Read-Host варіанти у квадратних дужках, наприклад
/// «Виконати дозапит? [П]ідтвердити / [З]мінити / [В]ідхилити» → питання й кнопки «Підтвердити» (П), «Змінити» (З), «Відхилити» (В).
/// </summary>
public static partial class ChoicePromptParser
{
	[GeneratedRegex(@"\[(?<key>[^\[\]\s]{1,3})\](?<rest>[\p{L}\p{N}'’-]*)")]
	private static partial Regex ChoicePattern();

	public static bool TryParse(string? prompt, out string question, out IReadOnlyList<PromptChoice> choices)
	{
		question = prompt?.Trim() ?? string.Empty;
		choices = [];
		if (string.IsNullOrWhiteSpace(prompt))
		{
			return false;
		}
		var matches = ChoicePattern().Matches(prompt);
		if (matches.Count < 2)
		{
			return false;
		}
		var list = new List<PromptChoice>(matches.Count);
		foreach (Match match in matches)
		{
			var key = match.Groups["key"].Value;
			var rest = match.Groups["rest"].Value;
			var label = rest.Length > 0 ? key + rest : key;
			list.Add(new PromptChoice(label, key));
		}
		if (list.Select(c => c.Answer).Distinct(StringComparer.OrdinalIgnoreCase).Count() != list.Count)
		{
			return false;
		}
		question = prompt[..matches[0].Index].Trim().TrimEnd(':').Trim();
		choices = list;
		return true;
	}
}
