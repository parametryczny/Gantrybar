using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Gantry.Models;
using Gantry.Services;
using Application = System.Windows.Application;

namespace Gantry.UI;

/// <summary>System tray presence — the Windows counterpart of the macOS menu bar item.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly PrinterStore _store;
    private readonly NotifyIcon _notifyIcon;
    private readonly Dictionary<string, NotifyIcon> _progressIcons = new();
    private DashboardWindow? _dashboard;
    private SettingsWindow? _settings;
    private SpoolbaseWindow? _spoolbase;
    private TrayFlyout? _flyout;
    private System.Windows.Threading.DispatcherTimer? _flyoutTimer;
    private DateTime _lastIconHover;

    public TrayIcon(PrinterStore store)
    {
        _store = store;
        _notifyIcon = new NotifyIcon
        {
            Icon = BuildIcon(out _mainIconHandle),
            Visible = true,
            Text = "Gantry"
        };
        _notifyIcon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleDashboard(); };
        _notifyIcon.MouseMove += (_, _) => ShowFlyout();
        _notifyIcon.BalloonTipClicked += (_, _) => OpenPendingUpdate();
        _notifyIcon.ContextMenuStrip = BuildMenu();
        _store.Updated += (_, _) =>
        {
            try { RefreshTooltip(); UpdateProgressIcons(); }
            catch (Exception ex) { Gantry.App.LogError("TrayUpdated", ex); }
        };
        RefreshTooltip();
        UpdateProgressIcons();
        AnnounceInstalledIfPending();
        _ = RunUpdateChecksAsync();
    }

    private string? _pendingUpdateUrl;

    /// <summary>If we just auto-installed, confirm it (and whether the hash checked out) on relaunch.</summary>
    private void AnnounceInstalledIfPending()
    {
        try
        {
            if (UpdateChecker.TakePendingInstalled() is not { } inst) return;
            var body = inst.Verified
                ? AppSettings.Text($"Zainstalowano wersję {inst.Version}. Hash zweryfikowany — wszystko OK.",
                                   $"Installed version {inst.Version}. Hash verified — all good.")
                : AppSettings.Text($"Zainstalowano wersję {inst.Version}. Wszystko OK.",
                                   $"Installed version {inst.Version}. All good.");
            ShowNotification(AppSettings.Text("Zaktualizowano Gantry", "Gantry updated"), body, null);
        }
        catch (Exception ex) { Gantry.App.LogError("UpdateAnnounce", ex); }
    }

    private async Task RunUpdateChecksAsync()
    {
        while (true)
        {
            try
            {
                if (!QuietHours.IsActive())
                {
                    if (AppSettings.AutoUpdate)
                    {
                        var latest = await UpdateChecker.LatestAsync();
                        if (latest is { IsNewer: true } l && !string.IsNullOrEmpty(l.Release.SetupUrl)
                            && await UpdateChecker.DownloadAndInstallAsync(l.Release))
                        {
                            // The helper will install and relaunch once we exit.
                            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                                System.Windows.Application.Current.Shutdown());
                            return;
                        }
                    }
                    else
                    {
                        var release = await UpdateChecker.CheckAsync();
                        if (release is not null)
                        {
                            UpdateChecker.MarkNotified(release.Version);
                            _pendingUpdateUrl = release.PageUrl;
                            ShowNotification(
                                AppSettings.Text("Dostępna aktualizacja Gantry", "Gantry update available"),
                                AppSettings.Text($"Wersja {release.Version} jest do pobrania. Kliknij, aby otworzyć stronę.",
                                                 $"Version {release.Version} is available. Click to open the page."),
                                null);
                        }
                    }
                }
            }
            catch (Exception ex) { Gantry.App.LogError("UpdateCheck", ex); }
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

        if (AppSettings.SpoolbaseEnabled)
        {
            menu.Items.Add(new ToolStripMenuItem(
                AppSettings.Text("Spoolbase — magazyn filamentów", "Spoolbase — filament stock"),
                null, (_, _) => ToggleSpoolbase()));
        }
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
        legend.DropDownItems.Add(new ToolStripSeparator());
        var header = new ToolStripMenuItem(AppSettings.Text("Sloty filamentu:", "Filament slots:")) { Enabled = false };
        legend.DropDownItems.Add(header);
        (string Dot, string Text)[] slotEntries =
        {
            ("⭕", AppSettings.Text("Slot AMS z białym pierścieniem — aktywny (drukuje z niego)",
                                    "AMS slot with a white ring — active (printing from it)")),
            ("🔴", AppSettings.Text("Czerwona kropka na slocie — mało filamentu (≤15%)",
                                    "Red dot on a slot — low filament (≤15%)")),
        };
        foreach (var (dot, text) in slotEntries)
            legend.DropDownItems.Add(new ToolStripMenuItem($"{dot}  {text}"));
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

    private void ToggleSpoolbase()
    {
        if (_spoolbase is null)
        {
            _spoolbase = new SpoolbaseWindow();
            _spoolbase.Closed += (_, _) => _spoolbase = null;
        }
        _spoolbase.TogglePopover();
    }

    // Hovering a tray icon pops up the flyout with the pinned printers' names/%/status; a timer hides
    // it once the cursor leaves both the icon and the flyout.
    private void ShowFlyout()
    {
        try
        {
            _lastIconHover = DateTime.Now;
            var items = PinnedFlyoutItems();
            if (items.Count == 0) { _flyout?.Hide(); return; }

            if (_flyout is null)
            {
                _flyout = new TrayFlyout();
                _flyoutTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
                _flyoutTimer.Tick += (_, _) =>
                {
                    if (_flyout is { IsVisible: true } && !_flyout.IsMouseOver
                        && (DateTime.Now - _lastIconHover).TotalMilliseconds > 600)
                        _flyout.Hide();
                };
                _flyoutTimer.Start();
            }
            _flyout.SetItems(items);
            if (!_flyout.IsVisible) _flyout.Show();
        }
        catch (Exception ex) { Gantry.App.LogError("TrayFlyout", ex); }
    }

    private List<(string Name, PrinterState State, int? Percent)> PinnedFlyoutItems()
    {
        var pinned = new HashSet<string>(TrayProgressPreference.Serials());
        var result = new List<(string, PrinterState, int?)>();
        foreach (var printer in _store.Printers)
        {
            if (!pinned.Contains(printer.Serial)) continue;
            bool has = _store.Telemetry.TryGetValue(printer.Serial, out var t);
            var state = has ? t.State : PrinterState.Offline;
            int? percent = has && t.State is PrinterState.Printing or PrinterState.Paused ? t.Progress : null;
            result.Add((printer.Name, state, percent));
        }
        return result;
    }

    private void ShowSettings()
    {
        if (_settings is null)
        {
            _settings = new SettingsWindow();
            _settings.Closed += (_, _) => { _settings = null; RebuildMenu(); };
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
            ? AppSettings.Text($"Gantry — {active} drukuje", $"Gantry — {active} printing")
            : AppSettings.Text($"Gantry — {total} drukarek", $"Gantry — {total} printers");
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
        var pinnedSet = new HashSet<string>(TrayProgressPreference.Serials());
        var ordered = validSerials.Where(pinnedSet.Contains).ToList();   // stable dashboard order

        // The FIRST pinned printer rides on the main Gantry tray icon (which turns into its progress),
        // so there's no redundant extra icon; any others get their own extra icons.
        var extras = ordered.Skip(1).ToList();
        var extrasSet = new HashSet<string>(extras);

        foreach (var serial in _progressIcons.Keys.Where(s => !extrasSet.Contains(s)).ToList())
            RemoveProgressIcon(serial);

        foreach (var serial in extras)
        {
            var printer = _store.Printers.FirstOrDefault(p => p.Serial == serial);
            _store.Telemetry.TryGetValue(serial, out var telemetry);
            if (!_progressIcons.TryGetValue(serial, out var icon))
            {
                // Right-click gives the full app menu, matching the main icon — the indicators are
                // the app's entry points when printers are pinned.
                icon = new NotifyIcon { Visible = true, ContextMenuStrip = BuildMenu() };
                icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleDashboard(); };
                icon.MouseMove += (_, _) => ShowFlyout();
                _progressIcons[serial] = icon;
            }

            string name = printer?.Name ?? serial;
            int? percent = telemetry is { State: PrinterState.Printing or PrinterState.Paused }
                ? telemetry.Progress : null;

            if (_progressHandles.TryGetValue(serial, out var oldHandle)) DestroyIcon(oldHandle);
            icon.Icon = BuildProgressIcon(percent, telemetry?.State ?? PrinterState.Offline, out var handle);
            _progressHandles[serial] = handle;
            icon.Text = percent is int p ? $"{name} — {p}%" : name;
        }

        // Main icon: the first pinned printer's live progress, or the Gantry logo when none are pinned.
        if (ordered.Count > 0)
        {
            var serial = ordered[0];
            var printer = _store.Printers.FirstOrDefault(p => p.Serial == serial);
            _store.Telemetry.TryGetValue(serial, out var tel);
            string name = printer?.Name ?? serial;
            int? percent = tel is { State: PrinterState.Printing or PrinterState.Paused } ? tel.Progress : null;
            SetMainIcon(BuildProgressIcon(percent, tel?.State ?? PrinterState.Offline, out var handle), handle);
            _notifyIcon.Text = percent is int p ? $"{name} — {p}%" : name;
        }
        else
        {
            SetMainIcon(BuildIcon(out var handle), handle);   // back to the Gantry logo; tooltip via RefreshTooltip
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

    // Tray-icon fill by printer state, matching the dashboard dots: blue printing, green ready/done,
    // orange paused, red error, grey offline.
    private static Color StatusColor(PrinterState state) => state switch
    {
        PrinterState.Printing => Color.FromArgb(235, 10, 132, 255),
        PrinterState.Finished => Color.FromArgb(235, 52, 199, 89),
        PrinterState.Idle => Color.FromArgb(235, 52, 199, 89),
        PrinterState.Paused => Color.FromArgb(235, 255, 159, 10),
        PrinterState.Error => Color.FromArgb(235, 255, 69, 58),
        _ => Color.FromArgb(230, 90, 90, 96),
    };

    private static Icon BuildProgressIcon(int? percent, PrinterState state, out IntPtr handle)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var back = new SolidBrush(StatusColor(state));
            using var path = RoundedRect(new Rectangle(1, 1, 30, 30), 7);
            g.FillPath(back, path);
            string text = state == PrinterState.Error ? "!"
                : percent is int p ? (p >= 100 ? "OK" : p.ToString())
                : "–";
            using var font = new Font("Segoe UI", text.Length >= 3 ? 11 : 15, FontStyle.Bold, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(Color.FromArgb(255, 245, 245, 247));
            var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(text, font, brush, new RectangleF(0, 0, 32, 32), format);
        }
        handle = bmp.GetHicon();
        return Icon.FromHandle(handle);
    }

    private static Icon BuildIcon(out IntPtr handle)
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
        handle = bmp.GetHicon();
        return Icon.FromHandle(handle);
    }

    // Handle for the main tray icon's current bitmap (freed before it's replaced, like the progress
    // icons') — the main icon doubles as the first pinned printer's progress indicator.
    private IntPtr _mainIconHandle = IntPtr.Zero;

    private void SetMainIcon(Icon icon, IntPtr handle)
    {
        if (_mainIconHandle != IntPtr.Zero) DestroyIcon(_mainIconHandle);
        _notifyIcon.Icon = icon;
        _mainIconHandle = handle;
    }

    /// <summary>Draws the Gantry "G" mark filled into <paramref name="dst"/>, centered.</summary>
    private static void DrawLogo(Graphics g, RectangleF dst, Color color)
    {
        // Gantry logo: a bold "G" glyph fitted to the destination rectangle.
        using var brush = new SolidBrush(color);
        using var font = new Font("Segoe UI", dst.Height * 0.86f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.DrawString("G", font, brush,
            new RectangleF(dst.X, dst.Y - dst.Height * 0.04f, dst.Width, dst.Height), format);
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
