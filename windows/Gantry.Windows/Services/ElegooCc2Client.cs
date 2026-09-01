using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Gantry.Models;

namespace Gantry.Services;

public sealed class ElegooCc2Client : IPrinterConnection
{
    private readonly SavedPrinter _printer; private readonly string _code; private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new(); private readonly SemaphoreSlim _sendGate = new(1, 1);
    private TcpClient? _tcp; private NetworkStream? _stream; private PrinterTelemetry _telemetry = new(); private JsonObject _status = new();
    private readonly string _clientId, _requestId; private int _sequence; private bool _registered;
    private int? _lastStatusId; private int _statusGaps, _heartbeatTicks;
    public ElegooCc2Client(SavedPrinter printer, string accessCode, Action<MqttEvent> onEvent)
    {
        _printer = printer; _code = string.IsNullOrEmpty(accessCode) ? "123456" : accessCode; _onEvent = onEvent;
        _clientId = "1_PC_" + Guid.NewGuid().ToString("N")[..10];
        _requestId = _clientId + "_req";
    }
    public void Start() => _ = Task.Run(RunAsync);
    public void Stop() { _cts.Cancel(); _stream?.Dispose(); _tcp?.Dispose(); }
    public void SendMethod(int method, object? parameters = null)
    {
        if (!_registered) return;
        _ = PublishAsync($"elegoo/{_printer.Serial}/{_clientId}/api_request",
            new { id = Interlocked.Increment(ref _sequence), method, @params = parameters ?? new { } });
    }

    private async Task RunAsync()
    {
        try
        {
            _tcp = new TcpClient { NoDelay = true }; await _tcp.ConnectAsync(_printer.Host, _printer.Port ?? 1883, _cts.Token); _stream = _tcp.GetStream();
            await SendAsync(MqttCodec.Connect(_clientId, "elegoo", _code)); _ = HeartbeatAsync();
            byte[] buffer = Array.Empty<byte>(), chunk = new byte[65536];
            while (!_cts.IsCancellationRequested)
            {
                int read = await _stream.ReadAsync(chunk, _cts.Token); if (read <= 0) break;
                var grown = new byte[buffer.Length + read]; buffer.CopyTo(grown, 0); Array.Copy(chunk, 0, grown, buffer.Length, read); buffer = grown;
                foreach (var packet in MqttCodec.ExtractPackets(ref buffer)) await HandlePacketAsync(packet.Type, packet.Body);
            }
            if (!_cts.IsCancellationRequested) _onEvent(new MqttEvent { Type = MqttEventType.Disconnected });
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!_cts.IsCancellationRequested) _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = error.Message }); }
    }

    private async Task HandlePacketAsync(byte type, byte[] body)
    {
        if ((type >> 4) == 2)
        {
            if (body.Length < 2 || body[1] != 0) throw new UnauthorizedAccessException("Drukarka Elegoo odrzuciła kod dostępu");
            await SendAsync(MqttCodec.Subscribe($"elegoo/{_printer.Serial}/{_requestId}/register_response"));
            await PublishAsync($"elegoo/{_printer.Serial}/api_register", new { client_id = _clientId, request_id = _requestId }); return;
        }
        if ((type >> 4) != 3 || MqttCodec.PublishTopic(type, body) is not string topic || MqttCodec.PublishPayload(type, body) is not byte[] payload) return;
        JsonObject? message; try { message = JsonNode.Parse(payload) as JsonObject; } catch { return; } if (message is null) return;
        if (topic.EndsWith("/register_response"))
        {
            var error = message["error"]?.GetValue<string>() ?? "fail";
            if (error != "ok") throw new IOException(error.Contains("too many") ? "Limit klientów Elegoo został przekroczony" : $"Rejestracja Elegoo: {error}");
            _registered = true;
            await SendAsync(MqttCodec.Subscribe($"elegoo/{_printer.Serial}/api_status", 2));
            await SendAsync(MqttCodec.Subscribe($"elegoo/{_printer.Serial}/{_clientId}/api_response", 3));
            _onEvent(new MqttEvent { Type = MqttEventType.Connected }); SendMethod(1002); SendMethod(2005); return;
        }
        int method = message["method"]?.GetValue<int>() ?? 0; var result = message["result"] as JsonObject; if (result is null) return;
        if (method is 6000 or 6008 or 1002)
        {
            if ((method is 6000 or 6008) && message["id"]?.GetValue<int>() is int eventId)
            {
                if (_lastStatusId is int last) { _statusGaps = eventId == last + 1 ? 0 : _statusGaps + 1; if (_statusGaps >= 5) { SendMethod(1002); _statusGaps = 0; } }
                _lastStatusId = eventId;
            }
            _status = ElegooStatusParser.DeepMerge(_status, result); _telemetry = ElegooStatusParser.Cc2(_status, _telemetry);
        }
        else if (method == 2005) _telemetry = ElegooStatusParser.Canvas(result, _telemetry); else return;
        _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = _telemetry });
    }

    private async Task HeartbeatAsync()
    {
        try { while (!_cts.IsCancellationRequested) { await Task.Delay(TimeSpan.FromSeconds(30), _cts.Token); if (_registered) { await PublishAsync($"elegoo/{_printer.Serial}/{_clientId}/api_request", new { type = "PING" }); if (++_heartbeatTicks % 10 == 0) { SendMethod(1002); SendMethod(2005); } } } }
        catch (OperationCanceledException) { }
    }
    private Task PublishAsync(string topic, object value) => SendAsync(MqttCodec.Publish(topic, JsonSerializer.SerializeToUtf8Bytes(value)));
    private async Task SendAsync(byte[] data)
    {
        if (_stream is null) return; await _sendGate.WaitAsync(_cts.Token);
        try { await _stream.WriteAsync(data, _cts.Token); } finally { _sendGate.Release(); }
    }
}
