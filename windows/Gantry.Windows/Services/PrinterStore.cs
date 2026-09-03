using System.Text.Json.Nodes;
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
    // Rolling temperature history per printer, drawn by the detail window's graph.
    public Dictionary<string, List<TemperatureSample>> TemperatureHistory { get; } = new();
    private const int MaxTemperatureSamples = 240;
    public Dictionary<string, string?> ConnectionMessages { get; } = new();
    /// <summary>Transient per-printer notices shown on the card until dismissed (e.g. a Spoolbase spool
    /// auto-detached because an NFC roll was inserted into its slot).</summary>
    public Dictionary<string, List<string>> SpoolNotices { get; } = new();
    public List<DiscoveredPrinter> Discovered { get; private set; } = new();
    public bool IsScanning { get; private set; }
    public string? GlobalMessage { get; set; }

    public event EventHandler? Updated;

    private readonly SsdpDiscovery _discovery = new();
    private readonly SubnetDiscovery _subnetDiscovery = new();
    private readonly ElegooDiscovery _elegooDiscovery = new();
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
            var elegoo = _elegooDiscovery.ScanAsync();
            await Task.WhenAll(ssdp, subnet, elegoo);
            var combined = ssdp.Result.Concat(subnet.Result).Concat(elegoo.Result)
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

    /// <summary>Refreshes names which still look automatically generated, without overwriting a
    /// user-provided name. This is the Windows counterpart of macOS refreshPrinterNames().</summary>
    public void RefreshPrinterNames()
    {
        _ = Task.Run(async () =>
        {
            var ssdp = _discovery.ScanAsync(4);
            var subnet = _subnetDiscovery.ScanAsync();
            var elegoo = _elegooDiscovery.ScanAsync(4);
            await Task.WhenAll(ssdp, subnet, elegoo);
            var results = ssdp.Result.Concat(subnet.Result).Concat(elegoo.Result)
                .GroupBy(p => p.Serial).Select(g => g.First()).ToList();

            _post(() =>
            {
                bool changed = false;
                foreach (var found in results)
                {
                    var index = Printers.FindIndex(p => p.Serial == found.Serial);
                    if (index < 0 || !ShouldReplaceAutomaticName(Printers[index].Name) ||
                        ShouldReplaceAutomaticName(found.Name)) continue;
                    Printers[index].Name = found.Name.Normalize();
                    if (found.Model != "Bambu Lab") Printers[index].Model = found.Model;
                    changed = true;
                }
                if (!changed) return;
                SavedPrinterStore.Save(Printers);
                RaiseUpdated();
            });
        });
    }

    private static bool ShouldReplaceAutomaticName(string? name)
    {
        var trimmed = (name ?? string.Empty).Trim();
        if (!trimmed.StartsWith("Bambu ", StringComparison.OrdinalIgnoreCase)) return trimmed.Length == 0;
        var suffix = trimmed.Substring(6);
        return suffix.Length <= 6 && suffix.All(char.IsLetterOrDigit);
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

    public void AddElegoo(string name, string serial, string host, int generation, string accessCode, int? port)
    {
        var cleanSerial = serial.Trim(); var cleanHost = host.Trim(); var cleanCode = accessCode.Trim();
        if (cleanSerial.Length == 0 || cleanHost.Length == 0)
            throw new ArgumentException(AppSettings.Text("Adres IP i numer seryjny Elegoo są wymagane.", "Elegoo IP address and serial number are required."));
        if (generation == 2 && cleanCode.Length == 0)
            throw new ArgumentException(AppSettings.Text("Podaj kod dostępu Elegoo CC2 i włącz tryb LAN-only.", "Enter the Elegoo CC2 access code and enable LAN-only mode."));
        var printer = new SavedPrinter { Serial = cleanSerial,
            Name = string.IsNullOrWhiteSpace(name) ? $"Centauri Carbon {(generation == 2 ? "2 " : "")}{cleanSerial[^Math.Min(4, cleanSerial.Length)..]}" : name.Trim(),
            Model = generation == 2 ? "Elegoo Centauri Carbon 2" : "Elegoo Centauri Carbon", Host = cleanHost,
            Kind = generation == 2 ? PrinterKind.ElegooCc2 : PrinterKind.ElegooCc1, Port = port ?? (generation == 2 ? 1883 : 3030) };
        if (generation == 2) { AccessCodeStore.Save(cleanCode, cleanSerial); _sessionCodes[cleanSerial] = cleanCode; }
        var index = Printers.FindIndex(p => p.Serial == cleanSerial); if (index >= 0) Printers[index] = printer; else Printers.Add(printer);
        Telemetry[cleanSerial] = new PrinterTelemetry(); SavedPrinterStore.Save(Printers); Reconnect(printer); RaiseUpdated();
    }

    public void AddSnapmaker(string name, string host, int? port)
    {
        var cleanHost = host.Trim();
        if (cleanHost.Length == 0)
            throw new ArgumentException(AppSettings.Text("Adres IP / nazwa hosta jest wymagana.", "IP address / host name is required."));
        var cleanName = name.Trim();
        // No stored secret: Snapmaker authorizes each session via a token confirmed on the printer's
        // touchscreen, so there is nothing to keep in DPAPI.
        var printer = new SavedPrinter
        {
            Serial = $"snapmaker-{cleanHost}",
            Name = cleanName.Length == 0 ? $"Snapmaker {cleanHost}" : cleanName,
            Model = "Snapmaker",
            Host = cleanHost,
            Kind = PrinterKind.Snapmaker,
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

    public void AddAnycubicKobraS1(string name, string host, int? port)
    {
        var cleanHost = host.Trim(); if (cleanHost.Length == 0) throw new ArgumentException(AppSettings.Text("Adres IP jest wymagany.", "IP address is required."));
        var printer = new SavedPrinter { Serial = $"anycubic-kobra-s1-{cleanHost}", Name = string.IsNullOrWhiteSpace(name) ? $"Kobra S1 {cleanHost}" : name.Trim(),
            Model = "Anycubic Kobra S1", Host = cleanHost, Kind = PrinterKind.AnycubicKobraS1, Port = port ?? 18910 };
        var index = Printers.FindIndex(p => p.Serial == printer.Serial); if (index >= 0) Printers[index] = printer; else Printers.Add(printer);
        Telemetry[printer.Serial] = new PrinterTelemetry(); SavedPrinterStore.Save(Printers); Reconnect(printer); RaiseUpdated();
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

    /// <summary>Clears the card notices for a printer (the user pressed "OK" on the on-card message).</summary>
    public void DismissSpoolNotices(string serial) => SpoolNotices.Remove(serial);

    /// <summary>Merges peer printers from LAN sync: adds any printer we do not already have (by serial).
    /// Secrets are never synced (Bambu access codes stay in this machine's store, apiKey is dropped), so
    /// a new printer appears but needs its access code entered once here before it connects.</summary>
    public bool MergeRemote(List<SyncPrinter> remote)
    {
        bool changed = false;
        foreach (var r in remote)
            if (!Printers.Any(p => p.Serial == r.Serial))
            {
                Printers.Add(new SavedPrinter { Serial = r.Serial, Name = r.Name, Model = r.Model, Host = r.Host, Kind = SyncPrinter.KindFromString(r.Kind), Port = r.Port });
                changed = true;
            }
        if (changed) { SavedPrinterStore.Save(Printers); ReconnectAll(); }
        return changed;
    }

    public void Reconnect(SavedPrinter printer)
    {
        if (_reconnectTasks.Remove(printer.Serial, out var task)) task.Cancel();
        if (_clients.Remove(printer.Serial, out var existing)) existing.Stop();
        Telemetry[printer.Serial] = new PrinterTelemetry();
        ConnectionMessages[printer.Serial] = AppSettings.Text("Łączenie…", "Connecting…");

        if (printer.Kind == PrinterKind.Klipper)
        {
            var moonraker = new MoonrakerClient(HydratedWithSecret(printer), evt => _post(() => Handle(evt, printer.Serial)), PrinterOverridesStore.For(printer.Serial).MoonrakerObjects);
            _clients[printer.Serial] = moonraker;
            moonraker.Start();
            RaiseUpdated();
            return;
        }
        if (printer.Kind == PrinterKind.Snapmaker)
        {
            var snapmaker = new SnapmakerClient(printer, evt => _post(() => Handle(evt, printer.Serial)));
            _clients[printer.Serial] = snapmaker;
            snapmaker.Start();
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
        if (printer.Kind == PrinterKind.ElegooCc1)
        {
            var elegoo = new ElegooCc1Client(printer, evt => _post(() => Handle(evt, printer.Serial)));
            _clients[printer.Serial] = elegoo; elegoo.Start(); RaiseUpdated(); return;
        }
        if (printer.Kind == PrinterKind.AnycubicKobraS1)
        {
            var anycubic = new AnycubicS1Client(printer, evt => _post(() => Handle(evt, printer.Serial)));
            _clients[printer.Serial] = anycubic; anycubic.Start(); RaiseUpdated(); return;
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

        IPrinterConnection client = printer.Kind == PrinterKind.ElegooCc2
            ? new ElegooCc2Client(printer, code, evt => _post(() => Handle(evt, printer.Serial)))
            : new MqttClient(printer, code, evt => _post(() => Handle(evt, printer.Serial)));
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
                // Inserting an RFID/NFC spool into a slot supersedes a stale manual Spoolbase assignment;
                // surface a dismissible notice on the card so the change is not silent.
                foreach (var (spoolId, slot) in SpoolbaseShared.Spools.DetachAssignmentsReplacedByNfc(serial, previous?.FilamentGroups ?? new(), value.FilamentGroups))
                {
                    if (!SpoolNotices.TryGetValue(serial, out var list)) SpoolNotices[serial] = list = new();
                    list.Add(AppSettings.Text($"{spoolId} wróciła do magazynu (wykryto tag NFC w {slot})",
                                              $"{spoolId} returned to storage (NFC tag detected in {slot})"));
                }
                RecordTemperature(serial, value);
                if (Printers.FirstOrDefault(p => p.Serial == serial) is { } observedPrinter)
                    PrinterInsights.Observe(observedPrinter, previous, value);
                ConnectionMessages[serial] = null;
                if (_printersWithTelemetry.Contains(serial) && Printers.FirstOrDefault(p => p.Serial == serial) is { } printer)
                {
                    NotifyChanges(printer, previous, value);
                    // Decrement the assigned physical spool on a real finish (idempotent per job).
                    FilamentConsumption.OnUpdate(printer, previous, value);
                }
                _printersWithTelemetry.Add(serial);
                EvaluateAutomations(serial, previous, value);
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
        var elegoo = _elegooDiscovery.ScanAsync(3);
        await Task.WhenAll(ssdp, subnet, elegoo);
        var results = ssdp.Result.Concat(subnet.Result).Concat(elegoo.Result).ToList();
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

    // --- Control (Phase 2): send commands to the printer ---

    /// Raw JSON command to a Bambu printer over MQTT (chamber LED, pause, …).
    public void SendCommand(string serial, string json)
    {
        if (_clients.TryGetValue(serial, out var c) && c is MqttClient mqtt) mqtt.SendCommand(json);
    }

    public void SendElegooMethod(string serial, int method, object? parameters = null)
    {
        if (!_clients.TryGetValue(serial, out var client)) return;
        if (client is ElegooCc1Client cc1) cc1.SendMethod(method, parameters);
        else if (client is ElegooCc2Client cc2) cc2.SendMethod(method, parameters);
    }

    public void SendAnycubicPrint(string serial, string action) { if (_clients.GetValueOrDefault(serial) is AnycubicS1Client client) client.SendPrint(action); }

    private bool SendElegooRaw(string serial, string json)
    {
        JsonObject? value; try { value = JsonNode.Parse(json) as JsonObject; } catch { return false; }
        if (value?["method"]?.GetValue<int>() is not int method) return false;
        SendElegooMethod(serial, method, value["params"] as JsonObject ?? new JsonObject());
        return true;
    }

    /// Raw G-code line to a Klipper printer over Moonraker.
    public void SendGcode(string serial, string script)
    {
        if (_clients.TryGetValue(serial, out var c) && c is MoonrakerClient m) m.SendGcode(script);
    }

    /// Chamber LED on/off. Bambu uses ledctrl; Klipper a best-effort caselight pin. A per-printer
    /// override wins: Bambu treats it as MQTT JSON, Klipper as a G-code line.
    public void SetChamberLight(bool on, string serial)
    {
        var ov = PrinterOverridesStore.For(serial);
        var custom = on ? ov.LedOn : ov.LedOff;
        if (!string.IsNullOrEmpty(custom))
        {
            var kind = Printers.FirstOrDefault(p => p.Serial == serial)?.Kind;
            if (kind == PrinterKind.Klipper) SendGcode(serial, custom);
            else if (kind is PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2) SendElegooRaw(serial, custom);
            else SendCommand(serial, custom);
            return;
        }
        if (Printers.FirstOrDefault(p => p.Serial == serial)?.Kind == PrinterKind.Klipper)
            SendGcode(serial, on ? "SET_PIN PIN=caselight VALUE=1" : "SET_PIN PIN=caselight VALUE=0");
        else if (Printers.FirstOrDefault(p => p.Serial == serial)?.Kind == PrinterKind.ElegooCc1)
            SendElegooMethod(serial, 403, new { LightStatus = new { SecondLight = on ? 1 : 0 } });
        else if (Printers.FirstOrDefault(p => p.Serial == serial)?.Kind == PrinterKind.ElegooCc2)
            SendElegooMethod(serial, 1029, new { power = on ? 1 : 0 });
        else if (Printers.FirstOrDefault(p => p.Serial == serial)?.Kind == PrinterKind.AnycubicKobraS1 && _clients.GetValueOrDefault(serial) is AnycubicS1Client anycubic)
            anycubic.SetLight(on);
        else
        {
            var mode = on ? "on" : "off";
            SendCommand(serial, $"{{\"system\":{{\"sequence_id\":\"2003\",\"command\":\"ledctrl\",\"led_node\":\"chamber_light\",\"led_mode\":\"{mode}\",\"led_on_time\":500,\"led_off_time\":500,\"loop_times\":0,\"interval_time\":0}}}}");
        }
    }

    /// Runs one automation's action now (Run button and the trigger engine).
    public void RunAutomation(PrinterAutomation auto, string serial)
    {
        var printer = Printers.FirstOrDefault(p => p.Serial == serial);
        var name = printer?.Name ?? serial;
        bool isKlipper = printer?.Kind == PrinterKind.Klipper;
        void PrintCmd(string bambu, string macro)
        {
            if (isKlipper) SendGcode(serial, macro);
            else if (printer?.Kind == PrinterKind.ElegooCc1) SendElegooMethod(serial, bambu.Contains("\"pause\"") ? 129 : bambu.Contains("\"resume\"") ? 131 : 130);
            else if (printer?.Kind == PrinterKind.ElegooCc2) SendElegooMethod(serial, bambu.Contains("\"pause\"") ? 1021 : bambu.Contains("\"resume\"") ? 1023 : 1022);
            else if (printer?.Kind == PrinterKind.AnycubicKobraS1) SendAnycubicPrint(serial, bambu.Contains("\"pause\"") ? "pause" : bambu.Contains("\"resume\"") ? "resume" : "stop");
            else SendCommand(serial, bambu);
        }

        switch (auto.ActionKind)
        {
            case "lightOn": SetChamberLight(true, serial); break;
            case "lightOff": SetChamberLight(false, serial); break;
            case "pause": PrintCmd("{\"print\":{\"sequence_id\":\"2004\",\"command\":\"pause\"}}", "PAUSE"); break;
            case "resume": PrintCmd("{\"print\":{\"sequence_id\":\"2004\",\"command\":\"resume\"}}", "RESUME"); break;
            case "stop": PrintCmd("{\"print\":{\"sequence_id\":\"2004\",\"command\":\"stop\"}}", "CANCEL_PRINT"); break;
            case "notify": NotificationService.Post(name, auto.ActionText); break;
            case "command":
                if (!AllowCodeAction(auto, name)) break;
                if (isKlipper) SendGcode(serial, auto.ActionText);
                else if (printer?.Kind is PrinterKind.ElegooCc1 or PrinterKind.ElegooCc2) SendElegooRaw(serial, auto.ActionText);
                else SendCommand(serial, auto.ActionText);
                break;
            case "script":
                if (!AllowCodeAction(auto, name)) break;
                ScriptRunner.Run(auto.Id, auto.ActionText);
                NotificationService.Post(name, AppSettings.Text($"Uruchomiono skrypt: {auto.Name}", $"Ran script: {auto.Name}"));
                break;
        }
    }

    /// Guard for automation actions that execute code — "script" (a program on this PC) and "command"
    /// (an arbitrary raw MQTT/G-code command). Two layers: (1) a kill switch that is OFF by default, so a
    /// planted config cannot run code silently; (2) a one-time, per-rule consent prompt that shows exactly
    /// what will run. Returns true only when the action may proceed.
    private bool AllowCodeAction(PrinterAutomation auto, string printerName)
    {
        if (!AppSettings.AllowScriptActions)
        {
            NotificationService.Post(printerName, AppSettings.Text(
                $"Pominięto „{auto.Name}” — akcje skryptowe/komendy są wyłączone (Ustawienia → Bezpieczeństwo).",
                $"Skipped \"{auto.Name}\" — script/command actions are disabled (Settings → Security)."));
            return false;
        }
        if (AppSettings.IsScriptRuleApproved(auto.Id)) return true;

        bool approved = false;
        void Ask()
        {
            var preview = (auto.ActionText ?? "").Trim();
            if (preview.Length > 700) preview = preview[..700] + "…";
            bool script = auto.ActionKind == "script";
            var msg = AppSettings.Text(
                $"Automatyzacja „{auto.Name}” ({printerName}) chce wykonać {(script ? "skrypt na tym komputerze" : "komendę drukarki")}:\n\n{preview}\n\nZezwolić i zapamiętać dla tej reguły?",
                $"Automation \"{auto.Name}\" ({printerName}) wants to run {(script ? "a script on this PC" : "a printer command")}:\n\n{preview}\n\nAllow and remember for this rule?");
            approved = System.Windows.MessageBox.Show(msg, "Gantry — " + AppSettings.Text("Potwierdzenie", "Confirm"),
                System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Warning) == System.Windows.MessageBoxResult.Yes;
        }
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is not null && !dispatcher.CheckAccess()) dispatcher.Invoke(Ask); else Ask();
        if (approved) AppSettings.ApproveScriptRule(auto.Id);
        return approved;
    }

    private readonly Dictionary<string, HashSet<string>> _firedAutomations = new();
    /// Printers already warned that their job is nearly done, so the alert fires once per print.
    private readonly HashSet<string> _finishingSoonWarned = new();

    // Fires conditional automations once per print; re-arms only at a clear end-of-print state so
    // Bambu's partial reports (which drop the job name) don't retrigger a rule mid-print.
    private void EvaluateAutomations(string serial, PrinterTelemetry? previous, PrinterTelemetry current)
    {
        if (current.State is PrinterState.Idle or PrinterState.Finished) _firedAutomations[serial] = new();
        foreach (var auto in AutomationStore.For(serial).Where(a => a.Enabled))
        {
            if (!ShouldFire(auto, previous, current)) continue;
            if (!_firedAutomations.TryGetValue(serial, out var fired)) { fired = new(); _firedAutomations[serial] = fired; }
            if (fired.Add(auto.Id)) RunAutomation(auto, serial);
        }
    }

    private static bool ShouldFire(PrinterAutomation auto, PrinterTelemetry? prev, PrinterTelemetry cur) => auto.TriggerKind switch
    {
        "layer" => (cur.CurrentLayer ?? 0) >= auto.TriggerValue && (prev?.CurrentLayer ?? 0) < auto.TriggerValue,
        "progress" => cur.Progress >= auto.TriggerValue && (prev?.Progress ?? -1) < auto.TriggerValue,
        "state" => cur.State.ToString() == auto.TriggerState && prev?.State.ToString() != auto.TriggerState,
        _ => false
    };

    // Append the latest temperatures to the rolling history (throttled to one sample / 2 s).
    private void RecordTemperature(string serial, PrinterTelemetry value)
    {
        if (value.NozzleTemperature is null && value.BedTemperature is null && value.ChamberTemperature is null) return;
        var now = value.LastUpdated ?? DateTime.Now;
        if (!TemperatureHistory.TryGetValue(serial, out var history))
        {
            history = new List<TemperatureSample>();
            TemperatureHistory[serial] = history;
        }
        if (history.Count > 0 && (now - history[^1].Time).TotalSeconds < 2) return;
        history.Add(new TemperatureSample(now, value.NozzleTemperature, value.BedTemperature, value.ChamberTemperature));
        if (history.Count > MaxTemperatureSamples) history.RemoveRange(0, history.Count - MaxTemperatureSamples);
    }

    private void NotifyChanges(SavedPrinter printer, PrinterTelemetry? previous, PrinterTelemetry current)
    {
        bool pl = AppSettings.Polish;
        // Fan every alert out to the native banner and (when enabled) Telegram, both gated by the same
        // per-event toggles below.
        void Push(string title, string body)
        {
            NotificationService.Post(title, body, printer.Name);
            TelegramService.Notify(printer.Name, title, body);
        }
        if (current.State == PrinterState.Finished && previous?.State != PrinterState.Finished)
            PrintHistory.Record(printer.Serial, printer.Name, current.JobName ?? "");
        // Heads-up before the end. Armed once per print: it re-arms as soon as the remaining time is
        // back above the threshold (a new job) or the printer stops printing, so one job cannot nag.
        int remainingMinutes = current.RemainingMinutes ?? int.MaxValue;
        if (current.State == PrinterState.Printing && remainingMinutes > 0
            && remainingMinutes <= AppSettings.FinishingSoonMinutes)
        {
            if (AppSettings.NotifyFinishingSoon && _finishingSoonWarned.Add(printer.Serial))
                Push(string.Format(AppSettings.Text("Koniec za ~{0} min", "Finishing in ~{0} min"), remainingMinutes),
                     current.JobName ?? AppSettings.Text("Wydruk dobiega końca.", "The print is nearly done."));
        }
        else _finishingSoonWarned.Remove(printer.Serial);
        if (AppSettings.NotifyPrintFinished && current.State == PrinterState.Finished && previous?.State != PrinterState.Finished)
            Push(AppSettings.Text("Druk zakończony", "Print finished"),
                current.JobName ?? AppSettings.Text("Zadanie zostało ukończone.", "The job has completed."));

        if (AppSettings.NotifyPrinterError && current.State == PrinterState.Error && (previous?.State != PrinterState.Error || !SequenceEqual(previous?.HmsCodes, current.HmsCodes)))
        {
            string description = HmsResolver.Description(current.HmsCodes, printer.Serial, pl)
                ?? (current.ErrorCode != 0
                    ? string.Format(AppSettings.Text("Kod błędu: 0x{0:X}", "Error code: 0x{0:X}"), current.ErrorCode)
                    : AppSettings.Text("Drukarka zgłosiła błąd.", "The printer reported an error."));
            Push(AppSettings.Text("Błąd drukarki", "Printer error"), description);
        }
        else if (AppSettings.NotifyPrintPaused && current.State == PrinterState.Paused && previous?.State != PrinterState.Paused)
        {
            Push(AppSettings.Text("Druk wstrzymany", "Print paused"),
                current.JobName ?? AppSettings.Text("Drukarka oczekuje na działanie.", "The printer needs attention."));
        }

        // Only trust the level for a chipped (RFID/NFC) spool: a chipless spool has no reliable remain,
        // so RemainingPercent reads as 0 and must not raise a false "low filament" alert (issue #27).
        bool LowAndTrusted(AmsSlot s) => s.RemainingWeightGrams != null && (s.RemainingPercent ?? 100) <= 15;
        var previousLow = new HashSet<string>((previous?.AmsSlots ?? new()).Where(LowAndTrusted).Select(s => s.Id));
        var newLow = current.AmsSlots.Where(s => LowAndTrusted(s) && !previousLow.Contains(s.Id)).ToList();
        if (AppSettings.NotifyLowFilament && newLow.FirstOrDefault() is { } slot)
            Push(AppSettings.Text("Niski poziom filamentu", "Low filament"),
                $"{slot.Label} • {slot.Material} • {slot.RemainingPercent ?? 0}%");

        if (AppSettings.NotifyHighAmsHumidity && IsHumidityHigh(current.AmsHumidity) && !IsHumidityHigh(previous?.AmsHumidity))
            Push(AppSettings.Text("Wysoka wilgotność AMS", "High AMS humidity"),
                AppSettings.Text("Sprawdź lub osusz pochłaniacz wilgoci.", "Check or dry the desiccant."));
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
