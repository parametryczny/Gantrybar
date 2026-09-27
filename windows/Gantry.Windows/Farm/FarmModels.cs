using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml;
using Gantry.Models;

namespace Gantry.Services;

// Farm: a library of sliced 3MF files, sent to Bambu Lab printers over local FTPS and started over
// MQTT, plus a queue that hands copies to printers whose bed the user confirmed empty. Mirrors the
// macOS Farm (Sources/Gantry/Farm).

public sealed class FarmFilament
{
    [JsonPropertyName("id")] public int Id { get; set; }
    [JsonPropertyName("material")] public string Material { get; set; } = "?";
    [JsonPropertyName("color")] public string Color { get; set; } = "";
    [JsonPropertyName("grams")] public double Grams { get; set; }
}

public sealed class FarmPlate
{
    [JsonPropertyName("index")] public int Index { get; set; }
    [JsonPropertyName("filaments")] public List<FarmFilament> Filaments { get; set; } = new();
    [JsonPropertyName("seconds")] public int? Seconds { get; set; }
    [JsonPropertyName("printerModel")] public string? PrinterModel { get; set; }
    [JsonPropertyName("nozzle")] public double? Nozzle { get; set; }
}

public sealed class FarmFile
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("bytes")] public long Bytes { get; set; }
    [JsonPropertyName("plates")] public List<FarmPlate> Plates { get; set; } = new();
    [JsonPropertyName("importedAt")] public DateTime ImportedAt { get; set; } = DateTime.UtcNow;
    /// "gcode" or "bgcode" for files printed on Klipper, PrusaLink and OctoPrint; null for a Bambu 3MF.
    [JsonPropertyName("format")] [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Format { get; set; }
    [JsonIgnore] public string FileExtension => Format ?? "3mf";
    [JsonIgnore] public bool IsGcode => Format is not null;
}

public enum FarmJobState { Uploading, Uploaded, AwaitingStart, Printing, Finished, Failed, Uncertain }

public sealed class FarmJob
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("fileID")] public Guid FileId { get; set; }
    [JsonPropertyName("fileName")] public string FileName { get; set; } = "";
    [JsonPropertyName("serial")] public string Serial { get; set; } = "";
    [JsonPropertyName("printerName")] public string PrinterName { get; set; } = "";
    [JsonPropertyName("plate")] public FarmPlate Plate { get; set; } = new();
    [JsonPropertyName("mapping")] public List<int> Mapping { get; set; } = new();
    [JsonPropertyName("remoteName")] public string RemoteName { get; set; } = "";
    [JsonPropertyName("state")] [JsonConverter(typeof(JsonStringEnumConverter))] public FarmJobState State { get; set; }
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("startRequestedAt")] public DateTime? StartRequestedAt { get; set; }
    [JsonPropertyName("updatedAt")] public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("bedLeveling")] public bool BedLeveling { get; set; } = true;
    [JsonPropertyName("queueItemID")] public Guid? QueueItemId { get; set; }
    [JsonPropertyName("autoStart")] public bool? AutoStart { get; set; }
    /// A G-code job, started over HTTP; a 3MF job is a Bambu project_file start.
    [JsonIgnore] public bool IsGcode => !RemoteName.EndsWith(".3mf", StringComparison.OrdinalIgnoreCase);
}

/// <summary>A plate waiting for a free printer; copies go one per printer, only to a printer the user
/// marked as having an empty bed, with the file's filaments already loaded.</summary>
public sealed class FarmQueueItem
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("fileID")] public Guid FileId { get; set; }
    [JsonPropertyName("fileName")] public string FileName { get; set; } = "";
    [JsonPropertyName("plate")] public FarmPlate Plate { get; set; } = new();
    [JsonPropertyName("copies")] public int Copies { get; set; } = 1;
    /// Serials allowed to take this item; empty means any Bambu Lab printer. G-code items always name
    /// their printers: G-code is sliced for one machine and must not wander to another.
    [JsonPropertyName("printers")] public List<string> Printers { get; set; } = new();
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("format")] [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Format { get; set; }
}

public sealed class FarmError : Exception { public FarmError(string message) : base(message) { } }

/// <summary>Reads what a slicer writes into a G-code file's comments: time, filaments, nozzle, printer,
/// and the embedded PNG thumbnail. Only the head and tail are scanned, never the whole toolpath.
/// Mirrors macOS FarmGcode.</summary>
public static class FarmGcode
{
    public static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) { "gcode", "gco", "g", "bgcode" };

    public static bool IsGcode(string path) => Extensions.Contains(Path.GetExtension(path).TrimStart('.'));

    public static string Format(string path) =>
        Path.GetExtension(path).Equals(".bgcode", StringComparison.OrdinalIgnoreCase) ? "bgcode" : "gcode";

    private static string Comments(byte[] data)
    {
        const int window = 512 * 1024;
        var head = Encoding.UTF8.GetString(data, 0, Math.Min(window, data.Length));
        var tail = data.Length > window ? Encoding.UTF8.GetString(data, data.Length - window, window) : "";
        return head + "\n" + tail;
    }

    /// <summary>Key/value comments such as <c>; filament_type = PLA;PETG</c> or <c>;TIME:3600</c>.</summary>
    public static Dictionary<string, string> Settings(string text)
    {
        var result = new Dictionary<string, string>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (!line.StartsWith(';')) continue;
            var body = line[1..].Trim();
            int equals = body.IndexOf('='), colon = body.IndexOf(':');
            int separator = equals >= 0 ? equals : colon;
            if (separator < 0) continue;
            var key = body[..separator].Trim().ToLowerInvariant();
            var value = body[(separator + 1)..].Trim();
            if (key.Length == 0 || key.Length >= 80 || result.ContainsKey(key)) continue;
            result[key] = value;
        }
        return result;
    }

    /// <summary>"1d 2h 3m 4s" (PrusaSlicer, Orca), or plain seconds (Cura).</summary>
    public static int? Seconds(string text)
    {
        if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var plain)) return plain;
        int total = 0;
        bool found = false;
        var number = new StringBuilder();
        foreach (char character in text)
        {
            if (char.IsDigit(character)) { number.Append(character); continue; }
            if (!int.TryParse(number.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value)) { number.Clear(); continue; }
            switch (character)
            {
                case 'd': total += value * 86_400; found = true; break;
                case 'h': total += value * 3_600; found = true; break;
                case 'm': total += value * 60; found = true; break;
                case 's': total += value; found = true; break;
            }
            number.Clear();
        }
        return found ? total : null;
    }

    public static FarmPlate Plate(byte[] data)
    {
        var values = Settings(Comments(data));
        string? Value(string key) => values.TryGetValue(key, out var value) ? value : null;
        var plate = new FarmPlate { Index = 1 };
        plate.Seconds = (Value("estimated printing time (normal mode)") is { } normal ? Seconds(normal) : null)
            ?? (Value("time") is { } time ? Seconds(time) : null)
            ?? (Value("total estimated time") is { } total ? Seconds(total) : null);
        plate.PrinterModel = Value("printer_model") ?? Value("printer_settings_id");
        if (Value("nozzle_diameter") is { } nozzle
            && double.TryParse(nozzle.Split(',')[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var diameter))
            plate.Nozzle = diameter;
        List<string> List(string key) => (Value(key) ?? "").Split(new[] { ';', ',' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(item => item.Trim()).ToList();
        var materials = List("filament_type");
        var colours = List("filament_colour");
        var grams = List("filament used [g]");
        if (grams.Count == 0) grams = List("total filament used [g]");
        for (int index = 0; index < materials.Count; index++)
        {
            if (materials[index].Length == 0) continue;
            double used = index < grams.Count && double.TryParse(grams[index], NumberStyles.Float, CultureInfo.InvariantCulture, out var g) ? g : 0;
            // Unused extruders of a multi-tool profile carry a material but no weight.
            if (materials.Count > 1 && used == 0 && grams.Count > 0) continue;
            plate.Filaments.Add(new FarmFilament
            {
                Id = index + 1, Material = materials[index], Color = index < colours.Count ? colours[index] : "", Grams = used,
            });
        }
        return plate;
    }

    /// <summary>The largest <c>; thumbnail begin WxH N</c> PNG block (PrusaSlicer, Orca, Cura with the plug-in).</summary>
    public static byte[]? Thumbnail(byte[] data)
    {
        var text = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 2 * 1024 * 1024));
        (int Area, byte[] Png)? best = null;
        int? area = null;
        var base64 = new StringBuilder();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith("; thumbnail begin", StringComparison.Ordinal))
            {
                var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var size = parts.Length > 3 ? parts[3] : "";
                area = size.Split('x').Select(v => int.TryParse(v, out var n) ? n : 1).Aggregate(1, (a, b) => a * b);
                base64.Clear();
            }
            else if (line.StartsWith("; thumbnail end", StringComparison.Ordinal))
            {
                if (area is { } current && current > (best?.Area ?? 0))
                {
                    try { best = (current, Convert.FromBase64String(base64.ToString())); } catch (FormatException) { }
                }
                area = null;
            }
            else if (area is not null && line.StartsWith(';'))
            {
                base64.Append(line[1..].Trim());
            }
        }
        return best?.Png;
    }
}

/// <summary>Reads only the plate metadata and thumbnails of a sliced 3MF; never expands G-code.</summary>
public static class FarmArchive
{
    public const long MaxBytes = 512L * 1024 * 1024;

    public static List<FarmPlate> Plates(ZipArchive zip)
    {
        var indices = zip.Entries
            .Select(entry => Regex.Match(entry.FullName, @"^Metadata/plate_(\d+)\.gcode$"))
            .Where(match => match.Success).Select(match => int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture))
            .Where(index => index is > 0 and < 1000).Distinct().OrderBy(index => index).ToList();
        if (indices.Count == 0)
            throw new FarmError("To nie jest pocięty plik. W Bambu Studio wybierz eksport pociętej płyty (.3mf).");
        var metadata = zip.GetEntry("Metadata/slice_info.config") is { } config && config.Length < 16 * 1024 * 1024
            ? ParseSliceInfo(config.Open()) : new List<FarmPlate>();
        return indices.Select(index => metadata.FirstOrDefault(plate => plate.Index == index) ?? new FarmPlate { Index = index }).ToList();
    }

    public static byte[]? Preview(ZipArchive zip, int plate)
    {
        var entry = zip.GetEntry($"Metadata/plate_{plate}.png") ?? zip.GetEntry($"Metadata/top_{plate}.png");
        if (entry is null || entry.Length > 16 * 1024 * 1024) return null;
        using var stream = entry.Open();
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    public static List<FarmPlate> ParseSliceInfo(Stream stream)
    {
        var plates = new List<FarmPlate>();
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
        try
        {
            using var reader = XmlReader.Create(stream, settings);
            FarmPlate? current = null;
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element && reader.Name == "plate")
                {
                    current = new FarmPlate { Index = -1 };
                    if (reader.IsEmptyElement) { plates.Add(current); current = null; }
                    continue;
                }
                if (reader.NodeType == XmlNodeType.EndElement && reader.Name == "plate" && current is not null)
                {
                    plates.Add(current); current = null; continue;
                }
                if (current is null || reader.NodeType != XmlNodeType.Element) continue;
                if (reader.Name == "metadata" && reader.GetAttribute("value") is { } value)
                {
                    switch (reader.GetAttribute("key"))
                    {
                        case "index": current.Index = int.TryParse(value, out var i) ? i : -1; break;
                        case "prediction": current.Seconds = int.TryParse(value, out var s) ? s : null; break;
                        case "printer_model_id": current.PrinterModel = value; break;
                        case "nozzle_diameters":
                            current.Nozzle = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) ? n : null; break;
                    }
                }
                if (reader.Name == "filament" && int.TryParse(reader.GetAttribute("id"), out var id) && id is > 0 and <= 64)
                {
                    current.Filaments.Add(new FarmFilament
                    {
                        Id = id, Material = reader.GetAttribute("type") ?? "?", Color = reader.GetAttribute("color") ?? "",
                        Grams = double.TryParse(reader.GetAttribute("used_g"), NumberStyles.Float, CultureInfo.InvariantCulture, out var g) ? g : 0,
                    });
                }
            }
        }
        catch (XmlException) { }
        return plates;
    }
}

public static class FarmRules
{
    public static int? SlotIndex(string id)
    {
        var parts = id.Split('-');
        if (parts.Length != 3 || parts[0] != "ams" || !int.TryParse(parts[1], out var unit) || !int.TryParse(parts[2], out var tray)) return null;
        return unit is >= 0 and <= 15 && tray is >= 0 and <= 3 ? unit * 4 + tray : null;
    }

    public static string? StartBlock(PrinterTelemetry? t, DateTime? now = null)
    {
        var at = now ?? DateTime.Now;
        if (t?.LastUpdated is not { } updated || (at - updated).TotalSeconds >= 30) return "Brak świeżego statusu drukarki.";
        if (t.State is not (PrinterState.Idle or PrinterState.Finished)) return "Drukarka nie jest gotowa.";
        if (t.ErrorCode != 0) return "Drukarka zgłasza błąd.";
        return null;
    }

    public static bool Matches(FarmJob job, PrinterTelemetry t)
    {
        string stem = Path.GetFileNameWithoutExtension(job.RemoteName);
        string? reported = t.JobName is { } name ? Path.GetFileName(name) : null;
        return reported == stem || reported == job.RemoteName
            || (reported is not null && Path.GetFileNameWithoutExtension(reported) == stem)
            || (t.GcodeFile is { } file && Path.GetFileName(file) == job.RemoteName);
    }

    public static string Command(FarmJob job)
    {
        var payload = new Dictionary<string, object>
        {
            ["print"] = new Dictionary<string, object>
            {
                ["command"] = "project_file",
                ["sequence_id"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture),
                ["param"] = $"Metadata/plate_{job.Plate.Index}.gcode",
                ["url"] = $"ftp:///{job.RemoteName}",
                ["subtask_name"] = job.RemoteName.EndsWith(".3mf") ? job.RemoteName[..^4] : job.RemoteName,
                ["project_id"] = "0", ["profile_id"] = "0", ["task_id"] = "0", ["subtask_id"] = "0",
                ["file"] = "", ["md5"] = "", ["bed_type"] = "auto",
                ["bed_levelling"] = job.BedLeveling, ["flow_cali"] = false, ["vibration_cali"] = false,
                ["timelapse"] = false, ["layer_inspect"] = false,
                ["use_ams"] = job.Mapping.Count > 0, ["ams_mapping"] = job.Mapping,
            },
        };
        return JsonSerializer.Serialize(payload);
    }

    private static (double R, double G, double B)? Rgb(string value)
    {
        string hex = (value ?? "").Trim().Replace("#", "");
        if (hex.Length < 6 || !uint.TryParse(hex[..6], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return null;
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    }

    /// <summary>Weighted RGB distance (0…~765), enough to tell "same spool colour" from "different".</summary>
    public static double? ColorDistance(string a, string b)
    {
        if (Rgb(a) is not { } x || Rgb(b) is not { } y) return null;
        double r = (x.R + y.R) / 2, dr = x.R - y.R, dg = x.G - y.G, db = x.B - y.B;
        return Math.Sqrt((2 + r / 256) * dr * dr + 4 * dg * dg + (2 + (255 - r) / 256) * db * db);
    }

    /// <summary>AMS mapping from the slots loaded now: same material, closest colour within the limit,
    /// enough filament when the roll reports its weight. A single-filament plate may use the external
    /// spool (empty mapping). Null when a filament has no source.</summary>
    public static List<int>? AutoMapping(FarmPlate plate, IReadOnlyList<AmsSlot> slots, double maxColorDistance = 90)
    {
        if (plate.Filaments.Count == 0) return null;
        double? Fits(AmsSlot slot, FarmFilament filament)
        {
            if (!string.Equals(slot.Material, filament.Material, StringComparison.OrdinalIgnoreCase)) return null;
            if (slot.RemainingWeightGrams is { } grams && grams < filament.Grams) return null;
            if (Rgb(filament.Color) is null) return 0;
            return ColorDistance(filament.Color, slot.ColorHex) is { } d && d <= maxColorDistance ? d : null;
        }
        var mapping = Enumerable.Repeat(-1, plate.Filaments.Max(f => f.Id)).ToList();
        bool complete = true;
        foreach (var filament in plate.Filaments)
        {
            var best = slots.Where(slot => !slot.IsExternal && SlotIndex(slot.Id) is not null)
                .Select(slot => (Index: SlotIndex(slot.Id)!.Value, Distance: Fits(slot, filament)))
                .Where(candidate => candidate.Distance is not null)
                .OrderBy(candidate => candidate.Distance).FirstOrDefault();
            if (best.Distance is not null) mapping[filament.Id - 1] = best.Index; else complete = false;
        }
        if (complete) return mapping;
        if (plate.Filaments.Count == 1 && slots.Any(slot => slot.IsExternal && Fits(slot, plate.Filaments[0]) is not null)) return new List<int>();
        return null;
    }

    /// <summary>First queue item this printer can take right now, with the AMS mapping to use.
    /// <paramref name="accepts"/> says whether the printer prints an item's format (null = 3MF); by
    /// default only 3MF, which is what a Bambu printer takes.</summary>
    public static (int Index, List<int> Mapping)? NextQueueItem(IReadOnlyList<FarmQueueItem> queue, string serial, PrinterTelemetry t,
                                                               Func<string?, bool>? accepts = null)
    {
        accepts ??= format => format is null;
        for (int index = 0; index < queue.Count; index++)
        {
            var item = queue[index];
            if (item.Copies <= 0 || (item.Printers.Count > 0 && !item.Printers.Contains(serial)) || !accepts(item.Format)) continue;
            if (item.Plate.Nozzle is { } nozzle && t.NozzleDiameter is { } actual && Math.Abs(nozzle - actual) > 0.01) continue;
            // G-code carries its own filament choice and was sliced for the printers it names.
            if (item.Format is not null)
            {
                if (item.Printers.Contains(serial)) return (index, new List<int>());
                continue;
            }
            if (AutoMapping(item.Plate, t.AmsSlots) is { } mapping) return (index, mapping);
        }
        return null;
    }
}
