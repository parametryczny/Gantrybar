using Microsoft.Toolkit.Uwp.Notifications;

namespace Gantry.UI;

/// <summary>
/// Native Windows toast notifications that land in the Action Center (notification panel), not the
/// old tray balloon tips. Uses ToastNotificationManagerCompat, which auto-registers an AppUserModelID
/// and a Start Menu shortcut for this unpackaged Win32 app the first time a toast is shown.
/// </summary>
internal static class WindowsToast
{
    /// <summary>Shows an Action Center toast. Returns false if the toast infrastructure is unavailable
    /// (very old Windows / locked-down policy) so the caller can fall back to a tray balloon.</summary>
    public static bool Show(string title, string body, string? subtitle)
    {
        try
        {
            var builder = new ToastContentBuilder().AddText(title);
            if (!string.IsNullOrEmpty(subtitle)) builder.AddText(subtitle);
            if (!string.IsNullOrEmpty(body)) builder.AddText(body);
            builder.Show();
            return true;
        }
        catch
        {
            return false;
        }
    }
}
