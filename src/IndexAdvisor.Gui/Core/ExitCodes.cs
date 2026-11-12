namespace IndexAdvisor.Gui.Core;

/// <summary>Коди повернення Invoke-IndexAdvisor (CONTRACTS.md, розділ 11).</summary>
public static class ExitCodes
{
	public static string Describe(int code) => code switch
	{
		0 => "Успіх",
		1 => "Успіх з попередженнями",
		2 => "Помилка конфігурації",
		3 => "Відмова в підключенні",
		4 => "Помилка збору",
		5 => "Помилка LLM або перевищено бюджет",
		6 => "Помилка репозиторію",
		9 => "Непередбачена помилка",
		_ => $"Код {code}",
	};

	/// <summary>0 — успіх, 1 — попередження, решта — помилка.</summary>
	public static Severity GetSeverity(int code) => code switch
	{
		0 => Severity.Success,
		1 => Severity.Warning,
		_ => Severity.Error,
	};
}

public enum Severity
{
	None,
	Success,
	Warning,
	Error,
}
