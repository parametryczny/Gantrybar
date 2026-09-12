using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

internal sealed class SkipObjectsPanel : Grid
{
    private readonly PrinterStore _store;
    private readonly string _serial;
    private readonly Action _close;
    private readonly Canvas _bed = new() { Height = 330, Background = new SolidColorBrush(Color.FromRgb(0x18, 0x19, 0x1B)) };
    private readonly StackPanel _list = new();
    private readonly TextBlock _status = new() { Foreground = GTheme.Brush(GTheme.Secondary), FontSize = 11 };
    private readonly Button _action = new() { IsEnabled = false, MinWidth = 140 };
    private readonly HashSet<string> _selected = new();
    private PrintObjectLayout? _layout;
    private bool _confirming;

    public SkipObjectsPanel(PrinterStore store, string serial, Action close)
    {
        _store = store; _serial = serial; _close = close;
        var root = new StackPanel { Margin = new Thickness(16) };
        var header = new DockPanel();
        var back = new Button { Content = "‹  " + AppSettings.T("Back"), Margin = new Thickness(0, 0, 12, 0) };
        back.Click += (_, _) => close(); header.Children.Add(back);
        header.Children.Add(new TextBlock { Text = AppSettings.T("Skip object"), FontSize = 20, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center });
        root.Children.Add(header);
        root.Children.Add(new TextBlock { Text = AppSettings.T("Select the failed object on the bed. Gantry will leave the remaining objects printing."), TextWrapping = TextWrapping.Wrap, Foreground = GTheme.Brush(GTheme.Secondary), Margin = new Thickness(0, 10, 0, 10) });
        root.Children.Add(new Border { CornerRadius = new CornerRadius(12), ClipToBounds = true, Child = _bed });
        root.Children.Add(new ScrollViewer { Content = _list, Height = 160, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 10, 0, 8) });
        var bottom = new DockPanel(); bottom.Children.Add(_status); DockPanel.SetDock(_action, Dock.Right); bottom.Children.Add(_action);
        root.Children.Add(bottom); Children.Add(root);
        _status.Text = AppSettings.T("Loading objects…");
        _action.Content = AppSettings.T("Select an object");
        _action.Click += (_, _) => ConfirmOrSkip();
        Loaded += async (_, _) => await LoadAsync();
        _bed.SizeChanged += (_, _) => DrawBed();
    }

    private async Task LoadAsync()
    {
        var load = _store.LoadPrintObjectLayoutAsync(_serial);
        var timeout = Task.Delay(TimeSpan.FromSeconds(65));
        if (await Task.WhenAny(load, timeout) == timeout) { _status.Text = AppSettings.T("The printer did not respond in time."); return; }
        var result = await load;
        if (result.Layout is null || result.Layout.Objects.Count < 2) { _status.Text = result.Error ?? AppSettings.T("This print does not expose multiple objects."); return; }
        _layout = result.Layout; _status.Text = AppSettings.T("Choose one or more objects");
        BuildList(); DrawBed();
    }

    private void BuildList()
    {
        _list.Children.Clear(); if (_layout is null) return;
        foreach (var item in _layout.Objects)
        {
            var check = new CheckBox { Content = item.Name + (_layout.CurrentObjectId == item.Id ? "  ·  " + AppSettings.T("printing now") : ""), Tag = item.Id, Margin = new Thickness(2), IsChecked = _selected.Contains(item.Id), IsEnabled = !_layout.SkippedObjectIds.Contains(item.Id) };
            if (_layout.SkippedObjectIds.Contains(item.Id)) check.Content += "  ·  " + AppSettings.T("skipped");
            check.Click += (_, _) => Toggle((string)check.Tag); _list.Children.Add(check);
        }
    }

    private void DrawBed()
    {
        _bed.Children.Clear(); if (_layout is null) return;
        if (_layout.PreviewPng is { Length: > 0 }) try
        {
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad; bitmap.StreamSource = new MemoryStream(_layout.PreviewPng); bitmap.EndInit();
            _bed.Children.Add(new Image { Source = bitmap, Width = _bed.ActualWidth, Height = _bed.ActualHeight, Stretch = Stretch.Uniform, Opacity = .72 });
        } catch { }
        double minX = _layout.BedBounds[0], minY = _layout.BedBounds[1], dx = Math.Max(.001, _layout.BedBounds[2] - minX), dy = Math.Max(.001, _layout.BedBounds[3] - minY);
        foreach (var item in _layout.Objects.Where(o => o.Polygon.Count >= 3))
        {
            var polygon = new Polygon { Tag = item.Id, Cursor = System.Windows.Input.Cursors.Hand, StrokeThickness = _selected.Contains(item.Id) ? 3 : 1.5 };
            foreach (var point in item.Polygon) polygon.Points.Add(new Point(12 + (point.X-minX)/dx*Math.Max(1,_bed.ActualWidth-24), 12 + (1-(point.Y-minY)/dy)*Math.Max(1,_bed.ActualHeight-24)));
            var color = _selected.Contains(item.Id) ? Colors.Red : _layout.SkippedObjectIds.Contains(item.Id) ? Colors.Gray : _layout.CurrentObjectId == item.Id ? Colors.LimeGreen : Colors.DarkOrange;
            polygon.Stroke = new SolidColorBrush(color); polygon.Fill = new SolidColorBrush(Color.FromArgb(_selected.Contains(item.Id) ? (byte)82 : (byte)42, color.R, color.G, color.B));
            polygon.MouseLeftButtonUp += (_, _) => Toggle(item.Id); _bed.Children.Add(polygon);
        }
    }

    private void Toggle(string id) { if (_layout?.SkippedObjectIds.Contains(id) == true) return; if (!_selected.Add(id)) _selected.Remove(id); _confirming = false; BuildList(); DrawBed(); UpdateAction(); }
    private void UpdateAction() { _action.IsEnabled = _selected.Count > 0; _action.Content = _selected.Count == 0 ? AppSettings.T("Select an object") : _confirming ? string.Format(AppSettings.T("Confirm skipping ({0})"), _selected.Count) : string.Format(AppSettings.T("Skip selected ({0})"), _selected.Count); }
    private void ConfirmOrSkip() { if (_selected.Count == 0) return; if (!_confirming) { _confirming = true; _status.Text = AppSettings.T("This cannot be undone during the current print."); UpdateAction(); return; } _store.SkipPrintObjects(_serial, _selected); _close(); }
}
