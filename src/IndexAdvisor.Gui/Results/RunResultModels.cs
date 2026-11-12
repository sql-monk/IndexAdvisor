using System.Text.Json;

namespace IndexAdvisor.Gui.Results;

// Моделі RunResult (CONTRACTS.md 5.9, contracts/recommendation.schema.json). Усі поля необов'язкові:
// формат читається поблажливо, щоб старіші й неповні result.json теж відкривалися.

public sealed class RunResultDto
{
	public string? RunId { get; set; }
	public string? Module { get; set; }
	public string? RequestedServer { get; set; }
	public string? StartedAtUtc { get; set; }
	public string? FinishedAtUtc { get; set; }
	public string? StartedBy { get; set; }
	public string? HostName { get; set; }
	public string? ToolVersion { get; set; }
	public string? FromArchive { get; set; }
	public string? ArchivePath { get; set; }
	public AnalysisWindowDto? AnalysisWindow { get; set; }
	public TopologyDto? Topology { get; set; }
	public DatasetsDto? Datasets { get; set; }
	public List<DataPeriodDto>? DataPeriods { get; set; }
	public MaskingDto? Masking { get; set; }
	public List<string>? UnsafeFlags { get; set; }
	public LoginCheckDto? LoginCheck { get; set; }
	public LlmRunDto? Llm { get; set; }
	public List<ToolRequestDto>? ToolRequests { get; set; }
	public List<FindingDto>? Findings { get; set; }
	public List<RecommendationDto>? Recommendations { get; set; }
	public List<JsonElement>? Warnings { get; set; }
	public List<RunErrorDto>? Errors { get; set; }
	public JsonElement? Maintenance { get; set; }
	public string? Status { get; set; }
	public int? ExitCode { get; set; }
}

public sealed class AnalysisWindowDto
{
	public string? FromUtc { get; set; }
	public string? ToUtc { get; set; }
	public string? Mode { get; set; }
	public string? Reason { get; set; }
}

public sealed class TopologyDto
{
	public string? Type { get; set; }
	public string? ServerName { get; set; }
}

public sealed class DatasetsDto
{
	public List<string>? Enabled { get; set; }
	public List<string>? Disabled { get; set; }
	public List<JsonElement>? Warnings { get; set; }
}

public sealed class DataPeriodDto
{
	public string? Server { get; set; }
	public string? Database { get; set; }
	public string? SqlserverStartTimeUtc { get; set; }
	public string? LastFailoverUtc { get; set; }
	public string? StatsFromUtc { get; set; }
	public string? StatsToUtc { get; set; }
	public double? UptimeDays { get; set; }
	public double? QueryStoreDays { get; set; }
	public int? MinRequiredDays { get; set; }
	public bool? IsSufficient { get; set; }
	public List<JsonElement>? Warnings { get; set; }
}

public sealed class MaskingDto
{
	public bool? NamesMasked { get; set; }
	public bool? LiteralsMasked { get; set; }
}

public sealed class LoginCheckDto
{
	public string? Login { get; set; }
	public string? Authentication { get; set; }
	public bool? IsStandard { get; set; }
	public List<JsonElement>? Warnings { get; set; }
}

public sealed class LlmRunDto
{
	public string? Provider { get; set; }
	public string? Model { get; set; }
	public string? CrossCheckProvider { get; set; }
	public List<LlmNoteDto>? Notes { get; set; }
	public List<LlmCallDto>? Calls { get; set; }
	public long? TotalInputTokens { get; set; }
	public long? TotalOutputTokens { get; set; }
	public double? TotalCostUsd { get; set; }
}

public sealed class LlmNoteDto
{
	public string? Module { get; set; }
	public string? Text { get; set; }
}

public sealed class LlmCallDto
{
	public string? Provider { get; set; }
	public string? Model { get; set; }
	public string? Purpose { get; set; }
	public long? InputTokens { get; set; }
	public long? OutputTokens { get; set; }
	public double? CostUsd { get; set; }
	public long? DurationMs { get; set; }
	public bool? Success { get; set; }
}

public sealed class ToolRequestDto
{
	public string? Tool { get; set; }
	public string? Server { get; set; }
	public string? Database { get; set; }
	public JsonElement? Arguments { get; set; }
	public string? Reason { get; set; }
	public string? Decision { get; set; }
	public string? DecisionReason { get; set; }
	public ToolResponseDto? Response { get; set; }
	public string? ExecutedAtUtc { get; set; }
}

public sealed class ToolResponseDto
{
	public bool? Success { get; set; }
	public long? RowCount { get; set; }
	public bool? Truncated { get; set; }
	public long? DurationMs { get; set; }
	public JsonElement? Error { get; set; }
}

public sealed class TargetDto
{
	public string? Server { get; set; }
	public string? Database { get; set; }
	public string? Schema { get; set; }
	public string? Table { get; set; }
	public string? Index { get; set; }
	public string? ObjectKey { get; set; }
}

public sealed class FindingDto
{
	public string? RuleId { get; set; }
	public string? Severity { get; set; }
	public TargetDto? Target { get; set; }
	public List<JsonElement>? RelatedIndexes { get; set; }
	public string? Message { get; set; }
	public string? SuggestedAction { get; set; }
}

public sealed class RecommendationDto
{
	public string? RecommendationId { get; set; }
	public string? Module { get; set; }
	public string? Action { get; set; }
	public string? Source { get; set; }
	public TargetDto? Target { get; set; }
	public string? Title { get; set; }
	public string? Rationale { get; set; }
	public RiskDto? Risk { get; set; }
	public ImpactDto? Impact { get; set; }
	public string? ExecuteScript { get; set; }
	public string? RollbackScript { get; set; }
	public List<JsonElement>? ReplacesIndexes { get; set; }
	public JsonElement? Partitioning { get; set; }
	public string? Confidence { get; set; }
	public DataPeriodDto? DataPeriod { get; set; }
	public DropEligibilityDto? DropEligibility { get; set; }
	public ValidationDto? Validation { get; set; }
	public CrossCheckDto? CrossCheck { get; set; }
	public List<JsonElement>? Warnings { get; set; }
}

public sealed class RiskDto
{
	public string? Level { get; set; }
	public string? Description { get; set; }
}

public sealed class ImpactDto
{
	public double? EstimatedSizeMb { get; set; }
	public double? EstimatedBuildMinutes { get; set; }
	public double? TableWritesPerDay { get; set; }
	public List<JsonElement>? AffectedQueryIds { get; set; }
	public string? Notes { get; set; }
}

public sealed class ValidationDto
{
	public string? Status { get; set; }
	public List<ValidationCheckDto>? Checks { get; set; }
}

public sealed class ValidationCheckDto
{
	public string? Id { get; set; }
	public string? Status { get; set; }
	public string? Message { get; set; }
}

public sealed class DropEligibilityDto
{
	public string? RulesProfile { get; set; }
	public string? RelaxedReason { get; set; }
	public int? RequiredConsecutive { get; set; }
	public int? ConsecutiveCount { get; set; }
	public int? MissingConfirmations { get; set; }
	public List<DropConditionDto>? Conditions { get; set; }
	public bool? IsEligible { get; set; }
	public string? Warning { get; set; }
}

public sealed class DropConditionDto
{
	public string? Id { get; set; }
	public bool? Met { get; set; }
	public string? Details { get; set; }
}

public sealed class CrossCheckDto
{
	public string? Provider { get; set; }
	public string? Model { get; set; }
	public string? Verdict { get; set; }
	public string? Notes { get; set; }
}

public sealed class RunErrorDto
{
	public string? Stage { get; set; }
	public string? Code { get; set; }
	public int? ExitCode { get; set; }
	public string? Message { get; set; }
}
