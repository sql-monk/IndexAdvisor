using System.Collections;
using System.Text;

namespace IndexAdvisor.Gui.Core;

/// <summary>Параметр командлета: значення — string, string[], int або bool (перемикач).</summary>
public sealed record CommandParameter(string Name, object Value);

/// <summary>Перетворює RunOptions на параметри Invoke-IndexAdvisor і на текст командного рядка.</summary>
public static class CommandLineBuilder
{
	private static readonly char[] ListSeparators = [',', ';', '\r', '\n'];

	/// <summary>Рядок «A, B; C» → [A, B, C]: без порожніх і повторів (без урахування регістру).</summary>
	public static string[] SplitList(string? text)
	{
		if (string.IsNullOrWhiteSpace(text))
		{
			return [];
		}
		return text.Split(ListSeparators, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
			.Distinct(StringComparer.OrdinalIgnoreCase)
			.ToArray();
	}

	public static IReadOnlyList<CommandParameter> BuildParameters(RunOptions options)
	{
		var result = new List<CommandParameter>();

		void AddText(string name, string? value)
		{
			if (!string.IsNullOrWhiteSpace(value))
			{
				result.Add(new CommandParameter(name, value.Trim()));
			}
		}

		void AddList(string name, string? text)
		{
			var items = SplitList(text);
			if (items.Length > 0)
			{
				result.Add(new CommandParameter(name, items));
			}
		}

		void AddSwitch(string name, bool? value)
		{
			if (value.HasValue)
			{
				result.Add(new CommandParameter(name, value.Value));
			}
		}

		AddText("Config", options.ConfigPath);
		AddList("Server", options.Servers);
		AddList("Database", options.Databases);
		AddList("ExcludeDatabase", options.ExcludeDatabases);
		AddList("Schema", options.Schemas);
		AddList("ExcludeSchema", options.ExcludeSchemas);
		AddList("Table", options.Tables);
		AddList("ExcludeTable", options.ExcludeTables);
		AddText("Module", options.Module);
		AddText("Provider", options.Provider);
		AddText("Model", options.Model);
		AddText("CrossCheckProvider", options.CrossCheckProvider);
		if (options.AnalysisWindowDays is int days)
		{
			result.Add(new CommandParameter("AnalysisWindowDays", days));
		}
		if (options.Datasets is not null)
		{
			// Обов'язкові набори модуль вмикає завжди; явний перелік із ними виражається й у pwsh -File (порожній масив — ні).
			var datasets = IaConstants.MandatoryDatasets
				.Concat(options.Datasets.Where(name => IaConstants.OptionalDatasets.Contains(name, StringComparer.OrdinalIgnoreCase)))
				.Distinct(StringComparer.OrdinalIgnoreCase)
				.ToArray();
			result.Add(new CommandParameter("Dataset", datasets));
		}
		AddText("OutputPath", options.OutputPath);
		if (options.Formats is { Count: > 0 })
		{
			result.Add(new CommandParameter("Format", options.Formats.Distinct(StringComparer.OrdinalIgnoreCase).ToArray()));
		}
		AddSwitch("NoRepository", options.NoRepository);
		AddSwitch("NoArchive", options.NoArchive);
		AddText("FromArchive", options.FromArchive);
		AddSwitch("NonInteractive", options.NonInteractive);
		AddSwitch("AutoApprove", options.AutoApprove);
		AddSwitch("LocalOnly", options.LocalOnly);
		AddSwitch("MaskNames", options.MaskNames);
		AddSwitch("Maintenance", options.Maintenance);
		AddSwitch("UnsafeDisableSelectCheck", options.UnsafeDisableSelectCheck ? true : null);
		AddSwitch("UnsafeDisableMaxdop", options.UnsafeDisableMaxdop ? true : null);
		AddSwitch("UnsafeDisableTimeouts", options.UnsafeDisableTimeouts ? true : null);
		AddSwitch("UnsafeAllowFreeQuery", options.UnsafeAllowFreeQuery ? true : null);
		AddSwitch("AllowNonStandardLogin", options.AllowNonStandardLogin ? true : null);
		return result;
	}

	/// <summary>Таблиця для splatting у PowerShell (@Arguments).</summary>
	public static Hashtable ToHashtable(IEnumerable<CommandParameter> parameters, bool verbose)
	{
		var table = new Hashtable(StringComparer.OrdinalIgnoreCase);
		foreach (var parameter in parameters)
		{
			table[parameter.Name] = parameter.Value;
		}
		if (verbose)
		{
			table["Verbose"] = true;
		}
		return table;
	}

	/// <summary>Команда для сесії PowerShell: Invoke-IndexAdvisor -Config '...' -Server 'A','B' -MaskNames:$false.</summary>
	public static string FormatPowerShell(RunOptions options, string command = "Invoke-IndexAdvisor")
	{
		var text = new StringBuilder(command);
		foreach (var parameter in BuildParameters(options))
		{
			text.Append(' ').Append(FormatPowerShellParameter(parameter));
		}
		if (options.Verbose)
		{
			text.Append(" -Verbose");
		}
		return text.ToString();
	}

	/// <summary>
	/// Неінтерактивний запуск для SQL Agent (CmdExec), Rundeck чи Планувальника завдань.
	/// Якщо режим не задано явно, додається -NonInteractive: за розкладом нікому підтверджувати дозапити.
	/// </summary>
	public static string FormatPwshFile(RunOptions options, string scriptPath)
	{
		var text = new StringBuilder("pwsh -NoProfile -File ").Append(QuoteCmd(scriptPath));
		foreach (var parameter in BuildParameters(options))
		{
			text.Append(' ').Append(FormatFileParameter(parameter));
		}
		if (options.NonInteractive is null)
		{
			text.Append(" -NonInteractive");
		}
		if (options.Verbose)
		{
			text.Append(" -Verbose");
		}
		return text.ToString();
	}

	/// <summary>Будь-яка команда модуля з параметрами: New-IaIndexMaintenance -FromArchive '...' -Config '...'.</summary>
	public static string FormatCommand(string command, IEnumerable<CommandParameter> parameters)
	{
		var text = new StringBuilder(command);
		foreach (var parameter in parameters)
		{
			text.Append(' ').Append(FormatPowerShellParameter(parameter));
		}
		return text.ToString();
	}

	public static string QuotePowerShell(string value) => "'" + value.Replace("'", "''") + "'";

	private static string FormatPowerShellParameter(CommandParameter parameter) => parameter.Value switch
	{
		bool flag => flag ? $"-{parameter.Name}" : $"-{parameter.Name}:$false",
		int number => $"-{parameter.Name} {number}",
		string[] items => $"-{parameter.Name} {string.Join(',', items.Select(FormatPowerShellToken))}",
		_ => $"-{parameter.Name} {FormatPowerShellToken(Convert.ToString(parameter.Value) ?? string.Empty)}",
	};

	/// <summary>Прості слова (Both, SQL01) — без лапок, решта — в одинарних.</summary>
	private static string FormatPowerShellToken(string value)
		=> value.Length > 0 && value.All(c => char.IsLetterOrDigit(c) || c is '_' or '-' or '.')
			? value
			: QuotePowerShell(value);

	private static string FormatFileParameter(CommandParameter parameter) => parameter.Value switch
	{
		bool flag => flag ? $"-{parameter.Name}" : $"-{parameter.Name}:$false",
		int number => $"-{parameter.Name} {number}",
		// bin/IndexAdvisor.ps1 сам розбиває "A,B" на масив.
		string[] items => $"-{parameter.Name} {QuoteCmd(string.Join(',', items))}",
		_ => $"-{parameter.Name} {QuoteCmd(Convert.ToString(parameter.Value) ?? string.Empty)}",
	};

	private static string QuoteCmd(string value)
	{
		if (value.Length > 0 && value.All(c => !char.IsWhiteSpace(c) && c is not '"' and not '&' and not '|' and not '<' and not '>' and not '^' and not '%' and not '\''))
		{
			return value;
		}
		return "\"" + value.Replace("\"", "\\\"") + "\"";
	}
}
