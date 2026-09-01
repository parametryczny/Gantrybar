using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

public sealed class ElegooDiscovery
{
    public async Task<List<DiscoveredPrinter>> ScanAsync(double seconds = 3.5)
    {
        var scans = await Task.WhenAll(ScanAsync(PrinterKind.ElegooCc1, seconds), ScanAsync(PrinterKind.ElegooCc2, seconds));
        return scans.SelectMany(x => x).GroupBy(x => x.Serial).Select(x => x.First()).ToList();
    }
    private static async Task<List<DiscoveredPrinter>> ScanAsync(PrinterKind kind, double seconds)
    {
        var found = new Dictionary<string, DiscoveredPrinter>(); using var udp = new UdpClient();
        udp.EnableBroadcast = true; udp.Client.Bind(new IPEndPoint(IPAddress.Any, 0));
        int port = kind == PrinterKind.ElegooCc1 ? 3000 : 52700;
        byte[] message = kind == PrinterKind.ElegooCc1 ? Encoding.ASCII.GetBytes("M99999") : Encoding.UTF8.GetBytes("{\"id\":0,\"method\":7000}");
        try { await udp.SendAsync(message, new IPEndPoint(IPAddress.Broadcast, port)); } catch { return []; }
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        while (!timeout.IsCancellationRequested)
        {
            try
            {
                var response = await udp.ReceiveAsync(timeout.Token);
                if (Parse(response.Buffer, response.RemoteEndPoint.Address.ToString(), kind) is { } printer) found[printer.Serial] = printer;
            }
            catch (OperationCanceledException) { break; } catch { break; }
        }
        return found.Values.ToList();
    }
    public static DiscoveredPrinter? Parse(byte[] data, string host, PrinterKind kind)
    {
        JsonElement root; try { root = JsonDocument.Parse(data).RootElement.Clone(); } catch { return null; }
        if (kind == PrinterKind.ElegooCc2)
        {
            if (!root.TryGetProperty("result", out var result)) return null;
            var serial = Property(result, "sn"); if (string.IsNullOrEmpty(serial)) return null;
            var name = Property(result, "host_name") ?? "Centauri Carbon 2"; var model = Property(result, "machine_model") ?? "Centauri Carbon 2";
            return new DiscoveredPrinter { Serial = serial, Name = name, Model = "Elegoo " + model, Host = host, Kind = kind };
        }
        var sn = Recursive(root, ["mainboardid", "mainboard_id", "serialnumber", "sn"]); if (string.IsNullOrEmpty(sn)) return null;
        return new DiscoveredPrinter { Serial = sn, Name = Recursive(root, ["machinename", "devicename", "name"]) ?? $"Centauri Carbon {sn[^Math.Min(4, sn.Length)..]}",
            Model = "Elegoo " + (Recursive(root, ["machinemodel", "model"]) ?? "Centauri Carbon"), Host = host, Kind = kind };
    }
    private static string? Property(JsonElement value, string name) => value.TryGetProperty(name, out var child) ? child.ToString() : null;
    private static string? Recursive(JsonElement value, HashSet<string> keys)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in value.EnumerateObject()) if (keys.Contains(property.Name.ToLowerInvariant())) return property.Value.ToString();
            foreach (var property in value.EnumerateObject()) if (Recursive(property.Value, keys) is { } found) return found;
        }
        else if (value.ValueKind == JsonValueKind.Array) foreach (var child in value.EnumerateArray()) if (Recursive(child, keys) is { } found) return found;
        return null;
    }
}
