using System.Windows.Controls;
using System.Windows.Input;
using System.Xml;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Highlighting;
using ICSharpCode.AvalonEdit.Highlighting.Xshd;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels;

namespace IndexAdvisor.Gui.Views;

public partial class ConfigView : UserControl
{
	private static readonly Lazy<IHighlightingDefinition?> YamlHighlighting = new(LoadYamlHighlighting);

	private ConfigEditorViewModel? _viewModel;

	public ConfigView()
	{
		InitializeComponent();
		Editor.SyntaxHighlighting = YamlHighlighting.Value;
		Editor.Options.ConvertTabsToSpaces = true;
		Editor.Options.IndentationSize = 2;
		Editor.Options.HighlightCurrentLine = true;
		DataContextChanged += (_, _) => Attach(DataContext as ConfigEditorViewModel);
	}

	private void Attach(ConfigEditorViewModel? viewModel)
	{
		if (_viewModel is not null)
		{
			_viewModel.GoToLineRequested -= OnGoToLine;
		}
		_viewModel = viewModel;
		if (_viewModel is not null)
		{
			_viewModel.GoToLineRequested += OnGoToLine;
		}
	}

	private void OnGoToLine(object? sender, (int Line, int Column) position)
	{
		if (Editor.Document is null || Editor.Document.LineCount == 0)
		{
			return;
		}
		var line = Math.Clamp(position.Line, 1, Editor.Document.LineCount);
		var column = Math.Max(1, position.Column);
		Editor.TextArea.Caret.Location = new TextLocation(line, column);
		Editor.ScrollTo(line, column);
		var documentLine = Editor.Document.GetLineByNumber(line);
		Editor.Select(documentLine.Offset, documentLine.Length);
		Editor.Focus();
	}

	private void OnErrorDoubleClick(object sender, MouseButtonEventArgs e)
	{
		if (ErrorList.SelectedItem is ConfigError error && _viewModel is not null)
		{
			_viewModel.GoToErrorCommand.Execute(error);
		}
	}

	private static IHighlightingDefinition? LoadYamlHighlighting()
	{
		using var stream = typeof(ConfigView).Assembly.GetManifestResourceStream("IndexAdvisor.Gui.Views.Yaml.xshd");
		if (stream is null)
		{
			return null;
		}
		using var reader = XmlReader.Create(stream);
		return HighlightingLoader.Load(reader, HighlightingManager.Instance);
	}
}
