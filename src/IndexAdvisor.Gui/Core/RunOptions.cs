namespace IndexAdvisor.Gui.Core;

/// <summary>
/// Параметри запуску Invoke-IndexAdvisor, задані у формі. Порожнє значення або null — «з конфігурації YAML».
/// Перемикачі тристанні: null — не передається, true — -Switch, false — -Switch:$false.
/// </summary>
public sealed class RunOptions
{
	public string? ConfigPath { get; set; }

	public string? Servers { get; set; }
	public string? Databases { get; set; }
	public string? ExcludeDatabases { get; set; }
	public string? Schemas { get; set; }
	public string? ExcludeSchemas { get; set; }
	public string? Tables { get; set; }
	public string? ExcludeTables { get; set; }

	/// <summary>Indexes | Partitioning | Both; null — з конфігурації.</summary>
	public string? Module { get; set; }
	public string? Provider { get; set; }
	public string? Model { get; set; }
	public string? CrossCheckProvider { get; set; }
	public int? AnalysisWindowDays { get; set; }

	/// <summary>null — з конфігурації; інакше — точний перелік увімкнених необов'язкових наборів даних.</summary>
	public List<string>? Datasets { get; set; }

	public string? OutputPath { get; set; }

	/// <summary>null — з конфігурації; інакше — точний перелік форматів.</summary>
	public List<string>? Formats { get; set; }

	public string? FromArchive { get; set; }

	public bool? NoRepository { get; set; }
	public bool? NoArchive { get; set; }
	public bool? NonInteractive { get; set; }
	public bool? AutoApprove { get; set; }
	public bool? LocalOnly { get; set; }
	public bool? MaskNames { get; set; }
	public bool? Maintenance { get; set; }

	public bool UnsafeDisableSelectCheck { get; set; }
	public bool UnsafeDisableMaxdop { get; set; }
	public bool UnsafeDisableTimeouts { get; set; }
	public bool UnsafeAllowFreeQuery { get; set; }
	public bool AllowNonStandardLogin { get; set; }

	/// <summary>-Verbose: докладні повідомлення модуля в журналі.</summary>
	public bool Verbose { get; set; }

	public bool HasUnsafeFlags =>
		UnsafeDisableSelectCheck || UnsafeDisableMaxdop || UnsafeDisableTimeouts || UnsafeAllowFreeQuery || AllowNonStandardLogin;

	public RunOptions Clone()
	{
		var copy = (RunOptions)MemberwiseClone();
		copy.Datasets = Datasets is null ? null : [.. Datasets];
		copy.Formats = Formats is null ? null : [.. Formats];
		return copy;
	}
}

/// <summary>Довідкові значення модуля (Shared/Contracts.ps1, Shared/ConfigSchema.psd1).</summary>
public static class IaConstants
{
	public static readonly string[] Modules = ["Indexes", "Partitioning", "Both"];

	public static readonly string[] MandatoryDatasets = ["indexStructure", "instanceStartTime"];

	public static readonly string[] OptionalDatasets =
		["usageStats", "operationalStats", "sizeAndFragmentation", "missingIndexes", "queryStore", "constraintsAndReplication"];

	public static readonly string[] Formats = ["Markdown", "Sql", "Html", "Json", "Console"];

	public static string DescribeDataset(string name) => name switch
	{
		"usageStats" => "Використання індексів (sys.dm_db_index_usage_stats)",
		"operationalStats" => "Операційна статистика (sys.dm_db_index_operational_stats)",
		"sizeAndFragmentation" => "Розміри й фрагментація (sys.dm_db_index_physical_stats)",
		"missingIndexes" => "Відсутні індекси (missing index DMV)",
		"queryStore" => "Query Store: топ-запити й плани",
		"constraintsAndReplication" => "Обмеження, FK і реплікація",
		_ => name,
	};

	public static string DescribeFormat(string name) => name switch
	{
		"Markdown" => "recommendations.md",
		"Sql" => "SQL-скрипти виконання й відкату",
		"Html" => "report.html",
		"Json" => "result.json",
		"Console" => "Підсумок у журналі",
		_ => name,
	};
}
