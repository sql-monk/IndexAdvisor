using IndexAdvisor.Gui.Infrastructure;

namespace IndexAdvisor.Gui.ViewModels;

/// <summary>Пункт випадного списку: значення (null — з конфігурації) і напис.</summary>
public sealed record ChoiceOption(string? Value, string Display)
{
	public override string ToString() => Display;
}

/// <summary>Текстове перевизначення (перелік через кому) з підказкою значення з конфігурації.</summary>
public sealed class TextOption : ObservableObject
{
	private string? _value;
	private string _hint = "з конфігурації";

	public TextOption(string key, string label, string toolTip)
	{
		Key = key;
		Label = label;
		ToolTip = toolTip;
	}

	public string Key { get; }

	public string Label { get; }

	public string ToolTip { get; }

	public string? Value
	{
		get => _value;
		set => SetProperty(ref _value, value);
	}

	/// <summary>Підказка в порожньому полі.</summary>
	public string Hint
	{
		get => _hint;
		set => SetProperty(ref _hint, value);
	}
}

/// <summary>
/// Перемикач. Тристанний: null — з конфігурації, true — -Switch, false — -Switch:$false.
/// Двостанний (небезпечні режими): false — не передається.
/// </summary>
public sealed class FlagOption : ObservableObject
{
	private bool? _value;
	private bool? _configValue;

	public FlagOption(string key, string label, string toolTip, bool isThreeState = true, bool invertedInConfig = false)
	{
		Key = key;
		Label = label;
		ToolTip = toolTip;
		IsThreeState = isThreeState;
		InvertedInConfig = invertedInConfig;
		_value = isThreeState ? null : false;
	}

	public string Key { get; }

	public string Label { get; }

	public string ToolTip { get; }

	public bool IsThreeState { get; }

	/// <summary>NoRepository/NoArchive протилежні ключам YAML repository.enabled/archive.enabled.</summary>
	public bool InvertedInConfig { get; }

	public bool? Value
	{
		get => _value;
		set
		{
			if (SetProperty(ref _value, value))
			{
				OnPropertyChanged(nameof(Hint));
			}
		}
	}

	/// <summary>Значення з конфігурації вже в термінах перемикача (з урахуванням інверсії).</summary>
	public bool? ConfigValue
	{
		get => _configValue;
		set
		{
			if (SetProperty(ref _configValue, value))
			{
				OnPropertyChanged(nameof(Hint));
			}
		}
	}

	public string Hint => !IsThreeState || _value.HasValue
		? string.Empty
		: _configValue switch
		{
			true => "з конфігурації: так",
			false => "з конфігурації: ні",
			null => "з конфігурації",
		};

	/// <summary>Значення для RunOptions: для двостанного false означає «не передавати».</summary>
	public bool? EffectiveValue => IsThreeState ? _value : _value == true ? true : null;
}

/// <summary>Пункт переліку з позначкою (набір даних, формат).</summary>
public sealed class CheckItem : ObservableObject
{
	private bool _isChecked;

	public CheckItem(string name, string description, bool isChecked = true, bool isEnabled = true)
	{
		Name = name;
		Description = description;
		_isChecked = isChecked;
		IsEnabled = isEnabled;
	}

	public string Name { get; }

	public string Description { get; }

	public bool IsEnabled { get; }

	public bool IsChecked
	{
		get => _isChecked;
		set => SetProperty(ref _isChecked, value);
	}
}
