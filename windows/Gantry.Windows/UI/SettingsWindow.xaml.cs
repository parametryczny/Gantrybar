using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Gantry.Services;

namespace Gantry.UI;

public partial class SettingsWindow : Window
{
    /// Raised when the Transparency setting changes, so the tray owner can refresh the live flyout
    /// without a restart. Set by TrayIcon to re-apply the dashboard's acrylic tint immediately.
    public Action? OnTransparencyChanged;

    public SettingsWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => ApplyModernChrome();
        ApplyLanguage();
        LoadSettings();

        LanguageButton.Click += (_, _) =>
        {
            AppSettings.Polish = !AppSettings.Polish;
            ApplyLanguage();
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
        PrinterErrorCheckBox.Click += (_, _) => AppSettings.NotifyPrinterError = PrinterErrorCheckBox.IsChecked == true;
        PrintPausedCheckBox.Click += (_, _) => AppSettings.NotifyPrintPaused = PrintPausedCheckBox.IsChecked == true;
        LowFilamentCheckBox.Click += (_, _) => AppSettings.NotifyLowFilament = LowFilamentCheckBox.IsChecked == true;
        HighHumidityCheckBox.Click += (_, _) => AppSettings.NotifyHighAmsHumidity = HighHumidityCheckBox.IsChecked == true;
        CardFileNameCheckBox.Click += (_, _) => AppSettings.CardShowFileName = CardFileNameCheckBox.IsChecked == true;
        CardProgressCheckBox.Click += (_, _) => AppSettings.CardShowProgress = CardProgressCheckBox.IsChecked == true;
        CardTempsCheckBox.Click += (_, _) => AppSettings.CardShowTemperatures = CardTempsCheckBox.IsChecked == true;
        CardFilamentsCheckBox.Click += (_, _) => AppSettings.CardShowFilaments = CardFilamentsCheckBox.IsChecked == true;
        CheckUpdatesButton.Click += async (_, _) => await CheckUpdatesAsync();
        QuietHoursCheckBox.Click += (_, _) => { QuietHours.Enabled = QuietHoursCheckBox.IsChecked == true; QuietTimesRow.IsEnabled = QuietHoursCheckBox.IsChecked == true; };
        QuietStartBox.LostFocus += (_, _) => SaveQuietTimes();
        QuietEndBox.LostFocus += (_, _) => SaveQuietTimes();
        CloseButton.Click += (_, _) => Close();
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
        Title = AppSettings.Text("Ustawienia Gantry", "Gantry Settings");
        Heading.Text = AppSettings.Text("Ustawienia", "Settings");

        GeneralHeading.Text = AppSettings.Text("OGÓLNE", "GENERAL");
        LanguageLabel.Text = AppSettings.Text("Język", "Language");
        LanguageButton.Content = AppSettings.Polish ? "Polski" : "English";
        TransparencyLabel.Text = AppSettings.Text("Przezroczystość", "Transparency");
        TransparencyButton.Content = TransparencyName(AppSettings.PanelTransparency);
        StartupCheckBox.Content = AppSettings.Text("Uruchamiaj z Windows", "Start with Windows");
        SpoolbaseCheckBox.Content = AppSettings.Text("Spoolbase — magazyn filamentów", "Spoolbase — filament stock");
        DeveloperCheckBox.Content = AppSettings.Text("Tryb deweloperski (sterowanie + automatyzacje)", "Developer mode (control + automations)");
        ScriptActionsCheckBox.Content = AppSettings.Text("Zezwól automatyzacjom na skrypty i własne komendy", "Allow automations to run scripts and custom commands");
        ScriptActionsHint.Text = AppSettings.Text(
            "Wyłączone domyślnie ze względów bezpieczeństwa: uniemożliwia podrzuconej regule ciche uruchomienie kodu. Każda reguła i tak pyta o zgodę przy pierwszym odpaleniu.",
            "Off by default for safety: stops a planted rule from silently running code. Each rule still asks for confirmation the first time it fires.");
        AutoUpdateCheckBox.Content = AppSettings.Text("Automatycznie pobieraj i instaluj aktualizacje", "Download and install updates automatically");

        CardsHeading.Text = AppSettings.Text("KARTY DRUKAREK", "PRINTER CARDS");
        CardFileNameCheckBox.Content = AppSettings.Text("Nazwa pliku", "File name");
        CardProgressCheckBox.Content = AppSettings.Text("Postęp", "Progress");
        CardTempsCheckBox.Content = AppSettings.Text("Temperatury", "Temperatures");
        CardFilamentsCheckBox.Content = AppSettings.Text("Filamenty / AMS", "Filaments / AMS");

        NotificationsHeading.Text = AppSettings.Text("POWIADOMIENIA", "NOTIFICATIONS");
        PrintFinishedCheckBox.Content = AppSettings.Text("Druk zakończony", "Print finished");
        PrinterErrorCheckBox.Content = AppSettings.Text("Błąd drukarki", "Printer error");
        PrintPausedCheckBox.Content = AppSettings.Text("Druk wstrzymany", "Print paused");
        LowFilamentCheckBox.Content = AppSettings.Text("Niski poziom filamentu", "Low filament");
        HighHumidityCheckBox.Content = AppSettings.Text("Wysoka wilgotność AMS", "High AMS humidity");
        QuietHoursCheckBox.Content = AppSettings.Text("Godziny ciszy (bez powiadomień)", "Quiet hours (no notifications)");
        QuietFromLabel.Text = AppSettings.Text("od", "from");
        QuietToLabel.Text = AppSettings.Text("do", "to");

        UpdatesHeading.Text = AppSettings.Text("AKTUALIZACJE", "UPDATES");
        UpdateStatus.Text = AppSettings.Text($"Wersja {UpdateChecker.CurrentVersion}", $"Version {UpdateChecker.CurrentVersion}");
        CheckUpdatesButton.Content = AppSettings.Text("Sprawdź aktualizacje", "Check for updates");

        CloseButton.Content = AppSettings.Text("Zamknij", "Close");
    }

    private static string TransparencyName(int level) => level switch
    {
        0 => AppSettings.Text("Niska", "Low"),
        2 => AppSettings.Text("Wysoka", "High"),
        _ => AppSettings.Text("Średnia", "Medium"),
    };

    private void LoadSettings()
    {
        StartupCheckBox.IsChecked = LaunchAtLogin.IsEnabled;
        SpoolbaseCheckBox.IsChecked = AppSettings.SpoolbaseEnabled;
        DeveloperCheckBox.IsChecked = AppSettings.DeveloperMode;
        ScriptActionsCheckBox.IsChecked = AppSettings.AllowScriptActions;
        AutoUpdateCheckBox.IsChecked = AppSettings.AutoUpdate;
        PrintFinishedCheckBox.IsChecked = AppSettings.NotifyPrintFinished;
        PrinterErrorCheckBox.IsChecked = AppSettings.NotifyPrinterError;
        PrintPausedCheckBox.IsChecked = AppSettings.NotifyPrintPaused;
        LowFilamentCheckBox.IsChecked = AppSettings.NotifyLowFilament;
        HighHumidityCheckBox.IsChecked = AppSettings.NotifyHighAmsHumidity;
        CardFileNameCheckBox.IsChecked = AppSettings.CardShowFileName;
        CardProgressCheckBox.IsChecked = AppSettings.CardShowProgress;
        CardTempsCheckBox.IsChecked = AppSettings.CardShowTemperatures;
        CardFilamentsCheckBox.IsChecked = AppSettings.CardShowFilaments;
        QuietHoursCheckBox.IsChecked = QuietHours.Enabled;
        QuietStartBox.Text = MinutesToText(QuietHours.StartMinutes);
        QuietEndBox.Text = MinutesToText(QuietHours.EndMinutes);
        QuietTimesRow.IsEnabled = QuietHours.Enabled;
    }

    private async Task CheckUpdatesAsync()
    {
        CheckUpdatesButton.IsEnabled = false;
        UpdateStatus.Text = AppSettings.Text("Sprawdzam…", "Checking…");
        try
        {
            var result = await UpdateChecker.LatestAsync();
            if (result is not { } r)
            {
                UpdateStatus.Text = AppSettings.Text("Nie udało się sprawdzić.", "Could not check.");
            }
            else if (r.IsNewer)
            {
                // Download, verify and install in-app (same path as auto-update), instead of just
                // sending the user to the GitHub page. Falls back to the page if there's no installer
                // asset or the download fails.
                if (!string.IsNullOrEmpty(r.Release.SetupUrl))
                {
                    UpdateStatus.Text = AppSettings.Text($"Pobieram wersję {r.Release.Version}…",
                                                         $"Downloading {r.Release.Version}…");
                    if (await UpdateChecker.DownloadAndInstallAsync(r.Release))
                    {
                        UpdateStatus.Text = AppSettings.Text("Instaluję i uruchamiam ponownie…",
                                                             "Installing and restarting…");
                        System.Windows.Application.Current?.Shutdown();   // the helper installs + relaunches
                        return;
                    }
                    UpdateStatus.Text = AppSettings.Text("Nie udało się pobrać — otwieram stronę…",
                                                         "Download failed — opening page…");
                }
                else
                {
                    UpdateStatus.Text = AppSettings.Text($"Dostępna wersja {r.Release.Version} — otwieram stronę…",
                                                         $"Version {r.Release.Version} available — opening page…");
                }
                try { Process.Start(new ProcessStartInfo(r.Release.PageUrl) { UseShellExecute = true }); } catch { }
            }
            else
            {
                UpdateStatus.Text = AppSettings.Text($"Masz najnowszą wersję ({UpdateChecker.CurrentVersion}).",
                                                     $"You have the latest version ({UpdateChecker.CurrentVersion}).");
            }
        }
        finally
        {
            CheckUpdatesButton.IsEnabled = true;
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = 1, round = 2, acrylic = 3;
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));    // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));   // DWMWA_WINDOW_CORNER_PREFERENCE
            DwmSetWindowAttribute(hwnd, 38, ref acrylic, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE
        }
        catch { /* older Windows — plain window is fine */ }
    }
}
