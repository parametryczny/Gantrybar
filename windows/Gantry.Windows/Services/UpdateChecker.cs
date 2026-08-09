using System.Net.Http;
using System.Reflection;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>Checks GitHub for a newer release and reports it once per version. Windows has no
/// in-app installer, so the notification points the user at the download page. Mirrors the macOS
/// UpdateChecker.</summary>
public static class UpdateChecker
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private const string NotifiedKey = "update-notified-version";
    private const string LatestApi = "https://api.github.com/repos/parametryczny/gantrybar/releases/latest";

    public sealed record Release(string Version, string PageUrl);

    public static string CurrentVersion
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetName().Version;
            return v is null ? "0.0.0" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    /// <summary>Fetches the latest release regardless of state; used by the manual "check" button.</summary>
    public static async Task<(Release Release, bool IsNewer)?> LatestAsync()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, LatestApi);
            request.Headers.Add("User-Agent", "Gantry");
            request.Headers.Add("Accept", "application/vnd.github+json");
            using var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return null;

            using var doc = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync());
            var root = doc.RootElement;
            var tag = root.TryGetProperty("tag_name", out var t) ? t.GetString() : null;
            if (string.IsNullOrEmpty(tag)) return null;

            var version = tag.StartsWith("v") ? tag[1..] : tag;
            var page = root.TryGetProperty("html_url", out var h) ? h.GetString() : null;
            var release = new Release(version, page ?? "https://github.com/parametryczny/gantrybar/releases");
            return (release, IsNewer(version, CurrentVersion));
        }
        catch { return null; }
    }

    /// <summary>Returns a newer release the user has not been told about yet, otherwise null.</summary>
    public static async Task<Release?> CheckAsync()
    {
        var latest = await LatestAsync();
        if (latest is not { } l || !l.IsNewer) return null;
        if (Defaults.GetString(NotifiedKey) == l.Release.Version) return null;  // already notified
        return l.Release;
    }

    public static void MarkNotified(string version) => Defaults.SetString(NotifiedKey, version);

    public static bool IsNewer(string candidate, string current)
    {
        var a = candidate.Split('.');
        var b = current.Split('.');
        for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length && int.TryParse(a[i], out var xi) ? xi : 0;
            int y = i < b.Length && int.TryParse(b[i], out var yi) ? yi : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
