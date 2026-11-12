using System.Collections;
using System.Globalization;
using System.Management.Automation.Language;

namespace IndexAdvisor.Gui.Core;

public enum SchemaType
{
	Object,
	String,
	Int,
	Number,
	Bool,
	Array,
	Map,
}

/// <summary>Вузол Shared/ConfigSchema.psd1: Name, Type, Default, Description, Enum, Min, Max, Required, Items, Properties, Values, Secret.</summary>
public sealed class SchemaNode
{
	public required string Name { get; init; }

	public SchemaType Type { get; init; }

	/// <summary>string, long, double, bool, IReadOnlyList&lt;object?&gt; або null.</summary>
	public object? Default { get; init; }

	public string Description { get; init; } = string.Empty;

	public IReadOnlyList<string>? Enum { get; init; }

	public double? Min { get; init; }

	public double? Max { get; init; }

	public bool Required { get; init; }

	public bool Secret { get; init; }

	/// <summary>Тип елемента масиву скалярів (string, int…).</summary>
	public SchemaType? ItemType { get; init; }

	/// <summary>Вузол елемента масиву об'єктів.</summary>
	public SchemaNode? ItemNode { get; init; }

	public IReadOnlyList<SchemaNode> Properties { get; init; } = [];

	/// <summary>Вузол значення для map.</summary>
	public SchemaNode? Values { get; init; }

	public bool IsScalar => Type is SchemaType.String or SchemaType.Int or SchemaType.Number or SchemaType.Bool;

	public SchemaNode? Find(string name) => Properties.FirstOrDefault(property => property.Name == name);
}

/// <summary>Читає ConfigSchema.psd1 парсером PowerShell (як Import-PowerShellDataFile), без runspace.</summary>
public static class ConfigSchemaLoader
{
	public static string? FindSchemaPath(string modulePath)
	{
		if (!File.Exists(modulePath))
		{
			return null;
		}
		var path = Path.Combine(Path.GetDirectoryName(modulePath)!, "Shared", "ConfigSchema.psd1");
		return File.Exists(path) ? path : null;
	}

	public static SchemaNode Load(string path)
	{
		var ast = Parser.ParseFile(path, out _, out var errors);
		if (errors.Length > 0)
		{
			throw new InvalidDataException($"ConfigSchema.psd1: {errors[0].Message} (рядок {errors[0].Extent.StartLineNumber}).");
		}
		if (ast.Find(node => node is HashtableAst, searchNestedScriptBlocks: false) is not HashtableAst table
			|| table.SafeGetValue() is not Hashtable root)
		{
			throw new InvalidDataException("ConfigSchema.psd1 не містить хеш-таблиці схеми.");
		}
		return FromHashtable(root);
	}

	internal static SchemaNode FromHashtable(Hashtable table)
	{
		var type = ParseType(Text(table, "Type")) ?? SchemaType.String;
		SchemaType? itemType = null;
		SchemaNode? itemNode = null;
		if (table["Items"] is Hashtable itemTable)
		{
			itemNode = FromHashtable(itemTable);
		}
		else if (table["Items"] is string itemName)
		{
			itemType = ParseType(itemName);
		}
		return new SchemaNode
		{
			Name = Text(table, "Name") ?? string.Empty,
			Type = type,
			Default = Normalize(table["Default"]),
			Description = Text(table, "Description") ?? string.Empty,
			Enum = table["Enum"] is IEnumerable values and not string ? values.Cast<object>().Select(item => Convert.ToString(item, CultureInfo.InvariantCulture)!).ToList() : null,
			Min = Number(table["Min"]),
			Max = Number(table["Max"]),
			Required = table["Required"] is true,
			Secret = table["Secret"] is true,
			ItemType = itemType,
			ItemNode = itemNode,
			Properties = table["Properties"] is IEnumerable properties and not string
				? properties.OfType<Hashtable>().Select(FromHashtable).ToList()
				: [],
			Values = table["Values"] is Hashtable valueTable ? FromHashtable(valueTable) : null,
		};
	}

	private static SchemaType? ParseType(string? type) => type?.ToLowerInvariant() switch
	{
		"object" => SchemaType.Object,
		"string" => SchemaType.String,
		"int" => SchemaType.Int,
		"number" => SchemaType.Number,
		"bool" => SchemaType.Bool,
		"array" => SchemaType.Array,
		"map" => SchemaType.Map,
		_ => null,
	};

	private static string? Text(Hashtable table, string key) => table[key] as string;

	private static double? Number(object? value) => value switch
	{
		int number => number,
		long number => number,
		double number => number,
		decimal number => (double)number,
		_ => null,
	};

	private static object? Normalize(object? value) => value switch
	{
		null => null,
		int number => (long)number,
		long number => number,
		double number => number,
		decimal number => (double)number,
		bool flag => flag,
		string text => text,
		Hashtable => null,
		IEnumerable items => items.Cast<object?>().Select(Normalize).ToList(),
		_ => Convert.ToString(value, CultureInfo.InvariantCulture),
	};
}
