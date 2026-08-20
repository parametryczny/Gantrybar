using System.IO;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Polls a Klipper printer's Moonraker API and reports status through MqttEvent, so
/// PrinterStore treats Klipper and Bambu connections identically. Mirrors the macOS client.</summary>
public sealed class MoonrakerClient : IPrinterConnection
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };
    private static readonly byte[] CfsRequest = Encoding.UTF8.GetBytes("{\"method\":\"get\",\"params\":{\"boxsInfo\":1}}");

    private readonly SavedPrinter _printer;
    private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new();
    private PrinterTelemetry _telemetry = new();
    private bool _connectedReported;
    private bool _disconnectReported;

    // Creality CFS lives on the printer's own WebSocket, not Moonraker; fed in on the side.
    private readonly object _cfsLock = new();
    private List<FilamentGroup> _cfsGroups = new();

    public MoonrakerClient(SavedPrinter printer, Action<MqttEvent> onEvent)
    {
        _printer = printer;
        _onEvent = onEvent;
    }

    public void Start()
    {
        _ = Task.Run(RunAsync);
        _ = Task.Run(CfsLoopAsync);
    }

    public void Stop()
    {
        try { _cts.Cancel(); } catch { }
    }

    private string BaseUrl => $"http://{_printer.Host}:{_printer.Port ?? 7125}";

    private async Task RunAsync()
    {
        var query = await BuildQueryUrlAsync();
        if (query is null)
        {
            ReportDisconnected(AppSettings.Text($"Nie znaleziono API Moonraker (port {_printer.Port ?? 7125})",
                $"Moonraker API not found (port {_printer.Port ?? 7125})"));
            return;
        }
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                var data = await GetAsync(query);
                var updated = MoonrakerStatusParser.Telemetry(data, _telemetry);
                if (updated is not null)
                {
                    // A Creality CFS overrides the (absent) Happy Hare gates with its own modules.
                    var cfs = CurrentCfsGroups();
                    if (cfs.Count > 0)
                    {
                        updated.FilamentGroups = cfs;
                        updated.AmsSlots = cfs.SelectMany(g => g.LegacyAmsSlots()).ToList();
                    }
                    _telemetry = updated;
                    if (!_connectedReported) { _connectedReported = true; _onEvent(new MqttEvent { Type = MqttEventType.Connected }); }
                    _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = updated });
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { ReportDisconnected(ex.Message); return; }
            try { await Task.Delay(TimeSpan.FromSeconds(2), _cts.Token); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task<string?> BuildQueryUrlAsync()
    {
        var wanted = new List<string> { "print_stats", "virtual_sdcard", "display_status", "extruder", "heater_bed", "mmu", "fan", "gcode_move" };
        try
        {
            var listData = await GetAsync($"{BaseUrl}/printer/objects/list");
            using var doc = JsonDocument.Parse(listData);
            if (doc.RootElement.TryGetProperty("result", out var res)
                && res.TryGetProperty("objects", out var objects) && objects.ValueKind == JsonValueKind.Array)
            {
                var available = objects.EnumerateArray().Select(o => o.GetString() ?? "").ToHashSet();
                wanted = wanted.Where(available.Contains).ToList();
                foreach (var name in available)
                    if (name.ToLowerInvariant().Contains("chamber")
                        && (name.StartsWith("temperature_sensor") || name.StartsWith("heater_generic")))
                        wanted.Add(name);
            }
        }
        catch { /* fall back to the default object set */ }

        if (wanted.Count == 0) return null;
        var query = string.Join("&", wanted.Select(Uri.EscapeDataString));
        return $"{BaseUrl}/printer/objects/query?{query}";
    }

    private async Task<byte[]> GetAsync(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (!string.IsNullOrEmpty(_printer.ApiKey)) request.Headers.Add("X-Api-Key", _printer.ApiKey);
        using var response = await Http.SendAsync(request, _cts.Token);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync(_cts.Token);
    }

    private List<FilamentGroup> CurrentCfsGroups()
    {
        lock (_cfsLock) return new List<FilamentGroup>(_cfsGroups);
    }

    private void SetCfsGroups(List<FilamentGroup> groups)
    {
        lock (_cfsLock) _cfsGroups = groups;
    }

    /// <summary>Best-effort Creality CFS reader. Connects to the printer's ws://host:9999, asks for
    /// <c>boxsInfo</c>, and maps any material boxes to AMS slots. Klipper printers without a CFS
    /// (Voron, stock Moonraker) never answer on that port, so this backs off and stays idle.</summary>
    private async Task CfsLoopAsync()
    {
        var uri = new Uri($"ws://{_printer.Host}:9999");
        while (!_cts.IsCancellationRequested)
        {
            var socket = new ClientWebSocket();
            Task? requester = null;
            try
            {
                await socket.ConnectAsync(uri, _cts.Token);
                await socket.SendAsync(CfsRequest, WebSocketMessageType.Text, true, _cts.Token);
                requester = RequestCfsPeriodicallyAsync(socket);

                var buffer = new byte[16384];
                using var stream = new MemoryStream();
                while (!_cts.IsCancellationRequested && socket.State == WebSocketState.Open)
                {
                    stream.SetLength(0);
                    ValueWebSocketReceiveResult result;
                    do
                    {
                        result = await socket.ReceiveAsync(buffer.AsMemory(), _cts.Token);
                        if (result.MessageType == WebSocketMessageType.Close) break;
                        stream.Write(buffer, 0, result.Count);
                    } while (!result.EndOfMessage);
                    if (result.MessageType == WebSocketMessageType.Close) break;

                    var groups = MoonrakerStatusParser.ParseCfsGroups(stream.ToArray());
                    if (groups is not null) SetCfsGroups(groups);
                }
            }
            catch (OperationCanceledException) { return; }
            catch { /* connection refused/closed — expected on non-Creality printers */ }
            finally
            {
                if (requester is not null) { try { await requester; } catch { } }
                socket.Dispose();
            }

            if (_cts.IsCancellationRequested) return;
            try { await Task.Delay(TimeSpan.FromSeconds(30), _cts.Token); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task RequestCfsPeriodicallyAsync(ClientWebSocket socket)
    {
        try
        {
            while (!_cts.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                await Task.Delay(TimeSpan.FromSeconds(5), _cts.Token);
                if (socket.State == WebSocketState.Open)
                    await socket.SendAsync(CfsRequest, WebSocketMessageType.Text, true, _cts.Token);
            }
        }
        catch { /* socket closed or cancelled */ }
    }

    private void ReportDisconnected(string? reason)
    {
        if (_disconnectReported) return;
        _disconnectReported = true;
        _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = reason });
    }
}
