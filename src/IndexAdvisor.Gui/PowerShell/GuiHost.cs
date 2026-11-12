using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Reflection;

namespace IndexAdvisor.Gui.PowerShell;

/// <summary>Хост PowerShell для GUI: вивід — у журнал, Read-Host і запити паролів — у діалоги.</summary>
internal sealed class GuiHost : PSHost
{
	private readonly GuiHostUserInterface _ui;

	public GuiHost(IHostInteraction interaction, Action? stopRequested = null)
	{
		_ui = new GuiHostUserInterface(interaction, stopRequested);
	}

	public override string Name => "IndexAdvisor.Gui";

	public override Version Version { get; } = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 1);

	public override Guid InstanceId { get; } = Guid.NewGuid();

	public override PSHostUserInterface UI => _ui;

	internal GuiHostUserInterface UserInterface => _ui;

	public override CultureInfo CurrentCulture => CultureInfo.CurrentCulture;

	public override CultureInfo CurrentUICulture => CultureInfo.CurrentUICulture;

	public int? ExitCode { get; private set; }

	public override void SetShouldExit(int exitCode) => ExitCode = exitCode;

	public override void EnterNestedPrompt() => throw new NotSupportedException("Вкладені сесії не підтримуються.");

	public override void ExitNestedPrompt() => throw new NotSupportedException("Вкладені сесії не підтримуються.");

	public override void NotifyBeginApplication()
	{
	}

	public override void NotifyEndApplication()
	{
	}
}

/// <summary>Мінімальний RawUI: широкий буфер для форматування, без читання клавіш.</summary>
internal sealed class GuiRawUserInterface : PSHostRawUserInterface
{
	private Size _bufferSize = new(200, 9999);
	private Size _windowSize = new(200, 50);

	public override ConsoleColor ForegroundColor { get; set; } = ConsoleColor.Gray;

	public override ConsoleColor BackgroundColor { get; set; } = ConsoleColor.Black;

	public override Size BufferSize
	{
		get => _bufferSize;
		set => _bufferSize = value;
	}

	public override Coordinates CursorPosition { get; set; }

	public override int CursorSize { get; set; } = 25;

	public override bool KeyAvailable => false;

	public override Size MaxPhysicalWindowSize => new(200, 100);

	public override Size MaxWindowSize => new(200, 100);

	public override Coordinates WindowPosition { get; set; }

	public override Size WindowSize
	{
		get => _windowSize;
		set => _windowSize = value;
	}

	public override string WindowTitle { get; set; } = "IndexAdvisor";

	public override void FlushInputBuffer()
	{
	}

	public override BufferCell[,] GetBufferContents(Rectangle rectangle)
		=> throw new NotSupportedException("Читання буфера консолі не підтримується.");

	public override KeyInfo ReadKey(ReadKeyOptions options)
		=> throw new NotSupportedException("Читання клавіш не підтримується: використовуйте Read-Host.");

	public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill)
	{
	}

	public override void SetBufferContents(Coordinates origin, BufferCell[,] contents)
	{
	}

	public override void SetBufferContents(Rectangle rectangle, BufferCell fill)
	{
	}
}
