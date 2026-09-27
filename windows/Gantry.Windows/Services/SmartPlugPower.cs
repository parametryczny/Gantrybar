using System.Globalization;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>Reads a socket's energy meter reply. Kept free of application state so the tests can run it.
/// Mirrors macOS SmartPlug.parsePower.</summary>
public static class SmartPlugPower
{
    /// <summary>Whether this kind of socket can report its power draw at all.</summary>
    public static bool Meters(string kind) => kind is "tasmota" or "shelly" or "shellyRPC";

    /// <summary>Watts out of an energy-meter reply. Null when the device does not meter this outlet.</summary>
    public static double? Parse(string kind, int channel, string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            int index = Math.Max(1, channel) - 1;
            switch (kind)
            {
                case "shellyRPC":
                    return Child(root, "apower") is { } apower ? Number(apower) : null;
                case "tasmota":
                {
                    if (Child(root, "StatusSNS") is not { } sns || Child(sns, "ENERGY") is not { } energy || Child(energy, "Power") is not { } power)
                        return null;
                    if (power.ValueKind == JsonValueKind.Array)
                        return index < power.GetArrayLength() ? Number(power[index]) : null;
                    return Number(power);
                }
                case "shelly":
                {
                    var meters = Child(root, "meters") ?? Child(root, "emeters");
                    if (meters is not { ValueKind: JsonValueKind.Array } list || index >= list.GetArrayLength()) return null;
                    return Child(list[index], "power") is { } watts ? Number(watts) : null;
                }
                default:
                    return null;
            }
        }
        catch (JsonException) { return null; }
    }

    private static double? Number(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Number => value.GetDouble(),
        JsonValueKind.String => double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : null,
        _ => null,
    };

    private static JsonElement? Child(JsonElement parent, string name) =>
        parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) ? value : null;
}
