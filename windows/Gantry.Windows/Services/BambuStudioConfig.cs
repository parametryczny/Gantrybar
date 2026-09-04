using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>Reads locally stored printer access codes and IPs from Bambu Studio's config.</summary>
public static class BambuStudioConfig
{
    public readonly record struct Device(string Serial, string AccessCode, string? Host);

    /// <summary>Every printer with a saved access code, paired with its last known IP so printers
    /// can be imported without a network scan.</summary>
    public static List<Device> Devices()
    {
        var sections = ReadSections();
        return DevicesFromSections(sections);
    }

    public static Dictionary<string, string> AccessCodes()
        => Devices().ToDictionary(d => d.Serial, d => d.AccessCode);

    /// <summary>
    /// Bambu Studio currently writes JSON on Windows followed by an MD5 checksum line. Older
    /// builds used INI sections. Supporting both formats also makes upgrades between Studio
    /// versions safe.
    /// </summary>
    internal static List<Device> DevicesFromContent(string content)
        => DevicesFromSections(ParseSections(content));

    internal static void RunSelfTest()
    {
        const string jsonWithChecksum = """
            {
              "access_code": { "SERIAL-A": "old-code" },
              "user_access_code": { "SERIAL-A": "new-code", "SERIAL-B": "code-b" },
              "ip_address": { "SERIAL-A": "192.168.1.10" },
              "user_access_dev_ip": { "SERIAL-B": "192.168.1.11" }
            }
            0123456789abcdef0123456789abcdef
            """;
        var jsonDevices = DevicesFromContent(jsonWithChecksum);
        Require(jsonDevices.Count == 2, "JSON device count");
        Require(jsonDevices.Single(d => d.Serial == "SERIAL-A").AccessCode == "new-code", "user code priority");
        Require(jsonDevices.Single(d => d.Serial == "SERIAL-A").Host == "192.168.1.10", "JSON IP");
        Require(jsonDevices.Single(d => d.Serial == "SERIAL-B").Host == "192.168.1.11", "plain LAN IP");

        const string ini = """
            # Bambu Studio configuration
            [access_code]
            SERIAL-C=code-c
            [ip_address]
            SERIAL-C=192.168.1.12
            """;
        var iniDevice = DevicesFromContent(ini).Single();
        Require(iniDevice.Serial == "SERIAL-C" && iniDevice.AccessCode == "code-c", "INI code");
        Require(iniDevice.Host == "192.168.1.12", "INI IP");
    }

    private static List<Device> DevicesFromSections(Dictionary<string, Dictionary<string, string>> sections)
    {
        var codes = Section(sections, "access_code");
        foreach (var kv in Section(sections, "user_access_code")) codes[kv.Key] = kv.Value;
        codes = codes
            .Where(kv => kv.Key.Length > 0 && kv.Value.Length > 0)
            .ToDictionary(kv => kv.Key, kv => kv.Value);
        if (codes.Count == 0)
            throw new BambuStudioConfigException(AppSettings.T("Bambu Studio has no stored printer codes. Connect the printer locally in Bambu Studio and try again."));

        var ips = Section(sections, "ip_address");
        foreach (var kv in Section(sections, "user_access_dev_ip"))
        {
            // Recent Studio versions may encode these values. Accept them only when the value
            // is already a plain address; detected printers will supply the IP otherwise.
            if (IPAddress.TryParse(kv.Value, out _)) ips[kv.Key] = kv.Value;
        }

        return codes.Select(kv =>
        {
            string? host = ips.TryGetValue(kv.Key, out var value) && IPAddress.TryParse(value, out _)
                ? value
                : null;
            return new Device(kv.Key, kv.Value, host);
        }).ToList();
    }

    private static Dictionary<string, Dictionary<string, string>> ReadSections()
    {
        var candidates = ConfigCandidates().Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var foundAny = false;
        Exception? lastError = null;

        foreach (var path in candidates)
        {
            foreach (var candidate in new[] { path, path + ".bak" })
            {
                if (!File.Exists(candidate)) continue;
                foundAny = true;
                try { return ParseSections(ReadShared(candidate)); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or FormatException)
                {
                    lastError = error;
                }
            }
        }

        if (!foundAny)
            throw new BambuStudioConfigException(AppSettings.T("Bambu Studio configuration was not found. Run Bambu Studio at least once and add a printer there."));

        throw new BambuStudioConfigException(AppSettings.T("Could not read the Bambu Studio configuration. Close Bambu Studio and try again."), lastError);
    }

    private static IEnumerable<string> ConfigCandidates()
    {
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
        };
        var folders = new[] { "BambuStudio", "Bambu Studio", "BambuStudioBeta", "BambuStudioInternal" };
        foreach (var root in roots.Where(path => !string.IsNullOrWhiteSpace(path)))
            foreach (var folder in folders)
                yield return Path.Combine(root, folder, "BambuStudio.conf");
    }

    private static string ReadShared(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    private static Dictionary<string, Dictionary<string, string>> ParseSections(string content)
    {
        var trimmed = content.TrimStart('\uFEFF', ' ', '\t', '\r', '\n');
        if (trimmed.StartsWith('{'))
        {
            var closingBrace = trimmed.LastIndexOf('}');
            if (closingBrace < 0) throw new FormatException("JSON object is incomplete.");
            using var document = JsonDocument.Parse(trimmed[..(closingBrace + 1)]);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                throw new FormatException("JSON root is not an object.");
            return JsonSections(document.RootElement);
        }

        return IniSections(content);
    }

    private static Dictionary<string, Dictionary<string, string>> JsonSections(JsonElement root)
    {
        var sections = NewSections();
        foreach (var section in root.EnumerateObject())
        {
            if (section.Value.ValueKind != JsonValueKind.Object) continue;
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in section.Value.EnumerateObject())
                if (property.Value.ValueKind == JsonValueKind.String && property.Value.GetString() is { } value)
                    values[property.Name.Trim()] = value.Trim();
            if (values.Count > 0) sections[section.Name] = values;
        }
        return sections;
    }

    private static Dictionary<string, Dictionary<string, string>> IniSections(string content)
    {
        var sections = NewSections();
        Dictionary<string, string>? current = null;
        using var reader = new StringReader(content);
        while (reader.ReadLine() is { } rawLine)
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.StartsWith(';')) continue;
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                var name = line[1..^1].Trim();
                if (name.Length == 0) continue;
                current = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                sections[name] = current;
                continue;
            }
            if (current is null) continue;
            var separator = line.IndexOf('=');
            if (separator <= 0) continue;
            var key = line[..separator].Trim();
            var value = line[(separator + 1)..].Trim();
            if (key.Length > 0) current[key] = value;
        }
        if (sections.Count == 0) throw new FormatException("Unsupported configuration format.");
        return sections;
    }

    private static Dictionary<string, Dictionary<string, string>> NewSections()
        => new(StringComparer.OrdinalIgnoreCase);

    private static Dictionary<string, string> Section(
        Dictionary<string, Dictionary<string, string>> sections,
        string name)
        => sections.TryGetValue(name, out var values)
            ? new Dictionary<string, string>(values, StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new InvalidOperationException($"Bambu Studio config self-test failed: {name}");
    }
}

public sealed class BambuStudioConfigException : Exception
{
    public BambuStudioConfigException(string message, Exception? innerException = null)
        : base(message, innerException) { }
}
