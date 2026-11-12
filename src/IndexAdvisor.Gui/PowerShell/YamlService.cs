using System.Management.Automation;
using System.Text.Json.Nodes;
using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.PowerShell;

public sealed record YamlParseResult(JsonObject? Values, string? Error);

/// <summary>
/// Розбір YAML тим самим powershell-yaml, що й модуль (ConvertFrom-Yaml), у вбудованому PowerShell.
/// Окремої бібліотеки YAML у процесі немає: дві версії YamlDotNet в одному процесі конфліктували б.
/// </summary>
public sealed class YamlService
{
	private const string ParseScript = """
		param([string]$Text)
		# Будь-яка помилка розбору — виняток: порожній результат замість помилки стер би конфігурацію з форми.
		$ErrorActionPreference = 'Stop'
		Import-Module -Name powershell-yaml
		if ([string]::IsNullOrWhiteSpace($Text)) {
			return '{}'
		}
		$value = ConvertFrom-Yaml -Yaml $Text -Ordered
		if ($null -eq $value) {
			return '{}'
		}
		ConvertTo-Json -InputObject $value -Depth 60 -Compress
		""";

	private readonly PowerShellRunner _runner = new(new SilentInteraction());

	public async Task<YamlParseResult> ParseAsync(string text, CancellationToken cancellationToken = default)
	{
		try
		{
			var output = await _runner.InvokeAsync(ParseScript, new Dictionary<string, object?> { ["Text"] = text }, null, cancellationToken);
			var json = output.LastOrDefault()?.BaseObject as string ?? "{}";
			return JsonNode.Parse(json) is JsonObject values
				? new YamlParseResult(values, null)
				: new YamlParseResult(null, "Корінь YAML має бути мапою ключів (version: 1, servers: ...).");
		}
		catch (RuntimeException ex)
		{
			return new YamlParseResult(null, ex.Message);
		}
		catch (System.Text.Json.JsonException ex)
		{
			return new YamlParseResult(null, ex.Message);
		}
	}

	/// <summary>Вивід розбору не потрібен; запитів введення тут не буває.</summary>
	private sealed class SilentInteraction : IHostInteraction
	{
		public void Write(HostLine line)
		{
		}

		public void Progress(ProgressRecord record)
		{
		}

		public PromptResponse? Prompt(PromptRequest request) => null;

		public int? PromptForChoice(string caption, string message, string context, IReadOnlyList<PromptChoice> choices, int defaultChoice) => null;
	}
}
