using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using Gantry.Services;
using Microsoft.Win32;

namespace Gantry.UI;

/// Fleet statistics: totals, what the prints cost, production over time and the latest prints, with
/// export to a text summary or a CSV of every print. Mirrors the macOS panel.
public sealed class FleetStatsWindow : Window
{
    private readonly PrinterStore _store;
    private readonly bool _pl = AppSettings.Polish;
    private readonly StackPanel _body = new();
    private readonly ComboBox _period = new();
    private int _periodDays = 30;
    private string _renderedText = "";
    private string _renderedCsv = "";

    private static readonly int[] Periods = { 7, 30, 365, 0 };   // 0 = all time

    /// One finished (or failed) print with what it cost.
    private sealed record PrintLine(string Printer, string Serial, PrinterInsights.HistoryEntry Entry,
                                    List<PrintCost.Use> Uses, PrintCost Cost)
    {
        public bool Ok => Entry.Result == PrinterInsights.PrintResult.Completed;
    }

    private sealed record Row(string Name, int Prints, int Failed, double Hours, double Grams, double Cost, double? Utilization)
    {
        public int? SuccessPercent => Prints == 0 ? null : (int)Math.Round((Prints - Failed) * 100.0 / Prints);
    }

    public FleetStatsWindow(PrinterStore store)
    {
        _store = store;
        Title = AppSettings.T("Fleet statistics");
        Width = 560; Height = 640; MinWidth = 460; MinHeight = 440;
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

        Button MakeButton(string text, Action onClick)
        {
            var button = new Button { Content = text, Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(6, 0, 0, 0) };
            button.Click += (_, _) => onClick();
            return button;
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(MakeButton(AppSettings.T("Prices…"), EditPrices));
        buttons.Children.Add(MakeButton(AppSettings.T("CSV…"), ExportCsv));
        buttons.Children.Add(MakeButton(AppSettings.T("Export to file…"), Export));

        var controls = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(buttons, 1);
        controls.Children.Add(_period);
        controls.Children.Add(buttons);

        var root = new DockPanel { Margin = new Thickness(18) };
        DockPanel.SetDock(controls, Dock.Top);
        root.Children.Add(controls);
        root.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _body,
        });
        PanelWindow.Wrap(this, AppSettings.T("Fleet statistics"), root);
        Render();
    }

    private string PeriodLabel(int days) => days switch
    {
        7 => AppSettings.T("last 7 days"),
        30 => AppSettings.T("last 30 days"),
        365 => AppSettings.T("last year"),
        _ => AppSettings.T("all time"),
    };

    private DateTime? Cutoff(int days) => days == 0 ? null : DateTime.Now.AddDays(-days);

    private List<PrintLine> Lines(int days)
    {
        var settings = PrintCostSettings.Current;
        var cutoff = Cutoff(days);
        var lines = new List<PrintLine>();
        foreach (var printer in _store.Printers)
        {
            foreach (var entry in PrinterInsights.GetSnapshot(printer.Serial, _pl).History)
            {
                if (cutoff is { } from && entry.EndedAt < from) continue;
                var uses = PrintCost.Uses(printer.Serial, entry.StartedAt, entry.EndedAt);
                lines.Add(new PrintLine(printer.Name, printer.Serial, entry, uses,
                    PrintCost.Compute(entry.DurationSeconds, uses, printer.Serial, settings)));
            }
        }
        return lines.OrderByDescending(line => line.Entry.EndedAt).ToList();
    }

    private List<Row> Rows(List<PrintLine> all)
    {
        var now = DateTime.Now;
        return _store.Printers.Select(printer =>
        {
            var mine = all.Where(line => line.Serial == printer.Serial).ToList();
            double hours = mine.Sum(line => line.Entry.DurationSeconds) / 3600;
            // Share of the period spent printing; "all time" starts at the printer's first recorded print.
            DateTime? start = _periodDays == 0 ? (mine.Count == 0 ? null : mine.Min(line => line.Entry.StartedAt)) : Cutoff(_periodDays);
            double span = start is { } from ? (now - from).TotalHours : 0;
            return new Row(printer.Name, mine.Count, mine.Count(line => !line.Ok), hours,
                           mine.Sum(line => line.Cost.Grams ?? 0), mine.Sum(line => line.Cost.Total),
                           span > 1 ? Math.Min(1, hours / span) : null);
        }).ToList();
    }

    private static string Money(double value) =>
        $"{value.ToString("0.00", CultureInfo.InvariantCulture)} {PrintCostSettings.Current.Currency}";

    private static string Num(double value, string format) => value.ToString(format, CultureInfo.InvariantCulture);

    /// Prints per week for the last eight weeks, oldest first, as a one-line bar chart.
    private static (string Bars, int[] Counts) WeeklyTrend(List<PrintLine> all)
    {
        var counts = new int[8];
        var now = DateTime.Now;
        foreach (var line in all)
        {
            int age = (int)((now - line.Entry.EndedAt).TotalDays / 7);
            if (age >= 0 && age < 8) counts[7 - age]++;
        }
        const string ticks = "▁▂▃▄▅▆▇█";
        int top = Math.Max(1, counts.Max());
        var bars = new string(counts.Select(count => count == 0 ? '·' : ticks[Math.Min(7, (count * 8 - 1) / top)]).ToArray());
        return (bars, counts);
    }

    private void Render()
    {
        _body.Children.Clear();
        var all = Lines(_periodDays);
        var rows = Rows(all);
        int prints = all.Count;
        int failed = all.Count(line => !line.Ok);
        double hours = all.Sum(line => line.Entry.DurationSeconds) / 3600;
        double grams = all.Sum(line => line.Cost.Grams ?? 0);
        int? success = prints == 0 ? null : (int)Math.Round((prints - failed) * 100.0 / prints);
        double cost = all.Sum(line => line.Cost.Total);
        var completed = all.Where(line => line.Ok).ToList();

        var summary = new List<string>
        {
            $"{AppSettings.T("Period")}: {PeriodLabel(_periodDays)}",
            $"{AppSettings.T("Prints")}: {prints} ({AppSettings.T("failed")}: {failed})",
            $"{AppSettings.T("Success rate")}: {(success is { } value ? $"{value}%" : "—")}",
            $"{AppSettings.T("Print time")}: {Num(hours, "0.0")} h",
        };
        if (grams > 0) summary.Add($"Filament: {Num(grams / 1000, "0.00")} kg");
        var used = rows.Where(row => row.Utilization is not null).Select(row => row.Utilization!.Value).ToList();
        if (used.Count > 0)
            summary.Add(AppSettings.T("Printer utilization: {0}%").Replace("{0}", ((int)Math.Round(used.Average() * 100)).ToString(CultureInfo.InvariantCulture)));
        _body.Children.Add(Caption(AppSettings.T("SUMMARY")));
        _body.Children.Add(Card(summary, titleFirst: false));

        var costs = new List<string>
        {
            AppSettings.T("Total: {0}").Replace("{0}", Money(cost)),
            AppSettings.T("Filament {0} · electricity {1} · machine time {2}")
                .Replace("{0}", Money(all.Sum(line => line.Cost.Filament ?? 0)))
                .Replace("{1}", Money(all.Sum(line => line.Cost.Energy)))
                .Replace("{2}", Money(all.Sum(line => line.Cost.Machine))),
        };
        if (completed.Count > 0)
            costs.Add(AppSettings.T("Average successful print: {0}").Replace("{0}", Money(completed.Average(line => line.Cost.Total))));
        double wasted = all.Where(line => !line.Ok).Sum(line => line.Cost.Total);
        if (wasted > 0) costs.Add(AppSettings.T("Lost on failed prints: {0}").Replace("{0}", Money(wasted)));
        int unknown = all.Count(line => line.Cost.Filament is null);
        if (unknown > 0)
            costs.Add(AppSettings.T("{0} prints without filament data — assign rolls in Spoolbase to count it.").Replace("{0}", unknown.ToString(CultureInfo.InvariantCulture)));
        _body.Children.Add(Caption(AppSettings.T("COSTS")));
        _body.Children.Add(Card(costs, titleFirst: false));

        var trend = WeeklyTrend(_periodDays is > 0 and <= 30 ? Lines(56) : all);
        var production = new List<string>
        {
            AppSettings.T("Prints per week (8 weeks): {0}  {1}").Replace("{0}", trend.Bars).Replace("{1}", string.Join(" ", trend.Counts)),
        };
        var materials = all.SelectMany(line => line.Uses)
            .GroupBy(use => (use.Material ?? "?").ToUpperInvariant())
            .Select(group => (Material: group.Key, Grams: group.Sum(use => use.Grams)))
            .OrderByDescending(item => item.Grams).ToList();
        if (materials.Count > 0)
            production.Add(AppSettings.T("By material: {0}").Replace("{0}",
                string.Join(" · ", materials.Select(item => $"{item.Material} {Num(item.Grams / 1000, "0.00")} kg"))));
        var jobs = completed.Where(line => !string.IsNullOrEmpty(line.Entry.Job))
            .GroupBy(line => line.Entry.Job).Select(group => (Job: group.Key, Count: group.Count()))
            .OrderByDescending(item => item.Count).ThenBy(item => item.Job, StringComparer.Ordinal).Take(5).ToList();
        if (jobs.Count > 0)
            production.Add(AppSettings.T("Most printed: {0}").Replace("{0}", string.Join(" · ", jobs.Select(item => $"{item.Job} ×{item.Count}"))));
        int cancelled = all.Count(line => line.Entry.Result == PrinterInsights.PrintResult.Cancelled);
        if (failed > 0)
            production.Add(AppSettings.T("Unsuccessful: {0} errors · {1} cancelled")
                .Replace("{0}", (failed - cancelled).ToString(CultureInfo.InvariantCulture))
                .Replace("{1}", cancelled.ToString(CultureInfo.InvariantCulture)));
        _body.Children.Add(Caption(AppSettings.T("PRODUCTION")));
        _body.Children.Add(Card(production, titleFirst: false));

        _body.Children.Add(Caption(AppSettings.T("BY PRINTER")));
        if (rows.Count == 0)
            _body.Children.Add(Card(new List<string> { AppSettings.T("No printers.") }, false));
        foreach (var row in rows.OrderByDescending(item => item.Prints))
        {
            string mark = row.SuccessPercent is { } percent ? $"{percent}%" : "—";
            string detail = $"{row.Prints} {AppSettings.T("prints")} · {Num(row.Hours, "0.0")} h · {mark} · {Money(row.Cost)}";
            if (row.Utilization is { } utilization)
                detail += " · " + AppSettings.T("utilization {0}%").Replace("{0}", ((int)Math.Round(utilization * 100)).ToString(CultureInfo.InvariantCulture));
            _body.Children.Add(Card(new List<string> { row.Name, detail }, titleFirst: true));
        }

        if (all.Count > 0)
        {
            _body.Children.Add(Caption(AppSettings.T("RECENT PRINTS")));
            var recent = all.Take(15).Select(line =>
                $"{(line.Ok ? "✓" : "✕")} {line.Entry.EndedAt:dd.MM HH:mm} · {line.Printer} · " +
                $"{(string.IsNullOrEmpty(line.Entry.Job) ? "—" : line.Entry.Job)} · {Num(line.Entry.DurationSeconds / 3600, "0.0")} h" +
                (line.Cost.Grams is { } g ? $" · {Num(g, "0")} g" : "") + $" · {Money(line.Cost.Total)}").ToList();
            _body.Children.Add(Card(recent, titleFirst: false));
        }

        _renderedText = PlainText(rows, prints, failed, hours, grams, success, cost);
        _renderedCsv = Csv(all);
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

    private string PlainText(List<Row> rows, int prints, int failed, double hours, double grams, int? success, double cost)
    {
        string successText = success is { } value ? $"{value}%" : "—";
        var out_ = new StringBuilder();
        out_.AppendLine($"Gantry {AppSettings.T("fleet statistics")}");
        out_.AppendLine($"{AppSettings.T("Generated")}: {DateTime.Now:yyyy-MM-dd HH:mm}");
        out_.AppendLine($"{AppSettings.T("Period")}: {PeriodLabel(_periodDays)}");
        out_.AppendLine();
        out_.AppendLine($"{AppSettings.T("Prints")}: {prints}  ({AppSettings.T("failed")}: {failed})");
        out_.AppendLine($"{AppSettings.T("Success rate")}: {successText}");
        out_.AppendLine($"{AppSettings.T("Print time")}: {Num(hours, "0.0")} h");
        if (grams > 0) out_.AppendLine($"Filament: {Num(grams / 1000, "0.00")} kg");
        out_.AppendLine($"{AppSettings.T("Cost")}: {Money(cost)}");
        out_.AppendLine();
        out_.AppendLine(AppSettings.T("By printer:"));
        foreach (var row in rows.OrderByDescending(item => item.Prints))
        {
            string mark = row.SuccessPercent is { } percent ? $"{percent}%" : "—";
            out_.AppendLine($"  {row.Name}: {row.Prints} {AppSettings.T("prints")}, {Num(row.Hours, "0.0")} h, {mark}, {Money(row.Cost)}");
        }
        return out_.ToString();
    }

    /// One row per print. Semicolons and a decimal comma in Polish, so Excel opens it into columns.
    private string Csv(List<PrintLine> all)
    {
        string sep = _pl ? ";" : ",";
        string N(double? value)
        {
            if (value is not { } v) return "";
            string text = v.ToString("0.00", CultureInfo.InvariantCulture);
            return _pl ? text.Replace('.', ',') : text;
        }
        string Field(string text) =>
            text.Contains(sep) || text.Contains('"') || text.Contains('\n') ? "\"" + text.Replace("\"", "\"\"") + "\"" : text;
        string currency = PrintCostSettings.Current.Currency;
        var out_ = new StringBuilder();
        out_.Append(string.Join(sep, "start", "end", "printer", "job", "result", "hours", "grams", "kWh",
            $"filament_{currency}", $"energy_{currency}", $"machine_{currency}", $"total_{currency}")).Append('\n');
        foreach (var line in Enumerable.Reverse(all))
        {
            out_.Append(string.Join(sep,
                line.Entry.StartedAt.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
                line.Entry.EndedAt.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
                Field(line.Printer), Field(line.Entry.Job), line.Entry.Result.ToString().ToLowerInvariant(),
                N(line.Entry.DurationSeconds / 3600), N(line.Cost.Grams), N(line.Cost.KWh),
                N(line.Cost.Filament), N(line.Cost.Energy), N(line.Cost.Machine), N(line.Cost.Total))).Append('\n');
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
        if (dialog.ShowDialog(Owner ?? this) != true) return;
        try { File.WriteAllText(dialog.FileName, _renderedText, Encoding.UTF8); }
        catch (Exception ex) { Gantry.App.LogError("FleetStatsExport", ex); }
    }

    private void ExportCsv()
    {
        var dialog = new SaveFileDialog { FileName = "gantry-wydruki.csv", Filter = "CSV|*.csv" };
        if (dialog.ShowDialog(Owner ?? this) != true) return;
        // UTF-8 with BOM so Excel reads Polish letters in job names.
        try { File.WriteAllText(dialog.FileName, _renderedCsv, new UTF8Encoding(true)); }
        catch (Exception ex) { Gantry.App.LogError("FleetStatsCsv", ex); }
    }

    private void EditPrices()
    {
        var settings = PrintCostSettings.Current;
        string F(double value) => value.ToString("0.##", CultureInfo.InvariantCulture);
        var currency = new TextBox { Text = settings.Currency };
        var perKg = new TextBox { Text = F(settings.FilamentPerKg) };
        var materials = new TextBox
        {
            Text = string.Join(", ", settings.MaterialPerKg.OrderBy(pair => pair.Key).Select(pair => $"{pair.Key}={F(pair.Value)}")),
            ToolTip = "PETG=90, ASA=120",
        };
        var kWh = new TextBox { Text = F(settings.ElectricityPerKWh) };
        var watts = new TextBox { Text = F(settings.PrinterWatts) };
        var machine = new TextBox { Text = F(settings.MachinePerHour) };

        var grid = new Grid { Margin = new Thickness(18) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        var fields = new (string Label, TextBox Box)[]
        {
            (AppSettings.T("Currency"), currency), (AppSettings.T("Filament per kg"), perKg),
            (AppSettings.T("Per material (per kg)"), materials), (AppSettings.T("Electricity per kWh"), kWh),
            (AppSettings.T("Average printer power (W)"), watts), (AppSettings.T("Machine time per hour"), machine),
        };
        for (int index = 0; index < fields.Length; index++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = fields[index].Label, Foreground = GTheme.Brush(GTheme.Secondary),
                                        Margin = new Thickness(0, 6, 12, 6), VerticalAlignment = VerticalAlignment.Center };
            fields[index].Box.Margin = new Thickness(0, 4, 0, 4);
            Grid.SetRow(label, index); Grid.SetRow(fields[index].Box, index); Grid.SetColumn(fields[index].Box, 1);
            grid.Children.Add(label); grid.Children.Add(fields[index].Box);
        }
        var note = new TextBlock
        {
            Text = AppSettings.T("Used to price every print: filament from Spoolbase usage, electricity and machine time from its duration."),
            TextWrapping = TextWrapping.Wrap, Foreground = GTheme.Brush(GTheme.Muted), FontSize = 11, Margin = new Thickness(0, 10, 0, 10),
        };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(note, fields.Length); Grid.SetColumnSpan(note, 2); grid.Children.Add(note);

        var dialog = new Window
        {
            Title = AppSettings.T("Print cost prices"), SizeToContent = SizeToContent.WidthAndHeight,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this, Background = GTheme.Brush(GTheme.Canvas),
        };
        var save = new Button { Content = AppSettings.T("Save"), IsDefault = true, Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(6, 0, 0, 0) };
        var cancel = new Button { Content = AppSettings.T("Cancel"), IsCancel = true, Padding = new Thickness(14, 4, 14, 4) };
        save.Click += (_, _) => dialog.DialogResult = true;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(cancel); buttons.Children.Add(save);
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(buttons, fields.Length + 1); Grid.SetColumnSpan(buttons, 2); grid.Children.Add(buttons);
        dialog.Content = grid;
        GTheme.ApplyWindowTheme(dialog);
        if (dialog.ShowDialog() != true) return;

        if (!string.IsNullOrWhiteSpace(currency.Text)) settings.Currency = currency.Text.Trim()[..Math.Min(8, currency.Text.Trim().Length)];
        if (PrintCostSettings.ParseAmount(perKg.Text) is { } a) settings.FilamentPerKg = a;
        if (PrintCostSettings.ParseAmount(kWh.Text) is { } b) settings.ElectricityPerKWh = b;
        if (PrintCostSettings.ParseAmount(watts.Text) is { } c) settings.PrinterWatts = c;
        if (PrintCostSettings.ParseAmount(machine.Text) is { } d) settings.MachinePerHour = d;
        settings.MaterialPerKg = PrintCostSettings.ParseMaterialPrices(materials.Text);
        PrintCostSettings.Current = settings;
        Render();
    }
}
