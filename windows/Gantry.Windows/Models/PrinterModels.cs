using System.Text.Json.Serialization;

namespace Gantry.Models;

public enum PrinterState
{
    Idle,
    Printing,
    Paused,
    Finished,
    Error,
    Offline
}

public static class PrinterStateExtensions
{
    private static readonly IReadOnlyDictionary<int, (string Pl, string En, string De)> StageLabels =
        new Dictionary<int, (string, string, string)>
        {
            [0] = ("Drukowanie", "Printing", "Druckt"),
            [1] = ("Poziomowanie stołu", "Auto bed leveling", "Automatische Druckbettnivellierung"),
            [2] = ("Nagrzewanie stołu", "Heating bed", "Druckbett wird aufgeheizt"),
            [3] = ("Kalibracja drgań", "Vibration calibration", "Vibrationskalibrierung"),
            [4] = ("Zmiana filamentu", "Changing filament", "Filament wird gewechselt"),
            [5] = ("Oczekiwanie", "Waiting", "Wartet"),
            [6] = ("Brak filamentu", "Filament runout", "Filament aufgebraucht"),
            [7] = ("Nagrzewanie dyszy", "Heating nozzle", "Düse wird aufgeheizt"),
            [8] = ("Kalibracja ekstruzji", "Calibrating extrusion", "Extrusion wird kalibriert"),
            [9] = ("Skanowanie stołu", "Scanning bed", "Druckbett wird gescannt"),
            [10] = ("Kontrola pierwszej warstwy", "Inspecting first layer", "Erste Schicht wird geprüft"),
            [11] = ("Rozpoznawanie płyty", "Identifying build plate", "Druckplatte wird erkannt"),
            [12] = ("Kalibracja LiDAR", "Calibrating LiDAR", "LiDAR wird kalibriert"),
            [13] = ("Bazowanie", "Homing", "Referenzfahrt"),
            [14] = ("Czyszczenie dyszy", "Cleaning nozzle", "Düse wird gereinigt"),
            [15] = ("Kontrola temperatury dyszy", "Checking nozzle temperature", "Düsentemperatur wird geprüft"),
            [16] = ("Wstrzymano przez użytkownika", "Paused by user", "Von dir pausiert"),
            [17] = ("Otwarta przednia osłona", "Front cover open", "Frontabdeckung geöffnet"),
            [18] = ("Kalibracja LiDAR", "Calibrating LiDAR", "LiDAR wird kalibriert"),
            [19] = ("Kalibracja przepływu", "Calibrating flow", "Fluss wird kalibriert"),
            [20] = ("Błąd temperatury dyszy", "Nozzle temperature issue", "Problem mit der Düsentemperatur"),
            [21] = ("Błąd temperatury stołu", "Bed temperature issue", "Problem mit der Druckbetttemperatur"),
            [22] = ("Wyładowanie filamentu", "Unloading filament", "Filament wird entladen"),
            [23] = ("Wykryto pominięty krok", "Skipped step detected", "Schrittverlust erkannt"),
            [24] = ("Ładowanie filamentu", "Loading filament", "Filament wird geladen"),
            [25] = ("Kalibracja silników", "Calibrating motors", "Motoren werden kalibriert"),
            [26] = ("Utracono połączenie z AMS", "AMS connection lost", "AMS-Verbindung verloren"),
            [27] = ("Niska prędkość wentylatora", "Low heatbreak fan speed", "Heatbreak-Lüfter zu langsam"),
            [28] = ("Błąd temperatury komory", "Chamber temperature issue", "Problem mit der Bauraumtemperatur"),
            [29] = ("Chłodzenie komory", "Cooling chamber", "Bauraum wird gekühlt"),
            [30] = ("Pauza z G-code", "Paused by G-code", "Durch G-Code pausiert"),
            [31] = ("Test dźwięku silników", "Motor noise test", "Motorgeräuschtest"),
            [32] = ("Filament na dyszy", "Filament covering nozzle", "Filament bedeckt die Düse"),
            [33] = ("Błąd obcinaka", "Cutter issue", "Problem mit dem Filamentschneider"),
            [34] = ("Błąd pierwszej warstwy", "First layer issue", "Problem mit der ersten Schicht"),
            [35] = ("Zatkana dysza", "Nozzle clog", "Düse verstopft"),
            [36] = ("Kontrola dokładności", "Checking accuracy", "Genauigkeit wird geprüft"),
            [37] = ("Kalibracja dokładności", "Calibrating accuracy", "Genauigkeit wird kalibriert"),
            [38] = ("Weryfikacja dokładności", "Verifying accuracy", "Genauigkeit wird verifiziert"),
            [39] = ("Kalibracja offsetu dyszy", "Calibrating nozzle offset", "Düsenversatz wird kalibriert"),
            [40] = ("Poziomowanie na gorąco", "High-temperature bed leveling", "Druckbettnivellierung bei hoher Temperatur"),
            [41] = ("Kontrola szybkozłącza", "Checking quick release", "Schnellverschluss wird geprüft"),
            [42] = ("Kontrola drzwi i osłon", "Checking doors and covers", "Türen und Abdeckungen werden geprüft"),
            [43] = ("Kalibracja lasera", "Calibrating laser", "Laser wird kalibriert"),
            [44] = ("Kontrola platformy", "Checking platform", "Plattform wird geprüft"),
            [45] = ("Kontrola kamery BirdEye", "Checking BirdEye camera", "BirdEye-Kamera wird geprüft"),
            [46] = ("Kalibracja kamery BirdEye", "Calibrating BirdEye camera", "BirdEye-Kamera wird kalibriert"),
            [47] = ("Poziomowanie stołu · 1", "Bed leveling · 1", "Druckbettnivellierung · 1"),
            [48] = ("Poziomowanie stołu · 2", "Bed leveling · 2", "Druckbettnivellierung · 2"),
            [49] = ("Nagrzewanie komory", "Heating chamber", "Bauraum wird aufgeheizt"),
            [50] = ("Chłodzenie stołu", "Cooling bed", "Druckbett wird gekühlt"),
            [51] = ("Druk linii kalibracyjnych", "Printing calibration lines", "Kalibrierungslinien werden gedruckt"),
            [52] = ("Kontrola materiału", "Checking material", "Material wird geprüft"),
            [53] = ("Kalibracja kamery podglądu", "Calibrating live-view camera", "Livebildkamera wird kalibriert"),
            [54] = ("Oczekiwanie na temperaturę stołu", "Waiting for bed temperature", "Wartet auf Druckbetttemperatur"),
            [55] = ("Kontrola pozycji materiału", "Checking material position", "Materialposition wird geprüft"),
            [56] = ("Kalibracja offsetu obcinaka", "Calibrating cutter offset", "Versatz des Filamentschneiders wird kalibriert"),
            [57] = ("Pomiar powierzchni", "Measuring surface", "Oberfläche wird vermessen"),
            [58] = ("Przygotowanie termiczne", "Thermal preconditioning", "Thermische Vorbereitung"),
            [59] = ("Bazowanie uchwytu ostrza", "Homing blade holder", "Referenzfahrt des Klingenhalters"),
            [60] = ("Kalibracja offsetu kamery", "Calibrating camera offset", "Kameraversatz wird kalibriert"),
            [61] = ("Kalibracja uchwytu ostrza", "Calibrating blade holder", "Klingenhalter wird kalibriert"),
            [62] = ("Test wymiany hotendu", "Hotend pick-and-place test", "Hotend-Wechseltest"),
            [63] = ("Stabilizacja temperatury komory", "Equalizing chamber temperature", "Bauraumtemperatur wird stabilisiert"),
            [64] = ("Przygotowanie hotendu", "Preparing hotend", "Hotend wird vorbereitet"),
            [65] = ("Kalibracja wykrywania grudek", "Calibrating clump detection", "Klumpenerkennung wird kalibriert"),
            [66] = ("Oczyszczanie powietrza", "Purifying chamber air", "Bauraumluft wird gereinigt"),
            [67] = ("Pomiar modułu obrotowego", "Measuring rotary attachment", "Drehmodul wird vermessen"),
            [68] = ("Przejazd nad zsyp", "Moving above purge chute", "Fährt über den Auswurfschacht"),
            [69] = ("Chłodzenie dyszy", "Cooling nozzle", "Düse wird gekühlt"),
            [70] = ("Centrowanie głowicy", "Centering toolhead", "Werkzeugkopf wird zentriert"),
            [71] = ("Dopasowanie łuków", "Arc fitting", "Bögen werden angepasst"),
            [72] = ("Rozpoznawanie hotendu", "Detecting hotend type", "Hotend-Typ wird erkannt"),
            [73] = ("Kontrola ułożenia płyty", "Checking build plate alignment", "Ausrichtung der Druckplatte wird geprüft"),
            [74] = ("Kontrola powierzchni stołu", "Checking bed surface", "Druckbettoberfläche wird geprüft"),
            [75] = ("Kontrola spodu stołu", "Checking bed underside", "Druckbettunterseite wird geprüft"),
            [76] = ("Wstępna ekstruzja", "Pre-extrusion", "Vor-Extrusion"),
            [77] = ("Przygotowanie AMS", "Preparing AMS", "AMS wird vorbereitet"),
        };

    public static string Label(this PrinterState state, string language) => (state, language) switch
    {
        (PrinterState.Idle, "pl") => "Gotowa",
        (PrinterState.Idle, "de") => "Bereit",
        (PrinterState.Printing, "pl") => "Drukowanie",
        (PrinterState.Printing, "de") => "Druckt",
        (PrinterState.Paused, "pl") => "Wstrzymana",
        (PrinterState.Paused, "de") => "Pausiert",
        (PrinterState.Finished, "pl") => "Zakończono",
        (PrinterState.Finished, "de") => "Abgeschlossen",
        (PrinterState.Error, "pl") => "Błąd",
        (PrinterState.Error, "de") => "Fehler",
        (PrinterState.Offline, _) => "Offline",
        (PrinterState.Idle, _) => "Ready",
        (PrinterState.Printing, _) => "Printing",
        (PrinterState.Paused, _) => "Paused",
        (PrinterState.Finished, _) => "Finished",
        (PrinterState.Error, _) => "Error",
        _ => "—"
    };

    public static string ActivityLabel(this PrinterTelemetry telemetry, string language)
    {
        if (telemetry.State is PrinterState.Printing or PrinterState.Paused &&
            telemetry.CurrentStage is int stage && StageLabels.TryGetValue(stage, out var label))
            return language switch { "pl" => label.Pl, "de" => label.De, _ => label.En };
        return telemetry.State.Label(language);
    }

    /// <summary>Accent colour (hex, no #) used on the printer card, mirroring the macOS symbols.</summary>
    public static string AccentHex(this PrinterState state) => state switch
    {
        PrinterState.Idle => "30D158",
        PrinterState.Printing => "0A84FF",
        PrinterState.Paused => "FF9F0A",
        PrinterState.Finished => "30D158",
        PrinterState.Error => "FF453A",
        PrinterState.Offline => "8E8E93",
        _ => "8E8E93"
    };
}

/// <summary>Live telemetry for one printer. Reference type so incremental MQTT updates merge in place.</summary>
public sealed class PrinterTelemetry
{
    public PrinterState State { get; set; } = PrinterState.Offline;
    public int Progress { get; set; }
    public int? RemainingMinutes { get; set; }
    public double? NozzleTemperature { get; set; }
    public double? NozzleTargetTemperature { get; set; }
    // Second nozzle on dual-nozzle printers (H2D); null on single-nozzle machines.
    public double? NozzleTemperature2 { get; set; }
    public double? NozzleTargetTemperature2 { get; set; }
    public double? BedTemperature { get; set; }
    public double? BedTargetTemperature { get; set; }
    public double? ChamberTemperature { get; set; }
    public int? CurrentLayer { get; set; }
    public int? TotalLayers { get; set; }
    public int? CurrentStage { get; set; }
    public string? JobName { get; set; }
    public ulong ErrorCode { get; set; }
    public List<string> HmsCodes { get; set; } = new();
    // Physical filament modules (AMS / AMS HT / CFS / MMU / external). Primary source for the
    // dashboard; AmsSlots stays as a flat compatibility view for notifications / the tray.
    public List<FilamentGroup> FilamentGroups { get; set; } = new();
    // One entry for a single-nozzle machine, two (Left/Right) for dual-nozzle printers like the H2D.
    public List<NozzleTelemetry> Nozzles { get; set; } = new();
    public List<AmsSlot> AmsSlots { get; set; } = new();
    public int? AmsHumidity { get; set; }
    public double? AmsTemperature { get; set; }
    public DateTime? LastUpdated { get; set; }

    public PrinterTelemetry Clone()
    {
        return new PrinterTelemetry
        {
            State = State,
            Progress = Progress,
            RemainingMinutes = RemainingMinutes,
            NozzleTemperature = NozzleTemperature,
            NozzleTargetTemperature = NozzleTargetTemperature,
            NozzleTemperature2 = NozzleTemperature2,
            NozzleTargetTemperature2 = NozzleTargetTemperature2,
            BedTemperature = BedTemperature,
            BedTargetTemperature = BedTargetTemperature,
            ChamberTemperature = ChamberTemperature,
            CurrentLayer = CurrentLayer,
            TotalLayers = TotalLayers,
            CurrentStage = CurrentStage,
            JobName = JobName,
            ErrorCode = ErrorCode,
            HmsCodes = new List<string>(HmsCodes),
            FilamentGroups = FilamentGroups.Select(g => g.Clone()).ToList(),
            Nozzles = Nozzles.Select(n => n.Clone()).ToList(),
            AmsSlots = AmsSlots.Select(s => s.Clone()).ToList(),
            AmsHumidity = AmsHumidity,
            AmsTemperature = AmsTemperature,
            LastUpdated = LastUpdated
        };
    }
}

public sealed class AmsSlot
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Material { get; set; } = "";
    public string ColorHex { get; set; } = "8E8E93FF";
    public int? RemainingPercent { get; set; }
    public bool IsActive { get; set; }
    public bool IsExternal { get; set; }

    public AmsSlot Clone() => (AmsSlot)MemberwiseClone();
}

/// <summary>Which physical filament system a group came from.</summary>
public enum FilamentSourceType { Ams, AmsHT, Cfs, Mmu, External }

/// <summary>One physical filament module and its slots. Empty slots stay so the layout never
/// collapses when a spool is removed.</summary>
public sealed class FilamentGroup
{
    public string Id { get; set; } = "";
    public FilamentSourceType SourceType { get; set; }
    public string DisplayName { get; set; } = "";   // AMS A, AMS HT, CFS 1, MMU, EXT
    public int DeclaredCapacity { get; set; }        // 1, 4 or a dynamic gate count
    public int? HumidityPercent { get; set; }        // per-module, null when the firmware omits it
    public double? TemperatureCelsius { get; set; }
    public bool IsExternal { get; set; }
    public List<FilamentSlot> Slots { get; set; } = new();

    public FilamentGroup Clone() => new()
    {
        Id = Id,
        SourceType = SourceType,
        DisplayName = DisplayName,
        DeclaredCapacity = DeclaredCapacity,
        HumidityPercent = HumidityPercent,
        TemperatureCelsius = TemperatureCelsius,
        IsExternal = IsExternal,
        Slots = Slots.Select(s => s.Clone()).ToList()
    };

    /// <summary>Flatten to the legacy AmsSlot list still used by notifications / the tray.</summary>
    public IEnumerable<AmsSlot> LegacyAmsSlots() => Slots.Select(s => new AmsSlot
    {
        Id = s.Id,
        Label = s.Label,
        Material = s.IsPresent ? (s.Material ?? "—") : "—",
        ColorHex = s.ColorHex ?? "8E8E93FF",
        RemainingPercent = s.RemainingPercent,
        IsActive = s.IsActive,
        IsExternal = IsExternal
    });
}

public sealed class FilamentSlot
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";      // A1, B3, T6, EXT
    public string? Material { get; set; }         // null / empty => empty slot
    public string? ColorHex { get; set; }
    public int? RemainingPercent { get; set; }
    public bool IsActive { get; set; }

    public bool IsPresent => !string.IsNullOrEmpty(Material) && Material != "—";

    public FilamentSlot Clone() => (FilamentSlot)MemberwiseClone();
}

public enum NozzlePosition { Single, Left, Right }

public sealed class NozzleTelemetry
{
    public NozzlePosition Position { get; set; }
    public double? CurrentTemperature { get; set; }
    public double? TargetTemperature { get; set; }

    public NozzleTelemetry Clone() => (NozzleTelemetry)MemberwiseClone();
}

public enum PrinterKind { Bambu, Klipper, Prusa }

public sealed class SavedPrinter
{
    [JsonPropertyName("serial")] public string Serial { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "Bambu Lab";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    // Missing in printers saved before Klipper support → defaults to Bambu.
    [JsonPropertyName("kind")] public PrinterKind Kind { get; set; } = PrinterKind.Bambu;
    [JsonPropertyName("port")] public int? Port { get; set; }
    [JsonPropertyName("apiKey")] public string? ApiKey { get; set; }
}

/// <summary>A live connection to one printer (MqttClient for Bambu, MoonrakerClient for Klipper).</summary>
public interface IPrinterConnection
{
    void Start();
    void Stop();
}

public sealed class DiscoveredPrinter
{
    public string Serial { get; set; } = "";
    public string Name { get; set; } = "";
    public string Model { get; set; } = "Bambu Lab";
    public string Host { get; set; } = "";
}
