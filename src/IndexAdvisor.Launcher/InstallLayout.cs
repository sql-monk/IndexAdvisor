namespace IndexAdvisor;

/// <summary>
/// Єдине місце встановлення IndexAdvisor на машині користувача — %LOCALAPPDATA%\IndexAdvisor:
/// app\&lt;версія&gt; — програма з одиночного exe (.NET, PowerShell SDK і модуль у Modules\IndexAdvisor);
/// Modules — залежності модуля з PowerShell Gallery (перша тека PSModulePath вбудованого PowerShell).
/// Налаштування й шаблони — окремо, у %APPDATA%\IndexAdvisor (переносяться з профілем користувача).
/// Файл спільний для лаунчера й GUI.
/// </summary>
internal static class InstallLayout
{
	public static string Root { get; } = Path.Combine(
		Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
		"IndexAdvisor");

	/// <summary>Розпакована програма: app\&lt;версія&gt;.</summary>
	public static string AppsRoot { get; } = Path.Combine(Root, "app");

	/// <summary>Залежності модуля (dbatools, powershell-yaml, SecretManagement, SecretStore).</summary>
	public static string ModulesRoot { get; } = Path.Combine(Root, "Modules");

	/// <summary>Змінна середовища, якою лаунчер передає програмі шлях до свого exe.</summary>
	public const string LauncherVariable = "INDEXADVISOR_LAUNCHER";
}
