using System.Globalization;
using System.Text.Json;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Results;

/// <summary>Запуск у списку результатів: з result.json на диску або з пам'яті (запуск без формату Json).</summary>
public sealed class RunListEntry
{
	public string? ResultPath { get; init; }
	public string? Directory { get; init; }
	public string? InMemoryJson { get; init; }
	public string RunId { get; init; } = string.Empty;
	public string Server { get; init; } = string.Empty;
	public string Module { get; init; } = string.Empty;
	public DateTimeOffset? StartedAt { get; init; }
	public string Status { get; init; } = string.Empty;
	public int ExitCode { get; init; }
	public int RecommendationCount { get; init; }
	public double? CostUsd { get; init; }
	public string? Model { get; init; }

	public string StartedText => StartedAt?.ToLocalTime().ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) ?? "—";

	public string StatusText => Labels.RunStatus(Status);

	public string DetailsText
	{
		get
		{
			var parts = new List<string> { Labels.Module(Module), $"рек.: {RecommendationCount}" };
			if (CostUsd is double cost && cost > 0)
			{
				parts.Add(cost.ToString("$0.00", CultureInfo.InvariantCulture));
			}
			if (InMemoryJson is not null)
			{
				parts.Add("без result.json");
			}
			return string.Join(" · ", parts);
		}
	}
}

public static class RunResultStore
{
	public const string ResultFileName = "result.json";

	public static RunResultDto Parse(string json)
		=> JsonSerializer.Deserialize<RunResultDto>(json, IndexAdvisorService.JsonOptions)
			?? throw new InvalidDataException("Порожній RunResult.");

	public static RunResultDto Load(RunListEntry entry)
		=> entry.InMemoryJson is not null
			? Parse(entry.InMemoryJson)
			: Parse(File.ReadAllText(entry.ResultPath ?? throw new InvalidOperationException("Немає шляху до result.json.")));

	public static RunListEntry CreateEntry(RunResultDto run, string? resultPath, string? inMemoryJson) => new()
	{
		ResultPath = resultPath,
		Directory = resultPath is null ? null : Path.GetDirectoryName(resultPath),
		InMemoryJson = inMemoryJson,
		RunId = run.RunId ?? string.Empty,
		Server = run.RequestedServer ?? run.Topology?.ServerName ?? "?",
		Module = run.Module ?? string.Empty,
		StartedAt = ParseDate(run.StartedAtUtc),
		Status = run.Status ?? string.Empty,
		ExitCode = run.ExitCode ?? 0,
		RecommendationCount = run.Recommendations?.Count ?? 0,
		CostUsd = run.Llm?.TotalCostUsd,
		Model = run.Llm?.Model,
	};

	/// <summary>
	/// Шукає result.json у підтеках (типово до трьох рівнів: out\запуск, прогін\out\запуск).
	/// Пошкоджені файли пропускаються. Новіші — першими.
	/// </summary>
	public static IReadOnlyList<RunListEntry> Scan(string root, int maxDepth = 3, int limit = 500)
	{
		if (string.IsNullOrWhiteSpace(root) || !System.IO.Directory.Exists(root))
		{
			return [];
		}
		var options = new EnumerationOptions
		{
			RecurseSubdirectories = true,
			MaxRecursionDepth = Math.Clamp(maxDepth, 0, 8),
			IgnoreInaccessible = true,
			MatchCasing = MatchCasing.CaseInsensitive,
		};
		var files = System.IO.Directory.EnumerateFiles(root, ResultFileName, options)
			.Select(path => new FileInfo(path))
			.OrderByDescending(file => file.LastWriteTimeUtc)
			.Take(limit);
		var entries = new List<RunListEntry>();
		foreach (var file in files)
		{
			try
			{
				entries.Add(CreateEntry(ReadSummary(file.FullName), file.FullName, null));
			}
			catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException or InvalidDataException)
			{
				// Не RunResult або файл зайнятий — пропускаємо.
			}
		}
		return entries.OrderByDescending(entry => entry.StartedAt ?? DateTimeOffset.MinValue).ToList();
	}

	/// <summary>Лише поля для списку, без десеріалізації рекомендацій і знахідок.</summary>
	private static RunResultDto ReadSummary(string path)
	{
		using var stream = File.OpenRead(path);
		using var document = JsonDocument.Parse(stream);
		var root = document.RootElement;
		if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("runId", out _))
		{
			throw new InvalidDataException("Не RunResult.");
		}
		string? Text(JsonElement element, string name)
			=> element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
				? value.GetString()
				: null;
		var run = new RunResultDto
		{
			RunId = Text(root, "runId"),
			Module = Text(root, "module"),
			RequestedServer = Text(root, "requestedServer"),
			StartedAtUtc = Text(root, "startedAtUtc"),
			Status = Text(root, "status"),
		};
		if (root.TryGetProperty("exitCode", out var exitCode) && ReadNumber(exitCode) is double code)
		{
			run.ExitCode = (int)code;
		}
		if (root.TryGetProperty("recommendations", out var recommendations) && recommendations.ValueKind == JsonValueKind.Array)
		{
			run.Recommendations = Enumerable.Range(0, recommendations.GetArrayLength()).Select(_ => new RecommendationDto()).ToList();
		}
		if (root.TryGetProperty("llm", out var llm) && llm.ValueKind == JsonValueKind.Object)
		{
			run.Llm = new LlmRunDto { Model = Text(llm, "model"), Provider = Text(llm, "provider") };
			if (llm.TryGetProperty("totalCostUsd", out var cost))
			{
				run.Llm.TotalCostUsd = ReadNumber(cost);
			}
		}
		return run;
	}

	/// <summary>Число або рядок з числом (decimal модуль серіалізує рядком).</summary>
	private static double? ReadNumber(JsonElement element) => element.ValueKind switch
	{
		JsonValueKind.Number => element.GetDouble(),
		JsonValueKind.String when double.TryParse(element.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) => value,
		_ => null,
	};

	public static DateTimeOffset? ParseDate(string? iso)
		=> DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value) ? value : null;

	public static string FormatDate(string? iso)
		=> ParseDate(iso)?.ToLocalTime().ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) ?? "—";

	/// <summary>Попередження бувають рядками або об'єктами з полем message.</summary>
	public static string ElementText(JsonElement element) => element.ValueKind switch
	{
		JsonValueKind.String => element.GetString() ?? string.Empty,
		JsonValueKind.Object when element.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String
			=> message.GetString() ?? string.Empty,
		JsonValueKind.Null or JsonValueKind.Undefined => string.Empty,
		_ => element.GetRawText(),
	};

	public static string PrettyJson(JsonElement element)
		=> JsonSerializer.Serialize(element, PrettyOptions);

	private static readonly JsonSerializerOptions PrettyOptions = new()
	{
		WriteIndented = true,
		Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
	};
}
