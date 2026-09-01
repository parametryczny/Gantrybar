using System.Diagnostics;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Controls;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

public sealed class DiagnosticsWindow : Window
{
    private readonly PrinterStore _store;
    private readonly bool _pl = AppSettings.Polish;
    private readonly StackPanel _results = new();
    private readonly TextBlock _status = new();
    private readonly Button _run;

    public DiagnosticsWindow(PrinterStore store)
    {
        _store = store;
        Title = AppSettings.Text("Centrum diagnostyczne", "Diagnostic Center");
        Width = 520; Height = 560; MinWidth = 450; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = GTheme.Brush(GTheme.Canvas);
        _status.Text = AppSettings.Text("Sprawdź łączność wszystkich drukarek.", "Check connectivity for every printer.");
        _status.Foreground = GTheme.Brush(GTheme.Secondary); _status.TextWrapping = TextWrapping.Wrap;
        _run = new Button { Content = AppSettings.Text("Uruchom wszystkie testy", "Run all tests"), Padding = new Thickness(12, 5, 12, 5), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 9, 0, 12) };
        _run.Click += async (_, _) => await RunAsync();
        var body = new StackPanel { Margin = new Thickness(18), Children = { _status, _run, _results } };
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = body };
    }

    private async Task RunAsync()
    {
        _run.IsEnabled = false; _status.Text = AppSettings.Text("Testuję…", "Testing…"); _results.Children.Clear();
        foreach (var printer in _store.Printers)
        {
            var network = await ProbeAsync(printer.Host, printer.Port);
            var telemetry = _store.Telemetry.TryGetValue(printer.Serial, out var value) ? value : null;
            bool mqtt = telemetry is not null && telemetry.State != PrinterState.Offline;
            int cameraPort = printer.Kind == PrinterKind.Bambu ? 6000 : printer.Kind == PrinterKind.ElegooCc1 ? 3031
                           : printer.Kind == PrinterKind.ElegooCc2 ? 8080 : printer.Port;
            var camera = await ProbeAsync(printer.Host, cameraPort);
            bool secret = !string.IsNullOrEmpty(AccessCodeStore.AccessCode(printer.Serial)) || printer.Kind is PrinterKind.ElegooCc1 or PrinterKind.Snapmaker;
            string reason = _store.ConnectionMessages.TryGetValue(printer.Serial, out var message) && !string.IsNullOrWhiteSpace(message) ? message! : "—";
            var rows = new[]
            {
                $"{Mark(network.Ok)}  {AppSettings.Text("Sieć", "Network")}" + (network.Latency is { } latency ? $" · {latency:0} ms · {Quality(latency)}" : $" · {network.Error}"),
                $"{Mark(mqtt)}  MQTT · " + (mqtt ? AppSettings.Text("telemetria aktywna", "telemetry active") : reason),
                $"{Mark(camera.Ok)}  {AppSettings.Text("Kamera", "Camera")}" + (camera.Latency is { } camLatency ? $" · {camLatency:0} ms" : $" · {camera.Error}"),
                $"{Mark(secret)}  {AppSettings.Text("Magazyn sekretów", "Secret storage")} · " + (secret ? "OK" : AppSettings.Text("brak kodu lub błąd DPAPI", "missing code or DPAPI error")),
            };
            _results.Children.Add(Card(printer.Name, rows));
        }
        if (_store.Printers.Count == 0) _results.Children.Add(new TextBlock { Text = AppSettings.Text("Brak drukarek.", "No printers."), Foreground = GTheme.Brush(GTheme.Secondary) });
        _status.Text = AppSettings.Text("Testy zakończone.", "Tests complete."); _run.IsEnabled = true;
    }

    private static async Task<(bool Ok, double? Latency, string? Error)> ProbeAsync(string host, int port)
    {
        var watch = Stopwatch.StartNew();
        try
        {
            using var client = new TcpClient();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await client.ConnectAsync(host, port, timeout.Token);
            watch.Stop(); return (true, watch.Elapsed.TotalMilliseconds, null);
        }
        catch (Exception error) { return (false, null, error.Message); }
    }

    private string Quality(double latency) => latency < 50 ? AppSettings.Text("bardzo dobra", "excellent")
        : latency < 150 ? AppSettings.Text("dobra", "good") : latency < 400 ? AppSettings.Text("słaba", "poor")
        : AppSettings.Text("bardzo słaba", "very poor");
    private static string Mark(bool ok) => ok ? "✓" : "×";
    private static FrameworkElement Card(string title, IEnumerable<string> rows)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Text), Margin = new Thickness(0, 0, 0, 5) });
        foreach (var row in rows) stack.Children.Add(new TextBlock { Text = row, FontSize = 11, Foreground = GTheme.Brush(GTheme.Secondary), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 2) });
        return new Border { Background = GTheme.Brush(GTheme.Surface), BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(11), Margin = new Thickness(0, 0, 0, 9), Child = stack };
    }
}
