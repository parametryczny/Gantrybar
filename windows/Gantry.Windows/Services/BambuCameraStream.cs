using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Gantry.Services;

/// Native Bambu chamber-camera client, ported from the working Codex "Bambu Kamera" app
/// (src/protocol.js + src/camera.js). It speaks the printer's camera protocols directly so we can
/// accept the printer's self-signed TLS certificate ourselves — the thing ffmpeg's Windows SChannel
/// build refused (SEC_E_UNTRUSTED_ROOT). ffmpeg is then used only as an offline H.264→MJPEG decoder
/// fed over a pipe (no network, no TLS), so it never sees the certificate.
///
/// Connection order mirrors the reference app: RTSPS:322 → RTSP:554 → JPEG:6000 (A1/P1). H.264 modes
/// emit JPEG frames via the ffmpeg decoder; the JPEG mode emits the printer's frames directly.
public sealed class BambuCameraStream
{
    public event Action<byte[]>? FrameReady;   // a full JPEG ready to display
    public event Action<string>? ModeResolved; // "RTSPS" | "RTSP" | "A1/P1"
    public event Action<string>? Failed;       // final, human-readable error

    private const int ConnectTimeoutMs = 6000;
    private const int FirstFrameTimeoutMs = 12000;

    private volatile bool _stopped;
    private TcpClient? _tcp;
    private Stream? _stream;
    private Process? _decoder;
    private CancellationTokenSource? _cts;
    private Timer? _keepalive;

    private string _host = "";
    private string _code = "";

    public void Start(string host, string code)
    {
        _host = host;
        _code = code;
        _ = Task.Run(RunAsync);
    }

    private async Task RunAsync()
    {
        Exception? best = null;
        // RTSPS (X1/H2/P2S/X2D …)
        try { if (await TryRtspAsync(322, secure: true)) { ModeResolved?.Invoke("RTSPS"); return; } }
        catch (AuthException ae) { Failed?.Invoke(ae.Message); return; }
        catch (Exception ex) { best = ex; CleanupAttempt(); }
        if (_stopped) return;

        // Plain RTSP (firmware/models exposing the unencrypted variant)
        try { if (await TryRtspAsync(554, secure: false)) { ModeResolved?.Invoke("RTSP"); return; } }
        catch (AuthException ae) { Failed?.Invoke(ae.Message); return; }
        catch (Exception ex) { if (!IsUnreachable(ex)) best = ex; CleanupAttempt(); }
        if (_stopped) return;

        // Legacy JPEG stream (A1 / A1 mini / P1P/P1S)
        try { if (await TryJpegAsync()) { ModeResolved?.Invoke("A1/P1"); return; } }
        catch (Exception ex) { best ??= ex; CleanupAttempt(); }

        if (!_stopped) Failed?.Invoke(Friendly(best?.Message));
    }

    // ---- RTSP / RTSPS (H.264 over interleaved TCP) ----

    private readonly Dictionary<int, TaskCompletionSource<RtspResponse>> _pending = new();
    private int _cseq = 1;
    private string? _authScheme;
    private string? _digestChallenge;
    private int _digestNc;
    private readonly List<byte[]> _parameterSets = new();
    private H264Depacketizer? _depack;
    private TaskCompletionSource<bool>? _firstVideo;
    private bool _receivedVideo;

    private async Task<bool> TryRtspAsync(int port, bool secure)
    {
        var scheme = secure ? "rtsps" : "rtsp";
        _authScheme = null; _digestChallenge = null; _digestNc = 0;
        _parameterSets.Clear(); _pending.Clear(); _receivedVideo = false;
        _firstVideo = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        await OpenSocketAsync(port, secure);

        // Start the ffmpeg decoder and the socket read loop before issuing any request.
        StartDecoder();
        _depack = new H264Depacketizer(nal =>
        {
            var nalType = nal.Length > 4 ? nal[4] & 0x1f : 0;
            if (nalType == 5) foreach (var ps in _parameterSets) WriteToDecoder(ps);
            WriteToDecoder(nal);
        });
        _cts = new CancellationTokenSource();
        _ = Task.Run(() => RtspReadLoopAsync(_cts.Token));

        var baseUrl = $"{scheme}://{_host}:{port}/streaming/live/1";
        await AuthorizedRequestAsync("OPTIONS", baseUrl);
        var describe = await AuthorizedRequestAsync("DESCRIBE", baseUrl, ("Accept", "application/sdp"));
        var (control, sets) = ParseSdp(Encoding.UTF8.GetString(describe.Body));
        _parameterSets.AddRange(sets);
        var trackUrl = ResolveControlUrl(baseUrl, control, scheme, port);
        var setup = await AuthorizedRequestAsync("SETUP", trackUrl, ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1"));
        var session = setup.Header("session")?.Split(';')[0];
        if (string.IsNullOrEmpty(session)) throw new Exception("Drukarka nie zwróciła identyfikatora sesji wideo.");

        await AuthorizedRequestAsync("PLAY", baseUrl, ("Session", session!));
        _keepalive = new Timer(async _ =>
        {
            try { await AuthorizedRequestAsync("GET_PARAMETER", baseUrl, ("Session", session!)); }
            catch { }
        }, null, 15000, 15000);

        var first = await Task.WhenAny(_firstVideo.Task, Task.Delay(FirstFrameTimeoutMs));
        if (first != _firstVideo.Task)
            throw new Exception("Połączenie RTSP działa, ale nie nadszedł obraz. Sprawdź „LAN Mode Live View”.");
        return true;
    }

    private async Task OpenSocketAsync(int port, bool secure)
    {
        var tcp = new TcpClient();
        using (var cts = new CancellationTokenSource(ConnectTimeoutMs))
            await tcp.ConnectAsync(_host, port).WaitAsync(cts.Token);
        _tcp = tcp;
        Stream stream = tcp.GetStream();
        if (secure)
        {
            var ssl = new SslStream(stream, false, (_, _, _, _) => true); // accept the printer's self-signed cert
            await ssl.AuthenticateAsClientAsync(_host);
            stream = ssl;
        }
        _stream = stream;
    }

    private async Task RtspReadLoopAsync(CancellationToken ct)
    {
        var buf = new byte[1 << 16];
        var acc = new List<byte>(1 << 16);
        try
        {
            while (!ct.IsCancellationRequested && _stream is not null)
            {
                int n = await _stream.ReadAsync(buf.AsMemory(0, buf.Length), ct);
                if (n <= 0) break;
                for (int i = 0; i < n; i++) acc.Add(buf[i]);
                ParseRtspIncoming(acc);
            }
        }
        catch { }
        if (!_stopped && _receivedVideo) Failed?.Invoke("Połączenie z kamerą zostało przerwane.");
    }

    private void ParseRtspIncoming(List<byte> b)
    {
        int pos = 0;
        while (pos < b.Count)
        {
            if (b[pos] == 0x24) // '$' interleaved binary
            {
                if (b.Count - pos < 4) break;
                int size = (b[pos + 2] << 8) | b[pos + 3];
                if (b.Count - pos < 4 + size) break;
                int channel = b[pos + 1];
                var packet = new byte[size];
                b.CopyTo(pos + 4, packet, 0, size);
                pos += 4 + size;
                if (channel % 2 == 0)
                {
                    if (!_receivedVideo) { _receivedVideo = true; _firstVideo?.TrySetResult(true); }
                    _depack?.PushRtp(packet);
                }
                continue;
            }

            int headerEnd = IndexOfCrlfCrlf(b, pos);
            if (headerEnd < 0) break;
            var head = Encoding.UTF8.GetString(b.GetRange(pos, headerEnd - pos).ToArray());
            var lines = head.Split("\r\n");
            var status = 0;
            var m = System.Text.RegularExpressions.Regex.Match(lines[0], @"^RTSP/\d\.\d\s+(\d+)");
            if (m.Success) status = int.Parse(m.Groups[1].Value);
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length; i++)
            {
                int c = lines[i].IndexOf(':');
                if (c > 0) headers[lines[i][..c].Trim()] = lines[i][(c + 1)..].Trim();
            }
            int bodySize = headers.TryGetValue("content-length", out var cl) && int.TryParse(cl, out var bs) ? bs : 0;
            if (b.Count - (headerEnd + 4) < bodySize) break;
            var body = new byte[bodySize];
            b.CopyTo(headerEnd + 4, body, 0, bodySize);
            pos = headerEnd + 4 + bodySize;
            if (!m.Success) continue;
            int cseq = headers.TryGetValue("cseq", out var cs) && int.TryParse(cs, out var q) ? q : -1;
            if (_pending.TryGetValue(cseq, out var tcs)) { _pending.Remove(cseq); tcs.TrySetResult(new RtspResponse(status, headers, body)); }
        }
        if (pos > 0) b.RemoveRange(0, pos);
    }

    private async Task<RtspResponse> AuthorizedRequestAsync(string method, string uri, params (string, string)[] headers)
    {
        var resp = await RequestAsync(method, uri, headers, AuthorizationFor(method, uri));
        if (resp.Status == 401)
        {
            var challenge = resp.Header("www-authenticate") ?? "";
            if (challenge.StartsWith("digest", StringComparison.OrdinalIgnoreCase)) { _authScheme = "digest"; _digestChallenge = challenge; _digestNc = 0; }
            else if (challenge.StartsWith("basic", StringComparison.OrdinalIgnoreCase)) _authScheme = "basic";
            else throw new Exception("Nieobsługiwany sposób logowania kamery.");
            resp = await RequestAsync(method, uri, headers, AuthorizationFor(method, uri));
        }
        if (resp.Status < 200 || resp.Status >= 300)
        {
            if (resp.Status == 401) throw new AuthException("Drukarka odrzuciła kod dostępu LAN. Włącz „LAN Mode Live View” i odśwież Access Code.");
            throw new Exception($"Drukarka zwróciła błąd RTSP {resp.Status}.");
        }
        return resp;
    }

    private string? AuthorizationFor(string method, string uri)
    {
        if (_authScheme == "basic")
            return "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes($"bblp:{_code}"));
        if (_authScheme == "digest" && _digestChallenge is not null)
            return DigestAuthorization(method, uri, "bblp", _code, _digestChallenge, ++_digestNc);
        return null;
    }

    private Task<RtspResponse> RequestAsync(string method, string uri, (string, string)[] headers, string? authorization)
    {
        int cseq = _cseq++;
        var sb = new StringBuilder();
        sb.Append(method).Append(' ').Append(uri).Append(" RTSP/1.0\r\n");
        sb.Append("CSeq: ").Append(cseq).Append("\r\n");
        sb.Append("User-Agent: Gantry/1.0\r\n");
        if (!string.IsNullOrEmpty(authorization)) sb.Append("Authorization: ").Append(authorization).Append("\r\n");
        foreach (var (k, v) in headers) if (!string.IsNullOrEmpty(v)) sb.Append(k).Append(": ").Append(v).Append("\r\n");
        sb.Append("\r\n");

        var tcs = new TaskCompletionSource<RtspResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[cseq] = tcs;
        var bytes = Encoding.ASCII.GetBytes(sb.ToString());
        try { _stream!.Write(bytes, 0, bytes.Length); _stream.Flush(); }
        catch (Exception ex) { _pending.Remove(cseq); tcs.TrySetException(ex); }
        _ = Task.Delay(ConnectTimeoutMs).ContinueWith(_ =>
        {
            if (_pending.Remove(cseq)) tcs.TrySetException(new Exception($"Brak odpowiedzi na żądanie RTSP {method}."));
        });
        return tcs.Task;
    }

    private static (string control, List<byte[]> sets) ParseSdp(string sdp)
    {
        var lines = sdp.Split('\n');
        bool inVideo = false;
        string? control = null;
        var sets = new List<byte[]>();
        foreach (var raw in lines)
        {
            var line = raw.TrimEnd('\r');
            if (line.StartsWith("m=")) inVideo = line.StartsWith("m=video");
            if (inVideo && line.StartsWith("a=control:") && control is null) control = line["a=control:".Length..].Trim();
            if (inVideo && line.StartsWith("a=fmtp:"))
            {
                var mm = System.Text.RegularExpressions.Regex.Match(line, @"sprop-parameter-sets=([^;\s]+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (mm.Success)
                    foreach (var enc in mm.Groups[1].Value.Split(','))
                        try { var nal = Convert.FromBase64String(enc); if (nal.Length > 0) sets.Add(WithStartCode(nal)); } catch { }
            }
        }
        if (control is null) throw new Exception("Nie znaleziono ścieżki wideo w odpowiedzi drukarki.");
        return (control, sets);
    }

    private static string ResolveControlUrl(string baseUrl, string control, string scheme, int port)
    {
        if (System.Text.RegularExpressions.Regex.IsMatch(control, @"^rtsps?://", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            return System.Text.RegularExpressions.Regex.Replace(control, @"^rtsps?:", scheme + ":", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        if (control.StartsWith("/")) return $"{scheme}://{baseUrl.Split('/')[2]}{control}";
        return baseUrl.TrimEnd('/') + "/" + control;
    }

    // ---- Legacy JPEG stream on port 6000 (A1 / P1) ----

    private async Task<bool> TryJpegAsync()
    {
        await OpenSocketAsync(6000, secure: true);
        _stream!.Write(CameraAuthPacket(_code), 0, 80);
        _stream.Flush();

        _cts = new CancellationTokenSource();
        var firstFrame = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _ = Task.Run(async () =>
        {
            var buf = new byte[1 << 16];
            var acc = new List<byte>(1 << 16);
            try
            {
                while (!_cts.Token.IsCancellationRequested && _stream is not null)
                {
                    int n = await _stream.ReadAsync(buf.AsMemory(0, buf.Length), _cts.Token);
                    if (n <= 0) break;
                    for (int i = 0; i < n; i++) acc.Add(buf[i]);
                    if (acc.Count > 8 * 1024 * 1024) acc.RemoveRange(0, acc.Count - 2 * 1024 * 1024);
                    foreach (var frame in SplitJpeg(acc)) { firstFrame.TrySetResult(true); FrameReady?.Invoke(frame); }
                }
            }
            catch { }
        });

        var done = await Task.WhenAny(firstFrame.Task, Task.Delay(FirstFrameTimeoutMs));
        if (done != firstFrame.Task) throw new Exception("Drukarka odpowiedziała, ale nie wysłała obrazu. Sprawdź kod i podgląd LAN.");
        return true;
    }

    private static byte[] CameraAuthPacket(string accessCode)
    {
        var packet = new byte[80];
        packet[0] = 0x40;                       // 0x40 little-endian
        packet[4] = 0x00; packet[5] = 0x30;     // 0x3000 little-endian
        Encoding.UTF8.GetBytes("bblp").CopyTo(packet, 16);
        Encoding.UTF8.GetBytes(accessCode).CopyTo(packet, 48);
        return packet;
    }

    // Pulls every complete JPEG (SOI FF D8 … EOI FF D9) out of the buffer, leaving the remainder.
    private static IEnumerable<byte[]> SplitJpeg(List<byte> b)
    {
        var frames = new List<byte[]>();
        int consumed = 0;
        while (true)
        {
            int start = IndexOfPair(b, 0xFF, 0xD8, consumed);
            if (start < 0) { consumed = Math.Max(consumed, b.Count - 1); break; }
            int end = IndexOfPair(b, 0xFF, 0xD9, start + 2);
            if (end < 0) { consumed = start; break; }
            var frame = new byte[end + 2 - start];
            b.CopyTo(start, frame, 0, frame.Length);
            frames.Add(frame);
            consumed = end + 2;
        }
        if (consumed > 0) b.RemoveRange(0, Math.Min(consumed, b.Count));
        return frames;
    }

    // ---- ffmpeg decoder (offline H.264 → MJPEG; no network, no TLS) ----

    private void StartDecoder()
    {
        var psi = new ProcessStartInfo
        {
            FileName = FfmpegPath(),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in new[] { "-nostdin", "-loglevel", "error", "-fflags", "nobuffer", "-flags", "low_delay",
                                  "-analyzeduration", "0", "-probesize", "32", "-f", "h264", "-i", "pipe:0",
                                  "-an", "-f", "mjpeg", "-q:v", "6", "pipe:1" })
            psi.ArgumentList.Add(a);
        var proc = Process.Start(psi)!;
        _decoder = proc;
        _ = Task.Run(async () => { try { while (await proc.StandardError.ReadLineAsync() is not null) { } } catch { } });
        _ = Task.Run(() => ReadDecoderMjpeg(proc));
    }

    private void WriteToDecoder(byte[] annexB)
    {
        try { var s = _decoder?.StandardInput.BaseStream; if (s is not null) { s.Write(annexB, 0, annexB.Length); s.Flush(); } }
        catch { }
    }

    private void ReadDecoderMjpeg(Process proc)
    {
        var stream = proc.StandardOutput.BaseStream;
        var chunk = new byte[1 << 16];
        var acc = new List<byte>(1 << 20);
        try
        {
            int n;
            while ((n = stream.Read(chunk, 0, chunk.Length)) > 0)
            {
                for (int i = 0; i < n; i++) acc.Add(chunk[i]);
                foreach (var frame in SplitJpeg(acc)) FrameReady?.Invoke(frame);
            }
        }
        catch { }
    }

    private static string FfmpegPath()
    {
        var bundled = System.IO.Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        return System.IO.File.Exists(bundled) ? bundled : "ffmpeg";
    }

    // ---- helpers ----

    public void Stop()
    {
        _stopped = true;
        try { _keepalive?.Dispose(); } catch { }
        try { _cts?.Cancel(); } catch { }
        try { _stream?.Dispose(); } catch { }
        try { _tcp?.Close(); } catch { }
        try { if (_decoder is { HasExited: false }) _decoder.Kill(true); } catch { }
        try { _decoder?.Dispose(); } catch { }
        _stream = null; _tcp = null; _decoder = null;
    }

    private void CleanupAttempt()
    {
        try { _keepalive?.Dispose(); } catch { }
        try { _cts?.Cancel(); } catch { }
        try { _stream?.Dispose(); } catch { }
        try { _tcp?.Close(); } catch { }
        try { if (_decoder is { HasExited: false }) _decoder.Kill(true); } catch { }
        try { _decoder?.Dispose(); } catch { }
        _stream = null; _tcp = null; _decoder = null; _keepalive = null;
    }

    private static bool IsUnreachable(Exception ex) =>
        System.Text.RegularExpressions.Regex.IsMatch(ex.Message, "refused|unreachable|timed out|Brak odpowiedzi", System.Text.RegularExpressions.RegexOptions.IgnoreCase)
        || ex is SocketException || ex is OperationCanceledException;

    private static string Friendly(string? message)
    {
        message ??= "Nieznany błąd połączenia.";
        if (message.Contains("refused", StringComparison.OrdinalIgnoreCase)) return "Drukarka odrzuciła połączenie. Sprawdź IP i włącz podgląd LAN.";
        if (System.Text.RegularExpressions.Regex.IsMatch(message, "unreachable|timed out", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) return "Nie można znaleźć drukarki w sieci lokalnej.";
        return message;
    }

    private static byte[] WithStartCode(byte[] nal)
    {
        var outp = new byte[nal.Length + 4];
        outp[3] = 1;
        Array.Copy(nal, 0, outp, 4, nal.Length);
        return outp;
    }

    private static int IndexOfCrlfCrlf(List<byte> b, int from)
    {
        for (int i = Math.Max(from, 0); i + 3 < b.Count; i++)
            if (b[i] == 0x0D && b[i + 1] == 0x0A && b[i + 2] == 0x0D && b[i + 3] == 0x0A) return i;
        return -1;
    }

    private static int IndexOfPair(List<byte> b, byte a, byte c, int from)
    {
        for (int i = Math.Max(from, 0); i + 1 < b.Count; i++)
            if (b[i] == a && b[i + 1] == c) return i;
        return -1;
    }

    private static string DigestAuthorization(string method, string uri, string username, string password, string challenge, int nonceCount)
    {
        var pars = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(challenge, "(\\w+)=(?:\"([^\"]*)\"|([^,\\s]+))"))
            pars[m.Groups[1].Value] = m.Groups[2].Success ? m.Groups[2].Value : m.Groups[3].Value;
        if (!pars.TryGetValue("realm", out var realm) || !pars.TryGetValue("nonce", out var nonce)) return "";

        static string Md5(string text) => Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
        var nc = nonceCount.ToString("x8");
        var cnonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
        var ha1 = Md5($"{username}:{realm}:{password}");
        var ha2 = Md5($"{method}:{uri}");
        string? qop = pars.TryGetValue("qop", out var q) ? Array.Find(q.Split(','), x => x.Trim() == "auth") : null;
        var response = qop is not null ? Md5($"{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}") : Md5($"{ha1}:{nonce}:{ha2}");

        var values = new List<string> { $"username=\"{username}\"", $"realm=\"{realm}\"", $"nonce=\"{nonce}\"", $"uri=\"{uri}\"", $"response=\"{response}\"" };
        if (pars.TryGetValue("algorithm", out var alg)) values.Add($"algorithm={alg}");
        if (pars.TryGetValue("opaque", out var opaque)) values.Add($"opaque=\"{opaque}\"");
        if (qop is not null) { values.Add($"qop={qop}"); values.Add($"nc={nc}"); values.Add($"cnonce=\"{cnonce}\""); }
        return "Digest " + string.Join(", ", values);
    }

    private sealed class AuthException : Exception { public AuthException(string m) : base(m) { } }

    private readonly record struct RtspResponse(int Status, Dictionary<string, string> Headers, byte[] Body)
    {
        public string? Header(string name) => Headers.TryGetValue(name, out var v) ? v : null;
    }

    // RTP H.264 depacketizer (single NAL / STAP-A / FU-A), ported from protocol.js.
    private sealed class H264Depacketizer
    {
        private readonly Action<byte[]> _onNal;
        private readonly List<byte[]> _fragmentParts = new();
        private uint _fragmentTimestamp;
        private bool _fragmenting;

        public H264Depacketizer(Action<byte[]> onNal) => _onNal = onNal;

        public void PushRtp(byte[] p)
        {
            if (p.Length < 12) return;
            if ((p[0] >> 6) != 2) return;
            int csrc = p[0] & 0x0f;
            bool hasExt = (p[0] & 0x10) != 0;
            bool hasPad = (p[0] & 0x20) != 0;
            uint timestamp = (uint)((p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7]);
            int offset = 12 + csrc * 4;
            if (hasExt)
            {
                if (p.Length < offset + 4) return;
                int words = (p[offset + 2] << 8) | p[offset + 3];
                offset += 4 + words * 4;
            }
            int end = p.Length;
            if (hasPad) end -= p[^1];
            if (offset >= end) return;
            var payload = p[offset..end];
            int nalType = payload[0] & 0x1f;

            if (nalType >= 1 && nalType <= 23) { EmitNal(payload); return; }

            if (nalType == 24) // STAP-A
            {
                int cursor = 1;
                while (cursor + 2 <= payload.Length)
                {
                    int size = (payload[cursor] << 8) | payload[cursor + 1];
                    cursor += 2;
                    if (size == 0 || cursor + size > payload.Length) break;
                    EmitNal(payload[cursor..(cursor + size)]);
                    cursor += size;
                }
                return;
            }

            if (nalType != 28 || payload.Length < 2) return; // FU-A
            bool start = (payload[1] & 0x80) != 0;
            bool finish = (payload[1] & 0x40) != 0;
            byte reconstructed = (byte)((payload[0] & 0xe0) | (payload[1] & 0x1f));
            if (start) { _fragmentTimestamp = timestamp; _fragmenting = true; _fragmentParts.Clear(); _fragmentParts.Add(new[] { reconstructed }); _fragmentParts.Add(payload[2..]); }
            else if (_fragmenting && _fragmentTimestamp == timestamp) _fragmentParts.Add(payload[2..]);
            else { _fragmenting = false; _fragmentParts.Clear(); return; }

            if (finish && _fragmentParts.Count > 0)
            {
                int total = 0; foreach (var part in _fragmentParts) total += part.Length;
                var nal = new byte[total]; int o = 0;
                foreach (var part in _fragmentParts) { Array.Copy(part, 0, nal, o, part.Length); o += part.Length; }
                EmitNal(nal);
                _fragmenting = false; _fragmentParts.Clear();
            }
        }

        private void EmitNal(byte[] nal) => _onNal(WithStartCode(nal));
    }
}
