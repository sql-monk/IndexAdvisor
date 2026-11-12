using IndexAdvisor.Gui.Results;

namespace IndexAdvisor.Gui.Tests;

public sealed class RunResultStoreTests : IDisposable
{
	private const string SampleJson = """
		{
			"runId": "5f0c1a2b-1111-2222-3333-444455556666",
			"module": "Indexes",
			"requestedServer": "SQL01",
			"startedAtUtc": "2026-11-10T08:00:00.000Z",
			"finishedAtUtc": "2026-11-10T08:05:30.000Z",
			"status": "Partial",
			"exitCode": 1,
			"llm": { "provider": "local", "model": "qwen", "totalInputTokens": 1000, "totalOutputTokens": 200, "totalCostUsd": "0.25", "notes": [ { "module": "Indexes", "text": "нотатка" } ] },
			"warnings": [ "рядок", { "message": "об'єкт" } ],
			"dataPeriods": [ { "server": "SQL01", "database": null, "uptimeDays": 3.5, "isSufficient": false, "minRequiredDays": 14, "warnings": [] } ],
			"recommendations": [
				{
					"action": "DropIndex",
					"module": "Indexes",
					"source": "Rules",
					"target": { "server": "SQL01", "database": "Sales", "schema": "dbo", "table": "Orders", "index": "IX_Status" },
					"title": "Видалити IX_Status",
					"risk": { "level": "Medium", "description": "опис" },
					"impact": { "estimatedSizeMb": "120.5", "affectedQueryIds": [ 1002 ] },
					"executeScript": "-- DROP INDEX [IX_Status] ON [dbo].[Orders];",
					"rollbackScript": "CREATE INDEX [IX_Status] ON [dbo].[Orders] ([Status]);",
					"validation": { "status": "Passed", "checks": [ { "id": "DropAllowed", "status": "Passed", "message": "ok" } ] },
					"dropEligibility": {
						"rulesProfile": "Standard", "requiredConsecutive": 3, "consecutiveCount": 1, "isEligible": false,
						"warning": "бракує 2 підтверджень",
						"conditions": [ { "id": "ConsecutiveSeries", "met": false, "details": "1 з 3" }, { "id": "NotPrimaryKey", "met": true, "details": "" }, { "id": "NotReplicated", "met": null, "details": "не зібрано" } ]
					},
					"warnings": [ "Період даних короткий" ]
				}
			],
			"findings": [ { "ruleId": "UnusedIndex", "severity": "High", "target": { "database": "Sales", "schema": "dbo", "table": "Orders", "index": "IX_Status" }, "message": "m", "suggestedAction": "DropIndex" } ],
			"errors": [ { "stage": "LLM", "code": "LlmFailed", "exitCode": 5, "message": "помилка" } ]
		}
		""";

	private readonly string _root = Path.Combine(Path.GetTempPath(), "IndexAdvisor.Gui.Tests", Guid.NewGuid().ToString("N"));

	public RunResultStoreTests()
	{
		Directory.CreateDirectory(_root);
	}

	public void Dispose()
	{
		try
		{
			Directory.Delete(_root, recursive: true);
		}
		catch (IOException)
		{
		}
	}

	[Fact]
	public void Parse_ReadsNestedObjectsAndNumbersAsStrings()
	{
		var run = RunResultStore.Parse(SampleJson);

		Assert.Equal("SQL01", run.RequestedServer);
		Assert.Equal(0.25, run.Llm!.TotalCostUsd);
		var recommendation = Assert.Single(run.Recommendations!);
		Assert.Equal(120.5, recommendation.Impact!.EstimatedSizeMb);
		Assert.Equal(3, recommendation.DropEligibility!.Conditions!.Count);
		Assert.Null(recommendation.DropEligibility.Conditions[2].Met);
	}

	[Fact]
	public void ElementText_ReadsStringsAndMessageObjects()
	{
		var run = RunResultStore.Parse(SampleJson);

		Assert.Equal(["рядок", "об'єкт"], run.Warnings!.Select(RunResultStore.ElementText));
	}

	[Fact]
	public void Scan_FindsResultsInNestedFoldersAndSkipsForeignJson()
	{
		var runDirectory = Directory.CreateDirectory(Path.Combine(_root, "live", "out", "20261110_080000_SQL01_5f0c1a2b"));
		File.WriteAllText(Path.Combine(runDirectory.FullName, "result.json"), SampleJson);
		var broken = Directory.CreateDirectory(Path.Combine(_root, "broken"));
		File.WriteAllText(Path.Combine(broken.FullName, "result.json"), "{ not json");
		var foreign = Directory.CreateDirectory(Path.Combine(_root, "foreign"));
		File.WriteAllText(Path.Combine(foreign.FullName, "result.json"), "{ \"name\": \"other\" }");

		var entries = RunResultStore.Scan(_root);

		var entry = Assert.Single(entries);
		Assert.Equal("SQL01", entry.Server);
		Assert.Equal(1, entry.RecommendationCount);
		Assert.Equal(0.25, entry.CostUsd);
		Assert.Equal(runDirectory.FullName, entry.Directory);
	}

	[Fact]
	public void Scan_MissingFolder_ReturnsEmpty()
	{
		Assert.Empty(RunResultStore.Scan(Path.Combine(_root, "missing")));
	}
}
