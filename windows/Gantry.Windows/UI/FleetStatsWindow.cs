using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using Gantry.Services;
using Microsoft.Win32;

namespace Gantry.UI;

/// Fleet statistics: one summary across every printer, with export to a text file.
///
/// PrinterInsights already collected history, print hours and filament use per printer, but nothing
/// added them up, so "how much did I print this month" had no answer. Mirrors the macOS panel,
/// including the caveat about lifetime counters in <see cref="Rows"/>.
public sealed class FleetStatsWindow : Window
{
    private readonly PrinterStore _store;
    private readonly bool _pl = AppSettings.Polish;
    private readonly StackPanel _body = new();
    private readonly ComboBox _period = new();
    private int _periodDays = 30;
    private string _renderedText = "";

    private static readonly int[] Periods = { 7, 30, 365, 0 };   // 0 = all time

    private sealed record Row(string Name, int Prints, int Failed, double Hours, double Grams)
    {
        public int? SuccessPercent => Prints == 0 ? null : (int)Math.Round((Prints - Failed) * 100.0 / Prints);
    }

    public FleetStatsWindow(PrinterStore store)
    {
        _store = store;
        Title = AppSettings.T("Fleet statistics");
        Width = 470; Height = 560; MinWidth = 420; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = GTheme.Brush(GTheme.Canvas);
        GTheme.ApplyWindowTheme(this);

        foreach (int days in Periods) _period.Items.Add(PeriodLabel(days));
        _period.SelectedIndex = 1;
        _period.SelectionChanged += (_, _) =>
        {
            _periodDays = Periods[Math.Max(0, _period.SelectedIndex)];
            Render();
        };

        var export = new Button
        {
            Content = AppSettings.T("Export to file…"),
            Padding = new Thickness(12, 5, 12, 5),
        };
        export.Click += (_, _) => Export();

        var controls = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(export, 1);
        controls.Children.Add(_period);
        controls.Children.Add(export);

        var root = new DockPanel { Margin = new Thickness(18) };
        DockPanel.SetDock(controls, Dock.Top);
        root.Children.Add(controls);
        root.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _body,
        });
        Content = root;
        Render();
    }

    private string PeriodLabel(int days) => days switch
    {
        7 => AppSettings.T("last 7 days"),
        30 => AppSettings.T("last 30 days"),
        365 => AppSettings.T("last year"),
        _ => AppSettings.T("all time"),
    };

    private List<Row> Rows()
    {
        DateTime? cutoff = _periodDays == 0 ? null : DateTime.Now.AddDays(-_periodDays);
        var rows = new List<Row>();
        foreach (var printer in _store.Printers)
        {
            var snapshot = PrinterInsights.GetSnapshot(printer.Serial, _pl);
            var history = snapshot.History.Where(entry => cutoff is null || entry.EndedAt >= cutoff).ToList();
            // Print hours and grams are lifetime counters, so a period view derives hours from the
            // entries themselves and only shows lifetime filament when no period is applied.
            double hours = _periodDays == 0
                ? snapshot.TotalPrintHours
                : history.Sum(entry => entry.DurationSeconds) / 3600;
            double grams = _periodDays == 0 ? snapshot.ConsumedGrams : 0;
            rows.Add(new Row(printer.Name, history.Count,
                             history.Count(entry => entry.Result != PrinterInsights.PrintResult.Completed), hours, grams));
        }
        return rows;
    }

    private void Render()
    {
        _body.Children.Clear();
        var rows = Rows();
        int prints = rows.Sum(row => row.Prints);
        int failed = rows.Sum(row => row.Failed);
        double hours = rows.Sum(row => row.Hours);
        double grams = rows.Sum(row => row.Grams);
        int? success = prints == 0 ? null : (int)Math.Round((prints - failed) * 100.0 / prints);
        string successText = success is { } value ? $"{value}%" : "—";

        var lines = new List<string>
        {
            $"{AppSettings.T("Period")}: {PeriodLabel(_periodDays)}",
            $"{AppSettings.T("Prints")}: {prints} ({AppSettings.T("failed")}: {failed})",
            $"{AppSettings.T("Success rate")}: {successText}",
            $"{AppSettings.T("Print time")}: {hours.ToString("0.0", CultureInfo.InvariantCulture)} h",
        };
        if (grams > 0)
            lines.Add($"Filament: {(grams / 1000).ToString("0.00", CultureInfo.InvariantCulture)} kg");

        _body.Children.Add(Caption(AppSettings.T("SUMMARY")));
        _body.Children.Add(Card(lines, titleFirst: false));
        _body.Children.Add(Caption(AppSettings.T("BY PRINTER")));
        if (rows.Count == 0)
            _body.Children.Add(Card(new List<string> { AppSettings.T("No printers.") }, false));
        foreach (var row in rows.OrderByDescending(item => item.Prints))
        {
            string mark = row.SuccessPercent is { } percent ? $"{percent}%" : "—";
            string detail = $"{row.Prints} {AppSettings.T("prints")} · " +
                            $"{row.Hours.ToString("0.0", CultureInfo.InvariantCulture)} h · {mark}";
            _body.Children.Add(Card(new List<string> { row.Name, detail }, titleFirst: true));
        }
        _renderedText = PlainText(rows, prints, failed, hours, grams, success);
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text, FontSize = 10, FontWeight = FontWeights.Bold,
        Foreground = GTheme.Brush(GTheme.Muted), Margin = new Thickness(2, 10, 0, 6),
    };

    private static Border Card(List<string> lines, bool titleFirst)
    {
        var stack = new StackPanel();
        for (int index = 0; index < lines.Count; index++)
        {
            bool title = titleFirst && index == 0;
            stack.Children.Add(new TextBlock
            {
                Text = lines[index],
                FontSize = title ? 13 : 12,
                FontWeight = title ? FontWeights.SemiBold : FontWeights.Normal,
                Foreground = GTheme.Brush(title ? GTheme.Text : GTheme.Secondary),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 2),
            });
        }
        return new Border
        {
            Background = GTheme.Brush(GTheme.CardTranslucent),
            BorderBrush = GTheme.Brush(GTheme.Line),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14, 11, 14, 11),
            Margin = new Thickness(0, 0, 0, 8),
            Child = stack,
        };
    }

    private string PlainText(List<Row> rows, int prints, int failed, double hours, double grams, int? success)
    {
        string successText = success is { } value ? $"{value}%" : "—";
        var out_ = new StringBuilder();
        out_.AppendLine($"Gantry {AppSettings.T("fleet statistics")}");
        out_.AppendLine($"{AppSettings.T("Generated")}: {DateTime.Now:yyyy-MM-dd HH:mm}");
        out_.AppendLine($"{AppSettings.T("Period")}: {PeriodLabel(_periodDays)}");
        out_.AppendLine();
        out_.AppendLine($"{AppSettings.T("Prints")}: {prints}  ({AppSettings.T("failed")}: {failed})");
        out_.AppendLine($"{AppSettings.T("Success rate")}: {successText}");
        out_.AppendLine($"{AppSettings.T("Print time")}: {hours.ToString("0.0", CultureInfo.InvariantCulture)} h");
        if (grams > 0)
            out_.AppendLine($"Filament: {(grams / 1000).ToString("0.00", CultureInfo.InvariantCulture)} kg");
        out_.AppendLine();
        out_.AppendLine(AppSettings.T("By printer:"));
        foreach (var row in rows.OrderByDescending(item => item.Prints))
        {
            string mark = row.SuccessPercent is { } percent ? $"{percent}%" : "—";
            out_.AppendLine($"  {row.Name}: {row.Prints} {AppSettings.T("prints")}, " +
                            $"{row.Hours.ToString("0.0", CultureInfo.InvariantCulture)} h, {mark}");
        }
        return out_.ToString();
    }

    private void Export()
    {
        var dialog = new SaveFileDialog
        {
            FileName = "gantry-statystyki.txt",
            Filter = AppSettings.T("Text file|*.txt"),
        };
        if (dialog.ShowDialog(this) != true) return;
        try { File.WriteAllText(dialog.FileName, _renderedText, Encoding.UTF8); }
        catch (Exception ex) { Gantry.App.LogError("FleetStatsExport", ex); }
    }
}
