using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gantry.Models;

namespace Gantry.Services;

// Wire models for LAN sync. The JSON MUST match the macOS Codable contract exactly (camelCase keys,
// ISO-8601 dates without fractional seconds), so a Mac and a Windows PC can sync with each other.

/// <summary>A printer as shared over sync. Secrets are omitted: Bambu access codes and Klipper/Prusa
/// apiKey are never sent. Kind is the lowercase string the macOS PrinterKind uses ("bambu", ...).</summary>
public sealed class SyncPrinter
{
    public string Serial { get; set; } = "";
    public string Name { get; set; } = "";
    public string Model { get; set; } = "Bambu Lab";
    public string Host { get; set; } = "";
    public string Kind { get; set; } = "bambu";
    public int? Port { get; set; }

    public static string KindToString(PrinterKind k) => k switch
    {
        PrinterKind.Klipper => "klipper",
        PrinterKind.Prusa => "prusa",
        PrinterKind.Snapmaker => "snapmaker",
        PrinterKind.ElegooCc1 => "elegoo_cc1",
        PrinterKind.ElegooCc2 => "elegoo_cc2",
        _ => "bambu",
    };
    public static PrinterKind KindFromString(string s) => s switch
    {
        "klipper" => PrinterKind.Klipper,
        "prusa" => PrinterKind.Prusa,
        "snapmaker" => PrinterKind.Snapmaker,
        "elegoo_cc1" => PrinterKind.ElegooCc1,
        "elegoo_cc2" => PrinterKind.ElegooCc2,
        _ => PrinterKind.Bambu,
    };
}

/// <summary>Display and notification preferences that travel between machines (last-write-wins by
/// UpdatedAt). Matches the macOS SyncSettings field set exactly.</summary>
public sealed class SyncSettings
{
    public DateTime UpdatedAt { get; set; }
    public string Theme { get; set; } = "dark";
    public string Language { get; set; } = "pl";
    public string PanelTransparency { get; set; } = "low";
    public bool SpoolbaseEnabled { get; set; }
    public bool WebDashboardEnabled { get; set; }
    public bool? Monochrome { get; set; }   // nullable so a peer on an older build still deserializes
    public bool AutoUpdate { get; set; }
    public bool CardShowFileName { get; set; }
    public bool CardShowProgress { get; set; }
    public bool CardShowTemperatures { get; set; }
    public bool CardShowFilaments { get; set; }
    public bool NotifyFinished { get; set; }
    public bool NotifyError { get; set; }
    public bool NotifyPaused { get; set; }
    public bool NotifyLowFilament { get; set; }
    public bool NotifyHumidity { get; set; }
}

/// <summary>One machine's full sync payload. Exchanged in both directions; each side merges what it gets.</summary>
public sealed class SyncSnapshot
{
    public int ProtocolVersion { get; set; } = 1;
    public string DeviceID { get; set; } = "";
    public string DeviceName { get; set; } = "";
    public DateTime GeneratedAt { get; set; } = DateTime.UtcNow;
    public List<PhysicalSpool> Spools { get; set; } = new();
    public List<SpoolUsageEvent> UsageEvents { get; set; } = new();
    public List<Filament> Catalog { get; set; } = new();
    public List<SyncPrinter> Printers { get; set; } = new();
    public SyncSettings? Settings { get; set; }
}

/// <summary>A paired machine we sync with, addressed by host (or host:port) on the LAN.</summary>
public sealed class SyncPeer
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string Address { get; set; } = "";
    public DateTime? LastSyncAt { get; set; }
    public string? LastError { get; set; }
}

/// <summary>Serialises dates as "yyyy-MM-ddTHH:mm:ssZ" (UTC, no fractional seconds) to match Swift's
/// .iso8601 strategy, and parses leniently so a fractional or offset date still round-trips.</summary>
public sealed class Iso8601DateTimeConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
        => DateTime.Parse(reader.GetString()!, CultureInfo.InvariantCulture,
                          DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions o)
        => writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
}

public sealed class Iso8601NullableDateTimeConverter : JsonConverter<DateTime?>
{
    public override DateTime? Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
        => reader.TokenType == JsonTokenType.Null ? null
           : DateTime.Parse(reader.GetString()!, CultureInfo.InvariantCulture,
                            DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
    public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions o)
    {
        if (value is null) writer.WriteNullValue();
        else writer.WriteStringValue(value.Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
    }
}

public static class SyncJson
{
    // camelCase so the wrapper types (SyncSnapshot/SyncPrinter/SyncSettings) match macOS; the nested
    // Spoolbase models keep their explicit [JsonPropertyName] which override this policy.
    public static readonly JsonSerializerOptions Options = Build();

    private static JsonSerializerOptions Build()
    {
        var o = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
        // Enums as lowercase strings ("active", "ams", ...) to match the macOS Codable String enums.
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        o.Converters.Add(new Iso8601DateTimeConverter());
        o.Converters.Add(new Iso8601NullableDateTimeConverter());
        return o;
    }
}
