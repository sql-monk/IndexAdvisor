using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;

namespace IndexAdvisor.Launcher;

/// <summary>
/// Одиночний exe IndexAdvisor (build.ps1 -Mode SingleFile). Усередині — архів програми (тека SelfContained з .NET,
/// PowerShell SDK і модулем). Під час першого запуску версії exe розпаковує її в %LOCALAPPDATA%\IndexAdvisor\app\&lt;версія&gt;,
/// прибирає інші версії й розпакування попередніх exe в %TEMP%\.net, а далі лише запускає звідти IndexAdvisor.Gui.exe
/// з тими самими аргументами й поточною текою.
/// </summary>
internal static class Program
{
	private const string PayloadResource = "IndexAdvisor.Payload.zip";
	private const string Caption = "IndexAdvisor";

	[STAThread]
	private static int Main(string[] args)
	{
		try
		{
			var assembly = typeof(Program).Assembly;
			var version = Metadata(assembly, "IndexAdvisor.AppVersion");
			var payloadId = Metadata(assembly, "IndexAdvisor.PayloadId");
			if (version is null || payloadId is null || assembly.GetManifestResourceInfo(PayloadResource) is null)
			{
				throw new InstallException("У цьому exe немає програми IndexAdvisor: одиночний exe збирає build.ps1 -Mode SingleFile.");
			}

			InstallResult result;
			using (var mutex = new Mutex(initiallyOwned: false, @"Local\IndexAdvisor.Launcher.Install"))
			{
				try
				{
					mutex.WaitOne();
				}
				catch (AbandonedMutexException)
				{
					// Попередній лаунчер завершився посеред встановлення; його тимчасову теку прибере RemoveOtherVersions.
				}
				try
				{
					result = AppInstaller.EnsureInstalled(
						InstallLayout.AppsRoot,
						version,
						payloadId,
						() => assembly.GetManifestResourceStream(PayloadResource) ?? throw new InstallException("Архів програми не читається."));
					Start(Path.Combine(result.Directory, AppInstaller.AppExeName), args);
					if (result.Installed)
					{
						AppInstaller.RemoveOtherVersions(InstallLayout.AppsRoot, result.Directory);
						AppInstaller.RemoveLegacyExtractions(Path.Combine(Path.GetTempPath(), ".net"));
					}
				}
				finally
				{
					mutex.ReleaseMutex();
				}
			}
			return 0;
		}
		catch (Exception ex)
		{
			var text = ex is InstallException
				? ex.Message
				: $"Не вдалося встановити або запустити IndexAdvisor у {InstallLayout.AppsRoot}:{Environment.NewLine}{ex.Message}";
			MessageBox(IntPtr.Zero, text, Caption, MessageBoxIconError);
			return 1;
		}
	}

	private static void Start(string exe, string[] args)
	{
		var info = new ProcessStartInfo(exe)
		{
			UseShellExecute = false,
			WorkingDirectory = Environment.CurrentDirectory,
		};
		foreach (var arg in args)
		{
			info.ArgumentList.Add(arg);
		}
		info.Environment[InstallLayout.LauncherVariable] = Environment.ProcessPath;
		using var process = Process.Start(info) ?? throw new InstallException($"Не вдалося запустити {exe}.");
	}

	private static string? Metadata(Assembly assembly, string key)
	{
		var value = assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
			.FirstOrDefault(attribute => attribute.Key == key)?.Value;
		return string.IsNullOrWhiteSpace(value) ? null : value;
	}

	private const uint MessageBoxIconError = 0x10;

	[DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxW")]
	private static extern int MessageBox(IntPtr owner, string text, string caption, uint type);
}
