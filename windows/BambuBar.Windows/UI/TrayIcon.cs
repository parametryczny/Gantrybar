using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using BambuBar.Models;
using BambuBar.Services;
using Application = System.Windows.Application;

namespace BambuBar.UI;

/// <summary>System tray presence — the Windows counterpart of the macOS menu bar item.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly PrinterStore _store;
    private readonly NotifyIcon _notifyIcon;
    private readonly Dictionary<string, NotifyIcon> _progressIcons = new();
    private DashboardWindow? _dashboard;
    private SettingsWindow? _settings;

    public TrayIcon(PrinterStore store)
    {
        _store = store;
        _notifyIcon = new NotifyIcon
        {
            Icon = BuildIcon(),
            Visible = true,
            Text = "PrismBar"
        };
        _notifyIcon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleDashboard(); };
        _notifyIcon.BalloonTipClicked += (_, _) => OpenPendingUpdate();
        _notifyIcon.ContextMenuStrip = BuildMenu();
        _store.Updated += (_, _) =>
        {
            try { RefreshTooltip(); UpdateProgressIcons(); }
            catch (Exception ex) { BambuBar.App.LogError("TrayUpdated", ex); }
        };
        RefreshTooltip();
        UpdateProgressIcons();
        _ = RunUpdateChecksAsync();
    }

    private string? _pendingUpdateUrl;

    private async Task RunUpdateChecksAsync()
    {
        while (true)
        {
            try
            {
                if (!QuietHours.IsActive())
                {
                var release = await UpdateChecker.CheckAsync();
                if (release is not null)
                {
                    UpdateChecker.MarkNotified(release.Version);
                    _pendingUpdateUrl = release.PageUrl;
                    ShowNotification(
                        AppSettings.Text("Dostępna aktualizacja PrismBar", "PrismBar update available"),
                        AppSettings.Text($"Wersja {release.Version} jest do pobrania. Kliknij, aby otworzyć stronę.",
                                         $"Version {release.Version} is available. Click to open the page."),
                        null);
                }
                }
            }
            catch (Exception ex) { BambuBar.App.LogError("UpdateCheck", ex); }
            await Task.Delay(TimeSpan.FromHours(6));
        }
    }

    private void OpenPendingUpdate()
    {
        if (string.IsNullOrEmpty(_pendingUpdateUrl)) return;
        try { Process.Start(new ProcessStartInfo(_pendingUpdateUrl) { UseShellExecute = true }); }
        catch { /* browser unavailable */ }
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        bool pl = AppSettings.Polish;

        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Pokaż drukarki", "Show printers"), null, (_, _) => ShowDashboard()));
        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Szukaj drukarek…", "Scan for printers…"), null, (_, _) => { ShowDashboard(); _store.Scan(); }));
        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Dodaj drukarkę…", "Add printer…"), null, (_, _) => { ShowDashboard(); _dashboard?.OpenAddPrinter(); }));
        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Połącz ponownie", "Reconnect all"), null, (_, _) => _store.ReconnectAll()));
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Ustawienia…", "Settings…"), null, (_, _) => ShowSettings()));

        var language = new ToolStripMenuItem(AppSettings.Text("Język: Polski", "Language: English"));
        language.Click += (_, _) => { AppSettings.Polish = !AppSettings.Polish; RebuildMenu(); };
        menu.Items.Add(language);

        var startup = new ToolStripMenuItem(AppSettings.Text("Uruchamiaj z Windows", "Start with Windows"))
        {
            Checked = LaunchAtLogin.IsEnabled,
            CheckOnClick = true
        };
        startup.Click += (_, _) => LaunchAtLogin.SetEnabled(startup.Checked);
        menu.Items.Add(startup);

        var quiet = new ToolStripMenuItem(
            AppSettings.Text($"Godziny ciszy ({QuietHours.RangeLabel()})", $"Quiet hours ({QuietHours.RangeLabel()})"))
        {
            Checked = QuietHours.Enabled,
            CheckOnClick = true
        };
        quiet.Click += (_, _) => QuietHours.Enabled = quiet.Checked;
        menu.Items.Add(quiet);

        menu.Items.Add(BuildColourLegend());

        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Postaw kawę ☕️", "Buy me a coffee ☕️"), null, (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo("https://buycoffee.to/parametryczny") { UseShellExecute = true }); }
            catch { /* browser unavailable */ }
        }));

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(AppSettings.Text("Zakończ", "Quit"), null, (_, _) => Application.Current.Shutdown()));
        _ = pl;
        return menu;
    }

    /// <summary>Non-interactive legend explaining the status colours on the cards. Emoji dots keep
    /// the colours crisp; mirrors the macOS "Colour legend" submenu.</summary>
    private static ToolStripMenuItem BuildColourLegend()
    {
        var legend = new ToolStripMenuItem(AppSettings.Text("🎨  Legenda kolorów", "🎨  Colour legend"));
        (string Dot, string Text)[] entries =
        {
            ("🔵", AppSettings.Text("Drukuje (świeże dane)", "Printing (live data)")),
            ("🟢", AppSettings.Text("Gotowe / zakończone", "Ready / finished")),
            ("🟠", AppSettings.Text("Uwaga: nieświeże dane, pauza lub wilgotność AMS",
                                    "Attention: stale data, paused, or AMS humidity")),
            ("🔴", AppSettings.Text("Błąd drukarki", "Printer error")),
            ("⚪", AppSettings.Text("Offline / brak / neutralna informacja", "Offline / none / neutral")),
        };
        foreach (var (dot, text) in entries)
        {
            // No Click handler — informational only; kept enabled so the emoji dot stays full-colour.
            legend.DropDownItems.Add(new ToolStripMenuItem($"{dot}  {text}"));
        }
        return legend;
    }

    private void RebuildMenu()
    {
        _notifyIcon.ContextMenuStrip?.Dispose();
        _notifyIcon.ContextMenuStrip = BuildMenu();
        _dashboard?.RefreshLanguage();
    }

    private DashboardWindow EnsureDashboard()
    {
        if (_dashboard is null)
        {
            _dashboard = new DashboardWindow(_store);
            _dashboard.Closed += (_, _) => _dashboard = null;
        }
        return _dashboard;
    }

    // Tray left-click toggles the popover panel.
    private void ToggleDashboard() => EnsureDashboard().TogglePopover();

    // Menu items always show it.
    private void ShowDashboard() => EnsureDashboard().ShowPopover();

    private void ShowSettings()
    {
        if (_settings is null)
        {
            _settings = new SettingsWindow();
            _settings.Closed += (_, _) => _settings = null;
        }
        _settings.Show();
        _settings.Activate();
        _settings.WindowState = System.Windows.WindowState.Normal;
    }

    public void ShowNotification(string title, string body, string? subtitle)
    {
        string text = string.IsNullOrEmpty(subtitle) ? body : $"{subtitle}\n{body}";
        _notifyIcon.ShowBalloonTip(5000, title, text, ToolTipIcon.Info);
    }

    private void RefreshTooltip()
    {
        int active = _store.ActivePrintCount;
        int total = _store.Printers.Count;
        _notifyIcon.Text = active > 0
            ? AppSettings.Text($"PrismBar — {active} drukuje", $"PrismBar — {active} printing")
            : AppSettings.Text($"PrismBar — {total} drukarek", $"PrismBar — {total} printers");
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool DestroyIcon(IntPtr handle);

    private readonly Dictionary<string, IntPtr> _progressHandles = new();

    /// <summary>Adds/removes/updates one extra tray icon per printer pinned to the tray, each
    /// showing its live progress. Mirrors the macOS extra menu-bar status items.</summary>
    private void UpdateProgressIcons()
    {
        var validSerials = _store.Printers.Select(p => p.Serial).ToList();
        TrayProgressPreference.Prune(validSerials);
        var pinned = new HashSet<string>(TrayProgressPreference.Serials().Where(validSerials.Contains));

        foreach (var serial in _progressIcons.Keys.Where(s => !pinned.Contains(s)).ToList())
            RemoveProgressIcon(serial);

        foreach (var serial in pinned)
        {
            var printer = _store.Printers.FirstOrDefault(p => p.Serial == serial);
            _store.Telemetry.TryGetValue(serial, out var telemetry);
            if (!_progressIcons.TryGetValue(serial, out var icon))
            {
                icon = new NotifyIcon { Visible = true };
                icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleDashboard(); };
                _progressIcons[serial] = icon;
            }

            string name = printer?.Name ?? serial;
            int? percent = telemetry is { State: PrinterState.Printing or PrinterState.Paused }
                ? telemetry.Progress : null;

            if (_progressHandles.TryGetValue(serial, out var oldHandle)) DestroyIcon(oldHandle);
            icon.Icon = BuildProgressIcon(percent, out var handle);
            _progressHandles[serial] = handle;
            icon.Text = percent is int p ? $"{name} — {p}%" : name;
        }
    }

    private void RemoveProgressIcon(string serial)
    {
        if (_progressIcons.Remove(serial, out var icon))
        {
            icon.Visible = false;
            icon.Dispose();
        }
        if (_progressHandles.Remove(serial, out var handle)) DestroyIcon(handle);
    }

    private static Icon BuildProgressIcon(int? percent, out IntPtr handle)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var fill = percent is null
                ? Color.FromArgb(230, 90, 90, 96)
                : Color.FromArgb(235, 10, 132, 255);
            using var back = new SolidBrush(fill);
            using var path = RoundedRect(new Rectangle(1, 1, 30, 30), 7);
            g.FillPath(back, path);
            string text = percent is int p ? (p >= 100 ? "OK" : p.ToString()) : "–";
            using var font = new Font("Segoe UI", text.Length >= 3 ? 11 : 15, FontStyle.Bold, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(Color.FromArgb(255, 245, 245, 247));
            var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(text, font, brush, new RectangleF(0, 0, 32, 32), format);
        }
        handle = bmp.GetHicon();
        return Icon.FromHandle(handle);
    }

    private static Icon BuildIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var back = new SolidBrush(Color.FromArgb(230, 28, 28, 30));
            using var path = RoundedRect(new Rectangle(1, 1, 30, 30), 7);
            g.FillPath(back, path);
            DrawLogo(g, new RectangleF(6, 6, 20, 20), Color.FromArgb(255, 245, 245, 247));
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // Front-face polygons of the PrismBar mark in a 400x400 design space (flat x,y pairs).
    private static readonly float[][] LogoPolygons =
    {
        new float[] { 197, 55, 119, 212, 188, 195 },
        new float[] { 203, 55, 193, 193, 263, 182 },
        new float[] { 115, 225, 268, 195, 303, 263, 92, 272 },
        new float[] { 81, 285, 51, 345, 175, 345 },
        new float[] { 100, 276, 303, 268, 282, 345, 182, 345 },
        new float[] { 315, 272, 288, 345, 345, 345 },
    };

    /// <summary>Draws the PrismBar mark filled into <paramref name="dst"/>, centered and scaled.</summary>
    private static void DrawLogo(Graphics g, RectangleF dst, Color color)
    {
        const float minX = 51f, minY = 55f, srcW = 294f, srcH = 290f;
        float scale = Math.Min(dst.Width / srcW, dst.Height / srcH);
        float offsetX = dst.X + (dst.Width - srcW * scale) / 2f;
        float offsetY = dst.Y + (dst.Height - srcH * scale) / 2f;
        using var brush = new SolidBrush(color);
        foreach (var polygon in LogoPolygons)
        {
            var points = new PointF[polygon.Length / 2];
            for (int i = 0; i < points.Length; i++)
                points[i] = new PointF(offsetX + (polygon[i * 2] - minX) * scale,
                                       offsetY + (polygon[i * 2 + 1] - minY) * scale);
            g.FillPolygon(brush, points);
        }
    }

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        int d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public void Dispose()
    {
        foreach (var serial in _progressIcons.Keys.ToList()) RemoveProgressIcon(serial);
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }
}
