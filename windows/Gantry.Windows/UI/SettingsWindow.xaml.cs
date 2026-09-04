using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Gantry.Services;

namespace Gantry.UI;

public partial class SettingsWindow : Window
{
    private readonly PrinterStore? _store;
    /// Raised when the Transparency setting changes, so the tray owner can refresh the live flyout
    /// without a restart. Set by TrayIcon to re-apply the dashboard's acrylic tint immediately.
    public Action? OnTransparencyChanged;
    public Action? OnThemeChanged;
    /// Raised when any edge-dock setting changes, so the tray owner can re-pin the strip live.
    public Action? OnEdgeDockChanged;

    public SettingsWindow(PrinterStore? store = null)
    {
        _store = store;
        InitializeComponent();
        SourceInitialized += (_, _) => ApplyModernChrome();
        ApplyThemeVisuals();
        ApplyLanguage();
        LoadSettings();

        TabGeneral.Checked += (_, _) => ShowPage(PageGeneral);
        TabAppearance.Checked += (_, _) => ShowPage(PageAppearance);
        TabAdvanced.Checked += (_, _) => ShowPage(PageAdvanced);

        LanguageButton.Click += (_, _) =>
        {
            // Cycles through the installed catalogs; the button label shows the current one.
            var codes = Translations.Available().Select(entry => entry.Code).ToList();
            int index = codes.IndexOf(AppSettings.Language);
            AppSettings.Language = codes[(index < 0 ? 0 : index + 1) % codes.Count];
            ApplyLanguage();
            RefreshWebSync();
        };
        DockEnableCheckBox.Click += (_, _) =>
        {
            AppSettings.EdgeDockEnabled = DockEnableCheckBox.IsChecked == true;
            ApplyDockEnabledState();
            OnEdgeDockChanged?.Invoke();
        };
        DockEdgeButton.Click += (_, _) =>
        {
            AppSettings.EdgeDockEdge = AppSettings.EdgeDockEdge == "left" ? "right" : "left";
            DockEdgeButton.Content = EdgeName();
            OnEdgeDockChanged?.Invoke();
        };
        DockOnlyPrintingCheckBox.Click += (_, _) =>
        {
            AppSettings.EdgeDockOnlyPrinting = DockOnlyPrintingCheckBox.IsChecked == true;
            OnEdgeDockChanged?.Invoke();
        };
        ThemeButton.Click += (_, _) =>
        {
            AppSettings.Theme = AppSettings.Theme == "dark" ? "light" : "dark";
            ThemeButton.Content = AppSettings.Theme == "dark" ? AppSettings.T("Dark") : AppSettings.T("Light");
            ApplyThemeVisuals();
            OnThemeChanged?.Invoke();
            ApplyModernChrome();
        };
        TransparencyButton.Click += (_, _) =>
        {
            AppSettings.PanelTransparency = (AppSettings.PanelTransparency + 1) % 3;
            TransparencyButton.Content = TransparencyName(AppSettings.PanelTransparency);
            OnTransparencyChanged?.Invoke();   // live-refresh the open flyout's acrylic tint
        };
        StartupCheckBox.Click += (_, _) => LaunchAtLogin.SetEnabled(StartupCheckBox.IsChecked == true);
        SpoolbaseCheckBox.Click += (_, _) => AppSettings.SpoolbaseEnabled = SpoolbaseCheckBox.IsChecked == true;
        DeveloperCheckBox.Click += (_, _) => AppSettings.DeveloperMode = DeveloperCheckBox.IsChecked == true;
        ScriptActionsCheckBox.Click += (_, _) => AppSettings.AllowScriptActions = ScriptActionsCheckBox.IsChecked == true;
        AutoUpdateCheckBox.Click += (_, _) => AppSettings.AutoUpdate = AutoUpdateCheckBox.IsChecked == true;
        PrintFinishedCheckBox.Click += (_, _) => AppSettings.NotifyPrintFinished = PrintFinishedCheckBox.IsChecked == true;
        FinishingSoonCheckBox.Click += (_, _) => AppSettings.NotifyFinishingSoon = FinishingSoonCheckBox.IsChecked == true;
        PrinterErrorCheckBox.Click += (_, _) => AppSettings.NotifyPrinterError = PrinterErrorCheckBox.IsChecked == true;
        PrintPausedCheckBox.Click += (_, _) => AppSettings.NotifyPrintPaused = PrintPausedCheckBox.IsChecked == true;
        LowFilamentCheckBox.Click += (_, _) => AppSettings.NotifyLowFilament = LowFilamentCheckBox.IsChecked == true;
        HighHumidityCheckBox.Click += (_, _) => AppSettings.NotifyHighAmsHumidity = HighHumidityCheckBox.IsChecked == true;
        CardFileNameCheckBox.Click += (_, _) => AppSettings.CardShowFileName = CardFileNameCheckBox.IsChecked == true;
        CardProgressCheckBox.Click += (_, _) => AppSettings.CardShowProgress = CardProgressCheckBox.IsChecked == true;
        CardTempsCheckBox.Click += (_, _) => AppSettings.CardShowTemperatures = CardTempsCheckBox.IsChecked == true;
        CardFilamentsCheckBox.Click += (_, _) => AppSettings.CardShowFilaments = CardFilamentsCheckBox.IsChecked == true;
        CardSpoolGramsCheckBox.Click += (_, _) => AppSettings.CardShowSpoolGrams = CardSpoolGramsCheckBox.IsChecked == true;
        MonochromeCheckBox.Click += (_, _) => AppSettings.Monochrome = MonochromeCheckBox.IsChecked == true;
        CheckUpdatesButton.Click += async (_, _) => await CheckUpdatesAsync();
        TelegramEnableCheckBox.Click += (_, _) =>
        {
            AppSettings.TelegramEnabled = TelegramEnableCheckBox.IsChecked == true;
            TelegramTokenBox.IsEnabled = TelegramChatBox.IsEnabled = TelegramTestButton.IsEnabled = TelegramEnableCheckBox.IsChecked == true;
            TelegramBot.Shared?.SyncWithSettings();
        };
        TelegramTokenBox.LostFocus += (_, _) => { AppSettings.TelegramBotToken = TelegramTokenBox.Text.Trim(); TelegramBot.Shared?.SyncWithSettings(); };
        TelegramChatBox.LostFocus += (_, _) => { AppSettings.TelegramChatId = TelegramChatBox.Text.Trim(); TelegramBot.Shared?.SyncWithSettings(); };
        TelegramTestButton.Click += async (_, _) => await TelegramTestAsync();
        QuietHoursCheckBox.Click += (_, _) => { QuietHours.Enabled = QuietHoursCheckBox.IsChecked == true; QuietTimesRow.IsEnabled = QuietHoursCheckBox.IsChecked == true; };
        QuietStartBox.LostFocus += (_, _) => SaveQuietTimes();
        QuietEndBox.LostFocus += (_, _) => SaveQuietTimes();
        WebDashboardCheckBox.Click += (_, _) =>
        {
            AppSettings.WebDashboardEnabled = WebDashboardCheckBox.IsChecked == true;
            if (AppSettings.WebDashboardEnabled) App.WebServerShared?.Start(); else App.WebServerShared?.Stop();
            RefreshWebSync();
        };
        SyncNewTokenButton.Click += (_, _) => { SyncService.Shared?.RegenerateToken(); RefreshWebSync(); };
        SyncAddPeerButton.Click += (_, _) => { SyncService.Shared?.AddPeer(SyncPeerBox.Text); SyncPeerBox.Text = ""; RefreshWebSync(); };
        SyncSetTokenButton.Click += (_, _) => { SyncService.Shared?.SetToken(SyncSetTokenBox.Text); SyncSetTokenBox.Text = ""; RefreshWebSync(); };
        SyncNowButton.Click += (_, _) => SyncService.Shared?.SyncNow();
        // The user may have changed synced settings; let the newer side win on the next merge.
        Closed += (_, _) => SyncService.Shared?.NoteSettingsChanged();
        CloseButton.Click += (_, _) => Close();
    }

    private void ShowPage(System.Windows.Controls.ScrollViewer page)
    {
        PageGeneral.Visibility = ReferenceEquals(page, PageGeneral) ? Visibility.Visible : Visibility.Collapsed;
        PageAppearance.Visibility = ReferenceEquals(page, PageAppearance) ? Visibility.Visible : Visibility.Collapsed;
        PageAdvanced.Visibility = ReferenceEquals(page, PageAdvanced) ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string EdgeName() => AppSettings.EdgeDockEdge == "left"
        ? AppSettings.T("Left") : AppSettings.T("Right");

    /// Dims the whole dock section, not just the switches, so an off strip reads as inactive.
    private void ApplyDockEnabledState()
    {
        bool on = AppSettings.EdgeDockEnabled;
        DockEdgeButton.IsEnabled = on;
        DockOnlyPrintingCheckBox.IsEnabled = on;
        DockPrintersList.IsEnabled = on;
        DockPrintersList.Opacity = on ? 1 : 0.45;
        DockEdgeButton.Opacity = on ? 1 : 0.45;
    }

    /// One switch row per printer. The serial rides in the control's Tag because the list is rebuilt
    /// whenever the window refreshes, so a captured index would go stale.
    private void RebuildDockPrinters()
    {
        DockPrintersList.Children.Clear();
        var printers = _store?.Printers ?? new List<Gantry.Models.SavedPrinter>();
        if (printers.Count == 0)
        {
            DockPrintersList.Children.Add(new System.Windows.Controls.TextBlock
            {
                Text = AppSettings.T("No printers"),
                Foreground = GTheme.Brush(GTheme.Muted),
                FontSize = 12,
                Margin = new Thickness(14, 11, 14, 12),
            });
            return;
        }
        var hidden = AppSettings.EdgeDockHiddenPrinters;
        for (int index = 0; index < printers.Count; index++)
        {
            var printer = printers[index];
            if (index > 0)
            {
                DockPrintersList.Children.Add(new System.Windows.Controls.Border
                {
                    Height = 1, Background = (Brush)FindResource("SettingsLineBrush"),
                });
            }
            var row = new System.Windows.Controls.CheckBox
            {
                Content = printer.Name,
                Tag = printer.Serial,
                IsChecked = !hidden.Contains(printer.Serial),
            };
            row.Click += (sender, _) =>
            {
                if (sender is not System.Windows.Controls.CheckBox box || box.Tag is not string serial) return;
                var set = AppSettings.EdgeDockHiddenPrinters;
                if (box.IsChecked == true) set.Remove(serial); else set.Add(serial);
                AppSettings.EdgeDockHiddenPrinters = set;
                OnEdgeDockChanged?.Invoke();
            };
            DockPrintersList.Children.Add(row);
        }
    }

    private void RefreshWebSync()
    {
        WebHeading.Text = AppSettings.T("WEB DASHBOARD");
        WebDashboardCheckBox.Content = AppSettings.T("Preview server (local network)");
        WebDashboardCheckBox.IsChecked = AppSettings.WebDashboardEnabled;
        var ip = GantryWebServer.LocalIPv4();
        WebAddressLabel.Text = ip != null ? $"http://{ip}:{GantryWebServer.Port}" : AppSettings.T("no IP address");

        SyncHeading.Text = AppSettings.T("SYNC BETWEEN COMPUTERS");
        SyncTokenLabel.Text = AppSettings.T("Shared token (copy to the other computer)");
        SyncNewTokenButton.Content = AppSettings.T("New");
        SyncAddPeerButton.Content = AppSettings.T("Add");
        SyncSetTokenButton.Content = AppSettings.T("Set token");
        SyncNowButton.Content = AppSettings.T("Sync now");
        SyncHint.Text = AppSettings.T("On the other computer paste this token (Set token), then add this computer's address. Local network only. Printer access codes are never sent.");

        var sync = SyncService.Shared;
        SyncTokenBox.Text = sync?.Token ?? "";
        SyncAddressLabel.Text = ip != null ? $"http://{ip}:{GantryWebServer.Port}" : "";
        SyncPeersList.Children.Clear();
        if (sync != null)
        {
            if (sync.Peers.Count == 0)
                SyncPeersList.Children.Add(new System.Windows.Controls.TextBlock { Text = AppSettings.T("No paired computers."), FontSize = 11, Foreground = GTheme.Brush(GTheme.Muted), Margin = new System.Windows.Thickness(0, 2, 0, 4) });
            foreach (var peer in sync.Peers.ToList())
            {
                var grid = new System.Windows.Controls.Grid { Margin = new System.Windows.Thickness(0, 2, 0, 2) };
                grid.ColumnDefinitions.Add(new System.Windows.Controls.ColumnDefinition { Width = new System.Windows.GridLength(1, System.Windows.GridUnitType.Star) });
                grid.ColumnDefinitions.Add(new System.Windows.Controls.ColumnDefinition { Width = System.Windows.GridLength.Auto });
                string status = peer.LastError != null ? string.Format(AppSettings.T("Error: {0}"), peer.LastError)
                    : peer.LastSyncAt is { } ls ? string.Format(AppSettings.T("last: {0:HH:mm}"), ls.ToLocalTime())
                    : AppSettings.T("not synced yet");
                var info = new System.Windows.Controls.StackPanel();
                info.Children.Add(new System.Windows.Controls.TextBlock { Text = peer.Address, FontFamily = new System.Windows.Media.FontFamily("Consolas"), FontSize = 11, Foreground = GTheme.Brush(GTheme.Text) });
                info.Children.Add(new System.Windows.Controls.TextBlock { Text = status, FontSize = 10, Foreground = peer.LastError != null ? GTheme.Brush(GTheme.StatusPrinting) : GTheme.Brush(GTheme.Secondary) });
                grid.Children.Add(info);
                var remove = new System.Windows.Controls.Button { Content = AppSettings.T("Remove"), MinWidth = 60, Height = 24, FontSize = 11 };
                string peerId = peer.Id;
                remove.Click += (_, _) => { SyncService.Shared?.RemovePeer(peerId); RefreshWebSync(); };
                System.Windows.Controls.Grid.SetColumn(remove, 1);
                grid.Children.Add(remove);
                SyncPeersList.Children.Add(grid);
            }
        }
    }

    private void SaveQuietTimes()
    {
        if (TryParseMinutes(QuietStartBox.Text, out var start)) QuietHours.StartMinutes = start;
        else QuietStartBox.Text = MinutesToText(QuietHours.StartMinutes);
        if (TryParseMinutes(QuietEndBox.Text, out var end)) QuietHours.EndMinutes = end;
        else QuietEndBox.Text = MinutesToText(QuietHours.EndMinutes);
    }

    private static string MinutesToText(int minutes) => $"{minutes / 60:D2}:{minutes % 60:D2}";

    private static bool TryParseMinutes(string text, out int minutes)
    {
        minutes = 0;
        var parts = text.Trim().Split(':');
        if (parts.Length != 2 || !int.TryParse(parts[0], out var h) || !int.TryParse(parts[1], out var m)) return false;
        if (h < 0 || h > 23 || m < 0 || m > 59) return false;
        minutes = h * 60 + m;
        return true;
    }

    private void ApplyLanguage()
    {
        Title = AppSettings.T("Gantry Settings");
        Heading.Text = AppSettings.T("Settings");

        AppearanceHeading.Text = AppSettings.T("APPEARANCE");
        GeneralHeading.Text = AppSettings.T("GENERAL");
        LanguageLabel.Text = AppSettings.T("Language");
        LanguageButton.Content = Translations.Available()
            .FirstOrDefault(entry => entry.Code == AppSettings.Language)?.Name ?? AppSettings.Language;
        ThemeLabel.Text = AppSettings.T("Appearance");
        ThemeButton.Content = AppSettings.Theme == "dark" ? AppSettings.T("Dark") : AppSettings.T("Light");
        TransparencyLabel.Text = AppSettings.T("Transparency");
        TransparencyButton.Content = TransparencyName(AppSettings.PanelTransparency);
        StartupCheckBox.Content = AppSettings.T("Start with Windows");
        SpoolbaseCheckBox.Content = AppSettings.T("Spoolbase — filament stock");
        DeveloperCheckBox.Content = AppSettings.T("Developer mode (control + automations)");
        ScriptActionsCheckBox.Content = AppSettings.T("Allow automations to run scripts and custom commands");
        ScriptActionsHint.Text = AppSettings.T("Off by default for safety: stops a planted rule from silently running code. Each rule still asks for confirmation the first time it fires.");
        AutoUpdateCheckBox.Content = AppSettings.T("Download and install updates automatically");

        CardsHeading.Text = AppSettings.T("PRINTER CARDS");
        CardFileNameCheckBox.Content = AppSettings.T("File name");
        CardProgressCheckBox.Content = AppSettings.T("Progress");
        CardTempsCheckBox.Content = AppSettings.T("Temperatures");
        CardFilamentsCheckBox.Content = AppSettings.T("Filaments / AMS");
        CardSpoolGramsCheckBox.Content = AppSettings.T("Grams on spool (AMS NFC / Spoolbase)");
        MonochromeCheckBox.Content = AppSettings.T("Monochrome colours");

        NotificationsHeading.Text = AppSettings.T("NOTIFICATIONS");
        PrintFinishedCheckBox.Content = AppSettings.T("Print finished");
        FinishingSoonCheckBox.Content = string.Format(
            AppSettings.T("Finishing in {0} minutes"), AppSettings.FinishingSoonMinutes);
        PrinterErrorCheckBox.Content = AppSettings.T("Printer error");
        PrintPausedCheckBox.Content = AppSettings.T("Print paused");
        LowFilamentCheckBox.Content = AppSettings.T("Low filament");
        HighHumidityCheckBox.Content = AppSettings.T("High AMS humidity");
        QuietHoursCheckBox.Content = AppSettings.T("Quiet hours (no notifications)");
        QuietFromLabel.Text = AppSettings.T("from");
        QuietToLabel.Text = AppSettings.T("to");

        TelegramHeading.Text = "TELEGRAM";
        TelegramEnableCheckBox.Content = AppSettings.T("Send notifications to Telegram");
        TelegramTokenLabel.Text = AppSettings.T("Bot token:");
        TelegramChatLabel.Text = "Chat ID:";
        TelegramTestButton.Content = AppSettings.T("Send test");
        TelegramHint.Text = AppSettings.T("Create a bot via @BotFather (token), message it, and get your chat_id from @userinfobot. Sends the same events as above + chat commands (/help).");
        TelegramEnableCheckBox.IsChecked = AppSettings.TelegramEnabled;
        TelegramTokenBox.Text = AppSettings.TelegramBotToken;
        TelegramChatBox.Text = AppSettings.TelegramChatId;
        TelegramTokenBox.IsEnabled = AppSettings.TelegramEnabled;
        TelegramChatBox.IsEnabled = AppSettings.TelegramEnabled;
        TelegramTestButton.IsEnabled = AppSettings.TelegramEnabled;

        UpdatesHeading.Text = AppSettings.T("UPDATES");
        UpdateStatus.Text = string.Format(AppSettings.T("Version {0}"), UpdateChecker.CurrentVersion);
        CheckUpdatesButton.Content = AppSettings.T("Check for updates");

        AboutHeading.Text = AppSettings.T("ABOUT");
        AboutVersion.Text = $"Gantry · {AppSettings.T("version")} {UpdateChecker.CurrentVersion} · DPAPI";
        AboutAuthor.Text = "@_parametryczny";
        GitHubButton.Content = "GitHub";
        XButton.Content = "@_parametryczny";
        SupportButton.Content = AppSettings.T("☕  Support the project");
        SupportSubtitle.Text = AppSettings.T("A virtual coffee gives me a caffeine kick to keep improving Gantry. 🚀");

        TabGeneral.Content = AppSettings.T("General");
        TabAppearance.Content = AppSettings.T("Appearance");
        TabAdvanced.Content = AppSettings.T("Advanced");
        HeaderSubtitle.Text = "Gantry · @_parametryczny";
        FooterVersion.Text = string.Format(AppSettings.T("Version {0} · DPAPI"), UpdateChecker.CurrentVersion);
        DeveloperHeading.Text = AppSettings.T("DEVELOPER");

        DockHeading.Text = AppSettings.T("EDGE DOCK");
        DockEnableCheckBox.Content = AppSettings.T("Show the strip on top");
        DockEnableCheckBox.IsChecked = AppSettings.EdgeDockEnabled;
        DockEdgeLabel.Text = AppSettings.T("Edge");
        DockEdgeButton.Content = EdgeName();
        DockOnlyPrintingCheckBox.Content = AppSettings.T("Only printing");
        DockOnlyPrintingCheckBox.IsChecked = AppSettings.EdgeDockOnlyPrinting;
        DockPrintersCaption.Text = AppSettings.T("WHICH PRINTERS");
        DockHint.Text = AppSettings.T("A narrow strip pinned to the screen edge, always on top. Hovering expands it to names, clicking opens details.");
        RebuildDockPrinters();
        ApplyDockEnabledState();

        CloseButton.Content = AppSettings.T("Done");
    }

    /// <summary>
    /// The settings window uses the same semantic palette as the dashboard. Replacing dynamic
    /// resources makes every visible control repaint immediately; opening another view or
    /// restarting the app is not required after changing the theme.
    /// </summary>
    private void ApplyThemeVisuals()
    {
        Resources["SettingsTextBrush"] = GTheme.Brush(GTheme.Text);
        Resources["SettingsSecondaryBrush"] = GTheme.Brush(GTheme.Secondary);
        Resources["SettingsMutedBrush"] = GTheme.Brush(GTheme.Muted);
        Resources["SettingsPanelBrush"] = GTheme.Brush(GTheme.With(GTheme.Card, 0.94));
        Resources["SettingsCardBrush"] = GTheme.Brush(GTheme.With(GTheme.Card, 0.82));
        Resources["SettingsLineBrush"] = GTheme.Brush(GTheme.Line);
        Resources["SettingsFieldBrush"] = GTheme.Brush(GTheme.With(GTheme.Card, 0.96));
        Resources["SettingsSoftBrush"] = GTheme.Brush(GTheme.W(0.075));
        Resources["SettingsSoftHoverBrush"] = GTheme.Brush(GTheme.W(0.12));
        Resources["SettingsSoftPressedBrush"] = GTheme.Brush(GTheme.W(0.18));
        Resources["SettingsCheckIdleBrush"] = GTheme.Brush(GTheme.W(0.10));
        Resources["SettingsCheckBorderBrush"] = GTheme.Brush(GTheme.W(0.24));
        Resources["SettingsCheckHoverBrush"] = GTheme.Brush(GTheme.W(0.42));
        Resources["SettingsAccentBrush"] = GTheme.Brush(GTheme.Accent);
        Resources["SettingsAccentInkBrush"] = GTheme.Brush(GTheme.Canvas);

        Foreground = GTheme.Brush(GTheme.Text);
        InvalidateVisual();
    }

    private static string TransparencyName(int level) => level switch
    {
        0 => AppSettings.T("Low"),
        2 => AppSettings.T("High"),
        _ => AppSettings.T("Medium"),
    };

    private void LoadSettings()
    {
        StartupCheckBox.IsChecked = LaunchAtLogin.IsEnabled;
        SpoolbaseCheckBox.IsChecked = AppSettings.SpoolbaseEnabled;
        DeveloperCheckBox.IsChecked = AppSettings.DeveloperMode;
        ScriptActionsCheckBox.IsChecked = AppSettings.AllowScriptActions;
        AutoUpdateCheckBox.IsChecked = AppSettings.AutoUpdate;
        PrintFinishedCheckBox.IsChecked = AppSettings.NotifyPrintFinished;
        FinishingSoonCheckBox.IsChecked = AppSettings.NotifyFinishingSoon;
        PrinterErrorCheckBox.IsChecked = AppSettings.NotifyPrinterError;
        PrintPausedCheckBox.IsChecked = AppSettings.NotifyPrintPaused;
        LowFilamentCheckBox.IsChecked = AppSettings.NotifyLowFilament;
        HighHumidityCheckBox.IsChecked = AppSettings.NotifyHighAmsHumidity;
        CardFileNameCheckBox.IsChecked = AppSettings.CardShowFileName;
        CardProgressCheckBox.IsChecked = AppSettings.CardShowProgress;
        CardTempsCheckBox.IsChecked = AppSettings.CardShowTemperatures;
        CardFilamentsCheckBox.IsChecked = AppSettings.CardShowFilaments;
        CardSpoolGramsCheckBox.IsChecked = AppSettings.CardShowSpoolGrams;
        MonochromeCheckBox.IsChecked = AppSettings.Monochrome;
        QuietHoursCheckBox.IsChecked = QuietHours.Enabled;
        QuietStartBox.Text = MinutesToText(QuietHours.StartMinutes);
        QuietEndBox.Text = MinutesToText(QuietHours.EndMinutes);
        QuietTimesRow.IsEnabled = QuietHours.Enabled;
        RefreshWebSync();
        SupportButton.Click += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo("https://buycoffee.to/parametryczny") { UseShellExecute = true }); }
            catch { }
        };
        GitHubButton.Click += (_, _) => OpenUrl("https://github.com/parametryczny");
        XButton.Click += (_, _) => OpenUrl("https://x.com/_parametryczny");
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { }
    }

    private async Task TelegramTestAsync()
    {
        AppSettings.TelegramBotToken = TelegramTokenBox.Text.Trim();
        AppSettings.TelegramChatId = TelegramChatBox.Text.Trim();
        TelegramBot.Shared?.SyncWithSettings();
        var token = AppSettings.TelegramBotToken;
        var chat = AppSettings.TelegramChatId;
        if (token.Length == 0 || chat.Length == 0)
        {
            TelegramStatus.Text = AppSettings.T("Enter a token and chat_id.");
            return;
        }
        TelegramStatus.Text = AppSettings.T("Sending…");
        var text = TelegramService.Format("Gantry", AppSettings.T("Test notification"),
                                          AppSettings.T("The connection works."));
        bool ok = await TelegramService.SendMessageAsync(token, chat, text);
        TelegramStatus.Text = ok ? AppSettings.T("Sent ✓")
                                 : AppSettings.T("Failed. Check the token and chat_id.");
    }

    private async Task CheckUpdatesAsync()
    {
        CheckUpdatesButton.IsEnabled = false;
        UpdateStatus.Text = AppSettings.T("Checking…");
        try
        {
            var result = await UpdateChecker.LatestAsync();
            if (result is not { } r)
            {
                UpdateStatus.Text = AppSettings.T("Could not check.");
            }
            else if (r.IsNewer)
            {
                // Download, verify and install in-app (same path as auto-update), instead of just
                // sending the user to the GitHub page. Falls back to the page if there's no installer
                // asset or the download fails.
                if (!string.IsNullOrEmpty(r.Release.SetupUrl))
                {
                    UpdateStatus.Text = string.Format(AppSettings.T("Downloading {0}…"), r.Release.Version);
                    if (await UpdateChecker.DownloadAndInstallAsync(r.Release))
                    {
                        UpdateStatus.Text = AppSettings.T("Installing and restarting…");
                        System.Windows.Application.Current?.Shutdown();   // the helper installs + relaunches
                        return;
                    }
                    UpdateStatus.Text = AppSettings.T("Download failed — opening page…");
                }
                else
                {
                    UpdateStatus.Text = string.Format(AppSettings.T("Version {0} available — opening page…"), r.Release.Version);
                }
                try { Process.Start(new ProcessStartInfo(r.Release.PageUrl) { UseShellExecute = true }); } catch { }
            }
            else
            {
                UpdateStatus.Text = string.Format(AppSettings.T("You have the latest version ({0})."), UpdateChecker.CurrentVersion);
            }
        }
        finally
        {
            CheckUpdatesButton.IsEnabled = true;
        }
    }

    public Task CheckForUpdatesFromTrayAsync() => CheckUpdatesAsync();

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = GTheme.IsLight ? 0 : 1, round = 2, acrylic = 3;
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));    // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));   // DWMWA_WINDOW_CORNER_PREFERENCE
            DwmSetWindowAttribute(hwnd, 38, ref acrylic, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE
        }
        catch { /* older Windows — plain window is fine */ }
    }
}
