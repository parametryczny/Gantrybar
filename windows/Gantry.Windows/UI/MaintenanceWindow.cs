using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

public sealed class MaintenanceWindow : Window
{
    private readonly SavedPrinter _printer;
    private PrinterTelemetry _telemetry;
    private readonly StackPanel _body = new();
    private readonly bool _pl = AppSettings.Polish;
    private static readonly Dictionary<string, MaintenanceWindow> Active = new();

    public static void ShowFor(SavedPrinter printer, PrinterTelemetry telemetry, Window? owner = null)
    {
        if (Active.TryGetValue(printer.Serial, out var existing))
        {
            existing._telemetry = telemetry; existing.Rebuild(); existing.Activate(); return;
        }
        var window = new MaintenanceWindow(printer, telemetry) { Owner = owner };
        Active[printer.Serial] = window;
        window.Closed += (_, _) => Active.Remove(printer.Serial);
        window.Show();
    }

    private MaintenanceWindow(SavedPrinter printer, PrinterTelemetry telemetry)
    {
        _printer = printer; _telemetry = telemetry;
        Title = AppSettings.Text($"Konserwacja · {printer.Name}", $"Maintenance · {printer.Name}");
        Width = 460; Height = 590; MinWidth = 420; MinHeight = 430;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = GTheme.Brush(GTheme.Canvas);
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _body };
        Rebuild();
    }

    private void Rebuild()
    {
        _body.Children.Clear(); _body.Margin = new Thickness(18);
        var snap = PrinterInsights.GetSnapshot(_printer.Serial, _pl);
        _body.Children.Add(Text(20, FontWeights.Bold, Title));
        string nozzle = _telemetry.NozzleDiameter is { } d ? $"{d:0.0} mm" : "—";
        _body.Children.Add(Text(11, FontWeights.Normal,
            _pl ? $"{snap.TotalPrintHours:0.0} h druku · dysza {nozzle}" : $"{snap.TotalPrintHours:0.0} print h · nozzle {nozzle}", Muted()));
        foreach (var task in snap.Tasks) _body.Children.Add(TaskCard(task));
        _body.Children.Add(Section(_pl ? "OSTATNIE WYDRUKI" : "RECENT PRINTS"));
        foreach (var entry in snap.History.Take(3))
        {
            string icon = entry.Result == PrinterInsights.PrintResult.Completed ? "✓" : entry.Result == PrinterInsights.PrintResult.Failed ? "!" : "×";
            _body.Children.Add(Text(11, FontWeights.Medium, $"{icon}  {(string.IsNullOrWhiteSpace(entry.Job) ? "—" : entry.Job)} · {Duration(entry.DurationSeconds)}", Muted()));
        }
        if (snap.History.Count == 0) _body.Children.Add(Text(11, FontWeights.Normal, _pl ? "Brak zapisanej historii." : "No recorded history.", Muted()));
        string success = snap.SuccessPercent is { } percent ? $"{percent}%" : "—";
        _body.Children.Add(Text(10.5, FontWeights.SemiBold,
            _pl ? $"STATYSTYKI · {snap.CompletedCount} zakończonych · {success} skuteczności · {snap.ConsumedGrams:0} g"
                : $"STATISTICS · {snap.CompletedCount} completed · {success} success · {snap.ConsumedGrams:0} g", Muted()));
        var instructions = Button(_pl ? "Instrukcje" : "Instructions");
        instructions.Click += (_, _) => MessageBox.Show(this,
            _pl ? "Wyłącz i ostudź drukarkę. Oczyść prowadnice, zastosuj środek zalecany przez producenta, sprawdź paski i dyszę. Instrukcja producenta ma pierwszeństwo."
                : "Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, then inspect belts and nozzle. The manufacturer guide takes precedence.",
            instructions.Content?.ToString() ?? "", MessageBoxButton.OK, MessageBoxImage.Information);
        var history = Button(_pl ? "Pełna historia" : "Full history");
        history.Click += (_, _) => ShowHistory();
        var footer = new Grid { Margin = new Thickness(0, 8, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(instructions); Grid.SetColumn(history, 1); footer.Children.Add(history);
        _body.Children.Add(footer);
    }

    private FrameworkElement TaskCard(PrinterInsights.TaskStatus task)
    {
        string icon = task.IsUrgent ? "!" : task.IsDue ? "⚠" : "○";
        string timing = task.IsDue ? AppSettings.Text($"Przekroczono o {task.OverdueHours:0} h", $"Overdue by {task.OverdueHours:0} h")
                                   : AppSettings.Text($"Za {task.RemainingHours:0} h druku", $"In {task.RemainingHours:0} print h");
        var stack = new StackPanel();
        stack.Children.Add(Text(12.5, FontWeights.SemiBold, $"{icon}  {task.Title}"));
        stack.Children.Add(Text(10.5, FontWeights.Normal, timing, Muted()));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 5, 0, 0) };
        var done = Button(_pl ? "Wykonano" : "Done"); done.Click += (_, _) => { PrinterInsights.Complete(_printer.Serial, task.Id); Rebuild(); };
        var snooze = Button(_pl ? "Przypomnij za 7 dni" : "Remind in 7 days"); snooze.Click += (_, _) => { PrinterInsights.Snooze(_printer.Serial, task.Id); Rebuild(); };
        var interval = new TextBox { Text = Math.Round(task.IntervalHours).ToString(CultureInfo.InvariantCulture), Width = 48, Margin = new Thickness(12, 0, 4, 0), VerticalContentAlignment = VerticalAlignment.Center };
        var set = Button(_pl ? "Ustaw" : "Set"); set.Click += (_, _) => { if (double.TryParse(interval.Text, NumberStyles.Number, CultureInfo.InvariantCulture, out var hours)) { PrinterInsights.SetInterval(_printer.Serial, task.Id, hours); Rebuild(); } };
        actions.Children.Add(done); actions.Children.Add(snooze); actions.Children.Add(interval); actions.Children.Add(Text(10, FontWeights.Normal, "h", Muted())); actions.Children.Add(set);
        stack.Children.Add(actions);
        return new Border { Background = GTheme.Brush(GTheme.Surface), BorderBrush = task.IsUrgent ? new SolidColorBrush(Color.FromRgb(0xFF, 0x5A, 0x4E)) : task.IsDue ? new SolidColorBrush(Color.FromRgb(0xF2, 0xC9, 0x4C)) : GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(11), Margin = new Thickness(0, 8, 0, 0), Child = stack };
    }

    private void ShowHistory()
    {
        var rows = PrinterInsights.GetSnapshot(_printer.Serial, _pl).History.Select(value =>
            $"{value.EndedAt:g} · {(string.IsNullOrWhiteSpace(value.Job) ? "—" : value.Job)} · {Duration(value.DurationSeconds)}");
        MessageBox.Show(this, string.Join("\n", rows.DefaultIfEmpty(_pl ? "Brak historii." : "No history.")),
            _pl ? "Pełna historia" : "Full history", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private static string Duration(double seconds) { int minutes = (int)(seconds / 60); return minutes >= 60 ? $"{minutes / 60}h {minutes % 60}m" : $"{minutes}m"; }
    private static TextBlock Text(double size, FontWeight weight, string value, Brush? color = null) => new() { Text = value, FontSize = size, FontWeight = weight, Foreground = color ?? GTheme.Brush(GTheme.Text), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private static TextBlock Section(string value) => new() { Text = value, FontSize = 9.5, FontWeight = FontWeights.Bold, Foreground = Muted(), Margin = new Thickness(0, 12, 0, 2) };
    private static Button Button(string title) => new() { Content = title, Padding = new Thickness(9, 3, 9, 3), Margin = new Thickness(0, 0, 6, 0), FontSize = 10.5 };
    private static Brush Muted() => GTheme.Brush(GTheme.Secondary);
}
