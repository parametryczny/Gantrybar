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
    private readonly ProgressBar _progress = new();
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
        _progress.Height = 4; _progress.Minimum = 0; _progress.Visibility = Visibility.Collapsed;
        _progress.Margin = new Thickness(0, 8, 0, 0);
        var body = new StackPanel { Margin = new Thickness(18), Children = { _status, _progress, _run, _results } };
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = body };
    }

    private async Task RunAsync()
    {
        _run.IsEnabled = false;
        _results.Children.Clear();
        var printers = _store.Printers.ToList();
        if (printers.Count == 0)
        {
            _results.Children.Add(new TextBlock { Text = AppSettings.Text("Brak drukarek.", "No printers."), Foreground = GTheme.Brush(GTheme.Secondary) });
            _status.Text = AppSettings.Text("Testy zakończone.", "Tests complete.");
            _run.IsEnabled = true;
            return;
        }
        _progress.Maximum = printers.Count;
        _progress.Value = 0;
        _progress.Visibility = Visibility.Visible;
        var started = Stopwatch.StartNew();
        for (int index = 0; index < printers.Count; index++)
        {
            var printer = printers[index];
            // Name the printer under test: a silent "Testing..." for the whole run reads as a hang.
            _status.Text = string.Format(AppSettings.Text("Testuję {0} z {1}: {2}", "Testing {0} of {1}: {2}"),
                                         index + 1, printers.Count, printer.Name);
            int servicePort = printer.Port ?? (printer.Kind switch
            {
                PrinterKind.Bambu => 8883, PrinterKind.Klipper => 7125, PrinterKind.Prusa => 80,
                PrinterKind.Snapmaker => 8080, PrinterKind.ElegooCc1 => 3030, PrinterKind.ElegooCc2 => 3000,
                PrinterKind.AnycubicKobraS1 => 18910,
                _ => 80
            });
            var network = await ProbeAsync(printer.Host, servicePort);
            var telemetry = _store.Telemetry.TryGetValue(printer.Serial, out var value) ? value : null;
            bool connected = telemetry is not null && telemetry.State != PrinterState.Offline;
            string reason = _store.ConnectionMessages.TryGetValue(printer.Serial, out var message) && !string.IsNullOrWhiteSpace(message) ? message! : "—";
            var rows = new[]
            {
                $"{Mark(network.Ok)}  {AppSettings.Text("Sieć", "Network")}" + (network.Latency is { } latency ? $" · {latency:0} ms · {Quality(latency)}" : $" · {network.Error ?? "—"}"),
                $"{Mark(connected)}  {AppSettings.Text("Połączenie z drukarką", "Printer connection")} · " + (connected ? AppSettings.Text("telemetria aktywna", "telemetry active") : reason),
            };
            _results.Children.Add(Card(printer.Name, rows));
            _progress.Value = index + 1;
        }
        started.Stop();
        _status.Text = string.Format(AppSettings.Text("Testy zakończone: {0} drukarek w {1:0.0} s", "Tests complete: {0} printers in {1:0.0} s"),
                                     printers.Count, started.Elapsed.TotalSeconds);
        _progress.Visibility = Visibility.Collapsed;
        _run.IsEnabled = true;
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
