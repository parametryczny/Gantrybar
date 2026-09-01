using System.Threading.Tasks;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Grabs one still JPEG frame from a printer's camera for the Telegram bot's /photo. On Windows
/// BambuCameraStream and ElegooMjpegStream already emit JPEG frames (ffmpeg decodes Bambu's H.264
/// internally), so we just take the first frame with a timeout. Mirrors the macOS CameraSnapshot.</summary>
public static class CameraSnapshot
{
    public static async Task<byte[]?> CaptureAsync(SavedPrinter printer, PrinterStore store, int timeoutMs = 12000)
    {
        var host = string.IsNullOrEmpty(printer.Host) ? printer.Serial : printer.Host;
        switch (printer.Kind)
        {
            case PrinterKind.Bambu:
            {
                var code = AccessCodeStore.AccessCode(printer.Serial);
                if (string.IsNullOrEmpty(code)) return null;
                var tcs = new TaskCompletionSource<byte[]?>();
                var cam = new BambuCameraStream();
                void OnFrame(byte[] jpeg) => tcs.TrySetResult(jpeg);
                cam.FrameReady += OnFrame;
                cam.Failed += _ => tcs.TrySetResult(null);
                cam.Start(host, code!);
                var result = await WithTimeout(tcs.Task, timeoutMs);
                cam.FrameReady -= OnFrame;
                cam.Stop();
                return result;
            }
            case PrinterKind.ElegooCc1:
            case PrinterKind.ElegooCc2:
            {
                bool cc2 = printer.Kind == PrinterKind.ElegooCc2;
                store.SendElegooMethod(printer.Serial, cc2 ? 1042 : 386, cc2 ? new { } : new { Enable = 1 });
                var url = cc2 ? $"http://{host}:8080/?action=stream" : $"http://{host}:3031/video";
                var tcs = new TaskCompletionSource<byte[]?>();
                var cam = new ElegooMjpegStream();
                void OnFrame(byte[] jpeg) => tcs.TrySetResult(jpeg);
                cam.FrameReady += OnFrame;
                cam.Failed += _ => tcs.TrySetResult(null);
                cam.Start(url);
                var result = await WithTimeout(tcs.Task, timeoutMs);
                cam.FrameReady -= OnFrame;
                cam.Stop();
                return result;
            }
            case PrinterKind.AnycubicKobraS1:
            {
                var tcs = new TaskCompletionSource<byte[]?>(); var cam = new AnycubicFlvStream();
                void OnFrame(byte[] jpeg) => tcs.TrySetResult(jpeg);
                cam.FrameReady += OnFrame; cam.Failed += _ => tcs.TrySetResult(null); cam.Start($"http://{host}:18088/flv");
                var result = await WithTimeout(tcs.Task, timeoutMs); cam.FrameReady -= OnFrame; cam.Stop(); return result;
            }
            default:
                return null;
        }
    }

    private static async Task<byte[]?> WithTimeout(Task<byte[]?> task, int ms)
    {
        var finished = await Task.WhenAny(task, Task.Delay(ms));
        return finished == task ? await task : null;
    }
}
