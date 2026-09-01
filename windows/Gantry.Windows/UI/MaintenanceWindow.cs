using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>Maintenance card shown inside the dashboard overlay, matching the macOS panel.</summary>
internal sealed class MaintenancePanel
{
    private readonly SavedPrinter _printer;
    private readonly PrinterTelemetry _telemetry;
    private readonly Action _close;
    private readonly Action _changed;
    private readonly ContentControl _content = new();
    private readonly bool _pl = AppSettings.Polish;

    public static FrameworkElement Build(SavedPrinter printer, PrinterTelemetry telemetry, Action close, Action changed)
        => new MaintenancePanel(printer, telemetry, close, changed).Root;

    private MaintenancePanel(SavedPrinter printer, PrinterTelemetry telemetry, Action close, Action changed)
    {
        _printer = printer; _telemetry = telemetry; _close = close; _changed = changed;
        Root = new Border
        {
            Width = 520, Height = 680, MaxWidth = 560,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Background = GTheme.Brush(GTheme.Card), BorderBrush = GTheme.Brush(GTheme.Line),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12),
            ClipToBounds = true, Child = _content
        };
        Rebuild();
    }

    public Border Root { get; }

    private void Rebuild()
    {
        var snap = PrinterInsights.GetSnapshot(_printer.Serial, _pl);
        var body = new StackPanel { Margin = new Thickness(18) };
        var title = Text(20, FontWeights.Bold, AppSettings.Text($"Konserwacja · {_printer.Name}", $"Maintenance · {_printer.Name}"));
        var instructions = Button(_pl ? "Instrukcje" : "Instructions");
        instructions.Click += (_, _) => ShowInstructions();
        var close = Button("×");
        close.Width = 28; close.Height = 28; close.FontSize = 18; close.Padding = new Thickness(0); close.ToolTip = _pl ? "Zamknij" : "Close";
        close.Click += (_, _) => _close();
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(title);
        Grid.SetColumn(instructions, 2); header.Children.Add(instructions);
        Grid.SetColumn(close, 3); header.Children.Add(close);
        body.Children.Add(header);
        string nozzle = _telemetry.NozzleDiameter is { } d ? $"{d:0.0} mm" : "—";
        body.Children.Add(Text(11, FontWeights.Normal,
            _pl ? $"{snap.TotalPrintHours:0.0} h druku · dysza {nozzle}" : $"{snap.TotalPrintHours:0.0} print h · nozzle {nozzle}", Muted()));

        var alerts = PrinterAlerts();
        if (alerts.Count > 0)
        {
            body.Children.Add(Section(_pl ? "UWAGI DRUKARKI" : "PRINTER ALERTS"));
            foreach (var (message, code) in alerts) body.Children.Add(AlertCard(message, code));
        }
        foreach (var task in snap.Tasks) body.Children.Add(TaskCard(task));

        body.Children.Add(Section(_pl ? "OSTATNIE WYDRUKI" : "RECENT PRINTS"));
        foreach (var entry in snap.History.Take(3))
        {
            string icon = entry.Result == PrinterInsights.PrintResult.Completed ? "✓" : entry.Result == PrinterInsights.PrintResult.Failed ? "!" : "×";
            body.Children.Add(Text(11, FontWeights.Medium, $"{icon}  {(string.IsNullOrWhiteSpace(entry.Job) ? "—" : entry.Job)} · {Duration(entry.DurationSeconds)}", Muted()));
        }
        if (snap.History.Count == 0) body.Children.Add(Text(11, FontWeights.Normal, _pl ? "Brak zapisanej historii." : "No recorded history.", Muted()));
        string success = snap.SuccessPercent is { } percent ? $"{percent}%" : "—";
        body.Children.Add(Text(10.5, FontWeights.SemiBold,
            _pl ? $"STATYSTYKI · {snap.CompletedCount} zakończonych · {success} skuteczności · {snap.ConsumedGrams:0} g"
                : $"STATISTICS · {snap.CompletedCount} completed · {success} success · {snap.ConsumedGrams:0} g", Muted()));

        _content.Content = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = body
        };
        _changed();
    }

    private List<(string Message, string? Code)> PrinterAlerts()
    {
        var codes = HmsResolver.ActionableCodes(_telemetry.HmsCodes, _printer.Serial, _pl);
        if (codes.Count > 0)
            return codes.Select(code => (HmsResolver.Description(new[] { code }, _printer.Serial, _pl) ?? $"HMS {code}", (string?)code)).ToList();
        if (_telemetry.ErrorCode != 0)
            return new() { (string.Format(AppSettings.Text("Kod błędu: 0x{0:X}", "Error code: 0x{0:X}"), _telemetry.ErrorCode), null) };
        if (_telemetry.State == PrinterState.Error)
            return new() { (AppSettings.Text("Drukarka zgłosiła błąd", "Printer reported an error"), null) };
        return new();
    }

    private FrameworkElement AlertCard(string message, string? code)
    {
        var stack = new StackPanel();
        stack.Children.Add(Text(12, FontWeights.SemiBold, $"!  {message}"));
        if (!string.IsNullOrWhiteSpace(code)) stack.Children.Add(Text(10, FontWeights.Normal, code, Muted()));
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0x5A, 0x4E)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x62, 0xFF, 0x5A, 0x4E)),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9),
            Padding = new Thickness(11, 8, 11, 8), Margin = new Thickness(0, 6, 0, 0), Child = stack
        };
    }

    private FrameworkElement TaskCard(PrinterInsights.TaskStatus task)
    {
        string icon = task.IsUrgent ? "!" : task.IsDue ? "⚠" : "○";
        string timing = task.IsDue ? AppSettings.Text($"Przekroczono o {task.OverdueHours:0} h", $"Overdue by {task.OverdueHours:0} h")
                                   : AppSettings.Text($"Za {task.RemainingHours:0} h druku", $"In {task.RemainingHours:0} print h");
        var stack = new StackPanel();
        stack.Children.Add(Text(12.5, FontWeights.SemiBold, $"{icon}  {task.Title}"));
        stack.Children.Add(Text(10.5, FontWeights.Normal, timing, Muted()));
        var actions = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var done = Button(_pl ? "Wykonano" : "Done"); done.Click += (_, _) => { PrinterInsights.Complete(_printer.Serial, task.Id); Rebuild(); };
        var snooze = Button(_pl ? "Przypomnij za 7 dni" : "Remind in 7 days"); snooze.Click += (_, _) => { PrinterInsights.Snooze(_printer.Serial, task.Id); Rebuild(); };
        actions.Children.Add(done); Grid.SetColumn(snooze, 1); actions.Children.Add(snooze);
        var interval = new TextBox
        {
            Text = Math.Round(task.IntervalHours).ToString(CultureInfo.InvariantCulture), Width = 48, Height = 28,
            TextAlignment = TextAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
            Padding = new Thickness(0), Margin = new Thickness(5, 0, 5, 0), FontWeight = FontWeights.SemiBold,
            Background = GTheme.Brush(GTheme.Surface), Foreground = GTheme.Brush(GTheme.Text), BorderBrush = GTheme.Brush(GTheme.Line)
        };
        var set = Button(_pl ? "Ustaw" : "Set");
        set.Click += (_, _) => { if (double.TryParse(interval.Text, NumberStyles.Number, CultureInfo.InvariantCulture, out var hours)) { PrinterInsights.SetInterval(_printer.Serial, task.Id, hours); Rebuild(); } };
        var intervalRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        intervalRow.Children.Add(Text(10, FontWeights.Normal, _pl ? "Co" : "Every", Muted())); intervalRow.Children.Add(interval);
        intervalRow.Children.Add(Text(10, FontWeights.Normal, "h", Muted())); intervalRow.Children.Add(set);
        Grid.SetColumn(intervalRow, 3); actions.Children.Add(intervalRow);
        stack.Children.Add(actions);
        return new Border
        {
            Background = GTheme.Brush(GTheme.Surface),
            BorderBrush = task.IsUrgent ? new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0x5A, 0x4E)) : task.IsDue ? new SolidColorBrush(Color.FromArgb(0x72, 0xF2, 0xC9, 0x4C)) : GTheme.Brush(GTheme.Line),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(11), Margin = new Thickness(0, 8, 0, 0), Child = stack
        };
    }

    private void ShowInstructions() => MessageBox.Show(Window.GetWindow(Root),
        _pl ? "Wyłącz i ostudź drukarkę. Oczyść prowadnice, zastosuj środek zalecany przez producenta, sprawdź paski i dyszę. Instrukcja producenta ma pierwszeństwo."
            : "Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, then inspect belts and nozzle. The manufacturer guide takes precedence.",
        _pl ? "Instrukcje konserwacji" : "Maintenance instructions", MessageBoxButton.OK, MessageBoxImage.Information);

    private static string Duration(double seconds) { int minutes = (int)(seconds / 60); return minutes >= 60 ? $"{minutes / 60}h {minutes % 60}m" : $"{minutes}m"; }
    private static TextBlock Text(double size, FontWeight weight, string value, Brush? color = null) => new() { Text = value, FontSize = size, FontWeight = weight, Foreground = color ?? GTheme.Brush(GTheme.Text), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private static TextBlock Section(string value) => new() { Text = value, FontSize = 9.5, FontWeight = FontWeights.Bold, Foreground = Muted(), Margin = new Thickness(0, 12, 0, 2) };
    private static Button Button(string title) => new() { Content = title, Padding = new Thickness(9, 3, 9, 3), Margin = new Thickness(0, 0, 6, 0), FontSize = 10.5 };
    private static Brush Muted() => GTheme.Brush(GTheme.Secondary);
}
