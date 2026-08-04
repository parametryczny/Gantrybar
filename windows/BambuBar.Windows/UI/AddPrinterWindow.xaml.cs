using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using BambuBar.Models;
using BambuBar.Services;

namespace BambuBar.UI;

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
            if (editing.Kind != PrinterKind.Bambu)
            {
                if (editing.Kind == PrinterKind.Klipper) KlipperRadio.IsChecked = true;
                else PrusaRadio.IsChecked = true;
                PortBox.Text = editing.Port?.ToString() ?? "";
                ApiKeyBox.Text = editing.ApiKey ?? "";
            }
            // The tray-pin checkbox is offered only when editing a saved printer (its serial is known).
            ProgressCheck.Visibility = Visibility.Visible;
            ProgressCheck.IsChecked = TrayProgressPreference.IsEnabled(editing.Serial);
        }

        BambuRadio.Checked += (_, _) => ApplyKind();
        KlipperRadio.Checked += (_, _) => ApplyKind();
        PrusaRadio.Checked += (_, _) => ApplyKind();
        ScanButton.Click += (_, _) => _store.Scan();
        ImportButton.Click += (_, _) => ImportFromStudio();
        SubnetTargetsBox.LostFocus += (_, _) => SaveSubnetTargets();
        SubnetTargetsBox.TextChanged += (_, _) => ValidateSubnetTargets();
        SaveButton.Click += (_, _) => Save();
        CancelButton.Click += (_, _) => Close();
        DetectedList.SelectionChanged += OnDetectedSelected;
        ApplyKind();

        _store.Updated += OnStoreUpdated;
        Closed += (_, _) => _store.Updated -= OnStoreUpdated;
        RefreshDetected();
    }

    private void Localize()
    {
        Title = _editing is null ? AppSettings.Text("Dodaj drukarkę", "Add printer") : AppSettings.Text("Edytuj drukarkę", "Edit printer");
        Heading.Text = Title;
        DetectedLabel.Text = AppSettings.Text("Wykryte drukarki", "Detected printers");
        ImportButton.Content = AppSettings.Text("Importuj z Bambu Studio", "Import from Bambu Studio");
        SubnetTargetsLabel.Text = AppSettings.Text("Nie widać drukarki? Dodatkowe adresy do skanowania (VPN):",
                                                   "Printer not listed? Extra scan targets (VPN):");
        SubnetTargetsHint.Text = AppSettings.Text(
            $"Bambu wykrywa się w sieci lokalnej. Drukarkę spoza LAN (np. przez Tailscale) dopisz tu jej adresem, potem kliknij ⟳. Pojedynczy adres (zalecane), zakres a-b lub CIDR /n. Duże zakresy odrzucane (limit {SubnetTargets.MaxHosts}).",
            $"Bambu is found on the local network. Add a printer outside the LAN (e.g. over Tailscale) by its address here, then click ⟳. A single address (best), an a-b range or CIDR /n. Large ranges are rejected (limit {SubnetTargets.MaxHosts}).");
        if (!SubnetTargetsBox.IsKeyboardFocusWithin) SubnetTargetsBox.Text = AppSettings.SubnetScanTargets;
        ValidateSubnetTargets();
        NameLabel.Text = AppSettings.Text("Nazwa (opcjonalnie)", "Name (optional)");
        HostLabel.Text = AppSettings.Text("Adres IP", "IP address");
        SerialLabel.Text = AppSettings.Text("Numer seryjny", "Serial number");
        CodeLabel.Text = AppSettings.Text("Kod dostępu (Access Code / PIN)", "Access Code / PIN");
        BambuRadio.Content = AppSettings.Text("Bambu Lab", "Bambu Lab");
        KlipperRadio.Content = AppSettings.Text("Klipper (Moonraker)", "Klipper (Moonraker)");
        PrusaRadio.Content = AppSettings.Text("Prusa (PrusaLink)", "Prusa (PrusaLink)");
        ApiKeyLabel.Text = AppSettings.Text("Klucz API (opcjonalnie)", "API key (optional)");
        CancelButton.Content = AppSettings.Text("Anuluj", "Cancel");
        SaveButton.Content = _editing is null ? AppSettings.Text("Dodaj", "Add") : AppSettings.Text("Zapisz", "Save");
        ProgressCheck.Content = AppSettings.Text("Pokaż postęp tej drukarki w zasobniku",
                                                 "Show this printer's progress in the tray");
    }

    private bool IsKlipper => KlipperRadio.IsChecked == true;
    private bool IsPrusa => PrusaRadio.IsChecked == true;
    // Klipper and Prusa both connect over HTTP with host/port/API key.
    private bool UsesHostFields => IsKlipper || IsPrusa;

    /// <summary>Shows only the fields relevant to the selected printer kind. Klipper/Prusa need a
    /// host, optional port and API key; Bambu needs discovery, serial and access code.</summary>
    private void ApplyKind()
    {
        bool hostBased = UsesHostFields;
        DiscoverySection.Visibility = (hostBased || _editing is not null) ? Visibility.Collapsed : Visibility.Visible;
        SerialLabel.Visibility = SerialBox.Visibility = hostBased ? Visibility.Collapsed : Visibility.Visible;
        CodeLabel.Visibility = CodeBox.Visibility = hostBased ? Visibility.Collapsed : Visibility.Visible;
        PortLabel.Visibility = PortBox.Visibility = hostBased ? Visibility.Visible : Visibility.Collapsed;
        ApiKeyLabel.Visibility = ApiKeyBox.Visibility = hostBased ? Visibility.Visible : Visibility.Collapsed;
        HostLabel.Text = hostBased
            ? AppSettings.Text("Adres IP / nazwa hosta", "IP address / host name")
            : AppSettings.Text("Adres IP", "IP address");
        PortLabel.Text = IsPrusa
            ? AppSettings.Text("Port PrusaLink (domyślnie 80)", "PrusaLink port (default 80)")
            : AppSettings.Text("Port Moonraker (domyślnie 7125)", "Moonraker port (default 7125)");
        ApiKeyLabel.Text = IsPrusa
            ? AppSettings.Text("Klucz API PrusaLink", "PrusaLink API key")
            : AppSettings.Text("Klucz API (opcjonalnie)", "API key (optional)");
    }

    private void OnStoreUpdated(object? sender, EventArgs e) => Dispatcher.Invoke(RefreshDetected);

    private void RefreshDetected()
    {
        if (_editing is not null) return;
        var selectedSerial = (DetectedList.SelectedItem as DiscoveredItem)?.Printer.Serial;
        DetectedList.Items.Clear();
        foreach (var d in _store.Discovered)
            DetectedList.Items.Add(new DiscoveredItem(d));
        DetectedLabel.Text = _store.IsScanning
            ? AppSettings.Text("Skanowanie…", "Scanning…")
            : AppSettings.Text($"Wykryte drukarki ({_store.Discovered.Count})", $"Detected printers ({_store.Discovered.Count})");
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
            CodeBox.Focus();
        }
    }

    private void ImportFromStudio()
    {
        try
        {
            int count = _store.ImportFromBambuStudio();
            MessageBox.Show(this, AppSettings.Text($"Zaimportowano drukarek: {count}", $"Imported printers: {count}"), "PrismBar");
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
            if (UsesHostFields)
            {
                int? port = null;
                var portText = PortBox.Text.Trim();
                if (portText.Length > 0)
                {
                    if (!int.TryParse(portText, out var parsed) || parsed <= 0 || parsed > 65535)
                        throw new ArgumentException(AppSettings.Text("Nieprawidłowy port.", "Invalid port."));
                    port = parsed;
                }
                // Editing may change the host, which changes the derived serial; drop the old entry first.
                if (_editing is not null && _editing.Host != HostBox.Text.Trim())
                    _store.Remove(_editing);
                if (IsPrusa) _store.AddPrusa(NameBox.Text, HostBox.Text, port, ApiKeyBox.Text);
                else _store.AddKlipper(NameBox.Text, HostBox.Text, port, ApiKeyBox.Text);
            }
            else if (_editing is not null)
                _store.Update(_editing.Serial, NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text);
            else
                _store.AddManually(NameBox.Text, SerialBox.Text, HostBox.Text, CodeBox.Text);

            // The tray-pin checkbox is only shown when editing, so the final serial is known here.
            if (_editing is not null)
            {
                var host = HostBox.Text.Trim();
                var finalSerial = IsPrusa ? $"prusa-{host}" : IsKlipper ? $"klipper-{host}" : SerialBox.Text.Trim();
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
            ? AppSettings.Text($"Zakres za duży (max {SubnetTargets.MaxHosts}) — podaj węższy zakres lub pojedynczy adres.",
                               $"Range too large (max {SubnetTargets.MaxHosts}) — use a narrower range or a single address.")
            : AppSettings.Text("Nieprawidłowy wpis — użyj IP, zakresu a-b lub CIDR /n.",
                               "Invalid entry — use an IP, an a-b range or CIDR /n.");
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
        int dark = 1, round = 2, acrylic = 3;
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
