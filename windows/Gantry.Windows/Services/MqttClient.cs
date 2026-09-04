using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Gantry.Models;

namespace Gantry.Services;

public enum MqttEventType { Connected, Telemetry, Disconnected }

public sealed class MqttEvent
{
    public MqttEventType Type { get; init; }
    public PrinterTelemetry? Telemetry { get; init; }
    public string? Reason { get; init; }
}

/// <summary>
/// One MQTT-over-TLS connection to a printer, ported from the macOS MQTTClient.
/// Raises Connected / Telemetry / Disconnected events; reconnection is driven by PrinterStore.
/// </summary>
public sealed class MqttClient : IPrinterConnection
{
    private readonly SavedPrinter _printer;
    private readonly string _accessCode;
    private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new();

    private TcpClient? _tcp;
    private SslStream? _ssl;
    private PrinterTelemetry _telemetry = new();
    private bool _certificateMismatch;
    private bool _disconnectReported;

    public MqttClient(SavedPrinter printer, string accessCode, Action<MqttEvent> onEvent)
    {
        _printer = printer;
        _accessCode = accessCode;
        _onEvent = onEvent;
    }

    public void Start() => _ = Task.Run(RunAsync);

    public void Stop()
    {
        try { _cts.Cancel(); } catch { }
        try { _ssl?.Dispose(); } catch { }
        try { _tcp?.Close(); } catch { }
    }

    /// Publishes a raw JSON command to device/{serial}/request (chamber LED, pause, …).
    /// No-op until the socket is connected.
    public void SendCommand(string json)
    {
        _ = Task.Run(async () =>
        {
            try { await SendAsync(MqttCodec.Publish($"device/{_printer.Serial}/request", Encoding.UTF8.GetBytes(json))); }
            catch { }
        });
    }

    private async Task RunAsync()
    {
        try
        {
            _tcp = new TcpClient { NoDelay = true };
            using var connectTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token, connectTimeout.Token);
            try
            {
                await _tcp.ConnectAsync(_printer.Host, _printer.Port ?? 8883, linked.Token);
            }
            catch (OperationCanceledException) when (connectTimeout.IsCancellationRequested)
            {
                ReportDisconnected(AppSettings.T("Connection to the printer timed out"));
                return;
            }

            // The validation callback lives in the options only; setting it in the SslStream
            // constructor as well would throw at authentication time.
            _ssl = new SslStream(_tcp.GetStream(), false);
            var options = new SslClientAuthenticationOptions
            {
                TargetHost = _printer.Host,
                RemoteCertificateValidationCallback = ValidateCertificate,
                EnabledSslProtocols = System.Security.Authentication.SslProtocols.Tls12 | System.Security.Authentication.SslProtocols.Tls13
            };
            try
            {
                await _ssl.AuthenticateAsClientAsync(options, _cts.Token);
            }
            catch
            {
                ReportDisconnected(_certificateMismatch ? CertificateMismatchMessage : AppSettings.T("TLS handshake failed"));
                return;
            }

            string clientId = "Gantry-" + Guid.NewGuid().ToString("N")[..8];
            await SendAsync(MqttCodec.Connect(clientId, "bblp", _accessCode));

            _ = PingLoopAsync();
            await ReadLoopAsync();
        }
        catch (OperationCanceledException) { /* stopped */ }
        catch (Exception ex)
        {
            ReportDisconnected(ex.Message);
        }
    }

    private bool ValidateCertificate(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors errors)
    {
        if (certificate is null) return false;
        var result = CertificatePinStore.Validate(certificate.GetRawCertData(), _printer.Serial);
        _certificateMismatch = result == CertificatePinStore.ValidationResult.Mismatch;
        return result.Accepted();
    }

    private async Task ReadLoopAsync()
    {
        var buffer = Array.Empty<byte>();
        var chunk = new byte[65536];
        while (!_cts.IsCancellationRequested)
        {
            int read;
            try { read = await _ssl!.ReadAsync(chunk, _cts.Token); }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { ReportDisconnected(ex.Message); return; }
            if (read <= 0) { ReportDisconnected(null); return; }

            var grown = new byte[buffer.Length + read];
            Array.Copy(buffer, grown, buffer.Length);
            Array.Copy(chunk, 0, grown, buffer.Length, read);
            buffer = grown;

            foreach (var packet in MqttCodec.ExtractPackets(ref buffer))
            {
                switch (packet.Type >> 4)
                {
                    case 2: // CONNACK
                        if (packet.Body.Length < 2 || packet.Body[1] != 0)
                        {
                            ReportDisconnected(AppSettings.T("The printer rejected the access code"));
                            Stop();
                            return;
                        }
                        _onEvent(new MqttEvent { Type = MqttEventType.Connected });
                        await SendAsync(MqttCodec.Subscribe($"device/{_printer.Serial}/report"));
                        var request = Encoding.UTF8.GetBytes("{\"pushing\":{\"sequence_id\":\"0\",\"command\":\"pushall\"}}");
                        await SendAsync(MqttCodec.Publish($"device/{_printer.Serial}/request", request));
                        break;
                    case 3: // PUBLISH
                        var payload = MqttCodec.PublishPayload(packet.Type, packet.Body);
                        if (payload is null) continue;
                        var updated = StatusParser.Telemetry(payload, _telemetry);
                        if (updated is null) continue;
                        _telemetry = updated;
                        _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = updated });
                        break;
                }
            }
        }
    }

    private async Task PingLoopAsync()
    {
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(30), _cts.Token);
                await SendAsync(MqttCodec.Ping());
            }
        }
        catch (OperationCanceledException) { }
        catch { /* connection torn down elsewhere */ }
    }

    private readonly SemaphoreSlim _sendGate = new(1, 1);

    private async Task SendAsync(byte[] data)
    {
        if (_ssl is null) return;
        await _sendGate.WaitAsync(_cts.Token);
        try { await _ssl.WriteAsync(data, _cts.Token); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { ReportDisconnected(ex.Message); }
        finally { _sendGate.Release(); }
    }

    private void ReportDisconnected(string? reason)
    {
        if (_disconnectReported) return;
        _disconnectReported = true;
        _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = reason });
    }

    private static string CertificateMismatchMessage => AppSettings.T("The printer certificate changed. Connection blocked; remove and re-add the printer.");
}
