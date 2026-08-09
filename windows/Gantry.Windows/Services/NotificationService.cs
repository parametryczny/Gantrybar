namespace Gantry.Services;

/// <summary>
/// Posts user notifications. The tray icon wires up the actual sink (a balloon tip) at startup;
/// until then posts are ignored, mirroring the macOS NotificationService abstraction.
/// </summary>
public static class NotificationService
{
    public static Action<string, string, string?>? Sink { get; set; }

    public static void Post(string title, string body, string? subtitle = null)
    {
        if (QuietHours.IsActive()) return;   // suppressed during quiet hours
        Sink?.Invoke(title, body, subtitle);
    }
}
