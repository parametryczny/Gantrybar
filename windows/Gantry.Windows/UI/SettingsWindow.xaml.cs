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
    public Action? OnWindowModeChanged;
    public Action? OnCardScaleChanged;

    public SettingsWindow(PrinterStore? store = null)
    {
        _store = store;
        InitializeComponent();
        SourceInitialized += (_, _) => ApplyModernChrome();
        // SizeToContent="Height" in the XAML is what makes the window fit the pane on screen: the
        // top edge stays put and the bottom moves. This only stops a very tall pane on a short
        // screen from growing past the desktop — it then scrolls inside its own pane instead.
        Loaded += (_, _) => MaxHeight = SystemParameters.WorkArea.Height - 80;
        ApplyThemeVisuals();
        ApplyLanguage();
        LoadSettings();
        ApplyEditionVisibility();
        FloatingWindowCheckBox.Content = AppSettings.T("Show Gantry in a floating window");
        AlwaysOnTopCheckBox.Content = AppSettings.T("Always on top");
        FloatingWindowCheckBox.IsChecked = AppSettings.FloatingWindowEnabled;
        AlwaysOnTopCheckBox.IsChecked = Defaults.GetBool("floating-window-always-on-top", true);
        FloatingWindowCheckBox.Click += (_, _) =>
        {
            AppSettings.FloatingWindowEnabled = FloatingWindowCheckBox.IsChecked == true;
            OnWindowModeChanged?.Invoke();
        };
        AlwaysOnTopCheckBox.Click += (_, _) =>
        {
            Defaults.SetBool("floating-window-always-on-top", AlwaysOnTopCheckBox.IsChecked == true);
            OnWindowModeChanged?.Invoke();
        };

        PaneList.SelectionChanged += (_, _) => ShowPane(PaneList.SelectedIndex);
        ShowPane(0);

        LanguageButton.Click += (_, _) =>
        {
            // Cycles through the installed catalogs; the button label shows the current one.
            var codes = Translations.Available().Select(entry => entry.Code).ToList();
            int index = codes.IndexOf(AppSettings.Language);
            AppSettings.Language = codes[(index < 0 ? 0 : index + 1) % codes.Count];
            ApplyLanguage();
            RefreshWeb();
        };
        DockEnableCheckBox.Click += (_, _) =>
        {
            AppSettings.EdgeDockEnabled = DockEnableCheckBox.IsChecked == true;
            ApplyDockEnabledState();
            OnEdgeDockChanged?.Invoke();
        };
        // Cycles through the displays, like the other choice buttons in this window; the label names the
        // current one. From an unplugged display it goes back to the main one.
        DockDisplayButton.Click += (_, _) =>
        {
            var choices = EdgeDockPlacement.Choices(EdgeDockWindow.ConnectedDisplays(), AppSettings.EdgeDockDisplay,
                AppSettings.EdgeDockDisplayName, AppSettings.T);
            int index = choices.FindIndex(choice => choice.Selected);
            EdgeDockWindow.ChooseDisplay(choices[(index + 1) % choices.Count].Id);
            RefreshDockPlacement();
            OnEdgeDockChanged?.Invoke();
        };
        DockPositionPicker.MouseLeftButtonDown += (_, e) =>
        {
            if (!AppSettings.EdgeDockEnabled) return;
            var point = e.GetPosition(DockPositionPicker);
            double best = 18;
            (bool Left, string Row)? pick = null;
            foreach (bool left in new[] { true, false })
                foreach (var row in DockRows)
                {
                    var (x, y) = DockSquare(left, row);
                    double distance = Math.Sqrt((x - point.X) * (x - point.X) + (y - point.Y) * (y - point.Y));
                    if (distance <= best) { best = distance; pick = (left, row); }
                }
            if (pick is not { } chosen) return;
            AppSettings.EdgeDockEdge = chosen.Left ? "left" : "right";
            AppSettings.EdgeDockRow = chosen.Row;
            RefreshDockPlacement();
            OnEdgeDockChanged?.Invoke();
        };
        DockSizeMinusButton.Click += (_, _) => ChangeDockScale(-5);
        DockSizePlusButton.Click += (_, _) => ChangeDockScale(5);
        CardSizeMinusButton.Click += (_, _) => ChangeCardScale(-5);
        CardSizePlusButton.Click += (_, _) => ChangeCardScale(5);
        DockOnlyPrintingCheckBox.Click += (_, _) =>
        {
            AppSettings.EdgeDockOnlyPrinting = DockOnlyPrintingCheckBox.IsChecked == true;
            OnEdgeDockChanged?.Invoke();
        };
        DockPinnedCheckBox.Click += (_, _) =>
        {
            AppSettings.EdgeDockPinned = DockPinnedCheckBox.IsChecked == true;
            OnEdgeDockChanged?.Invoke();
        };
        DockCameraCheckBox.Click += (_, _) =>
        {
            AppSettings.EdgeDockCamera = DockCameraCheckBox.IsChecked == true;
            ApplyDockEnabledState();
            OnEdgeDockChanged?.Invoke();
        };
        // The strip pins and releases itself too; keep this box honest while the window is open.
        EdgeDockWindow.PinnedChanged += SyncDockPinned;
        Closed += (_, _) => EdgeDockWindow.PinnedChanged -= SyncDockPinned;
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
        PrinterControlCheckBox.Click += (_, _) => AppSettings.PrinterControlEnabled = PrinterControlCheckBox.IsChecked == true;
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
        CardDetailsChipCheckBox.Click += (_, _) => AppSettings.CardShowDetailsChip = CardDetailsChipCheckBox.IsChecked == true;
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
            RefreshWeb();
        };
    }

    /// <summary>Hides everything the LITE edition does not ship: the Integrations and Advanced panes
    /// (developer mode, Telegram, web dashboard), Spoolbase, updates, the floating window, the edge
    /// dock and the two card rows that belong to Spoolbase and the detail view. The handlers stay
    /// wired and the controls are still LOADED — they read the stored value and would write back
    /// exactly what they read — so a full Gantry sharing this machine is never edited behind the
    /// user's back. They are simply unreachable.</summary>
    private void ApplyEditionVisibility()
    {
        if (Build.HasExtras) return;
        PaneItemIntegrations.Visibility = PaneItemAdvanced.Visibility = Visibility.Collapsed;
        SpoolbaseCheckBox.Visibility = Visibility.Collapsed;
        UpdatesHeading.Visibility = UpdatesCard.Visibility = UpdatesRule.Visibility = Visibility.Collapsed;
        FloatingWindowRow.Visibility = Visibility.Collapsed;
        CardSpoolGramsCheckBox.Visibility = Visibility.Collapsed;
        CardDetailsChipCheckBox.Visibility = Visibility.Collapsed;
        DockHeading.Visibility = DockCard.Visibility = DockRule.Visibility =
            DockHint.Visibility = Visibility.Collapsed;
    }

    // Panes in the contract's order, the same six the macOS window shows.
    private System.Windows.Controls.ScrollViewer[] Panes => new[]
    {
        PageGeneral, PageAppearance, PageNotifications, PageWindows, PageIntegrations, PageAdvanced,
    };

    private static readonly string[] PaneTitleKeys =
    {
        "General", "Appearance", "Notifications", "Windows and strip", "Integrations", "Advanced",
    };

    /// <summary>For the edge strip's settings button: whoever clicks it came for the strip's options.</summary>
    public void SelectWindowsPane() => PaneList.SelectedItem = PaneItemWindows;

    private void ShowPane(int index)
    {
        var panes = Panes;
        if (index < 0 || index >= panes.Length) index = 0;
        for (int i = 0; i < panes.Length; i++)
            panes[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;
        // The window title names the active pane, so the taskbar and Alt+Tab read correctly too.
        Title = $"{Build.AppName} — {AppSettings.T(PaneTitleKeys[index])}";
    }

    private void SyncDockPinned() => Dispatcher.Invoke(() => DockPinnedCheckBox.IsChecked = AppSettings.EdgeDockPinned);

    private static readonly string[] DockRows = { "top", "middle", "bottom" };

    /// <summary>Centre of one square in the position picker: three down each side of a small screen.</summary>
    private (double X, double Y) DockSquare(bool left, string row)
    {
        double fraction = row == "top" ? EdgeDockPlacement.RowMargin : row == "bottom" ? 1 - EdgeDockPlacement.RowMargin : 0.5;
        return (left ? 14 : DockPositionPicker.Width - 14, DockPositionPicker.Height * fraction);
    }

    /// <summary>The display button's label and the picker, drawn the way macOS and GNU/Linux draw it: the
    /// screen, the strip flush with its side, and six squares with the chosen one larger.</summary>
    private void RefreshDockPlacement()
    {
        var choices = EdgeDockPlacement.Choices(EdgeDockWindow.ConnectedDisplays(), AppSettings.EdgeDockDisplay,
            AppSettings.EdgeDockDisplayName, AppSettings.T);
        DockDisplayButton.Content = choices.FirstOrDefault(choice => choice.Selected).Title ?? choices[0].Title;

        var canvas = DockPositionPicker;
        canvas.Children.Clear();
        // Mid grey reads on both themes; the chosen square takes the system accent.
        var grey = Color.FromRgb(0x8A, 0x8F, 0x98);
        SolidColorBrush Grey(double alpha) => new(Color.FromArgb((byte)(alpha * 255), grey.R, grey.G, grey.B));
        canvas.Children.Add(new System.Windows.Controls.Border
        {
            Width = canvas.Width, Height = canvas.Height, CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1), BorderBrush = Grey(0.45), Background = Grey(0.08),
        });
        bool left = AppSettings.EdgeDockEdge == "left";
        string row = AppSettings.EdgeDockRow;
        var (_, selectedY) = DockSquare(left, row);
        double stripTop = row == "top" ? selectedY - 4 : row == "bottom" ? selectedY + 4 - 24 : selectedY - 12;
        var strip = new System.Windows.Controls.Border { Width = 5, Height = 24, CornerRadius = new CornerRadius(2.5), Background = Grey(0.7) };
        System.Windows.Controls.Canvas.SetLeft(strip, left ? 2 : canvas.Width - 7);
        System.Windows.Controls.Canvas.SetTop(strip, stripTop);
        canvas.Children.Add(strip);
        foreach (bool side in new[] { true, false })
            foreach (var place in DockRows)
            {
                bool chosen = side == left && place == row;
                double size = chosen ? 12 : 9;
                var (x, y) = DockSquare(side, place);
                var square = new System.Windows.Controls.Border
                {
                    Width = size, Height = size, CornerRadius = new CornerRadius(2.5),
                    Background = chosen ? SystemColors.HighlightBrush : Grey(0.5),
                };
                System.Windows.Controls.Canvas.SetLeft(square, x - size / 2);
                System.Windows.Controls.Canvas.SetTop(square, y - size / 2);
                canvas.Children.Add(square);
            }
        canvas.ToolTip = EdgeDockPlacement.PositionTitle(left, row, AppSettings.T);
    }

    /// Dims the whole dock section, not just the switches, so an off strip reads as inactive.
    private void ApplyDockEnabledState()
    {
        bool on = AppSettings.EdgeDockEnabled;
        DockDisplayButton.IsEnabled = on;
        DockPositionPicker.IsEnabled = on;
        DockSizeMinusButton.IsEnabled = on && AppSettings.EdgeDockScalePercent > 100;
        DockSizePlusButton.IsEnabled = on && AppSettings.EdgeDockScalePercent < 150;
        DockSizeValue.Opacity = on ? 1 : 0.45;
        DockOnlyPrintingCheckBox.IsEnabled = on;
        DockPinnedCheckBox.IsEnabled = on;
        DockCameraCheckBox.IsEnabled = on;
        // A picture only makes sense while the strip is on and the camera switch is too.
        bool cameras = on && AppSettings.EdgeDockCamera;
        DockCamerasList.IsEnabled = cameras;
        DockCamerasList.Opacity = cameras ? 1 : 0.45;
        DockCamerasCaption.Opacity = cameras ? 1 : 0.45;
        DockCameraNote.Opacity = on ? 1 : 0.45;
        DockPrintersList.IsEnabled = on;
        DockPrintersList.Opacity = on ? 1 : 0.45;
        DockDisplayButton.Opacity = DockPositionPicker.Opacity = on ? 1 : 0.45;
    }

    private void ChangeDockScale(int delta)
    {
        AppSettings.EdgeDockScalePercent += delta;
        DockSizeValue.Text = $"{AppSettings.EdgeDockScalePercent}%";
        ApplyDockEnabledState();
        OnEdgeDockChanged?.Invoke();
    }

    private void ChangeCardScale(int delta)
    {
        AppSettings.CardScalePercent += delta;
        CardSizeValue.Text = $"{AppSettings.CardScalePercent}%";
        CardSizeMinusButton.IsEnabled = AppSettings.CardScalePercent > 75;
        CardSizePlusButton.IsEnabled = AppSettings.CardScalePercent < 150;
        OnCardScaleChanged?.Invoke();
    }

    /// One check box per printer, a plain column under its caption — no card, no rules between the
    /// rows. The serial rides in the control's Tag because the list is rebuilt whenever the window
    /// refreshes, so a captured index would go stale.
    private void RebuildDockPrinters()
    {
        DockPrintersList.Children.Clear();
        DockCamerasList.Children.Clear();
        var printers = _store?.Printers ?? new List<Gantry.Models.SavedPrinter>();
        if (printers.Count == 0)
        {
            DockPrintersList.Children.Add(new System.Windows.Controls.TextBlock
            {
                Text = AppSettings.T("No printers"),
                Foreground = GTheme.Brush(GTheme.Muted),
                FontSize = 12,
            });
            return;
        }
        var hidden = AppSettings.EdgeDockHiddenPrinters;
        foreach (var printer in printers)
        {
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

            // A brand with no stream Gantry can decode is simply not offered the choice, rather than
            // being listed with a box that can never do anything. Same rule as macOS.
            if (!DockCameraFeed.SupportsCamera(printer.Kind)) continue;
            var camera = new System.Windows.Controls.CheckBox
            {
                Content = printer.Name,
                Tag = printer.Serial,
                IsChecked = AppSettings.EdgeDockCameraSerials.Contains(printer.Serial),
            };
            camera.Click += (sender, _) =>
            {
                if (sender is not System.Windows.Controls.CheckBox box || box.Tag is not string serial) return;
                var set = AppSettings.EdgeDockCameraSerials;
                if (box.IsChecked == true) set.Add(serial); else set.Remove(serial);
                AppSettings.EdgeDockCameraSerials = set;
                OnEdgeDockChanged?.Invoke();
            };
            DockCamerasList.Children.Add(camera);
        }
    }

    private void RefreshWeb()
    {
        WebHeading.Text = AppSettings.T("Web dashboard");
        WebAddressCaption.Text = AppSettings.T("Address");
        WebHint.Text = AppSettings.T("Open on a phone on the same Wi-Fi. View only, no control.");
        WebDashboardCheckBox.Content = AppSettings.T("Preview server (local network)");
        WebDashboardCheckBox.IsChecked = AppSettings.WebDashboardEnabled;
        var ip = GantryWebServer.LocalIPv4();
        WebAddressLabel.Text = ip != null ? $"http://{ip}:{GantryWebServer.Port}" : AppSettings.T("no IP address");
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
        // Sidebar rows, in the contract's order.
        PaneItemGeneral.Content = AppSettings.T("General");
        PaneItemAppearance.Content = AppSettings.T("Appearance");
        PaneItemNotifications.Content = AppSettings.T("Notifications");
        PaneItemWindows.Content = AppSettings.T("Windows and strip");
        PaneItemIntegrations.Content = AppSettings.T("Integrations");
        PaneItemAdvanced.Content = AppSettings.T("Advanced");
        Title = $"{Build.AppName} — {AppSettings.T(PaneTitleKeys[PaneList.SelectedIndex < 0 ? 0 : PaneList.SelectedIndex])}";

        GeneralHeading.Text = AppSettings.T("Options");
        LanguageLabel.Text = AppSettings.T("Language");
        LanguageButton.Content = Translations.Available()
            .FirstOrDefault(entry => entry.Code == AppSettings.Language)?.Name ?? AppSettings.Language;
        ThemeLabel.Text = AppSettings.T("Appearance");
        ThemeButton.Content = AppSettings.Theme == "dark" ? AppSettings.T("Dark") : AppSettings.T("Light");
        TransparencyLabel.Text = AppSettings.T("Transparency");
        TransparencyButton.Content = TransparencyName(AppSettings.PanelTransparency);
        StartupCheckBox.Content = AppSettings.T("Start with Windows");
        SpoolbaseCheckBox.Content = AppSettings.T("Spoolbase — filament stock");
        PrinterControlCheckBox.Content = AppSettings.T("Printer control");
        PrinterControlHint.Text = AppSettings.T("Enables temperature, fan and speed controls in Details. Off by default.");
        DeveloperCheckBox.Content = AppSettings.T("Developer mode (control + automations)");
        ScriptActionsCheckBox.Content = AppSettings.T("Allow automations to run scripts and custom commands");
        ScriptActionsHint.Text = AppSettings.T("Off by default for safety: stops a planted rule from silently running code. Each rule still asks for confirmation the first time it fires.");
        AutoUpdateCheckBox.Content = AppSettings.T("Download and install updates automatically");

        CardsHeading.Text = AppSettings.T("Printer cards");
        CardContentCaption.Text = AppSettings.T("Show on the card");
        CardSizeLabel.Text = AppSettings.T("Card size");
        CardSizeValue.Text = $"{AppSettings.CardScalePercent}%";
        CardSizeMinusButton.IsEnabled = AppSettings.CardScalePercent > 75;
        CardSizePlusButton.IsEnabled = AppSettings.CardScalePercent < 150;
        CardFileNameCheckBox.Content = AppSettings.T("File name");
        CardProgressCheckBox.Content = AppSettings.T("Progress");
        CardTempsCheckBox.Content = AppSettings.T("Temperatures");
        CardFilamentsCheckBox.Content = AppSettings.T("Filaments / AMS");
        CardSpoolGramsCheckBox.Content = AppSettings.T("Grams on spool (AMS NFC / Spoolbase)");
        CardDetailsChipCheckBox.Content = AppSettings.T("Details chip on the card");
        CardDetailsChipCheckBox.ToolTip = AppSettings.T("Shortcut to the detail view; the ⋯ menu always has it");
        MonochromeCheckBox.Content = AppSettings.T("Monochrome colours");

        NotificationsHeading.Text = AppSettings.T("Notify me");
        QuietHeading.Text = AppSettings.T("Quiet hours");
        QuietRangeCaption.Text = AppSettings.T("Hours");
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

        TelegramHeading.Text = "Telegram";
        TelegramEnableCheckBox.Content = AppSettings.T("Send notifications to Telegram");
        TelegramTokenLabel.Text = AppSettings.T("Bot token");
        TelegramChatLabel.Text = "Chat ID";
        TelegramTestCaption.Text = AppSettings.T("Test");
        TelegramTestButton.Content = AppSettings.T("Send test");
        TelegramHint.Text = AppSettings.T("Create a bot via @BotFather (token), message it, and get your chat_id from @userinfobot. Sends the same events as above + chat commands (/help).");
        TelegramEnableCheckBox.IsChecked = AppSettings.TelegramEnabled;
        TelegramTokenBox.Text = AppSettings.TelegramBotToken;
        TelegramChatBox.Text = AppSettings.TelegramChatId;
        TelegramTokenBox.IsEnabled = AppSettings.TelegramEnabled;
        TelegramChatBox.IsEnabled = AppSettings.TelegramEnabled;
        TelegramTestButton.IsEnabled = AppSettings.TelegramEnabled;

        UpdatesHeading.Text = AppSettings.T("Updates");
        UpdateCaption.Text = AppSettings.T("Updates");
        UpdateStatus.Text = string.Format(AppSettings.T("Version {0}"), UpdateChecker.CurrentVersion);
        CheckUpdatesButton.Content = AppSettings.T("Check for updates");

        AboutHeading.Text = AppSettings.T("About Gantry");
        AboutCaption.Text = AppSettings.T("Version");
        AboutVersion.Text = $"{Build.AppName} · {AppSettings.T("version")} {UpdateChecker.CurrentVersion} · DPAPI";
        AboutAuthor.Text = "@_parametryczny";
        GitHubButton.Content = "GitHub";
        XButton.Content = "@_parametryczny";
        SupportButton.Content = AppSettings.T("☕  Support the project");
        SupportSubtitle.Text = AppSettings.T("A virtual coffee gives me a caffeine kick to keep improving Gantry. 🚀");

        DeveloperHeading.Text = AppSettings.T("Features");
        FloatingWindowCaption.Text = AppSettings.T("Floating window");
        DockBehaviourCaption.Text = AppSettings.T("Behaviour");

        DockHeading.Text = AppSettings.T("Edge dock");
        DockEnableCheckBox.Content = AppSettings.T("Show the strip on top");
        DockEnableCheckBox.IsChecked = AppSettings.EdgeDockEnabled;
        DockDisplayLabel.Text = AppSettings.T("Monitor");
        DockPositionLabel.Text = AppSettings.T("Position");
        RefreshDockPlacement();
        DockSizeLabel.Text = AppSettings.T("Edge dock size");
        DockSizeValue.Text = $"{AppSettings.EdgeDockScalePercent}%";
        DockOnlyPrintingCheckBox.Content = AppSettings.T("Only printing");
        DockOnlyPrintingCheckBox.IsChecked = AppSettings.EdgeDockOnlyPrinting;
        DockPinnedCheckBox.Content = AppSettings.T("Keep the strip open");
        DockPinnedCheckBox.IsChecked = AppSettings.EdgeDockPinned;
        DockCameraCheckBox.Content = AppSettings.T("Camera under the strip");
        DockCameraCheckBox.IsChecked = AppSettings.EdgeDockCamera;
        DockCameraNote.Text = AppSettings.T("With nothing picked it follows the printer that is printing. Pick printers below and each picture sits under its own row.");
        DockCamerasCaption.Text = AppSettings.T("Camera for");
        DockPrintersCaption.Text = AppSettings.T("Printers");
        DockHint.Text = AppSettings.T("A narrow strip pinned to the screen edge, always on top. Hovering expands it to names, clicking opens details.");
        RebuildDockPrinters();
        ApplyDockEnabledState();
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
        // Opaque: the window now has a real frame and no AllowsTransparency, so a translucent
        // background would composite against black instead of the desktop.
        Resources["SettingsPanelBrush"] = GTheme.Brush(GTheme.Card);
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
        PrinterControlCheckBox.IsChecked = AppSettings.PrinterControlEnabled;
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
        CardDetailsChipCheckBox.IsChecked = AppSettings.CardShowDetailsChip;
        MonochromeCheckBox.IsChecked = AppSettings.Monochrome;
        QuietHoursCheckBox.IsChecked = QuietHours.Enabled;
        QuietStartBox.Text = MinutesToText(QuietHours.StartMinutes);
        QuietEndBox.Text = MinutesToText(QuietHours.EndMinutes);
        QuietTimesRow.IsEnabled = QuietHours.Enabled;
        RefreshWeb();
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
