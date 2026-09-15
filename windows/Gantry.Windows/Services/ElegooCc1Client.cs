using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

public sealed class ElegooCc1Client : IPrinterConnection
{
    private readonly SavedPrinter _printer; private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new(); private readonly SemaphoreSlim _sendGate = new(1, 1); private ClientWebSocket? _socket;
    private PrinterTelemetry _telemetry = new();
    /// <summary>Cmd 386 handshake and the single stream slot, shared by every camera viewer of this printer.</summary>
    public ElegooVideoGate VideoGate { get; }
    public ElegooCc1Client(SavedPrinter printer, Action<MqttEvent> onEvent)
    {
        _printer = printer; _onEvent = onEvent;
        VideoGate = new ElegooVideoGate((enable, requestId) => SendMethod(386, new { Enable = enable ? 1 : 0 }, requestId));
    }
    public void Start() => _ = Task.Run(RunAsync);
    public void Stop() { _cts.Cancel(); _socket?.Dispose(); }

    public void SendMethod(int method, object? parameters = null, string? requestId = null) => _ = Task.Run(async () =>
    {
        if (_socket?.State != WebSocketState.Open) return;
        var message = new { Id = _printer.Serial, Data = new {
            Cmd = method, Data = parameters ?? new { }, RequestID = requestId ?? Guid.NewGuid().ToString("N"),
            MainboardID = _printer.Serial, TimeStamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), From = 1 },
            Topic = $"sdcp/request/{_printer.Serial}" };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(message);
        try
        {
            await _sendGate.WaitAsync(_cts.Token);
            try { await _socket.SendAsync(bytes, WebSocketMessageType.Text, true, _cts.Token); }
            finally { _sendGate.Release(); }
        }
        catch { }
    });

    private async Task RunAsync()
    {
        try
        {
            _socket = new ClientWebSocket();
            await _socket.ConnectAsync(new Uri($"ws://{_printer.Host}:{_printer.Port ?? 3030}/websocket"), _cts.Token);
            VideoGate.Reset();
            _onEvent(new MqttEvent { Type = MqttEventType.Connected }); SendMethod(0); SendMethod(1); SendMethod(512, new { TimePeriod = 5000 }); _ = PollStatusAsync();
            var chunk = new byte[65536]; using var message = new MemoryStream();
            while (!_cts.IsCancellationRequested)
            {
                var result = await _socket.ReceiveAsync(chunk, _cts.Token);
                if (result.MessageType == WebSocketMessageType.Close) break;
                message.Write(chunk, 0, result.Count);
                if (!result.EndOfMessage) continue;
                var frame = message.ToArray(); message.SetLength(0);
                if (ElegooVideoGate.ParseReply(frame) is { } reply) VideoGate.HandleReply(reply.RequestId, reply.Ack);
                var updated = ElegooStatusParser.Cc1(frame, _telemetry);
                if (updated is not null) { _telemetry = updated; _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = updated }); }
            }
            VideoGate.Reset();
            if (!_cts.IsCancellationRequested) _onEvent(new MqttEvent { Type = MqttEventType.Disconnected });
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { VideoGate.Reset(); if (!_cts.IsCancellationRequested) _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = error.Message }); }
    }

    private async Task PollStatusAsync()
    {
        try { while (!_cts.IsCancellationRequested) { await Task.Delay(TimeSpan.FromSeconds(10), _cts.Token); SendMethod(0); } }
        catch (OperationCanceledException) { }
    }
}
