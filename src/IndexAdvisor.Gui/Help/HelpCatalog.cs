using System.Globalization;
using System.Text.RegularExpressions;
using IndexAdvisor.Gui.Core;
using IndexAdvisor.Gui.ViewModels.ConfigForm;

namespace IndexAdvisor.Gui.Help;

/// <summary>Вміст довідки «?»: заголовок, ключ (YAML або параметр команди), пояснення й факти (типово, межі, відповідники).</summary>
public sealed record HelpInfo(string Title, string? Key, string? Text, IReadOnlyList<string> Facts)
{
	public bool HasKey => !string.IsNullOrWhiteSpace(Key);

	public bool HasText => !string.IsNullOrWhiteSpace(Text);

	public bool HasFacts => Facts.Count > 0;

	/// <summary>Для екранного диктора: усе одним рядком.</summary>
	public string AccessibleText => string.Join(" ", new[] { Title + ".", Text }.Concat(Facts).Where(part => !string.IsNullOrWhiteSpace(part)));

	public override string ToString() => AccessibleText;
}

/// <summary>
/// Довідка для параметрів: тексти з HelpTexts плюс факти, які GUI бере зі схеми модуля (типове значення, межі,
/// допустимі значення, посилання на секрет) і з відповідності параметрів запуску ключам YAML.
/// </summary>
public static partial class HelpCatalog
{
	/// <summary>Параметри форми запуску: властивість RunOptions → параметр Invoke-IndexAdvisor і ключ YAML, який він перевизначає.</summary>
	private static readonly (string Key, string Parameter, string? ConfigKey)[] RunParameters =
	[
		("ConfigPath", "-Config", null),
		("Servers", "-Server", "servers"),
		("Databases", "-Database", "scope.databases.include"),
		("ExcludeDatabases", "-ExcludeDatabase", "scope.databases.exclude"),
		("Schemas", "-Schema", "scope.schemas.include"),
		("ExcludeSchemas", "-ExcludeSchema", "scope.schemas.exclude"),
		("Tables", "-Table", "scope.tables.include"),
		("ExcludeTables", "-ExcludeTable", "scope.tables.exclude"),
		("Module", "-Module", "module"),
		("Provider", "-Provider", "llm.provider"),
		("Model", "-Model", "llm.model"),
		("CrossCheckProvider", "-CrossCheckProvider", "llm.crossCheckProvider"),
		("AnalysisWindowDays", "-AnalysisWindowDays", "analysisWindow.days"),
		("Datasets", "-Dataset", "collector.datasets"),
		("OutputPath", "-OutputPath", "output.path"),
		("Formats", "-Format", "output.formats"),
		("FromArchive", "-FromArchive", null),
		("NoRepository", "-NoRepository", "repository.enabled"),
		("NoArchive", "-NoArchive", "archive.enabled"),
		("NonInteractive", "-NonInteractive", "run.nonInteractive"),
		("AutoApprove", "-AutoApprove", "llm.autoApproveToolRequests"),
		("LocalOnly", "-LocalOnly", "llm.localOnly"),
		("MaskNames", "-MaskNames", "llm.maskNames"),
		("Maintenance", "-Maintenance", "maintenance.enabled"),
		("UnsafeDisableSelectCheck", "-UnsafeDisableSelectCheck", "unsafe.disableSelectCheck"),
		("UnsafeDisableMaxdop", "-UnsafeDisableMaxdop", "unsafe.disableMaxdop"),
		("UnsafeDisableTimeouts", "-UnsafeDisableTimeouts", "unsafe.disableTimeouts"),
		("UnsafeAllowFreeQuery", "-UnsafeAllowFreeQuery", "unsafe.allowFreeQuery"),
		("AllowNonStandardLogin", "-AllowNonStandardLogin", "unsafe.allowNonStandardLogin"),
		("Verbose", "-Verbose", null),
	];

	/// <summary>Поля вкладки «Інструменти» → команда й параметр.</summary>
	private static readonly Dictionary<string, string> ToolParameters = new(StringComparer.Ordinal)
	{
		["MaintenanceArchive"] = "New-IaIndexMaintenance -FromArchive",
		["MaintenanceConfig"] = "New-IaIndexMaintenance -Config",
		["MaintenanceResult"] = "New-IaIndexMaintenance -ResultPath",
		["MaintenanceOutput"] = "New-IaIndexMaintenance -OutputPath",
		["LoginServers"] = "Install-IaServiceLogin -SqlInstance",
		["LoginMode"] = "Install-IaServiceLogin -Mode",
		["LoginDatabases"] = "Install-IaServiceLogin -Database",
		["LoginName"] = "Install-IaServiceLogin -LoginName",
		["SecretName"] = "Install-IaServiceLogin -SecretName",
		["Vault"] = "Install-IaServiceLogin -Vault",
		["WindowsLogin"] = "Install-IaServiceLogin -WindowsLogin",
		["AskCredential"] = "Install-IaServiceLogin -SqlCredential",
	};

	[GeneratedRegex(@"\[[^\]]*\]")]
	private static partial Regex ItemIndexPattern();

	/// <summary>llm.providers[anthropic].model → llm.providers[].model.</summary>
	public static string NormalizePath(string path) => ItemIndexPattern().Replace(path, "[]");

	/// <summary>Довідка для поля форми налаштувань.</summary>
	public static HelpInfo ForSetting(SettingNodeVm setting)
	{
		var node = setting.Node;
		var key = NormalizePath(setting.Path);
		var text = Lookup(HelpTexts.Config, key);
		if (text is null && !string.IsNullOrWhiteSpace(node.Description) && setting.Label != node.Description)
		{
			text = node.Description;
		}
		var facts = new List<string>();
		if (setting is ScalarSettingVm)
		{
			facts.Add(node.Required && node.Default is null
				? "Обов'язковий параметр."
				: "Типово: " + ScalarSettingVm.FormatDefault(node.Default) + ".");
		}
		if (node.Enum is { Count: > 0 } values)
		{
			facts.Add((setting is EnumListSettingVm ? "Можна вибрати кілька: " : "Можливі значення: ") + string.Join(", ", values) + ".");
		}
		if (node.Min is not null || node.Max is not null)
		{
			facts.Add($"Межі: від {Number(node.Min)} до {Number(node.Max)}.");
		}
		if (node.Secret && text is null)
		{
			facts.Add("Лише посилання: secret:Сховище/Секрет, secret:Секрет або env:ЗМІННА — не сам пароль чи ключ.");
		}
		if (setting is StringListSettingVm)
		{
			facts.Add("Кілька значень — через кому.");
		}
		if (key == "llm.providers")
		{
			facts.Add("Готові провайдери («Додати готовий…»): " + string.Join(", ", LlmCatalog.Providers.Select(preset => preset.Title)) + ".");
		}
		if (key is "llm.providers[].model" or "llm.model")
		{
			facts.Add($"Список моделей залежить від типу й endpoint провайдера; ціни моделей зі списку перевірено: {LlmCatalog.PricesAsOf}. Можна ввести будь-яку іншу модель.");
		}
		if (key is "llm.provider" or "llm.crossCheckProvider")
		{
			facts.Add("У списку — додані провайдери й готові з каталогу; готовий провайдер додається до llm.providers автоматично.");
		}
		// Тексти довідки вже називають параметр запуску, що перевизначає ключ; без тексту — додаємо самі.
		if (text is null && RunParameters.FirstOrDefault(parameter => parameter.ConfigKey == key) is { Parameter: not null } run)
		{
			facts.Add($"На один запуск перевизначається параметром {run.Parameter} (вкладка «Запуск»).");
		}
		return new HelpInfo(setting.Label, key, text, facts);
	}

	/// <summary>Довідка для поля вкладки «Запуск» (ключ — властивість RunOptions).</summary>
	public static HelpInfo ForRun(string key, string title)
	{
		var parameter = RunParameters.FirstOrDefault(item => item.Key == key);
		var text = Lookup(HelpTexts.Run, key);
		// Тексти довідки самі кажуть, який ключ YAML перевизначає поле; без тексту — підказка з таблиці.
		IReadOnlyList<string> facts = text is null && parameter.ConfigKey is not null
			? [$"Ключ YAML: {parameter.ConfigKey}. Порожнє поле чи перемикач «як у конфігурації» — значення з файлу."]
			: [];
		return new HelpInfo(title, parameter.Parameter, text, facts);
	}

	/// <summary>Довідка для поля вкладки «Інструменти».</summary>
	public static HelpInfo ForTool(string key, string title) =>
		new(title, ToolParameters.GetValueOrDefault(key), Lookup(HelpTexts.Tools, key), []);

	/// <summary>Довідка для налаштування програми (вкладка «Параметри»).</summary>
	public static HelpInfo ForPreference(string key, string title) =>
		new(title, null, Lookup(HelpTexts.Preferences, key), []);

	/// <summary>Тема «Розділ:Ключ» з XAML: Run:Servers, Tools:LoginMode, Preferences:Theme.</summary>
	public static HelpInfo ForTopic(string topic, string? title)
	{
		var separator = topic.IndexOf(':');
		var area = separator > 0 ? topic[..separator] : string.Empty;
		var key = separator > 0 ? topic[(separator + 1)..] : topic;
		var caption = string.IsNullOrWhiteSpace(title) ? key : title;
		return area switch
		{
			"Run" => ForRun(key, caption),
			"Tools" => ForTool(key, caption),
			"Preferences" => ForPreference(key, caption),
			_ => new HelpInfo(caption, null, Lookup(HelpTexts.Config, key), []),
		};
	}

	private static string? Lookup(IReadOnlyDictionary<string, string> texts, string key) =>
		texts.TryGetValue(key, out var text) && !string.IsNullOrWhiteSpace(text) ? text : null;

	private static string Number(double? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "—";
}
