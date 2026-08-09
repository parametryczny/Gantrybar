using System.Text;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Parses an SSDP advertisement into a DiscoveredPrinter, ported from the macOS parser.</summary>
public static class SsdpResponseParser
{
    public static DiscoveredPrinter? Parse(byte[] data, string? fallbackHost = null)
    {
        string text;
        try { text = Encoding.UTF8.GetString(data); }
        catch { return null; }

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in text.Split('\n', '\r'))
        {
            int colon = line.IndexOf(':');
            if (colon < 0) continue;
            string key = line[..colon].Trim().ToLowerInvariant();
            string value = line[(colon + 1)..].Trim();
            headers[key] = value;
        }

        string rawSerial = Value(headers, "usn", "devserial.bambu.com", "serial-number")
            .Replace("uuid:", "", StringComparison.OrdinalIgnoreCase);
        string serial = rawSerial.Split(new[] { "::" }, 2, StringSplitOptions.None)[0];
        if (string.IsNullOrEmpty(serial)) return null;

        string location = Value(headers, "location");
        string host = HostFrom(location) ?? fallbackHost ?? "";
        if (string.IsNullOrEmpty(host)) return null;

        string name = Value(headers, "devname.bambu.com", "friendlyname", "name");
        string model = Value(headers, "devmodel.bambu.com", "modelname", "model");
        string suffix = serial.Length >= 4 ? serial[^4..] : serial;
        return new DiscoveredPrinter
        {
            Serial = serial,
            Name = string.IsNullOrEmpty(name) ? $"Bambu {suffix}" : name,
            Model = string.IsNullOrEmpty(model) ? "Bambu Lab" : model,
            Host = host
        };
    }

    private static string Value(Dictionary<string, string> headers, params string[] keys)
    {
        foreach (var key in keys)
            if (headers.TryGetValue(key, out var v) && !string.IsNullOrEmpty(v))
                return v;
        return "";
    }

    private static string? HostFrom(string location)
    {
        if (Uri.TryCreate(location, UriKind.Absolute, out var url) && !string.IsNullOrEmpty(url.Host))
            return url.Host;
        var trimmed = location.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }
}
