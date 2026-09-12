using System.Buffers.Binary;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>Minimal BambuTunnelLocal client for the active project's files on TLS port 6000.
/// Recent X2D/H2 firmware keeps the running job on internal storage, outside the FTPS chroot.</summary>
public sealed class BambuTunnelFileClient : IAsyncDisposable
{
    public sealed record ProjectParts(byte[] PickPng, byte[] SliceInfo);
    private readonly string _host, _code;
    private TcpClient? _client; private SslStream? _stream; private uint _frame = 1, _command = 1;
    public BambuTunnelFileClient(string host, string code) { _host = host; _code = code; }

    public async Task<ProjectParts> FetchActiveProjectPartsAsync(int plate)
    {
        await OpenAsync(); await HandshakeAsync();
        var pick = await ProjectFileAsync($"Metadata/pick_{plate}.png", 1);
        var slice = await ProjectFileAsync("Metadata/slice_info.config", 2);
        return new ProjectParts(pick, slice);
    }

    private async Task OpenAsync()
    {
        _client = new TcpClient(); await _client.ConnectAsync(_host, 6000);
        _stream = new SslStream(_client.GetStream(), false, (_, _, _, _) => true);
        await _stream.AuthenticateAsClientAsync(_host);
    }

    private async Task HandshakeAsync()
    {
        var login = new byte[16]; Encoding.ASCII.GetBytes("bblp").CopyTo(login, 0);
        Encoding.UTF8.GetBytes(_code).Take(8).ToArray().CopyTo(login, 8);
        await SendFrameAsync(0x0101013f, login); _ = await ReadFrameAsync();
        var setup = JsonSerializer.SerializeToUtf8Bytes(new { sequence = 0, mtype = 12291, req = new { t_av = 1, mtype = 12289, peer_t = 3, pid = _frame.ToString("x8"), ver = "02.03.00.00" } });
        await SendFrameAsync(0x0102013f, setup); var (reply, _) = Split(await ReadFrameAsync());
        if (!reply.RootElement.TryGetProperty("result", out var result) || result.GetInt32() != 0) throw new IOException("tunnel-handshake-rejected");
    }

    private async Task<byte[]> ProjectFileAsync(string path, int sequenceId)
    {
        var parameter = JsonSerializer.SerializeToUtf8Bytes(new { sequence_id = sequenceId, version = 1, peer_host = "studio", command = "get_project_file", file_rel_path = path });
        uint sequence = _command++;
        var request = JsonSerializer.SerializeToUtf8Bytes(new { mtype = 12289, cmdtype = 4, sequence, req = new { path = "mem:/16", offset = 0, mem_dl_param_size = parameter.Length } });
        await SendFrameAsync(0x0102013f, request.Concat(new byte[] { 10, 10 }).Concat(parameter).ToArray());
        using var output = new MemoryStream();
        while (true)
        {
            var (reply, binary) = Split(await ReadFrameAsync()); var root = reply.RootElement;
            if (!root.TryGetProperty("sequence", out var seq) || seq.GetUInt32() != sequence) continue;
            var details = root.TryGetProperty("reply", out var value) ? value : default;
            if (details.ValueKind == JsonValueKind.Object && details.TryGetProperty("mem_dl_param_size", out var header))
            {
                int size = header.GetInt32(); if (binary.Length < size) throw new IOException("short-project-header");
                using var response = JsonDocument.Parse(binary.AsMemory(0, size));
                if (response.RootElement.TryGetProperty("result", out var rejected) && rejected.GetInt32() == 1) throw new IOException("project-file-rejected");
                output.Write(binary, size, binary.Length - size);
            }
            else output.Write(binary);
            int result = root.TryGetProperty("result", out var resultValue) ? resultValue.GetInt32() : -1;
            if (result == 1) continue;
            if (result == 0 && output.Length > 0) return output.ToArray();
            throw new IOException("project-file-download-failed");
        }
    }

    private async Task SendFrameAsync(uint magic, byte[] payload)
    {
        if (_stream is null) throw new IOException("tunnel-not-open");
        var header = new byte[16]; BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0,4),(uint)payload.Length); BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(4,4),magic); BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(8,4),_frame++);
        await _stream.WriteAsync(header); await _stream.WriteAsync(payload); await _stream.FlushAsync();
    }
    private async Task<byte[]> ReadFrameAsync() { var header=await ReadExactlyAsync(16); int length=(int)BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0,4)); if(length<0||length>128*1024*1024)throw new IOException("invalid-tunnel-frame"); return await ReadExactlyAsync(length); }
    private async Task<byte[]> ReadExactlyAsync(int count) { if(_stream is null)throw new IOException("tunnel-not-open"); var data=new byte[count]; int read=0; while(read<count){int n=await _stream.ReadAsync(data.AsMemory(read,count-read)); if(n==0)throw new IOException("tunnel-closed"); read+=n;} return data; }
    private static (JsonDocument Json, byte[] Binary) Split(byte[] data)
    {
        int depth=0,end=0; bool quoted=false,escaped=false;
        for(int i=0;i<data.Length;i++){char c=(char)data[i]; if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;}else if(c=='"')quoted=true;else if(c=='{')depth++;else if(c=='}'&&--depth==0){end=i+1;break;}}
        if(end==0)throw new IOException("invalid-tunnel-json"); int start=end; if(data.AsSpan(end).StartsWith(new byte[]{10,10}))start+=2; else if(data.AsSpan(end).StartsWith(new byte[]{13,10,13,10}))start+=4;
        return (JsonDocument.Parse(data.AsMemory(0,end)), data[start..]);
    }
    public ValueTask DisposeAsync(){try{_stream?.Dispose();_client?.Dispose();}catch{} return ValueTask.CompletedTask;}
}
