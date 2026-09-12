using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Xml.Linq;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Reads per-filament <c>used_g</c> from a Bambu <c>.gcode.3mf</c> (a ZIP) via the built-in
/// ZipArchive. Fully local. Validated against real slicer output (Metadata/slice_info.config).</summary>
public static class ThreeMFReader
{
    public static PrintObjectLayout? ObjectLayout(byte[] sliceInfo, byte[] pickPng, HashSet<string>? skipped = null)
    {
        try
        {
            var doc = XDocument.Parse(Encoding.UTF8.GetString(sliceInfo));
            var objects = doc.Descendants("object").Where(e => e.Attribute("identify_id") is not null)
                .Select((e,i) => new PrintObject((string)e.Attribute("identify_id")!, (string?)e.Attribute("name") ?? $"Object {i+1}", new()))
                .GroupBy(o => o.Id).Select(g => g.First()).ToList();
            return objects.Count == 0 ? null : new PrintObjectLayout(objects, skipped ?? new(), null, new double[]{0,0,256,256}, pickPng);
        }
        catch { return null; }
    }
    public static PrintObjectLayout? ObjectLayout(byte[] data, string? gcodeFile, HashSet<string>? skipped = null)
    {
        try
        {
            using var ms = new MemoryStream(data);
            using var zip = new ZipArchive(ms, ZipArchiveMode.Read);
            var config = zip.GetEntry("Metadata/slice_info.config");
            if (config is null) return null;
            using var reader = new StreamReader(config.Open());
            var doc = XDocument.Parse(reader.ReadToEnd());
            var xmlObjects = doc.Descendants("object")
                .Where(e => e.Attribute("identify_id") is not null)
                .Select((e, i) => (Id: (string)e.Attribute("identify_id")!, Name: (string?)e.Attribute("name") ?? $"Object {i + 1}"))
                .GroupBy(o => o.Id).Select(g => g.First()).ToList();
            if (xmlObjects.Count == 0) return null;
            int? hinted = null;
            var match = System.Text.RegularExpressions.Regex.Match(gcodeFile ?? "", @"plate_(\d+)");
            if (match.Success && int.TryParse(match.Groups[1].Value, out var plateValue)) hinted = plateValue;
            var candidates = (hinted is null ? Enumerable.Empty<int>() : new[] { hinted.Value }).Concat(Enumerable.Range(1, 32)).Distinct();
            foreach (int plate in candidates)
            {
                var jsonEntry = zip.GetEntry($"Metadata/plate_{plate}.json");
                if (jsonEntry is null) continue;
                using var jsonReader = new StreamReader(jsonEntry.Open());
                using var json = System.Text.Json.JsonDocument.Parse(jsonReader.ReadToEnd());
                var root = json.RootElement;
                var map = root.TryGetProperty("map", out var mapValue) ? mapValue : root;
                var boxes = map.TryGetProperty("bbox_objects", out var boxValue) && boxValue.ValueKind == System.Text.Json.JsonValueKind.Array
                    ? boxValue.EnumerateArray().ToArray() : Array.Empty<System.Text.Json.JsonElement>();
                var objects = new List<PrintObject>();
                for (int i = 0; i < xmlObjects.Count; i++)
                {
                    var polygon = new List<BedPoint>();
                    if (i < boxes.Length && boxes[i].TryGetProperty("bbox", out var bounds) && bounds.ValueKind == System.Text.Json.JsonValueKind.Array)
                    {
                        var raw = bounds.EnumerateArray().Select(v => v.TryGetDouble(out var d) ? d : 0).ToArray();
                        if (raw.Length >= 4) polygon.AddRange(new[] { new BedPoint(raw[0], raw[1]), new BedPoint(raw[2], raw[1]), new BedPoint(raw[2], raw[3]), new BedPoint(raw[0], raw[3]) });
                    }
                    objects.Add(new PrintObject(xmlObjects[i].Id, xmlObjects[i].Name, polygon));
                }
                double[] all = map.TryGetProperty("bbox_all", out var allValue) && allValue.ValueKind == System.Text.Json.JsonValueKind.Array
                    ? allValue.EnumerateArray().Select(v => v.TryGetDouble(out var d) ? d : 0).Take(4).ToArray() : new double[] { 0, 0, 256, 256 };
                var previewEntry = zip.GetEntry($"Metadata/top_{plate}.png") ?? zip.GetEntry($"Metadata/plate_{plate}.png");
                byte[]? preview = null;
                if (previewEntry is not null) { using var output = new MemoryStream(); using var input = previewEntry.Open(); input.CopyTo(output); preview = output.ToArray(); }
                return new PrintObjectLayout(objects, skipped ?? new(), null, all.Length == 4 ? all : new double[] { 0, 0, 256, 256 }, preview);
            }
            return new PrintObjectLayout(xmlObjects.Select(o => new PrintObject(o.Id, o.Name, new())).ToList(), skipped ?? new(), null, new double[] { 0, 0, 256, 256 }, null);
        }
        catch { return null; }
    }

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
