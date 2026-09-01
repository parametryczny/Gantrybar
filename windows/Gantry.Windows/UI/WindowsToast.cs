using Microsoft.Toolkit.Uwp.Notifications;
using Windows.UI.Notifications;

namespace Gantry.UI;

/// <summary>
/// Native Windows toast notifications that land in the Action Center (notification panel), not the
/// old tray balloon tips. Registration is deliberately initialized on WPF's STA dispatcher thread;
/// printer telemetry arrives on worker threads, where WinRT/COM setup can silently fail.
/// </summary>
internal static class WindowsToast
{
    private static bool _initialized;

    public static void Initialize(Action activated)
    {
        if (_initialized) return;
        _initialized = true;
        try
        {
            ToastNotificationManagerCompat.OnActivated += _ => activated();
            _ = ToastNotificationManagerCompat.CreateToastNotifier().Setting;
        }
        catch (Exception ex)
        {
            Gantry.App.LogError("WindowsToast.Initialize", ex);
        }
    }

    /// <summary>Shows an Action Center toast. Returns false if the toast infrastructure is unavailable
    /// (very old Windows / locked-down policy) so the caller can fall back to a tray balloon.</summary>
    public static bool Show(string title, string body, string? subtitle)
    {
        try
        {
            var builder = new ToastContentBuilder().AddText(title);
            if (!string.IsNullOrEmpty(subtitle)) builder.AddText(subtitle);
            if (!string.IsNullOrEmpty(body)) builder.AddText(body);
            var notifier = ToastNotificationManagerCompat.CreateToastNotifier();
            // When the user or a corporate policy disabled Gantry notifications, Show() does not
            // necessarily throw. Returning false here enables the reliable tray-balloon fallback.
            if (notifier.Setting != NotificationSetting.Enabled) return false;
            var toast = new ToastNotification(builder.GetToastContent().GetXml())
            {
                ExpirationTime = DateTimeOffset.Now.AddMinutes(5)
            };
            toast.Failed += (_, args) => Gantry.App.LogError("WindowsToast.Failed",
                new InvalidOperationException($"HRESULT 0x{args.ErrorCode:X8}"));
            notifier.Show(toast);
            return true;
        }
        catch (Exception ex)
        {
            Gantry.App.LogError("WindowsToast.Show", ex);
            return false;
        }
    }
}
