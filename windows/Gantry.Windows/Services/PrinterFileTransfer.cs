using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Sends a sliced file to a printer that takes plain HTTP uploads, and starts it: Klipper
/// (Moonraker), PrusaLink and OctoPrint. Uploading never starts a print by itself; StartAsync is a
/// separate, explicit call. Mirrors macOS PrinterFileTransfer.</summary>
public static partial class PrinterFileTransfer
{
    public sealed class TransferError : Exception { public TransferError(string message) : base(message) { } }

    public static async Task UploadAsync(SavedPrinter printer, string? apiKey, string file, string remoteName,
                                         IProgress<double>? progress, CancellationToken cancel)
    {
        using var request = printer.Kind switch
        {
            PrinterKind.Klipper => Multipart($"http://{printer.Host}:{printer.Port ?? 7125}/server/files/upload", file, remoteName,
                                             new() { ["root"] = "gcodes" }, progress),
            PrinterKind.OctoPrint => Multipart(OctoPrintClient.BaseUrl(printer) + "/api/files/local", file, remoteName,
                                               new() { ["select"] = "false", ["print"] = "false" }, progress),
            PrinterKind.Prusa => PrusaUpload(printer, file, remoteName, progress),
            _ => throw new TransferError(AppSettings.T("This printer cannot receive files from Gantry.")),
        };
        if (!string.IsNullOrEmpty(apiKey)) request.Headers.Add("X-Api-Key", apiKey);
        await SendAsync(request, TimeSpan.FromMinutes(10), cancel).ConfigureAwait(false);
        progress?.Report(1);
    }

    public static async Task StartAsync(SavedPrinter printer, string? apiKey, string remoteName)
    {
        HttpRequestMessage request;
        switch (printer.Kind)
        {
            case PrinterKind.Klipper:
                request = new HttpRequestMessage(HttpMethod.Post,
                    $"http://{printer.Host}:{printer.Port ?? 7125}/printer/print/start?filename={Uri.EscapeDataString(remoteName)}");
                break;
            case PrinterKind.OctoPrint:
                request = new HttpRequestMessage(HttpMethod.Post, OctoPrintClient.BaseUrl(printer) + "/api/files/local/" + Uri.EscapeDataString(remoteName))
                {
                    Content = new StringContent(JsonSerializer.Serialize(new { command = "select", print = true }), Encoding.UTF8, "application/json"),
                };
                break;
            case PrinterKind.Prusa:
                request = new HttpRequestMessage(HttpMethod.Post, $"http://{printer.Host}:{printer.Port ?? 80}/api/v1/files/usb/" + Uri.EscapeDataString(remoteName));
                break;
            default:
                throw new TransferError(AppSettings.T("This printer cannot receive files from Gantry."));
        }
        using (request)
        {
            if (!string.IsNullOrEmpty(apiKey)) request.Headers.Add("X-Api-Key", apiKey);
            await SendAsync(request, TimeSpan.FromSeconds(15), CancellationToken.None).ConfigureAwait(false);
        }
    }

    private static HttpRequestMessage PrusaUpload(SavedPrinter printer, string file, string remoteName, IProgress<double>? progress)
    {
        var content = new FileContent(file, progress);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        var request = new HttpRequestMessage(HttpMethod.Put, $"http://{printer.Host}:{printer.Port ?? 80}/api/v1/files/usb/" + Uri.EscapeDataString(remoteName))
        {
            Content = content,
        };
        request.Headers.TryAddWithoutValidation("Print-After-Upload", "?0");
        request.Headers.TryAddWithoutValidation("Overwrite-File", "?1");
        return request;
    }

    private static HttpRequestMessage Multipart(string url, string file, string remoteName, Dictionary<string, string> fields, IProgress<double>? progress)
    {
        var form = new MultipartFormDataContent("gantry-" + Guid.NewGuid().ToString("N"));
        foreach (var (name, value) in fields.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            form.Add(new StringContent(value), name);
        var part = new FileContent(file, progress);
        part.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        form.Add(part, "file", remoteName.Replace("\"", ""));
        return new HttpRequestMessage(HttpMethod.Post, url) { Content = form };
    }

    private static async Task SendAsync(HttpRequestMessage request, TimeSpan timeout, CancellationToken cancel)
    {
        using var http = new HttpClient { Timeout = timeout };
        using var response = await http.SendAsync(request, cancel).ConfigureAwait(false);
        int code = (int)response.StatusCode;
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new TransferError(AppSettings.T("The printer refused the API key."));
        if (code is < 200 or >= 300)
        {
            string detail = "";
            try { detail = (await response.Content.ReadAsStringAsync(cancel).ConfigureAwait(false)).Trim(); } catch { }
            if (detail.Length > 200) detail = detail[..200];
            throw new TransferError(string.Format(AppSettings.T("The printer answered with HTTP {0}."), code) + (detail.Length == 0 ? "" : " " + detail));
        }
    }

    /// <summary>A file streamed from disk in chunks, reporting how much of it has gone out.</summary>
    private sealed class FileContent : HttpContent
    {
        private readonly string _path;
        private readonly IProgress<double>? _progress;

        public FileContent(string path, IProgress<double>? progress)
        {
            _path = path;
            _progress = progress;
        }

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            await using var source = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, useAsync: true);
            long total = source.Length, sent = 0;
            var buffer = new byte[81920];
            int read;
            while ((read = await source.ReadAsync(buffer).ConfigureAwait(false)) > 0)
            {
                await stream.WriteAsync(buffer.AsMemory(0, read)).ConfigureAwait(false);
                sent += read;
                if (total > 0) _progress?.Report((double)sent / total);
            }
        }

        protected override bool TryComputeLength(out long length)
        {
            length = new FileInfo(_path).Length;
            return true;
        }
    }
}
