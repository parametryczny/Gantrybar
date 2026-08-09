using System.IO;
using System.Windows;
using System.Windows.Threading;
using Gantry.Services;
using Gantry.UI;

namespace Gantry;

public partial class App : Application
{
    private PrinterStore? _store;
    private TrayIcon? _tray;

    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Gantry", "error.log");

    /// <summary>Appends an exception to %AppData%\Gantry\error.log so intermittent crashes can be
    /// diagnosed without a debugger. Best-effort; never throws.</summary>
    internal static void LogError(string source, Exception? ex)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {source}: {ex}\n\n");
        }
        catch { /* logging must never crash */ }
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Keep the tray app alive on recoverable UI-thread errors, and record everything for
        // diagnosis. A background printer or a Windows quirk should never take the whole app down.
        DispatcherUnhandledException += (_, args) => { LogError("Dispatcher", args.Exception); args.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, args) => LogError("AppDomain", args.ExceptionObject as Exception);
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, args) => { LogError("Task", args.Exception); args.SetObserved(); };

        if (e.Args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                BambuStudioConfig.RunSelfTest();
                SubnetTargets.RunSelfTest();
                AppSettings.RunLocalizationSelfTest();
                Shutdown(0);
            }
            catch
            {
                Shutdown(1);
            }
            return;
        }

        // Windows-1252 is not registered by default on .NET 8; the status parser uses it to
        // repair mis-encoded print names.
        System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);

        var dispatcher = Dispatcher.CurrentDispatcher;
        _store = new PrinterStore(action =>
        {
            if (dispatcher.CheckAccess()) action();
            else dispatcher.BeginInvoke(action);
        });

        _tray = new TrayIcon(_store);
        NotificationService.Sink = (title, body, subtitle) => _tray.ShowNotification(title, body, subtitle);

        if (LaunchAtLogin.IsEnabled) LaunchAtLogin.SetEnabled(true); // refresh path

        _store.ReconnectAll();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }
}
