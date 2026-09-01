using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// Per-printer advanced overrides: a camera on a separate IP, custom light commands, and (Klipper)
/// Moonraker object-name overrides. Mirrors the macOS PrinterAdvancedWindowController.
public sealed class AdvancedWindow : Window
{
    private readonly PrinterStore _store;
    private readonly string _serial;
    private readonly bool _pl;
    private readonly bool _klipper;
    private readonly TextBox _camera = Field();
    private readonly TextBox _ledOn = Field();
    private readonly TextBox _ledOff = Field();
    private readonly TextBox _nozzle = Field();
    private readonly TextBox _bed = Field();
    private readonly TextBox _chamber = Field();
    private readonly TextBox _fan = Field();

    public AdvancedWindow(PrinterStore store, string serial)
    {
        _store = store;
        _serial = serial;
        _pl = AppSettings.Polish;
        var printer = store.Printers.FirstOrDefault(p => p.Serial == serial);
        _klipper = printer?.Kind == PrinterKind.Klipper;

        Title = (_pl ? "Zaawansowane — " : "Advanced — ") + (printer?.Name ?? serial);
        Width = 480; Height = _klipper ? 540 : 320; MinWidth = 400;
        Background = GTheme.Brush(GTheme.Canvas);
        Foreground = GTheme.Brush(GTheme.Text);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var stack = new StackPanel { Margin = new Thickness(18) };
        stack.Children.Add(Label(_pl ? "IP kamery (opcjonalnie)" : "Camera IP (optional)", true));
        stack.Children.Add(Hint(_pl ? "Gdy kamera jest pod innym adresem niż drukarka (np. Raspberry Pi z kamerą)." : "When the camera is on a different address than the printer (e.g. a Pi cam)."));
        _camera.Text = "";
        stack.Children.Add(_camera);

        stack.Children.Add(Label(_pl ? "Własne komendy światła (opcjonalnie)" : "Custom light commands (optional)", true, 14));
        stack.Children.Add(Hint(_klipper
            ? (_pl ? "Klipper: linia G-code, np. „SET_PIN PIN=caselight VALUE=1”." : "Klipper: a G-code line, e.g. “SET_PIN PIN=caselight VALUE=1”.")
            : (_pl ? "Bambu: surowy JSON MQTT (jak w automatyzacjach)." : "Bambu: raw MQTT JSON (as in automations).")));
        stack.Children.Add(LabeledRow(_pl ? "Wł.:" : "On:", _ledOn));
        stack.Children.Add(LabeledRow(_pl ? "Wył.:" : "Off:", _ledOff));

        if (_klipper)
        {
            stack.Children.Add(Label(_pl ? "Nazwy obiektów Klipper (opcjonalnie)" : "Klipper object names (optional)", true, 14));
            stack.Children.Add(Hint(_pl ? "Dla niestandardowych konfiguracji. Puste = domyślne (extruder / heater_bed / auto / fan)." : "For non-standard configs. Empty = defaults (extruder / heater_bed / auto / fan)."));
            stack.Children.Add(LabeledRow(_pl ? "Dysza:" : "Nozzle:", _nozzle));
            stack.Children.Add(LabeledRow(_pl ? "Stół:" : "Bed:", _bed));
            stack.Children.Add(LabeledRow(_pl ? "Komora:" : "Chamber:", _chamber));
            stack.Children.Add(LabeledRow(_pl ? "Wentylator:" : "Fan:", _fan));
        }

        var save = new Button { Content = _pl ? "Zapisz" : "Save", Padding = new Thickness(14, 6, 14, 6) };
        save.Click += (_, _) => Save();
        var close = new Button { Content = _pl ? "Zamknij" : "Close", Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 0, 8, 0) };
        close.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0), Children = { close, save } };
        stack.Children.Add(buttons);

        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = stack };
        GTheme.ApplyWindowTheme(this);
        Load();
    }

    private void Load()
    {
        var ov = PrinterOverridesStore.For(_serial);
        _camera.Text = ov.CameraHost ?? "";
        _ledOn.Text = ov.LedOn ?? "";
        _ledOff.Text = ov.LedOff ?? "";
        _nozzle.Text = ov.NozzleObject ?? "";
        _bed.Text = ov.BedObject ?? "";
        _chamber.Text = ov.ChamberObject ?? "";
        _fan.Text = ov.FanObject ?? "";
    }

    private void Save()
    {
        static string? Trim(TextBox b) => string.IsNullOrWhiteSpace(b.Text) ? null : b.Text.Trim();
        PrinterOverridesStore.Set(_serial, new PrinterOverrides
        {
            CameraHost = Trim(_camera),
            LedOn = Trim(_ledOn),
            LedOff = Trim(_ledOff),
            NozzleObject = Trim(_nozzle),
            BedObject = Trim(_bed),
            ChamberObject = Trim(_chamber),
            FanObject = Trim(_fan)
        });
        if (_klipper && _store.Printers.FirstOrDefault(p => p.Serial == _serial) is { } printer) _store.Reconnect(printer);
        Close();
    }

    private static TextBox Field() => new() { VerticalAlignment = VerticalAlignment.Center, MinWidth = 200 };

    private UIElement LabeledRow(string text, TextBox field)
    {
        field.HorizontalAlignment = HorizontalAlignment.Stretch;
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var lbl = new TextBlock { Text = text, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(lbl);
        Grid.SetColumn(field, 1); grid.Children.Add(field);
        return grid;
    }

    private static TextBlock Label(string text, bool bold, double topMargin = 0) => new()
    {
        Text = text, FontSize = 12, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = GTheme.Brush(GTheme.Text), Margin = new Thickness(0, topMargin, 0, 2)
    };

    private static TextBlock Hint(string text) => new()
    {
        Text = text, FontSize = 10, Foreground = Muted(), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 4)
    };

    private static Brush Muted() => GTheme.Brush(GTheme.Muted);
}
