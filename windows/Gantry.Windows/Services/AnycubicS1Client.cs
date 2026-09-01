using System.Net.Security;
using System.Net.Sockets;
using System.Net.Http;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Globalization;
using Gantry.Models;

namespace Gantry.Services;

public static class AnycubicStatusParser
{
    private static double? Number(JsonNode? node) => node is null ? null :
        double.TryParse(node.ToJsonString().Trim('"'), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;
    private static int? Integer(JsonNode? node) => Number(node) is double value ? (int)value : null;
    private static PrinterState State(JsonNode? node) => (node?.ToString() ?? "").ToLowerInvariant() switch
    {
        "printing" or "running" or "prepare" or "working" => PrinterState.Printing,
        "pause" or "paused" or "pausing" => PrinterState.Paused,
        "done" or "finished" or "complete" or "completed" or "success" => PrinterState.Finished,
        "error" or "failed" or "failure" or "abnormal" => PrinterState.Error,
        _ => PrinterState.Idle
    };

    public static PrinterTelemetry? Parse(byte[] payload, PrinterTelemetry? previous = null)
    {
        JsonObject? root; try { root = JsonNode.Parse(payload) as JsonObject; } catch { return null; }
        if (root is null) return null;
        var telemetry = previous?.Clone() ?? new PrinterTelemetry(); bool changed = false;
        var type = root["type"]?.ToString() ?? ""; var data = root["data"] as JsonObject ?? new JsonObject();
        void ApplyProject(JsonObject project, JsonNode? reportState)
        {
            telemetry.State = State(reportState);
            if (Integer(project["progress"]) is int progress) telemetry.Progress = Math.Clamp(progress, 0, 100);
            // Kobra S1 reports both print_time and remain_time in minutes.
            if (Integer(project["remain_time"]) is int minutes) telemetry.RemainingMinutes = Math.Max(0, minutes);
            if (project.ContainsKey("curr_layer")) telemetry.CurrentLayer = Integer(project["curr_layer"]);
            if (project.ContainsKey("total_layers")) telemetry.TotalLayers = Integer(project["total_layers"]);
            if (project.ContainsKey("filename")) telemetry.JobName = string.IsNullOrEmpty(project["filename"]?.ToString()) ? null : project["filename"]!.ToString();
            changed = true;
        }
        if (type == "info")
        {
            telemetry.State = State(data["state"]); changed = true; var temp = data["temp"] as JsonObject ?? new();
            if (temp.ContainsKey("curr_nozzle_temp")) telemetry.NozzleTemperature = Number(temp["curr_nozzle_temp"]);
            if (temp.ContainsKey("target_nozzle_temp")) telemetry.NozzleTargetTemperature = Number(temp["target_nozzle_temp"]);
            if (temp.ContainsKey("curr_hotbed_temp")) telemetry.BedTemperature = Number(temp["curr_hotbed_temp"]);
            if (temp.ContainsKey("target_hotbed_temp")) telemetry.BedTargetTemperature = Number(temp["target_hotbed_temp"]);
            if (temp.ContainsKey("curr_chamber_temp")) telemetry.ChamberTemperature = Number(temp["curr_chamber_temp"]);
            if (Integer(data["fan_speed_pct"]) is int fan) telemetry.PartFanPercent = fan;
            if (Integer(data["aux_fan_speed_pct"]) is int aux) telemetry.AuxFanPercent = aux;
            if (Integer(data["box_fan_level"]) is int boxFan) telemetry.ChamberFanPercent = boxFan;
            if (Integer(data["print_speed_mode"]) is int speed) telemetry.SpeedLevel = speed;
            if (data["project"] is JsonObject project) ApplyProject(project, data["state"]);
        }
        else if (type == "tempature")
        {
            if (data.ContainsKey("curr_nozzle_temp")) { telemetry.NozzleTemperature = Number(data["curr_nozzle_temp"]); changed = true; }
            if (data.ContainsKey("target_nozzle_temp")) { telemetry.NozzleTargetTemperature = Number(data["target_nozzle_temp"]); changed = true; }
            if (data.ContainsKey("curr_hotbed_temp")) { telemetry.BedTemperature = Number(data["curr_hotbed_temp"]); changed = true; }
            if (data.ContainsKey("target_hotbed_temp")) { telemetry.BedTargetTemperature = Number(data["target_hotbed_temp"]); changed = true; }
        }
        else if (type == "print") ApplyProject(data, root["state"]);
        else if (type == "fan")
        {
            if (Integer(data["fan_speed_pct"]) is int fan) { telemetry.PartFanPercent = fan; changed = true; }
            if (Integer(data["aux_fan_speed_pct"]) is int aux) { telemetry.AuxFanPercent = aux; changed = true; }
            if (Integer(data["box_fan_level"]) is int boxFan) { telemetry.ChamberFanPercent = boxFan; changed = true; }
        }
        else if (type == "multiColorBox" && data["multi_color_box"] is JsonArray boxes)
        {
            var groups = new List<FilamentGroup>(); int boxIndex = 0;
            foreach (var node in boxes)
            {
                if (node is not JsonObject box) { boxIndex++; continue; }
                int? loaded = Integer(box["loaded_slot"]); var source = box["slots"] as JsonArray ?? new();
                var byIndex = new Dictionary<int, JsonObject>();
                foreach (var item in source.OfType<JsonObject>()) byIndex[Integer(item["index"]) ?? 0] = item;
                int capacity = Math.Max(4, byIndex.Keys.DefaultIfEmpty(-1).Max() + 1);
                var slots = new List<FilamentSlot>();
                for (int slotIndex = 0; slotIndex < capacity; slotIndex++)
                {
                    var slot = byIndex.GetValueOrDefault(slotIndex) ?? new(); bool present = (Integer(slot["status"]) ?? 0) > 0; string? color = null;
                    if (slot["color"] is JsonArray rgb && rgb.Count >= 3)
                        color = $"{Integer(rgb[0]) ?? 0:X2}{Integer(rgb[1]) ?? 0:X2}{Integer(rgb[2]) ?? 0:X2}FF";
                    slots.Add(new FilamentSlot { Id = $"ace-{boxIndex}-{slotIndex}", Label = $"{(char)('A' + boxIndex)}{slotIndex + 1}",
                        Material = present ? slot["type"]?.ToString() : null, ColorHex = present ? color : null,
                        IsActive = present && loaded == slotIndex });
                }
                groups.Add(new FilamentGroup { Id = $"ace-{boxIndex}", SourceType = FilamentSourceType.Ams,
                    DisplayName = boxIndex == 0 ? "ACE Pro" : $"ACE Pro {boxIndex + 1}", DeclaredCapacity = capacity,
                    TemperatureCelsius = Number(box["temp"]), Slots = slots }); boxIndex++;
            }
            if (groups.Count > 0) { telemetry.FilamentGroups = groups; telemetry.AmsSlots = groups.SelectMany(g => g.LegacyAmsSlots()).ToList(); changed = true; }
        }
        telemetry.Nozzles = new(); telemetry.LastUpdated = DateTime.Now;
        return changed ? telemetry : null;
    }
}

public sealed class AnycubicS1Client : IPrinterConnection
{
    private sealed record Credentials(string Broker, string Username, string Password, string ModeId, string DeviceId);
    private readonly SavedPrinter _printer; private readonly Action<MqttEvent> _onEvent;
    private readonly CancellationTokenSource _cts = new(); private readonly SemaphoreSlim _sendGate = new(1, 1);
    private TcpClient? _tcp; private Stream? _stream; private PrinterTelemetry _telemetry = new(); private string _base = "";
    public AnycubicS1Client(SavedPrinter printer, Action<MqttEvent> onEvent) { _printer = printer; _onEvent = onEvent; }
    public void Start() => _ = Task.Run(RunAsync);
    public void Stop() { _cts.Cancel(); _stream?.Dispose(); _tcp?.Dispose(); }
    public void SendPrint(string action) => _ = PublishAsync("print", action, null);
    public void SetLight(bool enabled) => _ = PublishAsync("light", "control", new { type = 2, status = enabled ? 1 : 0, brightness = 100 });

    private async Task RunAsync()
    {
        try
        {
            var credentials = await BootstrapAsync(); var uri = new Uri(credentials.Broker);
            _tcp = new TcpClient { NoDelay = true }; await _tcp.ConnectAsync(uri.Host, uri.Port > 0 ? uri.Port : 9883, _cts.Token);
            var ssl = new SslStream(_tcp.GetStream(), false, (_, _, _, _) => true); _stream = ssl;
            await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = uri.Host,
                RemoteCertificateValidationCallback = (_, _, _, _) => true }, _cts.Token);
            await SendAsync(MqttCodec.Connect("Gantry-" + Guid.NewGuid().ToString("N")[..8], credentials.Username, credentials.Password));
            byte[] buffer = Array.Empty<byte>(), chunk = new byte[65536]; bool ready = false;
            while (!_cts.IsCancellationRequested)
            {
                int read = await _stream.ReadAsync(chunk, _cts.Token); if (read <= 0) break;
                var grown = new byte[buffer.Length + read]; buffer.CopyTo(grown, 0); Array.Copy(chunk, 0, grown, buffer.Length, read); buffer = grown;
                foreach (var packet in MqttCodec.ExtractPackets(ref buffer))
                {
                    if ((packet.Type >> 4) == 2 && !ready)
                    {
                        if (packet.Body.Length < 2 || packet.Body[1] != 0) throw new UnauthorizedAccessException("Anycubic odrzucił połączenie MQTT");
                        ready = true; _base = $"anycubic/anycubicCloud/v1/web/printer/{credentials.ModeId}/{credentials.DeviceId}";
                        await SendAsync(MqttCodec.Subscribe($"anycubic/anycubicCloud/v1/printer/+/{credentials.ModeId}/{credentials.DeviceId}/#"));
                        await SendAsync(MqttCodec.Subscribe($"anycubic/anycubicCloud/v1/+/public/{credentials.ModeId}/{credentials.DeviceId}/+/report", 2));
                        _onEvent(new MqttEvent { Type = MqttEventType.Connected });
                        await PublishAsync("info", "query", null); await PublishAsync("light", "query", null); await PublishAsync("multiColorBox", "getInfo", null);
                        await PublishAsync("video", "startCapture", null);
                    }
                    else if ((packet.Type >> 4) == 3 && MqttCodec.PublishPayload(packet.Type, packet.Body) is byte[] payload && AnycubicStatusParser.Parse(payload, _telemetry) is { } updated)
                    { _telemetry = updated; _onEvent(new MqttEvent { Type = MqttEventType.Telemetry, Telemetry = updated }); }
                }
            }
            if (!_cts.IsCancellationRequested) _onEvent(new MqttEvent { Type = MqttEventType.Disconnected });
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!_cts.IsCancellationRequested) _onEvent(new MqttEvent { Type = MqttEventType.Disconnected, Reason = error.Message }); }
    }

    private async Task<Credentials> BootstrapAsync()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        var info = JsonNode.Parse(await http.GetStringAsync($"http://{_printer.Host}:{_printer.Port ?? 18910}/info", _cts.Token)) as JsonObject ?? throw new IOException("Brak odpowiedzi Anycubic LAN");
        if (info["ctrlType"]?.ToString() == "cloud") throw new IOException("Włącz tryb LAN w ustawieniach drukarki Anycubic");
        var token = info["token"]?.ToString() ?? ""; var control = info["ctrlInfoUrl"]?.ToString() ?? "";
        if (token.Length < 32 || control.Length == 0) throw new IOException("Drukarka nie zwróciła danych sterowania LAN");
        long ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); string nonce = Guid.NewGuid().ToString("N")[..6];
        static string Md5(string value) => Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
        string sign = Md5(Md5(token[..16]) + ts + nonce), separator = control.Contains('?') ? "&" : "?";
        var url = control + separator + $"ts={ts}&nonce={nonce}&sign={sign}&did={Guid.NewGuid():N}";
        using var response = await http.PostAsync(url, new ByteArrayContent(Array.Empty<byte>()), _cts.Token);
        var result = JsonNode.Parse(await response.Content.ReadAsStringAsync(_cts.Token)) as JsonObject ?? throw new IOException("Błędna odpowiedź Anycubic");
        var body = result["data"] as JsonObject ?? throw new IOException("Brak konfiguracji MQTT Anycubic");
        var encrypted = Convert.FromBase64String(body["info"]?.ToString() ?? ""); var localToken = body["token"]?.ToString() ?? "";
        using var aes = Aes.Create(); aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
        aes.Key = Encoding.UTF8.GetBytes(token.Substring(16, 16)); aes.IV = Encoding.UTF8.GetBytes(localToken.PadRight(16, '\0')[..16]);
        var clear = aes.CreateDecryptor().TransformFinalBlock(encrypted, 0, encrypted.Length);
        var config = JsonNode.Parse(clear) as JsonObject ?? throw new IOException("Nie można odszyfrować konfiguracji Anycubic");
        return new Credentials(config["broker"]?.ToString() ?? throw new IOException("Brak brokera Anycubic"),
            config["username"]?.ToString() ?? "", config["password"]?.ToString() ?? "",
            config["modeId"]?.ToString() ?? config["modelId"]?.ToString() ?? throw new IOException("Brak modelu Anycubic"),
            config["deviceId"]?.ToString() ?? throw new IOException("Brak identyfikatora Anycubic"));
    }
    private Task PublishAsync(string type, string action, object? data) => string.IsNullOrEmpty(_base) ? Task.CompletedTask :
        SendAsync(MqttCodec.Publish($"{_base}/{type}", JsonSerializer.SerializeToUtf8Bytes(new { type, action, timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), msgid = Guid.NewGuid(), data })));
    private async Task SendAsync(byte[] data) { if (_stream is null) return; await _sendGate.WaitAsync(_cts.Token); try { await _stream.WriteAsync(data, _cts.Token); } finally { _sendGate.Release(); } }
}
