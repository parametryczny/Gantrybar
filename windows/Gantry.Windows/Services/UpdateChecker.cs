using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>Checks GitHub for a newer release. With auto-update off it reports it once per version
/// (the notification opens the download page). With auto-update on it downloads the setup .exe,
/// verifies its SHA-256 against the release digest, and installs it silently via a detached helper
/// that closes the app, runs the installer and relaunches Gantry. Mirrors the macOS UpdateChecker.</summary>
public static class UpdateChecker
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private const string NotifiedKey = "update-notified-version";
    private const string InstalledPendingKey = "update-installed-pending";
    private const string LatestApi = "https://api.github.com/repos/parametryczny/gantrybar/releases/latest";

    // SetupUrl/Sha256 are populated when the release ships a Windows setup .exe (+ digest), which is
    // what enables silent auto-install; they stay null otherwise and the app falls back to notifying.
    public sealed record Release(string Version, string PageUrl, string? SetupUrl = null, string? Sha256 = null);

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

            string? setupUrl = null, sha = null;
            if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
                    if (name is null || !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) continue;
                    setupUrl = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
                    // GitHub reports a per-asset digest like "sha256:abc123…" — used to verify the download.
                    if (asset.TryGetProperty("digest", out var d) && d.ValueKind == JsonValueKind.String
                        && d.GetString() is { } dv && dv.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
                        sha = dv[7..];
                    break;
                }
            }

            var release = new Release(version, page ?? "https://github.com/parametryczny/gantrybar/releases", setupUrl, sha);
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

    /// <summary>Downloads the setup .exe, verifies its SHA-256 against the release digest (when
    /// present), then launches a detached PowerShell helper that waits for this app to exit, installs
    /// silently and relaunches Gantry. Returns true once the helper is running (the caller should then
    /// shut the app down); false if it couldn't proceed (no asset / hash mismatch / download error).</summary>
    public static async Task<bool> DownloadAndInstallAsync(Release release)
    {
        if (string.IsNullOrEmpty(release.SetupUrl)) return false;

        var setupPath = Path.Combine(Path.GetTempPath(), $"Gantry-Setup-{release.Version}.exe");
        bool verified = false;
        try
        {
            using (var req = new HttpRequestMessage(HttpMethod.Get, release.SetupUrl))
            {
                req.Headers.Add("User-Agent", "Gantry");
                using var resp = await Http.SendAsync(req);
                if (!resp.IsSuccessStatusCode) return false;
                await using var fs = File.Create(setupPath);
                await resp.Content.CopyToAsync(fs);
            }

            if (!string.IsNullOrEmpty(release.Sha256))
            {
                await using var fs = File.OpenRead(setupPath);
                var hash = Convert.ToHexString(await SHA256.HashDataAsync(fs)).ToLowerInvariant();
                if (!string.Equals(hash, release.Sha256, StringComparison.OrdinalIgnoreCase)) return false;  // tampered / corrupt
                verified = true;
            }
        }
        catch { return false; }

        var exePath = Environment.ProcessPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Gantry", "Gantry.exe");
        var ps1 = Path.Combine(Path.GetTempPath(), $"Gantry-update-{release.Version}.ps1");
        var script =
            "param($procId,$setup,$exe)\r\n" +
            "try { Wait-Process -Id $procId -ErrorAction SilentlyContinue } catch {}\r\n" +
            "Start-Sleep -Milliseconds 500\r\n" +
            "Start-Process -FilePath $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait\r\n" +
            "Start-Process -FilePath $exe\r\n";
        try { File.WriteAllText(ps1, script); }
        catch { return false; }

        Defaults.SetString(InstalledPendingKey, $"{release.Version}|{(verified ? "1" : "0")}");
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{ps1}\" {Environment.ProcessId} \"{setupPath}\" \"{exePath}\"",
                UseShellExecute = false,
                CreateNoWindow = true
            });
        }
        catch { Defaults.SetString(InstalledPendingKey, ""); return false; }
        return true;
    }

    /// <summary>On launch, returns the version we just auto-installed (and whether its hash was
    /// verified) so the app can confirm it — only when the running version matches, so a failed swap
    /// stays silent. Clears the pending marker.</summary>
    public static (string Version, bool Verified)? TakePendingInstalled()
    {
        var raw = Defaults.GetString(InstalledPendingKey);
        if (string.IsNullOrEmpty(raw)) return null;
        Defaults.SetString(InstalledPendingKey, "");
        var parts = raw.Split('|');
        if (parts[0] != CurrentVersion) return null;
        return (parts[0], parts.Length > 1 && parts[1] == "1");
    }

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
