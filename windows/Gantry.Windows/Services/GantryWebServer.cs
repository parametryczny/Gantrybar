using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>A tiny, read-only web dashboard served on the LAN. Nothing here accepts state changes. Uses a raw
/// TcpListener (not HttpListener) so it can bind to every interface without an admin URL reservation.
/// The dashboard view is polling-based (the shared HTML falls back from WebSocket to polling).</summary>
public sealed class GantryWebServer
{
    public const int Port = 8787;

    private readonly PrinterStore _store;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;

    public GantryWebServer(PrinterStore store) { _store = store; }

    public void Start()
    {
        if (_listener != null) return;
        try
        {
            _cts = new CancellationTokenSource();
            _listener = new TcpListener(IPAddress.Any, Port);
            _listener.Start();
            _ = AcceptLoop(_listener, _cts.Token);
        }
        catch { _listener = null; }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _listener?.Stop(); } catch { }
        _listener = null;
    }

    private async Task AcceptLoop(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(ct); }
            catch { break; }
            _ = HandleClient(client);
        }
    }

    private async Task HandleClient(TcpClient client)
    {
        try
        {
            using (client)
            using (var stream = client.GetStream())
            {
                var buffer = new byte[65536];
                var data = new List<byte>();
                int headerEnd = -1, contentLength = 0;
                // Read until headers complete, then until the Content-Length body has all arrived.
                while (true)
                {
                    if (headerEnd < 0)
                    {
                        headerEnd = IndexOf(data, "\r\n\r\n");
                        if (headerEnd >= 0)
                        {
                            var header = Encoding.UTF8.GetString(data.GetRange(0, headerEnd).ToArray());
                            contentLength = ContentLength(header);
                        }
                    }
                    if (headerEnd >= 0 && data.Count >= headerEnd + 4 + contentLength) break;
                    int n = await stream.ReadAsync(buffer);
                    if (n <= 0) break;
                    data.AddRange(buffer[..n]);
                    if (data.Count > 4_000_000) break; // guard
                }
                if (headerEnd < 0) return;

                var headerText = Encoding.UTF8.GetString(data.GetRange(0, headerEnd).ToArray());
                var body = data.Count >= headerEnd + 4 ? data.GetRange(headerEnd + 4, Math.Min(contentLength, data.Count - headerEnd - 4)).ToArray() : Array.Empty<byte>();
                var (status, payload, type) = Route(headerText, body);
                var reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : "Bad Request";
                var head = $"HTTP/1.1 {status} {reason}\r\nContent-Type: {type}\r\nContent-Length: {payload.Length}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.UTF8.GetBytes(head));
                await stream.WriteAsync(payload);
            }
        }
        catch { }
    }

    private (int, byte[], string) Route(string headerText, byte[] body)
    {
        var lines = headerText.Split("\r\n");
        var parts = lines[0].Split(' ');
        string path = parts.Length > 1 ? parts[1] : "/";

        if (path.StartsWith("/api/printers"))
            return (200, Encoding.UTF8.GetBytes(FleetJson()), "application/json");
        return (200, Encoding.UTF8.GetBytes(Html), "text/html; charset=utf-8");
    }

    private string FleetJson()
    {
        var printers = System.Windows.Application.Current.Dispatcher.Invoke(() =>
        {
            var list = new List<object>();
            foreach (var p in _store.Printers)
            {
                var t = _store.Telemetry.TryGetValue(p.Serial, out var tel) ? tel : new PrinterTelemetry();
                string state = t.State.ToString().ToLowerInvariant();
                bool active = t.State is PrinterState.Printing or PrinterState.Paused;
                var groups = new List<object>();
                for (int gi = 0; gi < t.FilamentGroups.Count; gi++)
                {
                    var g = t.FilamentGroups[gi];
                    var slots = new List<object>();
                    for (int si = 0; si < g.Slots.Count; si++)
                    {
                        var s = g.Slots[si];
                        var loc = SpoolLocation.At(p.Serial, g.IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, gi, si);
                        var sp = SpoolbaseShared.Spools.SpoolAt(loc);
                        var def = sp != null ? SpoolbaseShared.Filaments.Filaments.FirstOrDefault(f => f.Id == sp.FilamentDefinitionId) : null;
                        slots.Add(new
                        {
                            label = s.Label,
                            material = s.IsPresent ? (s.Material ?? "") : (def?.Type ?? ""),
                            colorHex = def?.ColorHex ?? s.ColorHex ?? "8E8E93",
                            percent = (int?)(sp?.Percent ?? s.RemainingPercent),
                            grams = sp != null ? (int?)sp.RemainingWeightGrams : null,
                            active = s.IsActive,
                        });
                    }
                    groups.Add(new { name = g.DisplayName, external = g.IsExternal, humidity = g.HumidityPercent, temp = g.TemperatureCelsius, slots });
                }
                list.Add(new
                {
                    name = p.Name, state, progress = t.Progress, remainingMinutes = t.RemainingMinutes,
                    job = active ? (t.JobName ?? "") : "", nozzle = t.NozzleTemperature, bed = t.BedTemperature,
                    chamber = t.ChamberTemperature, layer = t.CurrentLayer, totalLayers = t.TotalLayers, groups
                });
            }
            return list;
        });
        return JsonSerializer.Serialize(new { printers });
    }

    // MARK: helpers

    public static string? LocalIPv4()
    {
        try
        {
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
                foreach (var ip in ni.GetIPProperties().UnicastAddresses)
                    if (ip.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ip.Address))
                        return ip.Address.ToString();
            }
        }
        catch { }
        return null;
    }

    private static int ContentLength(string header)
    {
        foreach (var line in header.Split("\r\n"))
        {
            var p = line.Split(':', 2);
            if (p.Length == 2 && p[0].Trim().Equals("content-length", StringComparison.OrdinalIgnoreCase) && int.TryParse(p[1].Trim(), out var len))
                return len;
        }
        return 0;
    }

    private static int IndexOf(List<byte> data, string marker)
    {
        var m = Encoding.ASCII.GetBytes(marker);
        for (int i = 0; i + m.Length <= data.Count; i++)
        {
            bool ok = true;
            for (int j = 0; j < m.Length; j++) if (data[i + j] != m[j]) { ok = false; break; }
            if (ok) return i;
        }
        return -1;
    }

    private const string Html = "<!doctype html><html><head><meta charset=\"utf-8\">\n" +
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" +
        "<title>Gantry</title>\n<style>\n" +
        ":root{--bg:#0c0d0e;--card:#151719;--line:rgba(255,255,255,.09);--text:#f2f3f1;--sec:#a7aaa6;--muted:#6d716e;--acc:#d4d7d3;--noz:#ff8a61;--bed:#efbd5f;--cham:#bba5ef}\n" +
        "*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}\n" +
        "body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,system-ui,'Segoe UI',sans-serif;padding:14px}\n" +
        "h1{font-size:18px;font-weight:800;letter-spacing:.5px;margin:0 0 2px}\n" +
        ".sub{color:var(--sec);font-size:12px;margin-bottom:14px}\n" +
        ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px}\n" +
        ".card{background:rgba(21,23,25,.6);border:1px solid var(--line);border-radius:16px;padding:12px}\n" +
        ".top{display:flex;align-items:center;gap:8px}.name{font-weight:600;font-size:14px}\n" +
        ".pill{font-size:9px;color:var(--sec);border:1px solid var(--line);border-radius:5px;padding:2px 6px}\n" +
        ".status{color:var(--sec);font-size:11px;margin:6px 0 2px}.pct{font-size:26px;font-weight:600;font-variant-numeric:tabular-nums}\n" +
        ".rule{height:1px;background:var(--line);margin:8px 0}.temps{display:flex;gap:6px}\n" +
        ".temp{flex:1}.temp .l{font-size:7px;color:var(--sec);letter-spacing:.5px}\n" +
        ".temp .v{font-size:15px;font-weight:600;font-variant-numeric:tabular-nums}\n" +
        ".ams{display:flex;gap:10px;flex-wrap:wrap;margin-top:2px}.grp{flex:1;min-width:120px}.grp .h{font-size:10px;font-weight:600}\n" +
        ".slots{display:flex;gap:5px;margin-top:4px}.slot{flex:1;text-align:center}\n" +
        ".sw{height:22px;border-radius:6px;border:1px solid var(--line);display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700}\n" +
        ".mat{font-size:10px;font-weight:600;margin-top:2px}.off{opacity:.45}.foot{color:var(--muted);text-align:center;font-size:11px;margin-top:16px}\n" +
        "</style></head><body>\n<h1>GANTRY</h1><div class=\"sub\" id=\"sub\">Ładowanie…</div>\n<div class=\"grid\" id=\"grid\"></div>\n" +
        "<div class=\"foot\">Podgląd na żywo • tylko sieć lokalna</div>\n<script>\n" +
        "const NOZ='var(--noz)',BED='var(--bed)',CHAM='var(--cham)';\n" +
        "function ink(hex){hex=(hex||'').replace('#','');const r=parseInt(hex.substr(0,2),16),g=parseInt(hex.substr(2,2),16),b=parseInt(hex.substr(4,2),16);return (0.299*r+0.587*g+0.114*b)/255>0.58?'#151719':'#fff'}\n" +
        "function temp(v,c){return v==null?'<span class=\"v\" style=\"color:var(--muted)\">—</span>':'<span class=\"v\" style=\"color:'+c+'\">'+Math.round(v)+'°</span>'}\n" +
        "function render(d){const ps=(d&&d.printers)||[];document.getElementById('sub').textContent=ps.length+' drukarek • '+ps.filter(p=>p.state==='printing').length+' pracuje';\n" +
        "document.getElementById('grid').innerHTML=ps.map(p=>{const temps='<div class=\"temps\">'+'<div class=\"temp\"><div class=\"l\">DYSZA</div>'+temp(p.nozzle,NOZ)+'</div>'+'<div class=\"temp\"><div class=\"l\">STÓŁ</div>'+temp(p.bed,BED)+'</div>'+(p.chamber!=null?'<div class=\"temp\"><div class=\"l\">KOMORA</div>'+temp(p.chamber,CHAM)+'</div>':'')+'</div>';\n" +
        "const ams=(p.groups||[]).map(g=>'<div class=\"grp\"><div class=\"h\">'+g.name+'</div><div class=\"slots\">'+g.slots.map(s=>{const pct=s.percent==null?'':s.percent+'%';const col=s.material?('#'+(s.colorHex||'8E8E93')):'transparent';const style=s.material?('background:'+col+';color:'+ink(s.colorHex)):'';return '<div class=\"slot\"><div class=\"sw\" style=\"'+style+'\">'+pct+'</div><div class=\"mat\">'+(s.material||'—')+'</div></div>'}).join('')+'</div></div>').join('');\n" +
        "const off=p.state==='offline';return '<div class=\"card'+(off?' off':'')+'\"><div class=\"top\"><span class=\"name\">'+p.name+'</span><span class=\"pill\">'+p.state+'</span></div>'+'<div class=\"status\">'+(p.job||'')+'</div><div class=\"pct\">'+p.progress+'%</div>'+'<div class=\"rule\"></div>'+temps+(ams?'<div class=\"rule\"></div><div class=\"ams\">'+ams+'</div>':'')+'</div>';}).join('');}\n" +
        "function poll(){fetch('/api/printers').then(r=>r.json()).then(render).catch(()=>{document.getElementById('sub').textContent='Brak połączenia z Gantry';});}\n" +
        "poll();setInterval(poll,2000);\n</script></body></html>";
}
