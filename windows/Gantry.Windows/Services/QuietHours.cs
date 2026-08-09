namespace Gantry.Services;

/// <summary>A daily window during which notifications are suppressed. Configured in Settings and
/// toggled from the tray menu. Times stored as minutes since midnight. Mirrors macOS QuietHours.</summary>
public static class QuietHours
{
    public static bool Enabled
    {
        get => Defaults.GetBool("quiet-hours-enabled");
        set => Defaults.SetBool("quiet-hours-enabled", value);
    }

    public static int StartMinutes
    {
        get => Defaults.GetInt("quiet-hours-start", 22 * 60);
        set => Defaults.SetInt("quiet-hours-start", value);
    }

    public static int EndMinutes
    {
        get => Defaults.GetInt("quiet-hours-end", 7 * 60);
        set => Defaults.SetInt("quiet-hours-end", value);
    }

    public static bool IsActive()
    {
        if (!Enabled) return false;
        int start = StartMinutes, end = EndMinutes;
        if (start == end) return false;
        var now = DateTime.Now.Hour * 60 + DateTime.Now.Minute;
        return start < end ? (now >= start && now < end) : (now >= start || now < end);
    }

    public static string RangeLabel()
        => $"{StartMinutes / 60:D2}:{StartMinutes % 60:D2}–{EndMinutes / 60:D2}:{EndMinutes % 60:D2}";
}
