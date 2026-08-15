using System.Net;
using System.Net.Http;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>
/// Polls a Snapmaker printer's local HTTP API (port 8080, used by Luban) and reports status through
/// MqttEvent, so PrinterStore treats Snapmaker like any other connection.
///
/// Snapmaker's auth is stateful, unlike PrusaLink/Moonraker:
///  1. POST /api/v1/connect returns a session token.
///  2. GET /api/v1/status?token=… returns 204 until the user taps Allow on the printer's
///     touchscreen, then 200 with the live status. The token is dropped when the printer powers off.
///  3. The token has to be pinged regularly (our 2 s status poll doubles as the keep-alive).
/// The token is kept in memory for the connection's life, so the printer shows a single Allow dialog.
/// </summary>
public sealed class SnapmakerClient : IPrinterConnection
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    private readonly SavedPrinter _printer;
    private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new();
    private PrinterTelemetry _telemetry = new();
    private string? _token;
    private bool _connectedReported;
    private bool _disconnectReported;

    public SnapmakerClient(SavedPrinter printer, Action<MqttEvent> onEvent)
    {
        _printer = printer;
        _onEvent = onEvent;
    }

    public void Start() => _ = Task.Run(RunAsync);

    public void Stop()
    {
        try { _cts.Cancel(); } catch { }
    }

    private string BaseUrl => $"http://{_printer.Host}:{_printer.Port ?? 8080}";

    private async Task RunAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                if (_token is null) _token = await ConnectAsync();
                if (_token is null) { await DelayAsync(); continue; }

                using var request = new HttpRequestMessage(HttpMethod.Get, $"{BaseUrl}/api/v1/status?token={_token}");
                using var response = await Http.SendAsync(request, _cts.Token);
                switch (response.StatusCode)
                {
                    case HttpStatusCode.OK:
                        var data = await response.Content.ReadAsByteArrayAsync(_cts.Token);
                        var text = System.Text.Encoding.UTF8.GetString(data);
                        if (text.Contains("not connected", StringComparison.OrdinalIgnoreCase))
                        {
                            _token = null;   // stale token — re-handshake
                            break;
                        }
                        var updated = SnapmakerStatusParser.Telemetry(data, _telemetry);
                        if (updated is not null)
                        {
                            _telemetry = updated;
                            if (!_connectedReported) { _connectedReported = true; _onEvent(new MqttEvent { Type = MqttEventType.Connected }); }
                            _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = updated });
                        }
                        break;
                    case HttpStatusCode.NoContent:
                        break;   // waiting for the user to tap Allow on the printer — keep polling
                    case HttpStatusCode.Unauthorized:
                    case HttpStatusCode.Forbidden:
                        ReportDisconnected("Połączenie odrzucone na drukarce Snapmaker");
                        return;
                    default:
                        _token = null;   // re-handshake on anything unexpected
                        break;
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { ReportDisconnected(ex.Message); return; }
            await DelayAsync();
        }
    }

    /// <summary>POSTs to /api/v1/connect and returns the fresh session token (null on failure).</summary>
    private async Task<string?> ConnectAsync()
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{BaseUrl}/api/v1/connect")
        {
            Content = new StringContent("", System.Text.Encoding.UTF8, "application/x-www-form-urlencoded")
        };
        using var response = await Http.SendAsync(request, _cts.Token);
        if (response.StatusCode != HttpStatusCode.OK) return null;
        var data = await response.Content.ReadAsByteArrayAsync(_cts.Token);
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (doc.RootElement.TryGetProperty("token", out var tok) && tok.ValueKind == JsonValueKind.String)
            {
                var value = tok.GetString();
                return string.IsNullOrEmpty(value) ? null : value;
            }
        }
        catch { /* not JSON / no token */ }
        return null;
    }

    private async Task DelayAsync()
    {
        try { await Task.Delay(TimeSpan.FromSeconds(2), _cts.Token); }
        catch (OperationCanceledException) { }
    }

    private void ReportDisconnected(string? reason)
    {
        if (_disconnectReported) return;
        _disconnectReported = true;
        _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = reason });
    }
}
