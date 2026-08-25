using System;
using System.Globalization;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace Gantry.Services;

/// <summary>Downloads the printed <c>.gcode.3mf</c> from a Bambu printer over its local FTPS (implicit
/// TLS, port 990, user <c>bblp</c>, password = access code, self-signed accepted). Fully local. Untested
/// against hardware at build time; tuned live like the camera.</summary>
public sealed class BambuFileClient
{
    private readonly string _host;
    private readonly string _accessCode;
    private TcpClient? _control;
    private SslStream? _stream;

    public BambuFileClient(string host, string accessCode) { _host = host; _accessCode = accessCode; }

    public async Task<byte[]> FetchAsync(string fileName)
    {
        await OpenControlAsync();
        await ExpectAsync(220);
        await SendAsync($"USER bblp"); await ExpectAsync(331);
        await SendAsync($"PASS {_accessCode}"); await ExpectAsync(230);
        await SendAsync("PBSZ 0"); await ReadResponseAsync();
        await SendAsync("PROT P"); await ReadResponseAsync();
        await SendAsync("TYPE I"); await ReadResponseAsync();

        var baseName = Path.GetFileName(fileName);
        string[] candidates = { fileName, "/" + baseName, baseName, "/cache/" + baseName, "/model/" + baseName };
        string lastError = "no candidate path worked";
        foreach (var path in candidates)
        {
            try { return await RetrAsync(path); }
            catch (Exception e) { lastError = e.Message; }
        }
        Close();
        throw new IOException($"RETR failed for {baseName}: {lastError}");
    }

    private async Task<byte[]> RetrAsync(string path)
    {
        await SendAsync("PASV");
        var pasv = await ReadResponseAsync();
        int port = ParsePasv(pasv.Text) ?? throw new IOException($"bad PASV: {pasv.Text}");

        using var dataClient = new TcpClient();
        await dataClient.ConnectAsync(_host, port);
        using var dataSsl = new SslStream(dataClient.GetStream(), false, (_, _, _, _) => true);
        await dataSsl.AuthenticateAsClientAsync(_host);

        await SendAsync($"RETR {path}");
        var mark = await ReadResponseAsync();
        if (mark.Code is not (150 or 125)) throw new IOException($"RETR {path} -> {mark.Code} {mark.Text}");

        using var outMs = new MemoryStream();
        var buf = new byte[65536];
        int n;
        while ((n = await dataSsl.ReadAsync(buf)) > 0) outMs.Write(buf, 0, n);

        await ReadResponseAsync();   // 226
        Close();
        return outMs.ToArray();
    }

    private static int? ParsePasv(string text)
    {
        int open = text.IndexOf('('), close = text.IndexOf(')');
        if (open < 0 || close < 0 || close < open) return null;
        var parts = text.Substring(open + 1, close - open - 1).Split(',');
        if (parts.Length != 6) return null;
        if (int.TryParse(parts[4].Trim(), out var p1) && int.TryParse(parts[5].Trim(), out var p2))
            return p1 * 256 + p2;
        return null;
    }

    private async Task OpenControlAsync()
    {
        _control = new TcpClient();
        await _control.ConnectAsync(_host, 990);
        _stream = new SslStream(_control.GetStream(), false, (_, _, _, _) => true);
        await _stream.AuthenticateAsClientAsync(_host);
    }

    private void Close()
    {
        try { _stream?.Dispose(); } catch { }
        try { _control?.Dispose(); } catch { }
        _stream = null; _control = null;
    }

    private async Task SendAsync(string line)
    {
        if (_stream is null) throw new IOException("no control connection");
        var bytes = Encoding.ASCII.GetBytes(line + "\r\n");
        await _stream.WriteAsync(bytes);
        await _stream.FlushAsync();
    }

    private async Task ExpectAsync(int code)
    {
        var r = await ReadResponseAsync();
        if (r.Code != code) throw new IOException($"expected {code}, got {r.Code}: {r.Text}");
    }

    private readonly StringBuilder _pending = new();

    /// <summary>Reads one (possibly multi-line) FTP reply: "123-...\r\n...\r\n123 done".</summary>
    private async Task<(int Code, string Text)> ReadResponseAsync()
    {
        var lines = new StringBuilder();
        while (true)
        {
            var line = await ReadLineAsync();
            lines.AppendLine(line);
            if (line.Length >= 4 && int.TryParse(line.AsSpan(0, 3), out var code) && line[3] == ' ')
                return (code, lines.ToString());
        }
    }

    private async Task<string> ReadLineAsync()
    {
        if (_stream is null) throw new IOException("no control connection");
        var buf = new byte[4096];
        while (true)
        {
            var text = _pending.ToString();
            int nl = text.IndexOf("\r\n", StringComparison.Ordinal);
            if (nl >= 0)
            {
                _pending.Clear();
                _pending.Append(text.AsSpan(nl + 2));
                return text.Substring(0, nl);
            }
            int n = await _stream.ReadAsync(buf);
            if (n <= 0) throw new IOException("control closed");
            _pending.Append(Encoding.ASCII.GetString(buf, 0, n));
        }
    }
}
