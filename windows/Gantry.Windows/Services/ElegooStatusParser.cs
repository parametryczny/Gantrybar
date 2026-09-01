using System.Text.Json;
using System.Text.Json.Nodes;
using Gantry.Models;

namespace Gantry.Services;

public static class ElegooStatusParser
{
    public static JsonObject DeepMerge(JsonObject target, JsonObject update)
    {
        var result = (JsonObject)target.DeepClone();
        foreach (var pair in update)
            if (pair.Value is JsonObject next && result[pair.Key] is JsonObject old) result[pair.Key] = DeepMerge(old, next);
            else result[pair.Key] = pair.Value?.DeepClone();
        return result;
    }

    public static PrinterTelemetry Cc2(JsonObject result, PrinterTelemetry? previous = null)
    {
        var value = previous?.Clone() ?? new PrinterTelemetry();
        var machine = result["machine_status"] as JsonObject ?? new();
        var print = result["print_status"] as JsonObject ?? new();
        var extruder = result["extruder"] as JsonObject ?? new();
        var bed = result["heater_bed"] as JsonObject ?? new();
        var chamber = result["ztemperature_sensor"] as JsonObject ?? result["chamber"] as JsonObject ?? new();
        var fans = result["fans"] as JsonObject ?? new();
        var move = result["gcode_move_inf"] as JsonObject ?? result["gcode_move"] as JsonObject ?? new();
        var state = Text(print["state"]).ToLowerInvariant();
        int status = Int(machine["status"]) ?? 1, sub = Int(machine["sub_status"]) ?? -1;
        var errors = machine["exception_status"] as JsonArray;
        if (state == "error" || errors is { Count: > 0 } || status == 14) value.State = PrinterState.Error;
        else if (state.Contains("paus") || sub is 2501 or 2502 or 2505) value.State = PrinterState.Paused;
        else if (state.Contains("complete") || sub == 2077) value.State = PrinterState.Finished;
        else if (state is "printing" or "resuming" || status == 2) value.State = PrinterState.Printing;
        else value.State = PrinterState.Idle;
        if (Int(print["progress"] ?? machine["progress"]) is int progress) value.Progress = Math.Clamp(progress, 0, 100);
        if (Int(print["remaining_time_sec"]) is int seconds) value.RemainingMinutes = Math.Max(0, (int)Math.Round(seconds / 60d));
        if (print.ContainsKey("filename")) value.JobName = EmptyToNull(Text(print["filename"]));
        if (print.ContainsKey("current_layer")) value.CurrentLayer = Int(print["current_layer"]);
        if (print.ContainsKey("total_layer")) value.TotalLayers = Int(print["total_layer"]);
        if (print.ContainsKey("filament_used")) value.FilamentUsedMM = Double(print["filament_used"]);
        if (extruder.ContainsKey("temperature")) value.NozzleTemperature = Double(extruder["temperature"]);
        if (extruder.ContainsKey("target")) value.NozzleTargetTemperature = Double(extruder["target"]);
        if (bed.ContainsKey("temperature")) value.BedTemperature = Double(bed["temperature"]);
        if (bed.ContainsKey("target")) value.BedTargetTemperature = Double(bed["target"]);
        if (chamber.ContainsKey("temperature")) value.ChamberTemperature = Double(chamber["temperature"]);
        value.PartFanPercent = Fan(fans["fan"], value.PartFanPercent);
        value.AuxFanPercent = Fan(fans["aux_fan"], value.AuxFanPercent);
        value.ChamberFanPercent = Fan(fans["box_fan"], value.ChamberFanPercent);
        if (Int(move["speed_mode"]) is int mode)
        {
            value.SpeedLevel = mode + 1;
            value.SpeedPercent = mode switch { 0 => 50, 1 => 100, 2 => 150, 3 => 200, _ => null };
        }
        if (errors is { Count: > 0 })
        {
            value.HmsCodes = errors.Select(Text).ToList();
            value.ErrorCode = (ulong)(Int(errors[0]) ?? 0);
        }
        value.LastUpdated = DateTime.Now;
        return value;
    }

    public static PrinterTelemetry Canvas(JsonObject result, PrinterTelemetry previous)
    {
        var value = previous.Clone();
        if (result["canvas_info"] is not JsonObject info || info["canvas_list"] is not JsonArray canvases) return value;
        int activeCanvas = Int(info["active_canvas_id"]) ?? -1, activeTray = Int(info["active_tray_id"]) ?? -1;
        var groups = new List<FilamentGroup>();
        foreach (var node in canvases.OfType<JsonObject>())
        {
            if (Int(node["connected"]) == 0) continue;
            int canvasId = Int(node["canvas_id"]) ?? 0;
            var trays = (node["tray_list"] as JsonArray)?.OfType<JsonObject>().ToDictionary(x => Int(x["tray_id"]) ?? 0) ?? new();
            var slots = new List<FilamentSlot>();
            for (int trayId = 0; trayId < 4; trayId++)
            {
                var tray = trays.GetValueOrDefault(trayId) ?? new(); bool present = (Int(tray["status"]) ?? 0) > 0;
                var color = EmptyToNull(Text(tray["filament_color"]))?.TrimStart('#'); if (color?.Length == 6) color += "FF";
                slots.Add(new FilamentSlot { Id = $"canvas-{canvasId}-{trayId}", Label = $"{(char)('A' + canvasId)}{trayId + 1}",
                    Material = present ? EmptyToNull(Text(tray["filament_type"] ?? tray["filament_name"])) : null,
                    ColorHex = present ? color : null, RemainingPercent = null,
                    IsActive = present && canvasId == activeCanvas && trayId == activeTray });
            }
            groups.Add(new FilamentGroup { Id = $"canvas-{canvasId}", SourceType = FilamentSourceType.Canvas,
                DisplayName = canvasId == 0 ? "CANVAS" : $"CANVAS {(char)('A' + canvasId)}", DeclaredCapacity = 4, Slots = slots });
        }
        if (groups.Count > 0) { value.FilamentGroups = groups; value.AmsSlots = groups.SelectMany(g => g.LegacyAmsSlots()).ToList(); }
        value.LastUpdated = DateTime.Now; return value;
    }

    public static PrinterTelemetry? Cc1(byte[] data, PrinterTelemetry? previous = null)
    {
        JsonNode? root; try { root = JsonNode.Parse(data); } catch { return null; }
        var status = Find(root, "Status"); if (status is null) return null;
        var value = previous?.Clone() ?? new PrinterTelemetry(); var print = status["PrintInfo"] as JsonObject ?? new();
        int ps = Int(print["Status"]) ?? 0, error = Int(print["ErrorNumber"]) ?? 0;
        value.State = error != 0 || ps == 14 ? PrinterState.Error
            : ps is 5 or 6 ? PrinterState.Paused
            : ps is 1 or 7 or 13 or 15 or 16 ? PrinterState.Printing
            : ps == 9 ? PrinterState.Finished : PrinterState.Idle;
        value.NozzleTemperature = KeepDouble(status, "TempOfNozzle", value.NozzleTemperature);
        value.NozzleTargetTemperature = KeepDouble(status, "TempTargetNozzle", value.NozzleTargetTemperature);
        value.BedTemperature = KeepDouble(status, "TempOfHotbed", value.BedTemperature);
        value.BedTargetTemperature = KeepDouble(status, "TempTargetHotbed", value.BedTargetTemperature);
        value.ChamberTemperature = KeepDouble(status, "TempOfBox", value.ChamberTemperature);
        if (Int(print["Progress"]) is int p) value.Progress = Math.Clamp(p, 0, 100);
        if (print.ContainsKey("CurrentLayer")) value.CurrentLayer = Int(print["CurrentLayer"]);
        if (print.ContainsKey("TotalLayer")) value.TotalLayers = Int(print["TotalLayer"]);
        if (print.ContainsKey("Filename")) value.JobName = EmptyToNull(Text(print["Filename"]));
        if (Double(print["CurrentTicks"]) is double current && Double(print["TotalTicks"]) is double total)
            value.RemainingMinutes = Math.Max(0, (int)Math.Round((total - current) / 60));
        value.ErrorCode = (ulong)error; value.LastUpdated = DateTime.Now; return value;
    }

    private static JsonObject? Find(JsonNode? node, string key)
    {
        if (node is JsonObject obj) { if (obj[key] is JsonObject found) return found; foreach (var child in obj) if (Find(child.Value, key) is { } nested) return nested; }
        else if (node is JsonArray arr) foreach (var child in arr) if (Find(child, key) is { } nested) return nested;
        return null;
    }
    private static int? Int(JsonNode? value) => value is null ? null : int.TryParse(Text(value), out var n) ? n : null;
    private static double? Double(JsonNode? value) => value is null ? null : double.TryParse(Text(value), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var n) ? n : null;
    private static string Text(JsonNode? value) => value is JsonValue scalar && scalar.TryGetValue<string>(out var s) ? s : value?.ToJsonString().Trim('"') ?? "";
    private static string? EmptyToNull(string value) => string.IsNullOrWhiteSpace(value) || value == "null" ? null : value;
    private static int? Fan(JsonNode? node, int? fallback) => node is JsonObject fan && Double(fan["speed"]) is double raw ? Math.Clamp((int)Math.Round(raw / 255 * 100), 0, 100) : fallback;
    private static double? KeepDouble(JsonObject obj, string key, double? fallback) => obj.ContainsKey(key) ? Double(obj[key]) : fallback;
}
