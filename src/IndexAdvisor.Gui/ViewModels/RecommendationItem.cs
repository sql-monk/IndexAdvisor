using System.Globalization;
using System.Text.Json;
using ICSharpCode.AvalonEdit.Document;
using IndexAdvisor.Gui.Results;

namespace IndexAdvisor.Gui.ViewModels;

public sealed record CheckRow(string Status, string StatusText, string Name, string Message);

public sealed record ConditionRow(bool? Met, string Name, string Details)
{
	public string Glyph => Met switch
	{
		true => "✓",
		false => "✗",
		null => "?",
	};

	public string Status => Met switch
	{
		true => "Passed",
		false => "Failed",
		null => "Unknown",
	};
}

/// <summary>Рекомендація для таблиці й панелі подробиць.</summary>
public sealed class RecommendationItem
{
	private TextDocument? _executeDocument;
	private TextDocument? _rollbackDocument;
	private TextDocument? _partitioningDocument;

	public RecommendationItem(int number, RecommendationDto dto)
	{
		Number = number;
		Dto = dto;
		var target = dto.Target;
		DatabaseText = target?.Database ?? string.Empty;
		TableText = string.Join('.', new[] { target?.Schema, target?.Table }.Where(part => !string.IsNullOrWhiteSpace(part)));
		TargetText = string.Join('.', new[] { target?.Database, target?.Schema, target?.Table }.Where(part => !string.IsNullOrWhiteSpace(part)));
		ServerText = target?.Server ?? string.Empty;
		Checks = (dto.Validation?.Checks ?? [])
			.Select(check => new CheckRow(check.Status ?? string.Empty, Labels.Validation(check.Status), Labels.Check(check.Id), check.Message ?? string.Empty))
			.ToList();
		Conditions = (dto.DropEligibility?.Conditions ?? [])
			.Select(condition => new ConditionRow(condition.Met, Labels.DropCondition(condition.Id), condition.Details ?? string.Empty))
			.ToList();
		Warnings = (dto.Warnings ?? []).Select(RunResultStore.ElementText).Where(text => text.Length > 0).ToList();
		var replaces = (dto.ReplacesIndexes ?? []).Select(RunResultStore.ElementText).Where(text => text.Length > 0).ToList();
		ReplacesText = replaces.Count > 0 ? string.Join(", ", replaces) : null;
	}

	public RecommendationDto Dto { get; }

	public int Number { get; }

	public string Action => Dto.Action ?? string.Empty;

	public string ActionText => Labels.Action(Dto.Action);

	public string ModuleText => Labels.Module(Dto.Module);

	public string ServerText { get; }

	public string TargetText { get; }

	public string DatabaseText { get; }

	public string TableText { get; }

	public string IndexText => Dto.Target?.Index ?? string.Empty;

	public string Risk => Dto.Risk?.Level ?? string.Empty;

	public string RiskText => Labels.Level(Dto.Risk?.Level);

	public string? RiskDescription => Dto.Risk?.Description;

	public string Confidence => Dto.Confidence ?? string.Empty;

	public string ConfidenceText => Labels.Level(Dto.Confidence);

	public string Validation => Dto.Validation?.Status ?? string.Empty;

	public string ValidationText => Labels.Validation(Dto.Validation?.Status);

	public bool IsRejected => Dto.Validation?.Status == "Failed";

	public string SourceText => Labels.Source(Dto.Source);

	public string Title => Dto.Title ?? $"{ActionText} {TargetText}";

	public string? Rationale => Dto.Rationale;

	public IReadOnlyList<CheckRow> Checks { get; }

	public IReadOnlyList<ConditionRow> Conditions { get; }

	public bool HasDropEligibility => Dto.DropEligibility is not null;

	public string DropSummary
	{
		get
		{
			var drop = Dto.DropEligibility;
			if (drop is null)
			{
				return string.Empty;
			}
			var verdict = drop.IsEligible == true
				? "Умови видалення виконано: скрипт активний."
				: "Умови видалення виконано не всі: скрипт видалення записано закоментованим.";
			var series = drop.RequiredConsecutive is int required
				? $" Серія: {drop.ConsecutiveCount ?? 0} з {required}{(drop.RulesProfile == "Relaxed" ? " (послаблені правила)" : string.Empty)}."
				: string.Empty;
			return verdict + series + (string.IsNullOrWhiteSpace(drop.Warning) ? string.Empty : " " + drop.Warning);
		}
	}

	public bool DropEligible => Dto.DropEligibility?.IsEligible == true;

	public IReadOnlyList<string> Warnings { get; }

	public bool HasWarnings => Warnings.Count > 0;

	public string? ReplacesText { get; }

	public string? CrossCheckText => Dto.CrossCheck is { } cross
		? $"{Labels.CrossCheck(cross.Verdict)} ({cross.Provider}/{cross.Model}){(string.IsNullOrWhiteSpace(cross.Notes) ? string.Empty : ": " + cross.Notes)}"
		: null;

	public string? ImpactText
	{
		get
		{
			var impact = Dto.Impact;
			if (impact is null)
			{
				return null;
			}
			var parts = new List<string>();
			if (impact.EstimatedSizeMb is double size)
			{
				parts.Add($"розмір ≈ {size.ToString("N0", CultureInfo.CurrentCulture)} МБ");
			}
			if (impact.EstimatedBuildMinutes is double minutes)
			{
				parts.Add($"побудова ≈ {minutes.ToString("0.#", CultureInfo.CurrentCulture)} хв");
			}
			if (impact.TableWritesPerDay is double writes)
			{
				parts.Add($"записів на добу ≈ {writes.ToString("N0", CultureInfo.CurrentCulture)}");
			}
			var queries = (impact.AffectedQueryIds ?? []).Select(RunResultStore.ElementText).Where(text => text.Length > 0).ToList();
			if (queries.Count > 0)
			{
				parts.Add("запити Query Store: " + string.Join(", ", queries.Take(10)) + (queries.Count > 10 ? "…" : string.Empty));
			}
			if (!string.IsNullOrWhiteSpace(impact.Notes))
			{
				parts.Add(impact.Notes);
			}
			return parts.Count > 0 ? string.Join("; ", parts) : null;
		}
	}

	public string? DataPeriodText
	{
		get
		{
			var period = Dto.DataPeriod;
			if (period is null)
			{
				return null;
			}
			var text = $"статистика з {RunResultStore.FormatDate(period.StatsFromUtc)}";
			if (period.UptimeDays is double days)
			{
				text += $" ({days.ToString("0.#", CultureInfo.CurrentCulture)} дн.)";
			}
			if (period.QueryStoreDays is double qs)
			{
				text += $"; Query Store {qs.ToString("0.#", CultureInfo.CurrentCulture)} дн.";
			}
			if (period.IsSufficient == false)
			{
				text += $" — коротший за мінімальні {period.MinRequiredDays} дн.";
			}
			return text;
		}
	}

	public bool PeriodInsufficient => Dto.DataPeriod?.IsSufficient == false;

	public bool HasPartitioning => Dto.Partitioning is { ValueKind: JsonValueKind.Object };

	public string ExecuteScript => Dto.ExecuteScript ?? string.Empty;

	public string RollbackScript => Dto.RollbackScript ?? string.Empty;

	// Документи AvalonEdit створюються ліниво в потоці інтерфейсу (під час прив'язки).
	public TextDocument ExecuteDocument => _executeDocument ??= new TextDocument(ExecuteScript);

	public TextDocument RollbackDocument => _rollbackDocument ??= new TextDocument(RollbackScript);

	public TextDocument PartitioningDocument => _partitioningDocument ??= new TextDocument(
		Dto.Partitioning is { ValueKind: JsonValueKind.Object } partitioning ? RunResultStore.PrettyJson(partitioning) : string.Empty);

	/// <summary>Основа імені файлу: 001_CreateIndex_Table.</summary>
	public string FileBase
	{
		get
		{
			var name = string.IsNullOrWhiteSpace(Dto.Target?.Table) ? "object" : Dto.Target!.Table!;
			foreach (var invalid in Path.GetInvalidFileNameChars())
			{
				name = name.Replace(invalid, '_');
			}
			return $"{Number:000}_{Action}_{name}";
		}
	}

	public string SearchText => string.Join(' ', Title, TargetText, IndexText, ServerText, ActionText, Rationale);
}
