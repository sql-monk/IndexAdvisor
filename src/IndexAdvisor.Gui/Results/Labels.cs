namespace IndexAdvisor.Gui.Results;

/// <summary>Українські назви значень RunResult для інтерфейсу.</summary>
public static class Labels
{
	public static string RunStatus(string? status) => status switch
	{
		"Succeeded" => "Успішно",
		"Partial" => "Частково",
		"Failed" => "Помилка",
		null or "" => "—",
		_ => status,
	};

	public static string Module(string? module) => module switch
	{
		"Indexes" => "Індекси",
		"Partitioning" => "Партиціонування",
		"Both" => "Індекси й партиціонування",
		null or "" => "—",
		_ => module,
	};

	public static string Action(string? action) => action switch
	{
		"CreateIndex" => "Створити індекс",
		"DropIndex" => "Видалити індекс",
		"AlterIndex" => "Змінити індекс",
		"PartitionTable" => "Партиціонувати",
		"AlterPartitioning" => "Змінити партиції",
		null or "" => "—",
		_ => action,
	};

	public static string Level(string? level) => level switch
	{
		"Low" => "Низький",
		"Medium" => "Середній",
		"High" => "Високий",
		null or "" => "—",
		_ => level,
	};

	public static string Validation(string? status) => status switch
	{
		"Passed" => "Пройдено",
		"Failed" => "Не пройдено",
		"Warning" => "Попередження",
		"NotValidated" => "Не перевірено",
		"Skipped" => "Пропущено",
		null or "" => "—",
		_ => status,
	};

	public static string Source(string? source) => source switch
	{
		"Llm" => "Модель",
		"Rules" => "Правила",
		null or "" => "—",
		_ => source,
	};

	public static string Check(string? id) => id switch
	{
		"ObjectsExist" => "Об'єкти існують",
		"NotDuplicate" => "Не дублює наявний індекс",
		"DropAllowed" => "Видалення дозволене",
		"SyntaxValid" => "Синтаксис коректний",
		"RollbackMatches" => "Відкат відповідає виконанню",
		"PlatformLimits" => "Обмеження платформи",
		"EditionFeatures" => "Можливості редакції",
		"PartitionAlignment" => "Вирівнювання партицій",
		"SafeScript" => "Безпечний скрипт",
		null or "" => "—",
		_ => id,
	};

	public static string DropCondition(string? id) => id switch
	{
		"ConsecutiveSeries" => "Серія послідовних аналізів",
		"MinUptimePeriod" => "Мінімальний період роботи сервера",
		"MinInterval" => "Мінімальний інтервал між аналізами",
		"AnalysisWindow" => "Вікно аналізу",
		"NotPrimaryKey" => "Не первинний ключ",
		"NotUnique" => "Не унікальний індекс",
		"NoForeignKeySupport" => "Не підтримує зовнішній ключ",
		"NotReplicated" => "Не потрібен реплікації",
		"NoHintReferences" => "Немає посилань у хінтах",
		"NotUsedInQueryStore" => "Не використовується в Query Store",
		"CheckedOnAllReplicas" => "Перевірено на всіх репліках",
		null or "" => "—",
		_ => id,
	};

	public static string Decision(string? decision) => decision switch
	{
		"Approved" => "Підтверджено",
		"Modified" => "Змінено",
		"Rejected" => "Відхилено",
		"AutoApproved" => "Автопідтверджено",
		"Blocked" => "Заблоковано",
		null or "" => "—",
		_ => decision,
	};

	public static string CrossCheck(string? verdict) => verdict switch
	{
		"Agree" => "Погоджується",
		"Disagree" => "Не погоджується",
		"Uncertain" => "Не впевнена",
		null or "" => "—",
		_ => verdict,
	};
}
