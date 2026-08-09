using System.Net.Http;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Polls a Prusa printer's local PrusaLink HTTP API and reports status through MqttEvent,
/// so PrinterStore treats Prusa like any other connection. Local only (IP + API key), no account.</summary>
public sealed class PrusaLinkClient : IPrinterConnection
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    private readonly SavedPrinter _printer;
    private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new();
    private PrinterTelemetry _telemetry = new();
    private bool _connectedReported;
    private bool _disconnectReported;

    public PrusaLinkClient(SavedPrinter printer, Action<MqttEvent> onEvent)
    {
        _printer = printer;
        _onEvent = onEvent;
    }

    public void Start() => _ = Task.Run(RunAsync);

    public void Stop()
    {
        try { _cts.Cancel(); } catch { }
    }

    private string BaseUrl => $"http://{_printer.Host}:{_printer.Port ?? 80}";

    private async Task RunAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                var status = await GetAsync($"{BaseUrl}/api/v1/status");
                byte[]? job = null;
                try { job = await GetAsync($"{BaseUrl}/api/v1/job"); }
                catch { /* file name is optional / absent when idle */ }

                var updated = PrusaLinkStatusParser.Telemetry(status, job, _telemetry);
                if (updated is not null)
                {
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

    private async Task<byte[]> GetAsync(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (!string.IsNullOrEmpty(_printer.ApiKey)) request.Headers.Add("X-Api-Key", _printer.ApiKey);
        using var response = await Http.SendAsync(request, _cts.Token);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync(_cts.Token);
    }

    private void ReportDisconnected(string? reason)
    {
        if (_disconnectReported) return;
        _disconnectReported = true;
        _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = reason });
    }
}
