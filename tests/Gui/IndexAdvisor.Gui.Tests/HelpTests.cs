using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.Help;
using IndexAdvisor.Gui.PowerShell;
using IndexAdvisor.Gui.ViewModels.ConfigForm;

namespace IndexAdvisor.Gui.Tests;

/// <summary>Довідка «?»: текст є для кожного ключа схеми й кожного поля вкладок, факти беруться зі схеми.</summary>
public sealed class HelpTests
{
	private readonly string _modulePath = ModuleLocator.Resolve(null);

	private SchemaNode Schema() => ConfigSchemaLoader.Load(ConfigSchemaLoader.FindSchemaPath(_modulePath)!);

	/// <summary>Шляхи довідки для всіх вузлів схеми: групи, листки, елементи мап і списків через [].</summary>
	private static IEnumerable<string> HelpPaths(SchemaNode node, string path)
	{
		foreach (var child in node.Properties)
		{
			var childPath = string.IsNullOrEmpty(path) ? child.Name : path + "." + child.Name;
			yield return childPath;
			var item = child.Type == SchemaType.Map ? child.Values : child.ItemNode;
			if (item is not null)
			{
				yield return childPath + "[]";
				foreach (var nested in HelpPaths(item, childPath + "[]"))
				{
					yield return nested;
				}
			}
			foreach (var nested in HelpPaths(child, childPath))
			{
				yield return nested;
			}
		}
	}

	private static void AssertNone<T>(IEnumerable<T> items)
	{
		var list = items.ToList();
		Assert.True(list.Count == 0, "Без довідки або зайві: " + string.Join(", ", list));
	}

	[Fact]
	public void EverySchemaKey_HasHelpText_AndNoStaleKeys()
	{
		var paths = HelpPaths(Schema(), string.Empty).ToHashSet(StringComparer.Ordinal);

		AssertNone(paths.Where(path => !HelpTexts.Config.ContainsKey(path)));
		AssertNone(HelpTexts.Config.Keys.Where(key => !paths.Contains(key)));
	}

	[Fact]
	public void EveryRunOption_HasHelpText()
	{
		var properties = typeof(RunOptions).GetProperties()
			.Where(property => property.CanWrite && property.Name != nameof(RunOptions.HtmlTheme))
			.Select(property => property.Name);

		AssertNone(properties.Where(name => !HelpTexts.Run.ContainsKey(name)));
	}

	[Fact]
	public void HelpTopicsInViews_Resolve()
	{
		var views = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(_modulePath)!, "..", "IndexAdvisor.Gui", "Views"));
		Assert.True(Directory.Exists(views), views);
		var texts = new Dictionary<string, IReadOnlyDictionary<string, string>>
		{
			["Run"] = HelpTexts.Run,
			["Tools"] = HelpTexts.Tools,
			["Preferences"] = HelpTexts.Preferences,
		};
		var topics = Directory.EnumerateFiles(views, "*.xaml")
			.SelectMany(file => Regex.Matches(File.ReadAllText(file), "Topic=\"(?<area>\\w+):(?<key>\\w+)\"").Select(match => (Area: match.Groups["area"].Value, Key: match.Groups["key"].Value)))
			.ToList();

		Assert.NotEmpty(topics);
		AssertNone(topics.Where(topic => !texts.TryGetValue(topic.Area, out var dictionary) || !dictionary.ContainsKey(topic.Key)));
	}

	[Fact]
	public void SettingHelp_AddsSchemaFacts()
	{
		var form = new ConfigFormViewModel();
		form.Initialize(Schema());
		form.Load(new JsonObject { ["version"] = 1 });

		var days = form.Find("analysisWindow.days")!.Help;
		Assert.Equal("analysisWindow.days", days.Key);
		Assert.NotNull(days.Text);
		Assert.Contains("Типово: 30.", days.Facts);
		Assert.Contains("Межі: від 1 до 3650.", days.Facts);

		var encrypt = form.Find("connection.encrypt")!.Help;
		Assert.Contains(encrypt.Facts, fact => fact.StartsWith("Можливі значення: Mandatory", StringComparison.Ordinal));

		var item = ((MapSettingVm)form.Find("llm.providers")!).AddPreset(LlmCatalog.Find("openai")!);
		var model = item.Field<TextSettingVm>("model")!.Help;
		Assert.Equal("llm.providers[].model", model.Key);
		Assert.Contains(model.Facts, fact => fact.Contains(LlmCatalog.PricesAsOf, StringComparison.Ordinal));
	}

	[Fact]
	public void RunHelp_ShowsParameter()
	{
		var help = HelpCatalog.ForTopic("Run:AnalysisWindowDays", "Вікно аналізу");

		Assert.Equal("-AnalysisWindowDays", help.Key);
		Assert.Contains("analysisWindow.days", help.Text);
	}
}
