using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Polls an OctoPrint server's REST API and reports status through MqttEvent, so PrinterStore
/// treats it like Moonraker and PrusaLink. Also sends the controls: G-code lines, pause, resume, cancel.
/// Local only: host (usually OctoPi on port 80) and an API key from OctoPrint's settings. Mirrors macOS.</summary>
public sealed class OctoPrintClient : IPrinterConnection
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    private readonly SavedPrinter _printer;
    private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new();
    private PrinterTelemetry _telemetry = new();
    private bool _connectedReported;
    private bool _disconnectReported;

    public OctoPrintClient(SavedPrinter printer, Action<MqttEvent> onEvent)
    {
        _printer = printer;
        _onEvent = onEvent;
    }

    public void Start() => _ = Task.Run(RunAsync);

    public void Stop()
    {
        try { _cts.Cancel(); } catch { }
    }

    public static string BaseUrl(SavedPrinter printer) => $"http://{printer.Host}:{printer.Port ?? 80}";

    private async Task RunAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            try
            {
                var (printerData, status) = await GetAsync($"{BaseUrl(_printer)}/api/printer");
                if (status is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                {
                    ReportDisconnected(AppSettings.T("OctoPrint refused the API key."));
                    return;
                }
                byte[]? job = null;
                try { job = (await GetAsync($"{BaseUrl(_printer)}/api/job")).Data; }
                catch (OperationCanceledException) when (_cts.IsCancellationRequested) { return; }
                catch { /* the job is optional */ }
                // 409: OctoPrint is up but has no printer connected; report it as offline, keep polling.
                _telemetry = OctoPrintStatusParser.Telemetry(status == HttpStatusCode.OK ? printerData : null, job, _telemetry);
                if (!_connectedReported) { _connectedReported = true; _onEvent(new MqttEvent { Type = MqttEventType.Connected }); }
                _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = _telemetry });
            }
            catch (OperationCanceledException) when (_cts.IsCancellationRequested) { return; }
            catch (Exception ex) { ReportDisconnected(ex.Message); return; }
            try { await Task.Delay(TimeSpan.FromSeconds(2), _cts.Token); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task<(byte[] Data, HttpStatusCode Status)> GetAsync(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (!string.IsNullOrEmpty(_printer.ApiKey)) request.Headers.Add("X-Api-Key", _printer.ApiKey);
        using var response = await Http.SendAsync(request, _cts.Token);
        var status = response.StatusCode;
        if (status is not (HttpStatusCode.OK or HttpStatusCode.Conflict or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden))
            throw new HttpRequestException($"HTTP {(int)status}");
        return (await response.Content.ReadAsByteArrayAsync(_cts.Token), status);
    }

    /// <summary>One or more G-code lines, sent as one batch so a relative move and the G90 after it
    /// stay together.</summary>
    public void SendGcode(IEnumerable<string> lines) => Post("/api/printer/command", new { commands = lines.ToArray() });

    public enum JobAction { Pause, Resume, Cancel }

    public void Job(JobAction action)
    {
        switch (action)
        {
            case JobAction.Pause: Post("/api/job", new { command = "pause", action = "pause" }); break;
            case JobAction.Resume: Post("/api/job", new { command = "pause", action = "resume" }); break;
            default: Post("/api/job", new { command = "cancel" }); break;
        }
    }

    private void Post(string path, object body)
    {
        string url = BaseUrl(_printer) + path, json = JsonSerializer.Serialize(body);
        string? key = _printer.ApiKey;
        _ = Task.Run(async () =>
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, url)
                {
                    Content = new StringContent(json, Encoding.UTF8, "application/json"),
                };
                if (!string.IsNullOrEmpty(key)) request.Headers.Add("X-Api-Key", key);
                using var response = await Http.SendAsync(request);
            }
            catch { }
        });
    }

    private void ReportDisconnected(string? reason)
    {
        if (_disconnectReported) return;
        _disconnectReported = true;
        _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = reason });
    }
}
