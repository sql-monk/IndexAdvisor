using System.ComponentModel;
using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using IndexAdvisor.Gui.Dialogs;
using IndexAdvisor.Gui.Infrastructure;
using IndexAdvisor.Gui.Results;

namespace IndexAdvisor.Gui.ViewModels;

public sealed record MessageRow(string Severity, string Source, string Text);

public sealed record FindingRow(string RuleId, string Severity, string SeverityText, string Database, string Table, string Index, string Message, string SuggestedAction)
{
	public string SearchText => string.Join(' ', RuleId, Database, Table, Index, Message, SuggestedAction);
}

public sealed record NoteRow(string Module, string Text);

public sealed record ToolRequestRow(string Tool, string Target, string Decision, string DecisionText, string? DecisionReason, string? Reason, string ResponseText, string Executed);

public sealed record FileLink(string Label, string Path);

/// <summary>Подробиці одного запуску (RunResult): підсумок, рекомендації, знахідки правил, попередження, нотатки, дозапити.</summary>
public sealed class RunDetailsViewModel : ObservableObject
{
	private readonly RunResultDto _run;
	private RecommendationItem? _selectedRecommendation;
	private string? _searchText;
	private ChoiceOption _actionFilter;
	private ChoiceOption _validationFilter;
	private bool _hideRejected;
	private string? _findingSearch;

	public RunDetailsViewModel(RunResultDto run, string? directory)
	{
		_run = run;
		Directory = directory;
		Recommendations = (run.Recommendations ?? []).Select((dto, index) => new RecommendationItem(index + 1, dto)).ToList();
		RecommendationsView = CollectionViewSource.GetDefaultView(Recommendations);

		ActionChoices = new[] { new ChoiceOption(null, "Усі дії") }
			.Concat(Recommendations.Select(item => item.Action).Distinct().OrderBy(action => action).Select(action => new ChoiceOption(action, Labels.Action(action))))
			.ToList();
		ValidationChoices =
		[
			new(null, "Будь-яка перевірка"),
			new("Passed", "Пройдено"),
			new("Warning", "Попередження"),
			new("Failed", "Не пройдено"),
			new("NotValidated", "Не перевірено"),
		];
		_actionFilter = ActionChoices[0];
		_validationFilter = ValidationChoices[0];
		// Фільтр — після ініціалізації полів: присвоєння Filter одразу викликає Refresh.
		RecommendationsView.Filter = FilterRecommendation;

		Findings = (run.Findings ?? []).Select(finding => new FindingRow(
			finding.RuleId ?? string.Empty,
			finding.Severity ?? string.Empty,
			Labels.Level(finding.Severity),
			finding.Target?.Database ?? string.Empty,
			string.Join('.', new[] { finding.Target?.Schema, finding.Target?.Table }.Where(part => !string.IsNullOrWhiteSpace(part))),
			finding.Target?.Index ?? string.Empty,
			finding.Message ?? string.Empty,
			Labels.Action(finding.SuggestedAction))).ToList();
		FindingsView = CollectionViewSource.GetDefaultView(Findings);
		FindingsView.Filter = item => string.IsNullOrWhiteSpace(_findingSearch)
			|| ((FindingRow)item).SearchText.Contains(_findingSearch.Trim(), StringComparison.CurrentCultureIgnoreCase);

		Messages = BuildMessages(run);
		Notes = (run.Llm?.Notes ?? []).Select(note => new NoteRow(Labels.Module(note.Module), note.Text ?? string.Empty)).ToList();
		ToolRequests = (run.ToolRequests ?? []).Select(request => new ToolRequestRow(
			request.Tool ?? string.Empty,
			string.Join('/', new[] { request.Server, request.Database }.Where(part => !string.IsNullOrWhiteSpace(part))),
			request.Decision ?? string.Empty,
			Labels.Decision(request.Decision),
			request.DecisionReason,
			request.Reason,
			request.Response is { } response
				? response.Success == true
					? $"рядків: {response.RowCount}{(response.Truncated == true ? " (обрізано)" : string.Empty)}, {response.DurationMs} мс"
					: "помилка: " + (response.Error is { } error ? RunResultStore.ElementText(error) : "?")
				: "не виконано",
			RunResultStore.FormatDate(request.ExecutedAtUtc))).ToList();

		Files = BuildFiles(directory);
		SelectedRecommendation = Recommendations.FirstOrDefault();

		OpenFileCommand = new RelayCommand(parameter =>
		{
			if (parameter is FileLink link)
			{
				DialogService.OpenWithShell(link.Path);
			}
		});
		CopyScriptCommand = new RelayCommand(parameter =>
		{
			if (parameter is string text && text.Length > 0)
			{
				Clipboard.SetText(text);
			}
		});
		SaveScriptsCommand = new RelayCommand(SaveScripts, () => SelectedRecommendation is not null);
		CopySummaryCommand = new RelayCommand(() => Clipboard.SetText(BuildSummaryText()));
	}

	public string? Directory { get; }

	public string Server => _run.RequestedServer ?? "?";

	public string RunId => _run.RunId ?? string.Empty;

	public string Status => _run.Status ?? string.Empty;

	public string StatusText => $"{Labels.RunStatus(_run.Status)} · {Core.ExitCodes.Describe(_run.ExitCode ?? 0)} (код {_run.ExitCode ?? 0})";

	public string ModuleText => Labels.Module(_run.Module);

	public string TimeText
	{
		get
		{
			var started = RunResultStore.ParseDate(_run.StartedAtUtc);
			var finished = RunResultStore.ParseDate(_run.FinishedAtUtc);
			var text = RunResultStore.FormatDate(_run.StartedAtUtc);
			if (started is not null && finished is not null)
			{
				var duration = finished.Value - started.Value;
				text += $" · {(int)duration.TotalMinutes} хв {duration.Seconds} с";
			}
			if (!string.IsNullOrWhiteSpace(_run.StartedBy))
			{
				text += $" · {_run.StartedBy}";
			}
			return text;
		}
	}

	public string TopologyText
	{
		get
		{
			var topology = _run.Topology;
			var text = topology?.Type switch
			{
				"AG" => "Availability Group",
				"FCI" => "Failover Cluster Instance",
				"Standalone" => "Окремий інстанс",
				null => "—",
				var other => other,
			};
			if (!string.IsNullOrWhiteSpace(_run.FromArchive))
			{
				text += $" · з архіву {Path.GetFileName(_run.FromArchive)}";
			}
			return text;
		}
	}

	public string PeriodText
	{
		get
		{
			var periods = _run.DataPeriods ?? [];
			var shortest = periods.Where(period => period.UptimeDays is not null).MinBy(period => period.UptimeDays);
			if (shortest is null)
			{
				return "не визначено";
			}
			var scope = string.IsNullOrWhiteSpace(shortest.Database) ? shortest.Server : $"{shortest.Server}/{shortest.Database}";
			var days = shortest.UptimeDays!.Value.ToString("0.#", CultureInfo.CurrentCulture);
			var sufficient = shortest.IsSufficient == false ? $" — НЕДОСТАТНІЙ (мінімум {shortest.MinRequiredDays} дн.)" : string.Empty;
			return $"{days} дн. з {RunResultStore.FormatDate(shortest.StatsFromUtc)} ({scope}){sufficient}";
		}
	}

	public bool PeriodInsufficient => (_run.DataPeriods ?? []).Any(period => period.IsSufficient == false);

	public string AnalysisWindowText => _run.AnalysisWindow is { } window
		? $"{RunResultStore.FormatDate(window.FromUtc)} — {RunResultStore.FormatDate(window.ToUtc)}"
		: "—";

	public string LlmText
	{
		get
		{
			var llm = _run.Llm;
			if (llm is null || string.IsNullOrWhiteSpace(llm.Provider))
			{
				return "не викликалась";
			}
			var cost = llm.TotalCostUsd is double usd ? usd.ToString("0.00##", CultureInfo.InvariantCulture) + " USD" : "—";
			return $"{llm.Provider} / {llm.Model} · токени {llm.TotalInputTokens:N0} + {llm.TotalOutputTokens:N0} · {cost} · викликів {llm.Calls?.Count ?? 0}";
		}
	}

	public string MaskingText
	{
		get
		{
			var masking = _run.Masking;
			var names = masking?.NamesMasked == true ? "імена масковано" : "імена НЕ масковано";
			var literals = masking?.LiteralsMasked == false ? "літерали НЕ очищено" : "літерали очищено";
			var login = _run.LoginCheck is { } check
				? $" · логін {check.Login}{(check.IsStandard == false ? " (НЕШТАТНИЙ)" : string.Empty)}"
				: string.Empty;
			return $"{names}, {literals}{login}";
		}
	}

	public string? UnsafeText => _run.UnsafeFlags is { Count: > 0 } flags ? "Небезпечні режими: " + string.Join(", ", flags) : null;

	public string DatasetsText
	{
		get
		{
			var disabled = _run.Datasets?.Disabled ?? [];
			return disabled.Count == 0 ? "усі набори зібрано" : "не зібрано: " + string.Join(", ", disabled);
		}
	}

	public IReadOnlyList<RecommendationItem> Recommendations { get; }

	public ICollectionView RecommendationsView { get; }

	public RecommendationItem? SelectedRecommendation
	{
		get => _selectedRecommendation;
		set => SetProperty(ref _selectedRecommendation, value);
	}

	public string RecommendationsHeader => $"Рекомендації ({Recommendations.Count(item => !item.IsRejected)}" +
		(Recommendations.Any(item => item.IsRejected) ? $" + {Recommendations.Count(item => item.IsRejected)} відхилено" : string.Empty) + ")";

	public string RecommendationsSummary
	{
		get
		{
			var groups = Recommendations.Where(item => !item.IsRejected)
				.GroupBy(item => item.ActionText)
				.Select(group => $"{group.Key}: {group.Count()}");
			return string.Join(" · ", groups);
		}
	}

	public IReadOnlyList<ChoiceOption> ActionChoices { get; }

	public IReadOnlyList<ChoiceOption> ValidationChoices { get; }

	public string? SearchText
	{
		get => _searchText;
		set
		{
			if (SetProperty(ref _searchText, value))
			{
				RecommendationsView.Refresh();
			}
		}
	}

	public ChoiceOption ActionFilter
	{
		get => _actionFilter;
		set
		{
			if (SetProperty(ref _actionFilter, value ?? ActionChoices[0]))
			{
				RecommendationsView.Refresh();
			}
		}
	}

	public ChoiceOption ValidationFilter
	{
		get => _validationFilter;
		set
		{
			if (SetProperty(ref _validationFilter, value ?? ValidationChoices[0]))
			{
				RecommendationsView.Refresh();
			}
		}
	}

	public bool HideRejected
	{
		get => _hideRejected;
		set
		{
			if (SetProperty(ref _hideRejected, value))
			{
				RecommendationsView.Refresh();
			}
		}
	}

	public IReadOnlyList<FindingRow> Findings { get; }

	public ICollectionView FindingsView { get; }

	public string FindingsHeader => $"Знахідки правил ({Findings.Count})";

	public string? FindingSearch
	{
		get => _findingSearch;
		set
		{
			if (SetProperty(ref _findingSearch, value))
			{
				FindingsView.Refresh();
			}
		}
	}

	public IReadOnlyList<MessageRow> Messages { get; }

	public string MessagesHeader => $"Попередження й помилки ({Messages.Count})";

	public IReadOnlyList<NoteRow> Notes { get; }

	public string NotesHeader => $"Нотатки моделі ({Notes.Count})";

	public IReadOnlyList<ToolRequestRow> ToolRequests { get; }

	public string ToolRequestsHeader => $"Дозапити моделі ({ToolRequests.Count})";

	public IReadOnlyList<FileLink> Files { get; }

	public bool HasFiles => Files.Count > 0;

	public ICommand OpenFileCommand { get; }
	public ICommand CopyScriptCommand { get; }
	public ICommand SaveScriptsCommand { get; }
	public ICommand CopySummaryCommand { get; }

	private bool FilterRecommendation(object item)
	{
		var recommendation = (RecommendationItem)item;
		if (_hideRejected && recommendation.IsRejected)
		{
			return false;
		}
		if (_actionFilter.Value is { } action && recommendation.Action != action)
		{
			return false;
		}
		if (_validationFilter.Value is { } validation && recommendation.Validation != validation)
		{
			return false;
		}
		return string.IsNullOrWhiteSpace(_searchText)
			|| recommendation.SearchText.Contains(_searchText.Trim(), StringComparison.CurrentCultureIgnoreCase);
	}

	private static IReadOnlyList<MessageRow> BuildMessages(RunResultDto run)
	{
		var rows = new List<MessageRow>();
		foreach (var error in run.Errors ?? [])
		{
			rows.Add(new MessageRow("Error", $"{error.Stage} · {error.Code}", error.Message ?? string.Empty));
		}
		foreach (var flag in run.UnsafeFlags ?? [])
		{
			rows.Add(new MessageRow("Error", "Небезпечний режим", flag));
		}
		foreach (var warning in run.Warnings ?? [])
		{
			rows.Add(new MessageRow("Warning", "Запуск", RunResultStore.ElementText(warning)));
		}
		foreach (var warning in run.Datasets?.Warnings ?? [])
		{
			rows.Add(new MessageRow("Warning", "Набори даних", RunResultStore.ElementText(warning)));
		}
		foreach (var warning in run.LoginCheck?.Warnings ?? [])
		{
			rows.Add(new MessageRow("Warning", "Логін", RunResultStore.ElementText(warning)));
		}
		foreach (var period in run.DataPeriods ?? [])
		{
			var scope = string.IsNullOrWhiteSpace(period.Database) ? period.Server : $"{period.Server}/{period.Database}";
			foreach (var warning in period.Warnings ?? [])
			{
				rows.Add(new MessageRow("Info", $"Період даних {scope}", RunResultStore.ElementText(warning)));
			}
		}
		return rows.Where(row => row.Text.Length > 0).DistinctBy(row => row.Text).ToList();
	}

	private static IReadOnlyList<FileLink> BuildFiles(string? directory)
	{
		if (directory is null || !System.IO.Directory.Exists(directory))
		{
			return [];
		}
		var links = new List<FileLink>();
		void Add(string label, string relative)
		{
			var path = Path.Combine(directory, relative);
			if (File.Exists(path) || System.IO.Directory.Exists(path))
			{
				links.Add(new FileLink(label, path));
			}
		}
		Add("HTML-звіт", "report.html");
		Add("recommendations.md", "recommendations.md");
		Add("SQL-скрипти", "sql");
		Add("Обслуговування", "maintenance");
		links.Add(new FileLink("Тека запуску", directory));
		return links;
	}

	private void SaveScripts()
	{
		var item = SelectedRecommendation;
		if (item is null)
		{
			return;
		}
		var path = DialogService.SaveFile(DialogService.SqlFilter, item.FileBase + ".sql", "Зберегти скрипт виконання (поруч — скрипт відкату)");
		if (path is null)
		{
			return;
		}
		var rollback = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path) + "_rollback.sql");
		var header = $"-- IndexAdvisor: {item.Title}{Environment.NewLine}-- Сервер: {item.ServerText}; runId {RunId}{Environment.NewLine}";
		var encoding = new UTF8Encoding(true);
		File.WriteAllText(path, header + item.ExecuteScript, encoding);
		File.WriteAllText(rollback, header + item.RollbackScript, encoding);
	}

	private string BuildSummaryText()
	{
		var text = new StringBuilder();
		text.AppendLine($"IndexAdvisor: {Server} ({RunId})");
		text.AppendLine($"Статус: {StatusText}");
		text.AppendLine($"Модуль: {ModuleText}; {TimeText}");
		text.AppendLine($"Період даних: {PeriodText}");
		text.AppendLine($"Модель: {LlmText}");
		text.AppendLine($"{RecommendationsHeader}: {RecommendationsSummary}");
		return text.ToString();
	}
}
