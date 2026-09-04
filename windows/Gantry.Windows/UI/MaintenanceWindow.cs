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
            Width = 470, Height = 560, MaxWidth = 490,
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
        var body = new StackPanel { Margin = new Thickness(18, 16, 18, 14) };
        var title = Text(18, FontWeights.Bold, string.Format(AppSettings.T("Maintenance · {0}"), _printer.Name));
        var instructions = Button(AppSettings.T("Instructions"));
        instructions.Click += (_, _) => ShowInstructions();
        var close = Button("×");
        close.Width = 28; close.Height = 28; close.FontSize = 18; close.Padding = new Thickness(0); close.ToolTip = AppSettings.T("Close");
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
            body.Children.Add(Section(AppSettings.T("PRINTER ALERTS")));
            body.Children.Add(AlertList(alerts));
        }
        body.Children.Add(TaskGrid(snap.Tasks));

        var history = new StackPanel();
        history.Children.Add(Section(AppSettings.T("RECENT PRINTS"), false));
        foreach (var entry in snap.History.Take(3))
        {
            string icon = entry.Result == PrinterInsights.PrintResult.Completed ? "✓" : entry.Result == PrinterInsights.PrintResult.Failed ? "!" : "×";
            history.Children.Add(Text(10.5, FontWeights.Medium, $"{icon}  {(string.IsNullOrWhiteSpace(entry.Job) ? "—" : entry.Job)} · {Duration(entry.DurationSeconds)}"));
        }
        if (snap.History.Count == 0) history.Children.Add(Text(10.5, FontWeights.Normal, AppSettings.T("No recorded history."), Muted()));
        string success = snap.SuccessPercent is { } percent ? $"{percent}%" : "—";
        var stats = new StackPanel();
        stats.Children.Add(Section(AppSettings.T("STATISTICS"), false));
        var metrics = new Grid { Margin = new Thickness(0, 5, 0, 0) };
        for (int i = 0; i < 3; i++) metrics.ColumnDefinitions.Add(new ColumnDefinition());
        AddMetric(metrics, 0, snap.CompletedCount.ToString(), AppSettings.T("completed"));
        AddMetric(metrics, 1, success, AppSettings.T("success"));
        AddMetric(metrics, 2, $"{snap.ConsumedGrams:0} g", "filament");
        stats.Children.Add(metrics);
        var footer = new Grid { Margin = new Thickness(0, 7, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        var historyCard = CompactCard(history); var statsCard = CompactCard(stats);
        historyCard.Margin = new Thickness(0, 0, 3.5, 0); statsCard.Margin = new Thickness(3.5, 0, 0, 0);
        footer.Children.Add(historyCard); Grid.SetColumn(statsCard, 1); footer.Children.Add(statsCard);
        body.Children.Add(footer);

        _content.Content = body;
        _changed();
    }

    private List<(string Message, string? Code)> PrinterAlerts()
    {
        var codes = HmsResolver.ActionableCodes(_telemetry.HmsCodes, _printer.Serial, _pl);
        if (codes.Count > 0)
            return codes.Select(code => (HmsResolver.Description(new[] { code }, _printer.Serial, _pl) ?? $"HMS {code}", (string?)code)).ToList();
        if (_telemetry.ErrorCode != 0)
            return new() { (string.Format(AppSettings.T("Error code: 0x{0:X}"), _telemetry.ErrorCode), null) };
        if (_telemetry.State == PrinterState.Error)
            return new() { (AppSettings.T("Printer reported an error"), null) };
        return new();
    }

    private FrameworkElement AlertRow(string message, string? code)
    {
        var stack = new StackPanel();
        var heading = Text(11, FontWeights.SemiBold, $"!  {message}");
        heading.MaxHeight = 30;
        stack.Children.Add(heading);
        if (!string.IsNullOrWhiteSpace(code)) stack.Children.Add(Text(10, FontWeights.Normal, code, Muted()));
        return new Border { Padding = new Thickness(9, 6, 9, 6), Child = stack };
    }

    private FrameworkElement AlertList(IReadOnlyList<(string Message, string? Code)> alerts)
    {
        var rows = new StackPanel();
        for (int i = 0; i < alerts.Count; i++)
        {
            if (i > 0) rows.Children.Add(new Border { Height = 1, Background = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0x5A, 0x4E)) });
            rows.Children.Add(AlertRow(alerts[i].Message, alerts[i].Code));
        }
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0x5A, 0x4E)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x62, 0xFF, 0x5A, 0x4E)),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9),
            Margin = new Thickness(0, 4, 0, 0), Child = rows
        };
    }

    private FrameworkElement TaskGrid(IReadOnlyList<PrinterInsights.TaskStatus> tasks)
    {
        var grid = new Grid { Margin = new Thickness(0, 7, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition());
        int rowCount = (tasks.Count + 1) / 2;
        for (int i = 0; i < rowCount; i++) grid.RowDefinitions.Add(new RowDefinition());
        for (int i = 0; i < tasks.Count; i++)
        {
            var card = TaskCard(tasks[i]);
            int row = i / 2, column = i % 2;
            card.Margin = new Thickness(column == 0 ? 0 : 3.5, row == 0 ? 0 : 3.5,
                                        column == 0 ? 3.5 : 0, row == rowCount - 1 ? 0 : 3.5);
            Grid.SetRow(card, row); Grid.SetColumn(card, column); grid.Children.Add(card);
        }
        return grid;
    }

    private FrameworkElement TaskCard(PrinterInsights.TaskStatus task)
    {
        string icon = task.IsUrgent ? "!" : task.IsDue ? "⚠" : "○";
        string timing = task.IsDue ? string.Format(AppSettings.T("Overdue by {0:0} h"), task.OverdueHours)
                                   : string.Format(AppSettings.T("In {0:0} print h"), task.RemainingHours);
        if (_pl) timing = timing.Replace(" druku", "");
        var stack = new StackPanel();
        var heading = new Grid();
        heading.ColumnDefinitions.Add(new ColumnDefinition()); heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var taskTitle = Text(11, FontWeights.SemiBold, $"{icon}  {task.Title}");
        var taskTiming = Text(10, FontWeights.Normal, timing, Muted());
        heading.Children.Add(taskTitle); Grid.SetColumn(taskTiming, 1); heading.Children.Add(taskTiming);
        stack.Children.Add(heading);
        var actions = new Grid { Margin = new Thickness(0, 7, 0, 0) };
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var done = Button(AppSettings.T("Done")); done.Click += (_, _) => { PrinterInsights.Complete(_printer.Serial, task.Id); Rebuild(); };
        var snooze = Button("7d"); snooze.ToolTip = AppSettings.T("Remind in 7 days");
        snooze.Click += (_, _) => { PrinterInsights.Snooze(_printer.Serial, task.Id); Rebuild(); };
        done.Margin = new Thickness(0, 0, 4, 0); snooze.Margin = new Thickness(0, 0, 4, 0);
        actions.Children.Add(done); Grid.SetColumn(snooze, 1); actions.Children.Add(snooze);
        var interval = new TextBox
        {
            Text = Math.Round(task.IntervalHours).ToString(CultureInfo.InvariantCulture), Width = 34, Height = 26,
            TextAlignment = TextAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
            Padding = new Thickness(0), Margin = new Thickness(0), FontSize = 10.5, FontWeight = FontWeights.SemiBold,
            Background = GTheme.Brush(GTheme.Surface), Foreground = GTheme.Brush(GTheme.Text), BorderBrush = GTheme.Brush(GTheme.Line)
        };
        var set = Button("✎"); set.ToolTip = AppSettings.T("Set interval");
        set.Padding = new Thickness(5, 2, 5, 2); set.Margin = new Thickness(2, 0, 0, 0);
        set.Click += (_, _) => { if (double.TryParse(interval.Text, NumberStyles.Number, CultureInfo.InvariantCulture, out var hours)) { PrinterInsights.SetInterval(_printer.Serial, task.Id, hours); Rebuild(); } };
        var intervalRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        intervalRow.Children.Add(interval);
        var hoursLabel = Text(10, FontWeights.Normal, "h", Muted()); hoursLabel.Margin = new Thickness(2, 0, 0, 0);
        intervalRow.Children.Add(hoursLabel); intervalRow.Children.Add(set);
        Grid.SetColumn(intervalRow, 2); actions.Children.Add(intervalRow);
        stack.Children.Add(actions);
        return new Border
        {
            Background = GTheme.Brush(GTheme.Surface),
            BorderBrush = task.IsUrgent ? new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0x5A, 0x4E)) : task.IsDue ? new SolidColorBrush(Color.FromArgb(0x72, 0xF2, 0xC9, 0x4C)) : GTheme.Brush(GTheme.Line),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(9), Child = stack
        };
    }

    private static Border CompactCard(UIElement child) => new()
    {
        Background = GTheme.Brush(GTheme.Surface), BorderBrush = GTheme.Brush(GTheme.Line),
        BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10),
        Padding = new Thickness(10, 8, 10, 8), Child = child
    };

    private static void AddMetric(Grid grid, int column, string value, string caption)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(new TextBlock { Text = value, FontSize = 14, FontWeight = FontWeights.Bold, Foreground = GTheme.Brush(GTheme.Text), HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = caption, FontSize = 9, Foreground = Muted(), HorizontalAlignment = HorizontalAlignment.Center });
        Grid.SetColumn(stack, column); grid.Children.Add(stack);
    }

    private void ShowInstructions() => MessageBox.Show(Window.GetWindow(Root),
        AppSettings.T("Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, then inspect belts and nozzle. The manufacturer guide takes precedence."),
        AppSettings.T("Maintenance instructions"), MessageBoxButton.OK, MessageBoxImage.Information);

    private static string Duration(double seconds) { int minutes = (int)(seconds / 60); return minutes >= 60 ? $"{minutes / 60}h {minutes % 60}m" : $"{minutes}m"; }
    private static TextBlock Text(double size, FontWeight weight, string value, Brush? color = null) => new() { Text = value, FontSize = size, FontWeight = weight, Foreground = color ?? GTheme.Brush(GTheme.Text), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private static TextBlock Section(string value, bool margin = true) => new() { Text = value, FontSize = 9.5, FontWeight = FontWeights.Bold, Foreground = Muted(), Margin = margin ? new Thickness(0, 8, 0, 0) : new Thickness(0) };
    private static Button Button(string title) => new() { Content = title, Height = 26, Padding = new Thickness(7, 2, 7, 2), Margin = new Thickness(0), FontSize = 10 };
    private static Brush Muted() => GTheme.Brush(GTheme.Secondary);
}
