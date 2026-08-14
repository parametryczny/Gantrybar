using Gantry.Models;

namespace Gantry.Services;

/// <summary>
/// Central coordinator: owns the printer list, live telemetry, MQTT clients, reconnection and
/// notifications. Ported from the macOS PrinterStore. All mutations happen on the UI thread via
/// the supplied <c>post</c> marshaller; subscribers refresh on the <see cref="Updated"/> event.
/// </summary>
public sealed class PrinterStore
{
    private readonly Action<Action> _post;

    public List<SavedPrinter> Printers { get; private set; }
    public Dictionary<string, PrinterTelemetry> Telemetry { get; } = new();
    public Dictionary<string, string?> ConnectionMessages { get; } = new();
    public List<DiscoveredPrinter> Discovered { get; private set; } = new();
    public bool IsScanning { get; private set; }
    public string? GlobalMessage { get; set; }

    public event EventHandler? Updated;

    private readonly SsdpDiscovery _discovery = new();
    private readonly SubnetDiscovery _subnetDiscovery = new();
    private readonly Dictionary<string, IPrinterConnection> _clients = new();
    private readonly Dictionary<string, CancellationTokenSource> _reconnectTasks = new();
    private readonly Dictionary<string, string> _sessionCodes = new();
    private readonly Dictionary<string, string> _dismissedJobs = new();
    private readonly HashSet<string> _printersWithTelemetry = new();
    private DateTime? _lastAddressScan;
    private Guid _scanToken;

    public PrinterStore(Action<Action> post)
    {
        _post = post;
        Printers = SavedPrinterStore.Load();
        MigratePlaintextApiKeys();
        foreach (var printer in Printers) Telemetry[printer.Serial] = new PrinterTelemetry();
    }

    /// <summary>Saves an HTTP printer's API key to DPAPI (or clears it), keyed by serial.</summary>
    private static void StoreSecret(string? apiKey, string serial)
    {
        var key = apiKey?.Trim();
        if (string.IsNullOrEmpty(key)) AccessCodeStore.Delete(serial);
        else AccessCodeStore.Save(key, serial);
    }

    /// <summary>Fills in a Klipper/Prusa API key from DPAPI just before connecting, so the key
    /// never has to live on the persisted config.</summary>
    private static SavedPrinter HydratedWithSecret(SavedPrinter printer)
    {
        if (!string.IsNullOrEmpty(printer.ApiKey)) return printer;
        var key = AccessCodeStore.AccessCode(printer.Serial);
        if (string.IsNullOrEmpty(key)) return printer;
        return new SavedPrinter
        {
            Serial = printer.Serial, Name = printer.Name, Model = printer.Model, Host = printer.Host,
            Kind = printer.Kind, Port = printer.Port, ApiKey = key
        };
    }

    /// <summary>One-time move of plaintext Klipper/Prusa API keys from an older config into DPAPI,
    /// then strip them from the persisted config.</summary>
    private void MigratePlaintextApiKeys()
    {
        var changed = false;
        foreach (var printer in Printers)
        {
            if (printer.Kind is not (PrinterKind.Klipper or PrinterKind.Prusa)) continue;
            if (string.IsNullOrEmpty(printer.ApiKey)) continue;
            AccessCodeStore.Save(printer.ApiKey!, printer.Serial);
            printer.ApiKey = null;
            changed = true;
        }
        if (changed) SavedPrinterStore.Save(Printers);
    }

    public int ActivePrintCount => Telemetry.Values.Count(t => t.State == PrinterState.Printing);

    private void RaiseUpdated() => Updated?.Invoke(this, EventArgs.Empty);

    /// <summary>Reorders a printer relative to another (drag-and-drop). Mirrors the macOS store.</summary>
    public void MovePrinter(string serial, string relativeTo, bool insertAfter)
    {
        if (serial == relativeTo) return;
        var sourceIndex = Printers.FindIndex(p => p.Serial == serial);
        if (sourceIndex < 0) return;
        var printer = Printers[sourceIndex];
        Printers.RemoveAt(sourceIndex);
        var targetIndex = Printers.FindIndex(p => p.Serial == relativeTo);
        if (targetIndex < 0) Printers.Insert(Math.Min(sourceIndex, Printers.Count), printer);
        else Printers.Insert(targetIndex + (insertAfter ? 1 : 0), printer);
        SavedPrinterStore.Save(Printers);
        RaiseUpdated();
    }

    // ---- Discovery -----------------------------------------------------------------

    public void Scan()
    {
        if (IsScanning) return;
        var token = Guid.NewGuid();
        _scanToken = token;
        IsScanning = true;
        GlobalMessage = null;
        RaiseUpdated();

        _ = Task.Run(async () =>
        {
            var ssdp = _discovery.ScanAsync();
            var subnet = _subnetDiscovery.ScanAsync();
            await Task.WhenAll(ssdp, subnet);
            var combined = ssdp.Result.Concat(subnet.Result)
                .GroupBy(p => p.Serial).Select(g => g.First());

            _post(() =>
            {
                if (_scanToken != token) return;
                Discovered = combined
                    .Where(c => Printers.All(p => p.Serial != c.Serial))
                    .OrderBy(c => c.Host, new NumericHostComparer())
                    .ToList();
                IsScanning = false;
                if (Discovered.Count == 0)
                    GlobalMessage = AppSettings.Text("Nie znaleziono nowych drukarek.", "No new printers found.");
                RaiseUpdated();
            });
        });

        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(8));
            _post(() =>
            {
                if (_scanToken != token || !IsScanning) return;
                IsScanning = false;
                GlobalMessage = AppSettings.Text("Skanowanie przekroczyło 8 sekund.", "Scan exceeded 8 seconds.");
                RaiseUpdated();
            });
        });
    }

    // ---- Adding / editing ----------------------------------------------------------

    public void Add(DiscoveredPrinter discovered, string accessCode, string? customName = null)
    {
        var code = accessCode.Trim();
        if (code.Length == 0) throw new ArgumentException(AppSettings.Text("Podaj kod PIN / Access Code drukarki.", "Enter the printer PIN / Access Code."));
        var name = customName?.Trim();
        var printer = new SavedPrinter
        {
            Serial = discovered.Serial,
            Name = !string.IsNullOrEmpty(name) ? name! : discovered.Name,
            Model = discovered.Model,
            Host = discovered.Host
        };
        Upsert(printer, code);
        Discovered.RemoveAll(d => d.Serial == printer.Serial);
        RaiseUpdated();
    }

    public void AddManually(string name, string serial, string host, string accessCode, int? port = null)
    {
        var cleanSerial = serial.Trim();
        var cleanHost = host.Trim();
        var cleanCode = accessCode.Trim();
        if (cleanSerial.Length == 0 || cleanHost.Length == 0 || cleanCode.Length == 0)
            throw new ArgumentException(AppSettings.Text("Adres IP, numer seryjny i kod dostępu są wymagane.", "IP address, serial number and access code are required."));
        var cleanName = name.Trim();
        string suffix = cleanSerial.Length >= 4 ? cleanSerial[^4..] : cleanSerial;
        Upsert(new SavedPrinter
        {
            Serial = cleanSerial,
            Name = cleanName.Length == 0 ? $"Bambu {suffix}" : cleanName,
            Host = cleanHost,
            Port = port
        }, cleanCode);
        RaiseUpdated();
    }

    public void AddKlipper(string name, string host, int? port, string? apiKey)
    {
        var cleanHost = host.Trim();
        if (cleanHost.Length == 0)
            throw new ArgumentException(AppSettings.Text("Adres IP / nazwa hosta jest wymagana.", "IP address / host name is required."));
        var cleanName = name.Trim();
        // The API key is a secret: keep it out of the plaintext config and in DPAPI, keyed by serial
        // — the same place Bambu access codes live.
        StoreSecret(apiKey, $"klipper-{cleanHost}");
        var printer = new SavedPrinter
        {
            Serial = $"klipper-{cleanHost}",
            Name = cleanName.Length == 0 ? $"Klipper {cleanHost}" : cleanName,
            Model = "Klipper",
            Host = cleanHost,
            Kind = PrinterKind.Klipper,
            Port = port,
            ApiKey = null
        };

        var index = Printers.FindIndex(p => p.Serial == printer.Serial);
        if (index >= 0) Printers[index] = printer; else Printers.Add(printer);
        Telemetry[printer.Serial] = new PrinterTelemetry();
        SavedPrinterStore.Save(Printers);
        Reconnect(printer);
        RaiseUpdated();
    }

    public void AddPrusa(string name, string host, int? port, string? apiKey)
    {
        var cleanHost = host.Trim();
        if (cleanHost.Length == 0)
            throw new ArgumentException(AppSettings.Text("Adres IP / nazwa hosta jest wymagana.", "IP address / host name is required."));
        var cleanName = name.Trim();
        // Keep the PrusaLink API key in DPAPI, not the plaintext config.
        StoreSecret(apiKey, $"prusa-{cleanHost}");
        var printer = new SavedPrinter
        {
            Serial = $"prusa-{cleanHost}",
            Name = cleanName.Length == 0 ? $"Prusa {cleanHost}" : cleanName,
            Model = "Prusa",
            Host = cleanHost,
            Kind = PrinterKind.Prusa,
            Port = port,
            ApiKey = null
        };

        var index = Printers.FindIndex(p => p.Serial == printer.Serial);
        if (index >= 0) Printers[index] = printer; else Printers.Add(printer);
        Telemetry[printer.Serial] = new PrinterTelemetry();
        SavedPrinterStore.Save(Printers);
        Reconnect(printer);
        RaiseUpdated();
    }

    public int ImportFromBambuStudio()
    {
        var devices = BambuStudioConfig.Devices();
        int imported = 0;

        // Prefer an address we already know (saved printer or a fresh discovery hit) and fall
        // back to the IP stored in the Bambu Studio config, so import works on a clean install
        // with no saved printers and without waiting for a network scan.
        foreach (var device in devices)
        {
            var existing = Printers.FirstOrDefault(p => p.Serial == device.Serial);
            var found = Discovered.FirstOrDefault(d => d.Serial == device.Serial);
            var host = existing?.Host ?? found?.Host ?? device.Host;
            if (string.IsNullOrEmpty(host)) continue;
            string suffix = device.Serial.Length >= 4 ? device.Serial[^4..] : device.Serial;
            var name = existing?.Name ?? found?.Name ?? $"Bambu {suffix}";
            var model = found?.Model ?? existing?.Model ?? "Bambu Lab";
            Upsert(new SavedPrinter { Serial = device.Serial, Name = name, Model = model, Host = host }, device.AccessCode);
            imported++;
        }

        Discovered.RemoveAll(d => devices.Any(x => x.Serial == d.Serial));
        if (imported == 0)
            throw new BambuStudioConfigException(AppSettings.Text("Nie znaleziono drukarek z zapisanym kodem i adresem IP.", "No printers with a stored code and IP address."));
        RaiseUpdated();
        return imported;
    }

    public void Update(string originalSerial, string name, string serial, string host, string accessCode, int? port = null)
    {
        var cleanSerial = serial.Trim();
        var cleanHost = host.Trim();
        var cleanName = name.Trim();
        var entered = accessCode.Trim();
        if (cleanSerial.Length == 0 || cleanHost.Length == 0)
            throw new ArgumentException(AppSettings.Text("Adres IP i numer seryjny są wymagane.", "IP address and serial number are required."));
        string? code = entered.Length == 0
            ? (_sessionCodes.TryGetValue(originalSerial, out var s) ? s : AccessCodeStore.AccessCode(originalSerial))
            : entered;
        if (string.IsNullOrEmpty(code))
            throw new ArgumentException(AppSettings.Text("Podaj kod PIN / Access Code drukarki.", "Enter the printer PIN / Access Code."));

        if (_clients.Remove(originalSerial, out var existing)) existing.Stop();
        if (originalSerial != cleanSerial)
        {
            Printers.RemoveAll(p => p.Serial == originalSerial);
            Telemetry.Remove(originalSerial);
            ConnectionMessages.Remove(originalSerial);
            AccessCodeStore.Delete(originalSerial);
            CertificatePinStore.Delete(originalSerial);
        }
        string suffix = cleanSerial.Length >= 4 ? cleanSerial[^4..] : cleanSerial;
        Upsert(new SavedPrinter
        {
            Serial = cleanSerial,
            Name = cleanName.Length == 0 ? $"Bambu {suffix}" : cleanName,
            Host = cleanHost,
            Port = port
        }, code);
        RaiseUpdated();
    }

    public void Remove(SavedPrinter printer)
    {
        if (_reconnectTasks.Remove(printer.Serial, out var task)) task.Cancel();
        if (_clients.Remove(printer.Serial, out var client)) client.Stop();
        _sessionCodes.Remove(printer.Serial);
        Printers.RemoveAll(p => p.Serial == printer.Serial);
        Telemetry.Remove(printer.Serial);
        ConnectionMessages.Remove(printer.Serial);
        AccessCodeStore.Delete(printer.Serial);
        CertificatePinStore.Delete(printer.Serial);
        SavedPrinterStore.Save(Printers);
        RaiseUpdated();
    }

    public void ResetCompletedStatuses()
    {
        foreach (var serial in Telemetry.Keys.ToList())
        {
            var current = Telemetry[serial];
            if (current.State is PrinterState.Printing or PrinterState.Paused) continue;
            if (!string.IsNullOrEmpty(current.JobName)) _dismissedJobs[serial] = current.JobName!;
            Telemetry[serial] = ClearedCompletedJob(current);
            ConnectionMessages[serial] = null;
        }
        RaiseUpdated();
    }

    // ---- Connection lifecycle ------------------------------------------------------

    public void ReconnectAll()
    {
        foreach (var printer in Printers.ToList()) Reconnect(printer);
    }

    public void Reconnect(SavedPrinter printer)
    {
        if (_reconnectTasks.Remove(printer.Serial, out var task)) task.Cancel();
        if (_clients.Remove(printer.Serial, out var existing)) existing.Stop();
        Telemetry[printer.Serial] = new PrinterTelemetry();
        ConnectionMessages[printer.Serial] = AppSettings.Text("Łączenie…", "Connecting…");

        if (printer.Kind == PrinterKind.Klipper)
        {
            var moonraker = new MoonrakerClient(HydratedWithSecret(printer), evt => _post(() => Handle(evt, printer.Serial)));
            _clients[printer.Serial] = moonraker;
            moonraker.Start();
            RaiseUpdated();
            return;
        }
        if (printer.Kind == PrinterKind.Prusa)
        {
            var prusa = new PrusaLinkClient(HydratedWithSecret(printer), evt => _post(() => Handle(evt, printer.Serial)));
            _clients[printer.Serial] = prusa;
            prusa.Start();
            RaiseUpdated();
            return;
        }

        string code;
        if (_sessionCodes.TryGetValue(printer.Serial, out var sessionCode))
        {
            code = sessionCode;
        }
        else
        {
            try
            {
                code = AccessCodeStore.ReadAccessCode(printer.Serial);
                _sessionCodes[printer.Serial] = code;
            }
            catch (Exception ex)
            {
                ConnectionMessages[printer.Serial] = ex.Message;
                RaiseUpdated();
                return;
            }
        }

        var client = new MqttClient(printer, code, evt => _post(() => Handle(evt, printer.Serial)));
        _clients[printer.Serial] = client;
        client.Start();
        RaiseUpdated();
    }

    private void Upsert(SavedPrinter printer, string accessCode)
    {
        AccessCodeStore.Save(accessCode, printer.Serial);
        _sessionCodes[printer.Serial] = accessCode;
        var index = Printers.FindIndex(p => p.Serial == printer.Serial);
        if (index >= 0) Printers[index] = printer; else Printers.Add(printer);
        Telemetry[printer.Serial] = new PrinterTelemetry();
        SavedPrinterStore.Save(Printers);
        Reconnect(printer);
    }

    private void Handle(MqttEvent evt, string serial)
    {
        switch (evt.Type)
        {
            case MqttEventType.Connected:
                if (_reconnectTasks.Remove(serial, out var t)) t.Cancel();
                ConnectionMessages[serial] = null;
                break;

            case MqttEventType.Telemetry:
                if (_reconnectTasks.Remove(serial, out var t2)) t2.Cancel();
                var value = evt.Telemetry!;
                var previous = Telemetry.TryGetValue(serial, out var prev) ? prev : null;
                if (value.State is PrinterState.Printing or PrinterState.Paused)
                    _dismissedJobs.Remove(serial);
                else if (_dismissedJobs.TryGetValue(serial, out var dismissed) && value.JobName == dismissed)
                    value = ClearedCompletedJob(value);
                else if (value.JobName != (_dismissedJobs.TryGetValue(serial, out var d) ? d : null))
                    _dismissedJobs.Remove(serial);
                Telemetry[serial] = value;
                ConnectionMessages[serial] = null;
                if (_printersWithTelemetry.Contains(serial) && Printers.FirstOrDefault(p => p.Serial == serial) is { } printer)
                    NotifyChanges(printer, previous, value);
                _printersWithTelemetry.Add(serial);
                break;

            case MqttEventType.Disconnected:
                var offline = Telemetry.TryGetValue(serial, out var o) ? o : new PrinterTelemetry();
                offline.State = PrinterState.Offline;
                Telemetry[serial] = offline;
                ConnectionMessages[serial] = (evt.Reason ?? AppSettings.Text("Rozłączono", "Disconnected")) +
                                             AppSettings.Text(" • ponowna próba za 20 s", " • retrying in 20 s");
                ScheduleReconnect(serial);
                break;
        }
        RaiseUpdated();
    }

    private void ScheduleReconnect(string serial)
    {
        if (_reconnectTasks.ContainsKey(serial)) return;
        if (Printers.All(p => p.Serial != serial)) return;
        var cts = new CancellationTokenSource();
        _reconnectTasks[serial] = cts;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(TimeSpan.FromSeconds(20), cts.Token); }
            catch (OperationCanceledException) { return; }

            bool refreshNeeded = _lastAddressScan is null || (DateTime.Now - _lastAddressScan.Value).TotalSeconds >= 300;
            if (refreshNeeded)
            {
                _lastAddressScan = DateTime.Now;
                _post(() => { ConnectionMessages[serial] = AppSettings.Text("Szukam aktualnego adresu IP…", "Looking up current IP…"); RaiseUpdated(); });
                await RefreshAddressesAsync();
            }

            _post(() =>
            {
                _reconnectTasks.Remove(serial);
                if (cts.IsCancellationRequested) return;
                if (Telemetry.TryGetValue(serial, out var tel) && tel.State != PrinterState.Offline) return;
                var printer = Printers.FirstOrDefault(p => p.Serial == serial);
                if (printer is not null) Reconnect(printer);
            });
        });
    }

    private async Task RefreshAddressesAsync()
    {
        var ssdp = _discovery.ScanAsync(3);
        var subnet = _subnetDiscovery.ScanAsync();
        await Task.WhenAll(ssdp, subnet);
        var results = ssdp.Result.Concat(subnet.Result).ToList();
        _post(() =>
        {
            bool changed = false;
            foreach (var found in results)
            {
                var index = Printers.FindIndex(p => p.Serial == found.Serial);
                if (index < 0) continue;
                if (Printers[index].Host != found.Host) { Printers[index].Host = found.Host; changed = true; }
            }
            if (changed) SavedPrinterStore.Save(Printers);
        });
    }

    private static PrinterTelemetry ClearedCompletedJob(PrinterTelemetry telemetry)
    {
        var cleared = telemetry.Clone();
        if (cleared.State == PrinterState.Finished) cleared.State = PrinterState.Idle;
        cleared.Progress = 0;
        cleared.RemainingMinutes = null;
        cleared.CurrentLayer = null;
        cleared.TotalLayers = null;
        cleared.JobName = null;
        return cleared;
    }

    private void NotifyChanges(SavedPrinter printer, PrinterTelemetry? previous, PrinterTelemetry current)
    {
        bool pl = AppSettings.Polish;
        if (AppSettings.NotifyPrintFinished && current.State == PrinterState.Finished && previous?.State != PrinterState.Finished)
            NotificationService.Post(AppSettings.Text("Druk zakończony", "Print finished"),
                current.JobName ?? AppSettings.Text("Zadanie zostało ukończone.", "The job has completed."), printer.Name);

        if (AppSettings.NotifyPrinterError && current.State == PrinterState.Error && (previous?.State != PrinterState.Error || !SequenceEqual(previous?.HmsCodes, current.HmsCodes)))
        {
            string description = HmsResolver.Description(current.HmsCodes, printer.Serial, pl)
                ?? (current.ErrorCode != 0
                    ? string.Format(AppSettings.Text("Kod błędu: 0x{0:X}", "Error code: 0x{0:X}"), current.ErrorCode)
                    : AppSettings.Text("Drukarka zgłosiła błąd.", "The printer reported an error."));
            NotificationService.Post(AppSettings.Text("Błąd drukarki", "Printer error"), description, printer.Name);
        }
        else if (AppSettings.NotifyPrintPaused && current.State == PrinterState.Paused && previous?.State != PrinterState.Paused)
        {
            NotificationService.Post(AppSettings.Text("Druk wstrzymany", "Print paused"),
                current.JobName ?? AppSettings.Text("Drukarka oczekuje na działanie.", "The printer needs attention."), printer.Name);
        }

        var previousLow = new HashSet<string>((previous?.AmsSlots ?? new()).Where(s => (s.RemainingPercent ?? 100) <= 15).Select(s => s.Id));
        var newLow = current.AmsSlots.Where(s => (s.RemainingPercent ?? 100) <= 15 && !previousLow.Contains(s.Id)).ToList();
        if (AppSettings.NotifyLowFilament && newLow.FirstOrDefault() is { } slot)
            NotificationService.Post(AppSettings.Text("Niski poziom filamentu", "Low filament"),
                $"{slot.Label} • {slot.Material} • {slot.RemainingPercent ?? 0}%", printer.Name);

        if (AppSettings.NotifyHighAmsHumidity && IsHumidityHigh(current.AmsHumidity) && !IsHumidityHigh(previous?.AmsHumidity))
            NotificationService.Post(AppSettings.Text("Wysoka wilgotność AMS", "High AMS humidity"),
                AppSettings.Text("Sprawdź lub osusz pochłaniacz wilgoci.", "Check or dry the desiccant."), printer.Name);
    }

    private static bool IsHumidityHigh(int? value)
    {
        if (value is null) return false;
        return value <= 5 ? value >= 4 : value >= 40;
    }

    private static bool SequenceEqual(List<string>? a, List<string> b)
        => a is not null && a.Count == b.Count && a.SequenceEqual(b);

    private sealed class NumericHostComparer : IComparer<string>
    {
        public int Compare(string? x, string? y)
        {
            System.Net.IPAddress.TryParse(x, out var a);
            System.Net.IPAddress.TryParse(y, out var b);
            var ab = a?.GetAddressBytes();
            var bb = b?.GetAddressBytes();
            if (ab is null || bb is null) return string.CompareOrdinal(x, y);
            for (int i = 0; i < Math.Min(ab.Length, bb.Length); i++)
                if (ab[i] != bb[i]) return ab[i].CompareTo(bb[i]);
            return 0;
        }
    }
}
