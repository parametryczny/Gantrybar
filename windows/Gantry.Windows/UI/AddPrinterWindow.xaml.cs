using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

public partial class AddPrinterWindow : Window
{
    private readonly PrinterStore _store;
    private readonly SavedPrinter? _editing;
    // True while RefreshDetected re-selects the previously selected row after a rescan, so the
    // programmatic re-selection doesn't overwrite fields the user is currently editing.
    private bool _restoringSelection;

    public AddPrinterWindow(PrinterStore store, SavedPrinter? editing = null)
    {
        InitializeComponent();
        SourceInitialized += (_, _) => ApplyModernChrome();
        _store = store;
        _editing = editing;

        Localize();

        if (editing is not null)
        {
            NameBox.Text = editing.Name;
            HostBox.Text = editing.Host;
            SerialBox.Text = editing.Serial;
            CodeBox.Text = "";
            // The printer kind cannot change once added; lock the selector to the saved type.
            TypeSection.Visibility = Visibility.Collapsed;
            PortBox.Text = editing.Port?.ToString() ?? "";   // Bambu too (tunnel port)
            if (editing.Kind != PrinterKind.Bambu)
            {
                if (editing.Kind is PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2)
                {
                    ElegooRadio.IsChecked = true; ElegooModelBox.SelectedIndex = editing.Kind == PrinterKind.ElegooCc2 ? 1 : 0;
                    if (editing.Kind == PrinterKind.ElegooCc2) CodeBox.Text = AccessCodeStore.AccessCode(editing.Serial) ?? "";
                }
                else if (editing.Kind == PrinterKind.Klipper) KlipperRadio.IsChecked = true;
                else if (editing.Kind == PrinterKind.AnycubicKobraS1) AnycubicRadio.IsChecked = true;
                else if (editing.Kind == PrinterKind.Snapmaker) SnapmakerRadio.IsChecked = true;
                else PrusaRadio.IsChecked = true;
                // The key now lives in DPAPI, not the config — prefill from there so editing keeps
                // it. A legacy config may still carry it inline; prefer that if present.
                if (editing.Kind is PrinterKind.Klipper or PrinterKind.Prusa)
                    ApiKeyBox.Text = editing.ApiKey ?? AccessCodeStore.AccessCode(editing.Serial) ?? "";
            }
            // The tray-pin checkbox is offered only when editing a saved printer (its serial is known).
            ProgressCheck.Visibility = Visibility.Visible;
            ProgressCheck.IsChecked = TrayProgressPreference.IsEnabled(editing.Serial);
        }

        BambuRadio.Checked += (_, _) => ApplyKind();
        ElegooRadio.Checked += (_, _) => ApplyKind();
        AnycubicRadio.Checked += (_, _) => ApplyKind();
        KlipperRadio.Checked += (_, _) => ApplyKind();
        PrusaRadio.Checked += (_, _) => ApplyKind();
        SnapmakerRadio.Checked += (_, _) => ApplyKind();
        ElegooModelBox.SelectionChanged += (_, _) => { ApplyKind(); RefreshDetected(); };
        ScanButton.Click += (_, _) => _store.Scan();
        ImportButton.Click += (_, _) => ImportFromStudio();
        // Reading the slicer config is opt-in: it holds access codes, so gate the button on consent.
        ImportConsent.Checked += (_, _) => ImportButton.IsEnabled = true;
        ImportConsent.Unchecked += (_, _) => ImportButton.IsEnabled = false;
        SubnetTargetsBox.LostFocus += (_, _) => SaveSubnetTargets();
        SubnetTargetsBox.TextChanged += (_, _) => ValidateSubnetTargets();
        SaveButton.Click += (_, _) => Save();
        CancelButton.Click += (_, _) => Close();
        DetectedList.SelectionChanged += OnDetectedSelected;
        ApplyKind();
        GTheme.ApplyWindowTheme(this);
        Background = System.Windows.Media.Brushes.Transparent;

        _store.Updated += OnStoreUpdated;
        Closed += (_, _) => _store.Updated -= OnStoreUpdated;
        RefreshDetected();
    }

    private void Localize()
    {
        Title = _editing is null ? AppSettings.T("Add printer") : AppSettings.T("Edit printer");
        Heading.Text = Title;
        DetectedLabel.Text = AppSettings.T("Detected printers");
        ImportButton.Content = AppSettings.T("Import from Bambu Studio");
        ImportConsent.Content = AppSettings.T("Allow reading the Bambu Studio configuration");
        ImportHint.Text = AppSettings.T("Speeds up adding, but reads the local slicer file containing access codes. Nothing is read until you tick this.");
        SubnetTargetsLabel.Text = AppSettings.T("Printer not listed? Extra scan targets (VPN):");
        SubnetTargetsHint.Text = string.Format(AppSettings.T("Bambu is found on the local network. Add a printer outside the LAN (e.g. over Tailscale) by its address here, then click ⟳. A single address (best), an a-b range or CIDR /n. Large ranges are rejected (limit {0})."), SubnetTargets.MaxHosts);
        if (!SubnetTargetsBox.IsKeyboardFocusWithin) SubnetTargetsBox.Text = AppSettings.SubnetScanTargets;
        ValidateSubnetTargets();
        NameLabel.Text = AppSettings.T("Name (optional)");
        HostLabel.Text = AppSettings.T("IP address");
        SerialLabel.Text = AppSettings.T("Serial number");
        CodeLabel.Text = AppSettings.T("Access Code / PIN");
        BambuRadio.Content = "Bambu";
        ElegooRadio.Content = "Elegoo";
        AnycubicRadio.Content = "Anycubic";
        KlipperRadio.Content = "Klipper";
        PrusaRadio.Content = "Prusa";
        SnapmakerRadio.Content = "Snapmaker";
        ElegooModelLabel.Text = AppSettings.T("Elegoo model");
        SnapmakerHint.Text = AppSettings.T("Snapmaker 2.0 / Artisan (HTTP, port 8080). After adding, the PRINTER SCREEN shows a permission request — tap “Allow” to authorize. Re-authorize after each power cycle.");
        AnycubicHint.Text = AppSettings.T("Anycubic Kobra S1: enter its IP address and enable LAN mode on the printer. Gantry obtains MQTT settings automatically through port 18910. FLV camera: port 18088.");
        ApiKeyLabel.Text = AppSettings.T("API key (optional)");
        CancelButton.Content = AppSettings.T("Cancel");
        SaveButton.Content = _editing is null ? AppSettings.T("Add") : AppSettings.T("Save");
        ProgressCheck.Content = AppSettings.T("Show this printer's progress in the tray");
    }

    private bool IsKlipper => KlipperRadio.IsChecked == true;
    private bool IsPrusa => PrusaRadio.IsChecked == true;
    private bool IsSnapmaker => SnapmakerRadio.IsChecked == true;
    private bool IsElegoo => ElegooRadio.IsChecked == true;
    private bool IsAnycubic => AnycubicRadio.IsChecked == true;
    private bool IsElegooCc2 => IsElegoo && ElegooModelBox.SelectedIndex == 1;
    // Klipper, Prusa and Snapmaker all connect over HTTP with a host + port.
    private bool UsesHostFields => IsKlipper || IsPrusa || IsSnapmaker || IsAnycubic;

    /// <summary>Shows only the fields relevant to the selected printer kind. Klipper/Prusa need a
    /// host, optional port and API key; Bambu needs discovery, serial and access code.</summary>
    private void ApplyKind()
    {
        bool hostBased = UsesHostFields;
        ElegooModelSection.Visibility = IsElegoo ? Visibility.Visible : Visibility.Collapsed;
        DiscoverySection.Visibility = (hostBased || _editing is not null) ? Visibility.Collapsed : Visibility.Visible;
        SerialLabel.Visibility = SerialBox.Visibility = hostBased ? Visibility.Collapsed : Visibility.Visible;
        CodeLabel.Visibility = CodeBox.Visibility = (hostBased || (IsElegoo && !IsElegooCc2)) ? Visibility.Collapsed : Visibility.Visible;
        PortLabel.Visibility = PortBox.Visibility = Visibility.Visible;   // Bambu too (optional — tunnels)
        // Snapmaker authorizes via the touchscreen — no API key field.
        ApiKeyLabel.Visibility = ApiKeyBox.Visibility = (hostBased && !IsSnapmaker && !IsAnycubic) ? Visibility.Visible : Visibility.Collapsed;
        SnapmakerHintBox.Visibility = IsSnapmaker ? Visibility.Visible : Visibility.Collapsed;
        AnycubicHintBox.Visibility = IsAnycubic ? Visibility.Visible : Visibility.Collapsed;
        bool isBambu = BambuRadio.IsChecked == true;
        ImportConsent.Visibility = ImportHint.Visibility = ImportButton.Visibility = isBambu ? Visibility.Visible : Visibility.Collapsed;
        SubnetTargetsLabel.Visibility = SubnetTargetsBox.Visibility = SubnetTargetsError.Visibility = SubnetTargetsHint.Visibility = isBambu ? Visibility.Visible : Visibility.Collapsed;
        HostLabel.Text = hostBased
            ? AppSettings.T("IP address / host name")
            : AppSettings.T("IP address");
        PortLabel.Text = IsPrusa
            ? AppSettings.T("PrusaLink port (default 80)")
            : IsKlipper
                ? AppSettings.T("Moonraker port (default 7125)")
                : IsSnapmaker
                    ? AppSettings.T("Snapmaker port (default 8080)")
                    : IsAnycubic
                        ? AppSettings.T("Anycubic bootstrap port (18910)")
                    : IsElegooCc2
                        ? AppSettings.T("Elegoo MQTT port (default 1883)")
                        : IsElegoo
                            ? AppSettings.T("SDCP port (default 3030)")
                    : AppSettings.T("Port (usually 8883 — change for a tunnel, e.g. socat)");
        if (IsElegooCc2) CodeLabel.Text = AppSettings.T("Elegoo access code (LAN-only)");
        else if (!IsElegoo) CodeLabel.Text = AppSettings.T("Access Code / PIN");
        ApiKeyLabel.Text = IsPrusa
            ? AppSettings.T("PrusaLink API key")
            : AppSettings.T("API key (optional)");
    }

    private void OnStoreUpdated(object? sender, EventArgs e) => Dispatcher.Invoke(RefreshDetected);

    private void RefreshDetected()
    {
        if (_editing is not null) return;
        var selectedSerial = (DetectedList.SelectedItem as DiscoveredItem)?.Printer.Serial;
        DetectedList.Items.Clear();
        var expectedKind = IsElegoo ? (IsElegooCc2 ? PrinterKind.ElegooCc2 : PrinterKind.ElegooCc1) : PrinterKind.Bambu;
        var filtered = _store.Discovered.Where(value => value.Kind == expectedKind).ToList();
        foreach (var d in filtered)
            DetectedList.Items.Add(new DiscoveredItem(d));
        DetectedLabel.Text = _store.IsScanning
            ? AppSettings.T("Scanning…")
            : string.Format(AppSettings.T("Detected printers ({0})"), filtered.Count);
        if (selectedSerial is not null)
        {
            _restoringSelection = true;
            foreach (DiscoveredItem item in DetectedList.Items)
                if (item.Printer.Serial == selectedSerial) { DetectedList.SelectedItem = item; break; }
            _restoringSelection = false;
        }
    }

    private void OnDetectedSelected(object? sender, SelectionChangedEventArgs e)
    {
        if (_restoringSelection) return;   // a rescan re-selecting the row must not clobber edits
        if (DetectedList.SelectedItem is DiscoveredItem item)
        {
            NameBox.Text = item.Printer.Name;
            HostBox.Text = item.Printer.Host;
            SerialBox.Text = item.Printer.Serial;
            if (item.Printer.Kind is PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2)
                ElegooModelBox.SelectedIndex = item.Printer.Kind == PrinterKind.ElegooCc2 ? 1 : 0;
            CodeBox.Focus();
        }
    }

    private void ImportFromStudio()
    {
        // Defensive: never read the slicer config without explicit consent.
        if (ImportConsent.IsChecked != true) return;
        try
        {
            int count = _store.ImportFromBambuStudio();
            MessageBox.Show(this, string.Format(AppSettings.T("Imported printers: {0}"), count), "Gantry");
            Close();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void Save()
    {
        try
        {
            int? port = null;
            var portText = PortBox.Text.Trim();
            if (portText.Length > 0)
            {
                if (!int.TryParse(portText, out var parsed) || parsed <= 0 || parsed > 65535)
                    throw new ArgumentException(AppSettings.T("Invalid port."));
                port = parsed;
            }
            if (IsElegoo)
            {
                if (_editing is not null && _editing.Serial != SerialBox.Text.Trim()) _store.Remove(_editing);
                _store.AddElegoo(NameBox.Text, SerialBox.Text, HostBox.Text, IsElegooCc2 ? 2 : 1, CodeBox.Text, port);
            }
            else if (UsesHostFields)
            {
                // Editing may change the host, which changes the derived serial; drop the old entry first.
                if (_editing is not null && _editing.Host != HostBox.Text.Trim())
                    _store.Remove(_editing);
                if (IsPrusa) _store.AddPrusa(NameBox.Text, HostBox.Text, port, ApiKeyBox.Text);
                else if (IsSnapmaker) _store.AddSnapmaker(NameBox.Text, HostBox.Text, port);
                else if (IsAnycubic) _store.AddAnycubicKobraS1(NameBox.Text, HostBox.Text, port);
                else _store.AddKlipper(NameBox.Text, HostBox.Text, port, ApiKeyBox.Text);
            }
            else if (_editing is not null)
                _store.Update(_editing.Serial, NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text, port);
            else
                _store.AddManually(NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text, port);

            // The tray-pin checkbox is only shown when editing, so the final serial is known here.
            if (_editing is not null)
            {
                var host = HostBox.Text.Trim();
                var finalSerial = IsPrusa ? $"prusa-{host}" : IsKlipper ? $"klipper-{host}" : IsSnapmaker ? $"snapmaker-{host}" : IsAnycubic ? $"anycubic-kobra-s1-{host}" : SerialBox.Text.Trim();
                TrayProgressPreference.SetEnabled(ProgressCheck.IsChecked == true, finalSerial);
            }
            Close();
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    private void SaveSubnetTargets()
    {
        var input = (SubnetTargetsBox.Text ?? string.Empty).Trim();
        // Save only when valid; leave an invalid entry in place (message shown) instead of silently reverting.
        if (SubnetTargets.IsValid(input))
        {
            AppSettings.SubnetScanTargets = input;
            SubnetTargetsBox.Text = input;
        }
        ValidateSubnetTargets();
    }

    private void ValidateSubnetTargets()
    {
        var input = SubnetTargetsBox.Text ?? string.Empty;
        if (SubnetTargets.IsValid(input))
        {
            SubnetTargetsError.Visibility = Visibility.Collapsed;
            return;
        }
        SubnetTargetsError.Visibility = Visibility.Visible;
        SubnetTargetsError.Text = SubnetTargets.IsTooLarge(input)
            ? string.Format(AppSettings.T("Range too large (max {0}) — use a narrower range or a single address."), SubnetTargets.MaxHosts)
            : AppSettings.T("Invalid entry — use an IP, an a-b range or CIDR /n.");
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void ApplyModernChrome()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = GTheme.IsLight ? 0 : 1, round = 2, acrylic = 3;
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));
            DwmSetWindowAttribute(hwnd, 38, ref acrylic, sizeof(int));
        }
        catch { /* older Windows — plain window is fine */ }
    }

    private sealed class DiscoveredItem
    {
        public DiscoveredPrinter Printer { get; }
        public DiscoveredItem(DiscoveredPrinter printer) => Printer = printer;
        public override string ToString() => $"{Printer.Name}  —  {Printer.Host}  ({Printer.Serial})";
    }
}
