using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>
/// A small, non-activating, always-on-top flyout that pops up above the tray on hover and lists the
/// pinned printers as pills (status dot + name + %) — the Windows stand-in for the macOS menu-bar
/// pills, since a tray icon itself can't show a text label.
/// </summary>
internal sealed class TrayFlyout : Window
{
    private readonly StackPanel _list = new();

    public TrayFlyout()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;                 // never steal focus from the app the user is in
        Topmost = true;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = -10000; Top = -10000;           // parked off-screen until SizeChanged docks it

        var header = new TextBlock
        {
            Text = "Gantry",
            Foreground = new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF5)),
            FontSize = 12, FontWeight = FontWeights.Medium, Margin = new Thickness(2, 0, 2, 8)
        };
        var body = new StackPanel { Width = 200 };
        body.Children.Add(header);
        body.Children.Add(_list);
        Content = new Border
        {
            CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Color.FromRgb(0x1F, 0x1F, 0x22)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x20, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10, 10, 10, 6),
            Child = body
        };

        // Keep docked at the bottom-right, just above the taskbar tray, whenever the size changes.
        SizeChanged += (_, _) => Dock();
    }

    public void SetItems(IReadOnlyList<(string Name, PrinterState State, int? Percent)> items)
    {
        _list.Children.Clear();
        foreach (var item in items)
            _list.Children.Add(BuildRow(item.Name, item.State, item.Percent));
    }

    private void Dock()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 8;
        Top = area.Bottom - ActualHeight - 8;
    }

    private static UIElement BuildRow(string name, PrinterState state, int? percent)
    {
        var (color, label) = StatusInfo(state, percent);
        var brush = new SolidColorBrush(color);

        var dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = brush, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        var nameText = new TextBlock { Text = name, Foreground = new SolidColorBrush(Color.FromRgb(0xE9, 0xE9, 0xEE)), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var valueText = new TextBlock { Text = label, Foreground = brush, FontSize = 12, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(dot, 0); Grid.SetColumn(nameText, 1); Grid.SetColumn(valueText, 2);
        grid.Children.Add(dot); grid.Children.Add(nameText); grid.Children.Add(valueText);

        return new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb(0x10, 0xFF, 0xFF, 0xFF)),
            Padding = new Thickness(9, 6, 9, 6),
            Margin = new Thickness(0, 0, 0, 5),
            Child = grid
        };
    }

    private static (Color, string) StatusInfo(PrinterState state, int? percent) => state switch
    {
        PrinterState.Printing => (Color.FromRgb(0x4A, 0xA8, 0xFF), percent is int p ? $"{p}%" : "…"),
        PrinterState.Paused => (Color.FromRgb(0xFF, 0x9F, 0x0A), percent is int p ? $"{p}%" : AppSettings.Text("pauza", "paused")),
        PrinterState.Finished => (Color.FromRgb(0x4A, 0xE3, 0x7A), "100%"),
        PrinterState.Idle => (Color.FromRgb(0x4A, 0xE3, 0x7A), AppSettings.Text("gotowa", "ready")),
        PrinterState.Error => (Color.FromRgb(0xFF, 0x6A, 0x5F), AppSettings.Text("błąd", "error")),
        _ => (Color.FromRgb(0x9A, 0x9A, 0xA0), "offline"),
    };
}
