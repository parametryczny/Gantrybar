using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Xml.Linq;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Reads per-filament <c>used_g</c> from a Bambu <c>.gcode.3mf</c> (a ZIP) via the built-in
/// ZipArchive. Fully local. Validated against real slicer output (Metadata/slice_info.config).</summary>
public static class ThreeMFReader
{
    public static List<SlicedFilament> Filaments(byte[] data)
    {
        try
        {
            using var ms = new MemoryStream(data);
            using var zip = new ZipArchive(ms, ZipArchiveMode.Read);
            var entry = zip.GetEntry("Metadata/slice_info.config");
            if (entry is null) return new();
            using var reader = new StreamReader(entry.Open());
            return Parse(reader.ReadToEnd());
        }
        catch { return new(); }
    }

    public static List<SlicedFilament> FilamentsFromFile(string path)
    {
        try { return Filaments(File.ReadAllBytes(path)); }
        catch { return new(); }
    }

    private static List<SlicedFilament> Parse(string xml)
    {
        var result = new List<SlicedFilament>();
        XDocument doc;
        try { doc = XDocument.Parse(xml); } catch { return result; }
        foreach (var el in doc.Descendants("filament"))
        {
            double D(string key) => double.TryParse((string?)el.Attribute(key), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0;
            int id = int.TryParse((string?)el.Attribute("id"), out var i) ? i : result.Count + 1;
            result.Add(new SlicedFilament
            {
                Id = id,
                UsedGrams = D("used_g"),
                UsedMeters = D("used_m"),
                Type = (string?)el.Attribute("type") ?? "",
                ColorHex = ((string?)el.Attribute("color") ?? "").Replace("#", "").ToUpperInvariant()
            });
        }
        return result;
    }
}
