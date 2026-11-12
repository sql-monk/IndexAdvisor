using System.Collections.Concurrent;
using System.Management.Automation;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.PowerShell;

namespace IndexAdvisor.Gui.Tests;

/// <summary>Записує вивід хоста й відповідає на запити заготовленими відповідями.</summary>
internal sealed class FakeInteraction : IHostInteraction
{
	private readonly Queue<string?> _answers;

	public FakeInteraction(params string?[] answers)
	{
		_answers = new Queue<string?>(answers);
	}

	public ConcurrentQueue<HostLine> Lines { get; } = new();

	public List<PromptRequest> Prompts { get; } = [];

	public void Write(HostLine line) => Lines.Enqueue(line);

	public void Progress(ProgressRecord record)
	{
	}

	public PromptResponse? Prompt(PromptRequest request)
	{
		Prompts.Add(request);
		var answer = _answers.Count > 0 ? _answers.Dequeue() : string.Empty;
		return answer is null ? null : new PromptResponse(answer);
	}

	public int? PromptForChoice(string caption, string message, string context, IReadOnlyList<PromptChoice> choices, int defaultChoice) => defaultChoice;

	public string[] Texts(HostLineKind kind) => Lines.Where(line => line.Kind == kind).Select(line => line.Text).ToArray();
}

public class GuiHostTests
{
	private static Task<System.Collections.ObjectModel.Collection<PSObject>> Run(FakeInteraction interaction, string script, CancellationToken cancellationToken = default)
		=> new PowerShellRunner(interaction).InvokeAsync(script, new Dictionary<string, object?>(), null, cancellationToken);

	[Fact]
	public async Task WriteHost_PartialWritesBecomeWholeLines()
	{
		var interaction = new FakeInteraction();

		await Run(interaction, "Write-Host 'перша ' -NoNewline; Write-Host 'частина'; Write-Host \"два`nрядки\"");

		Assert.Equal(["перша частина", "два", "рядки"], interaction.Texts(HostLineKind.Host));
	}

	[Fact]
	public async Task Streams_WarningErrorAndColorAreSeparated()
	{
		var interaction = new FakeInteraction();

		await Run(interaction, "Write-Warning 'увага'; Write-Error 'збій' -ErrorId IaTestError; Write-Host 'червоний' -ForegroundColor Red");

		Assert.Equal(["увага"], interaction.Texts(HostLineKind.Warning));
		Assert.Equal(["збій [IaTestError]"], interaction.Texts(HostLineKind.Error));
		Assert.Equal(ConsoleColor.Red, interaction.Lines.Single(line => line.Text == "червоний").Color);
	}

	[Fact]
	public async Task ReadHost_PromptCarriesLabelAndContextFromLastHeader()
	{
		var interaction = new FakeInteraction("В");

		var output = await Run(interaction, """
			Write-Host 'стара історія'
			Write-Host ''
			Write-Host '=== Модель просить додаткові дані ==='
			Write-Host 'Інструмент: index_usage_stats'
			Read-Host -Prompt 'Виконати дозапит? [П]ідтвердити / [З]мінити / [В]ідхилити'
			""");

		Assert.Equal("В", output.Single().BaseObject);
		var prompt = Assert.Single(interaction.Prompts);
		Assert.Equal("Виконати дозапит? [П]ідтвердити / [З]мінити / [В]ідхилити", prompt.Label);
		Assert.StartsWith("=== Модель просить додаткові дані ===", prompt.Context);
		Assert.Contains("index_usage_stats", prompt.Context);
		Assert.DoesNotContain("стара історія", prompt.Context);
		Assert.Contains(interaction.Lines, line => line.Kind == HostLineKind.Prompt && line.Text.EndsWith(": В"));
	}

	[Fact]
	public async Task Prompt_NullAnswerStopsTheRun()
	{
		var interaction = new FakeInteraction([null]);

		await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Run(interaction, "Read-Host -Prompt 'Питання'; 'не дійшло'"));
	}

	[Fact]
	public async Task Cancellation_StopsLongPipeline()
	{
		using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));

		await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Run(new FakeInteraction(), "Start-Sleep -Seconds 60", cancellation.Token));
	}

	[Fact]
	public async Task WorkingDirectory_IsPowerShellLocation()
	{
		var directory = Path.GetTempPath().TrimEnd('\\');

		var output = await new PowerShellRunner(new FakeInteraction())
			.InvokeAsync("(Get-Location).ProviderPath", new Dictionary<string, object?>(), directory, CancellationToken.None);

		Assert.Equal(directory, ((string)output.Single().BaseObject).TrimEnd('\\'), ignoreCase: true);
	}
}
