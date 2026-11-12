using System.Management.Automation;
using System.Text.Json;
using System.Text.Json.Serialization;
using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.PowerShell;

public sealed record ConfigError(int? Line, int? Column, string? Path, string Message)
{
	public string Location => Line is null ? Path ?? string.Empty : $"{Line}:{Column ?? 1}";
}

/// <summary>Підсумок перевіреної конфігурації (Get-IaConfig) для підказок у формі запуску.</summary>
public sealed class ConfigSummary
{
	public string[] Servers { get; init; } = [];
	public string? Module { get; init; }
	public string[] Databases { get; init; } = [];
	public string[] ExcludeDatabases { get; init; } = [];
	public string? Provider { get; init; }
	public string[] Providers { get; init; } = [];
	public string? Model { get; init; }
	public string? CrossCheckProvider { get; init; }
	public int? AnalysisWindowDays { get; init; }
	public string[] Datasets { get; init; } = [];
	public string? OutputPath { get; init; }
	public string? ArchivePath { get; init; }
	public string[] Formats { get; init; } = [];
	public string? Login { get; init; }
	public string? Authentication { get; init; }
	public bool RepositoryEnabled { get; init; }
	public string? Repository { get; init; }
	public bool ArchiveEnabled { get; init; }
	public bool MaskNames { get; init; }
	public bool LocalOnly { get; init; }
	public bool AutoApprove { get; init; }
	public bool NonInteractive { get; init; }
	public bool Maintenance { get; init; }
}

public sealed class ConfigCheckResult
{
	public bool IsValid { get; init; }
	public ConfigError[] Errors { get; init; } = [];
	public ConfigSummary? Summary { get; init; }
}

/// <summary>Підсумок запуску: код повернення, тека результатів і RunResult кожного сервера (JSON).</summary>
public sealed record RunOutcome(int ExitCode, string? OutputRoot, IReadOnlyList<string> ResultJson);

/// <summary>Операції модуля IndexAdvisor, виконані через PowerShellRunner.</summary>
public sealed class IndexAdvisorService
{
	internal static readonly JsonSerializerOptions JsonOptions = new()
	{
		PropertyNameCaseInsensitive = true,
		NumberHandling = JsonNumberHandling.AllowReadingFromString,
	};

	private readonly PowerShellRunner _runner;
	private readonly Func<string> _modulePath;

	public IndexAdvisorService(PowerShellRunner runner, Func<string> modulePath)
	{
		_runner = runner;
		_modulePath = modulePath;
	}

	public async Task<ConfigCheckResult> TestConfigAsync(string path, CancellationToken cancellationToken = default)
	{
		var output = await _runner.InvokeAsync(
			HostedScripts.TestConfig,
			new Dictionary<string, object?> { ["ModulePath"] = _modulePath(), ["Path"] = path },
			Path.GetDirectoryName(path),
			cancellationToken);
		var json = output.LastOrDefault()?.BaseObject as string
			?? throw new InvalidOperationException("Test-IaConfig не повернув результату.");
		return ParseConfigCheck(json);
	}

	internal static ConfigCheckResult ParseConfigCheck(string json)
		=> JsonSerializer.Deserialize<ConfigCheckResult>(json, JsonOptions)
			?? throw new InvalidOperationException("Порожня відповідь Test-IaConfig.");

	public Task NewConfigTemplateAsync(string path, CancellationToken cancellationToken = default)
		=> _runner.InvokeAsync(
			HostedScripts.NewTemplate,
			new Dictionary<string, object?> { ["ModulePath"] = _modulePath(), ["Path"] = path },
			Path.GetDirectoryName(path),
			cancellationToken);

	/// <summary>
	/// Invoke-IndexAdvisor з параметрами форми. Робоча тека — тека конфігурації (відносні шляхи YAML),
	/// без конфігурації — <paramref name="fallbackDirectory"/>.
	/// </summary>
	public async Task<RunOutcome> RunAsync(RunOptions options, string? fallbackDirectory, CancellationToken cancellationToken)
	{
		var arguments = CommandLineBuilder.ToHashtable(CommandLineBuilder.BuildParameters(options), options.Verbose);
		var workingDirectory = !string.IsNullOrWhiteSpace(options.ConfigPath)
			? Path.GetDirectoryName(Path.GetFullPath(options.ConfigPath))
			: fallbackDirectory;
		var output = await _runner.InvokeAsync(
			HostedScripts.Run,
			new Dictionary<string, object?> { ["ModulePath"] = _modulePath(), ["Arguments"] = arguments },
			workingDirectory,
			cancellationToken);
		var summary = output.LastOrDefault()
			?? throw new InvalidOperationException("Invoke-IndexAdvisor не повернув результату.");
		var exitCode = Convert.ToInt32(summary.Properties["ExitCode"]?.Value ?? 9);
		var outputRoot = summary.Properties["OutputRoot"]?.Value as string;
		var results = summary.Properties["Results"]?.Value switch
		{
			string[] items => items,
			object[] items => items.Select(item => item?.ToString() ?? string.Empty).ToArray(),
			PSObject { BaseObject: string[] items } => items,
			_ => [],
		};
		return new RunOutcome(exitCode, outputRoot, results);
	}
}
