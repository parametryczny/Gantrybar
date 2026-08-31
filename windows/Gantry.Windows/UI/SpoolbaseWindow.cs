using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>
/// Spoolbase filament-stock window — the Windows counterpart of the macOS Spoolbase popover.
/// Opens near the tray, lists the user's filaments grouped by type with a coloured stock badge,
/// and supports add-from-catalog, edit, delete and quick count changes.
/// </summary>
public sealed class SpoolbaseWindow : Window
{
    // The one shared inventory, so filaments added here also appear in the slot assign panel (which uses
    // SpoolbaseShared.Filaments). A separate instance made the two views diverge — added filaments never
    // showed up when assigning a roll to a slot.
    private readonly FilamentStore _store = SpoolbaseShared.Filaments;
    private readonly TextBox _search = new();
    private readonly StackPanel _list = new();
    private readonly TextBlock _summary = new();
    private string _query = "";
    private bool _modalOpen;

    private static readonly Brush Ink = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF7));
    private static Brush Muted() => new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0x9E));
    private static Brush Surface() => new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF));

    public SpoolbaseWindow()
    {
        Title = "Spoolbase";
        Width = 500;
        Height = 600;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = false;
        Background = Brushes.Transparent;
        Foreground = Ink;
        FontFamily = new FontFamily("Segoe UI Variable, Segoe UI");
        Deactivated += (_, _) => { if (!_modalOpen) Hide(); };

        Content = BuildChrome();
        _store.Changed += (_, _) => Dispatcher.Invoke(Render);
        SourceInitialized += (_, _) => ApplyModernChrome();
        Render();
    }

    private bool Pl => AppSettings.Polish;

    private Border BuildChrome()
    {
        var root = new Border
        {
            CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x24, 0x24, 0x26)),
            SnapsToDevicePixels = true
        };
        var dock = new DockPanel { Margin = new Thickness(2) };

        // Header
        var title = new TextBlock { Text = "Spoolbase", FontSize = 18, FontWeight = FontWeights.Bold };
        _summary.FontSize = 11;
        _summary.Foreground = Muted();
        _summary.Margin = new Thickness(0, 1, 0, 0);
        var titles = new StackPanel();
        titles.Children.Add(title);
        titles.Children.Add(_summary);

        var add = new Button { Content = "+", Width = 32, Height = 30, FontSize = 17, ToolTip = Pl ? "Dodaj filament" : "Add filament" };
        add.Click += (_, _) => OpenCatalog();
        StyleSoftButton(add);

        var header = new Grid { Margin = new Thickness(16, 14, 12, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(titles);
        Grid.SetColumn(add, 1);
        add.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(add);
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);

        // Search
        var searchBox = new Border
        {
            CornerRadius = new CornerRadius(9),
            Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)),
            Margin = new Thickness(16, 0, 16, 8),
            Padding = new Thickness(10, 6, 10, 6)
        };
        _search.BorderThickness = new Thickness(0);
        _search.Background = Brushes.Transparent;
        _search.Foreground = Ink;
        _search.CaretBrush = Ink;
        _search.FontSize = 12;
        _search.VerticalContentAlignment = VerticalAlignment.Center;
        var placeholder = new TextBlock
        {
            Text = Pl ? "Szukaj nazwy, koloru lub kodu…" : "Search name, colour or code…",
            Foreground = Muted(), IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center, FontSize = 12
        };
        _search.TextChanged += (_, _) =>
        {
            _query = _search.Text.Trim();
            placeholder.Visibility = _query.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            Render();
        };
        var searchGrid = new Grid();
        searchGrid.Children.Add(_search);
        searchGrid.Children.Add(placeholder);
        searchBox.Child = searchGrid;
        DockPanel.SetDock(searchBox, Dock.Top);
        dock.Children.Add(searchBox);

        // List
        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Margin = new Thickness(12, 0, 12, 10),
            Content = _list
        };
        dock.Children.Add(scroll);

        root.Child = dock;
        return root;
    }

    private void Render()
    {
        _list.Children.Clear();
        var items = Filtered();

        var spools = _store.Filaments.Sum(f => f.SpoolCount);
        var variants = _store.Filaments.Count;
        _summary.Text = $"{spools} {SpoolWord(spools)} · {variants} {VariantWord(variants)}";

        if (!items.Any())
        {
            _list.Children.Add(new TextBlock
            {
                Text = Pl ? "Brak filamentów dla wybranych filtrów" : "No filaments match the filters",
                Foreground = Muted(),
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 40, 0, 0)
            });
            return;
        }

        var grouped = items.GroupBy(f => f.Type).ToDictionary(g => g.Key, g => g.ToList());
        var ordered = FilamentCatalogMeta.Types.Where(grouped.ContainsKey)
            .Concat(grouped.Keys.Where(k => !FilamentCatalogMeta.Types.Contains(k)).OrderBy(k => k));

        bool first = true;
        foreach (var type in ordered)
        {
            _list.Children.Add(BuildSection(type, grouped[type], !first));
            first = false;
        }
    }

    private UIElement BuildSection(string type, List<Filament> items, bool separator)
    {
        var panel = new StackPanel { Margin = new Thickness(7, separator ? 13 : 8, 7, 9) };
        if (separator)
        {
            panel.Children.Add(new Border
            {
                Height = 1,
                Background = new SolidColorBrush(Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF)),
                Margin = new Thickness(0, 0, 0, 8)
            });
        }

        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock { Text = type, FontSize = 12.5, FontWeight = FontWeights.SemiBold });
        var count = new TextBlock
        {
            Text = $"{items.Count} {(items.Count == 1 ? (Pl ? "filament" : "filament") : (Pl ? "filamentów" : "filaments"))}",
            FontSize = 9.5, Foreground = Muted(), VerticalAlignment = VerticalAlignment.Bottom
        };
        Grid.SetColumn(count, 1);
        head.Children.Add(count);
        panel.Children.Add(head);

        var grid = new UniformGrid { Columns = 2, Margin = new Thickness(0, 6, 0, 0) };
        foreach (var item in items) grid.Children.Add(BuildTile(item));
        panel.Children.Add(grid);
        return panel;
    }

    private UIElement BuildTile(Filament item)
    {
        var swatch = new Border
        {
            Width = 30, Height = 30, CornerRadius = new CornerRadius(15),
            Background = new SolidColorBrush(Filament.ColorFromHex(item.ColorHex)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(0.5),
            VerticalAlignment = VerticalAlignment.Center
        };

        var colorName = new TextBlock { Text = item.ColorName, FontSize = 10.5, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        var product = new TextBlock { Text = $"{item.Brand} · {item.Name}", FontSize = 8, Foreground = Muted(), TextTrimming = TextTrimming.CharacterEllipsis };
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(colorName);
        labels.Children.Add(product);

        var badge = BuildBadge(item.SpoolCount);

        var row = new Grid { Margin = new Thickness(8, 6, 7, 6) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(swatch, 0);
        labels.Margin = new Thickness(8, 0, 8, 0);
        Grid.SetColumn(labels, 1);
        Grid.SetColumn(badge, 2);
        row.Children.Add(swatch);
        row.Children.Add(labels);
        row.Children.Add(badge);

        var tile = new Border
        {
            CornerRadius = new CornerRadius(11),
            Background = Brushes.Transparent,
            Margin = new Thickness(2),
            Cursor = Cursors.Hand,
            Child = row,
            ToolTip = Pl ? "Kliknij, aby zmienić liczbę szpul" : "Click to change spool count"
        };
        tile.MouseEnter += (_, _) => tile.Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF));
        tile.MouseLeave += (_, _) => tile.Background = Brushes.Transparent;
        tile.MouseLeftButtonUp += (_, _) => ShowQuickStock(item, tile, badge);
        tile.ContextMenu = BuildTileMenu(item);
        return tile;
    }

    private Border BuildBadge(int count)
    {
        var color = BadgeColor(count);
        var badge = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb((byte)(count == 0 ? 0x1A : 0x2B), color.R, color.G, color.B)),
            Width = 30, Height = 25, VerticalAlignment = VerticalAlignment.Center
        };
        badge.Child = new TextBlock
        {
            Text = count.ToString(),
            Foreground = new SolidColorBrush(color),
            FontSize = 10, FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        return badge;
    }

    private static Color BadgeColor(int count)
    {
        if (count == 0) return Color.FromRgb(0x9A, 0x9A, 0x9E);
        if (count <= StockLevels.RedMaximum) return Color.FromRgb(0xFF, 0x45, 0x3A);
        if (count <= StockLevels.BlueMaximum) return Color.FromRgb(0x0A, 0x84, 0xFF);
        return Color.FromRgb(0x30, 0xD1, 0x58);
    }

    private ContextMenu BuildTileMenu(Filament item)
    {
        var menu = new ContextMenu();
        var stock = new MenuItem { Header = Pl ? "Zmień liczbę szpul…" : "Change spool count…" };
        stock.Click += (_, _) => OpenEditor(item, countOnly: true);
        menu.Items.Add(stock);
        var edit = new MenuItem { Header = Pl ? "Edytuj…" : "Edit…" };
        edit.Click += (_, _) => OpenEditor(item, countOnly: false);
        menu.Items.Add(edit);
        menu.Items.Add(new Separator());
        var del = new MenuItem { Header = Pl ? "Usuń z moich filamentów" : "Remove from my filaments" };
        del.Click += (_, _) => ConfirmDelete(item);
        menu.Items.Add(del);
        return menu;
    }

    private void ShowQuickStock(Filament item, UIElement anchor, Border badge)
    {
        var popup = new Popup { PlacementTarget = anchor, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true };
        var value = new TextBlock { Text = item.SpoolCount.ToString(), FontSize = 17, FontWeight = FontWeights.SemiBold, Foreground = Ink, MinWidth = 34, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

        void Refresh()
        {
            var fresh = _store.Filaments.FirstOrDefault(f => f.Id == item.Id);
            value.Text = (fresh?.SpoolCount ?? 0).ToString();
        }

        var minus = new Button { Content = "−", Width = 34, Height = 34, FontSize = 16 };
        var plus = new Button { Content = "+", Width = 34, Height = 34, FontSize = 16 };
        StyleSoftButton(minus); StyleSoftButton(plus);
        minus.Click += (_, _) => { _store.Adjust(item.Id, -1); Refresh(); };
        plus.Click += (_, _) => { _store.Adjust(item.Id, +1); Refresh(); };

        var title = new TextBlock { Text = $"{item.ColorName} · {item.Brand}", FontSize = 10, Foreground = Muted(), TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 0, 8) };
        var stepper = new StackPanel { Orientation = Orientation.Horizontal };
        stepper.Children.Add(minus);
        stepper.Children.Add(value);
        stepper.Children.Add(plus);
        var stack = new StackPanel { Margin = new Thickness(11) };
        stack.Children.Add(title);
        stack.Children.Add(stepper);
        popup.Child = new Border
        {
            CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Color.FromArgb(0xF5, 0x2E, 0x2E, 0x30)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Child = stack
        };
        popup.IsOpen = true;
    }

    private List<Filament> Filtered()
    {
        var q = _query.ToLowerInvariant();
        return _store.Filaments.Where(item =>
        {
            if (q.Length == 0) return true;
            var text = string.Join(" ", item.Brand, item.Name, item.Type, item.ColorName, item.ColorHex, item.ManufacturerCode).ToLowerInvariant();
            return text.Contains(q);
        }).ToList();
    }

    private void OpenCatalog()
    {
        _modalOpen = true;
        try { new SpoolbaseCatalogWindow(_store) { Owner = this }.ShowDialog(); }
        finally { _modalOpen = false; Activate(); }
    }

    private void OpenEditor(Filament item, bool countOnly)
    {
        _modalOpen = true;
        try { new SpoolbaseEditWindow(_store, item, countOnly) { Owner = this }.ShowDialog(); }
        finally { _modalOpen = false; Activate(); }
    }

    private void ConfirmDelete(Filament item)
    {
        var result = MessageBox.Show(this,
            $"{item.Brand} • {item.Name} • {item.ColorName}\n" + (Pl ? "Produkt pozostanie w katalogu." : "The product stays in the catalog."),
            Pl ? "Usunąć z moich filamentów?" : "Remove from my filaments?",
            MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (result == MessageBoxResult.OK) _store.Delete(item.Id);
    }

    // ---- Show / positioning / DWM ---------------------------------------------------------

    public void TogglePopover()
    {
        if (IsVisible) { Hide(); return; }
        ShowPopover();
    }

    public void ShowPopover()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 8;
        Top = area.Bottom - Height - 8;
        Show();
        Activate();
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void ApplyModernChrome()
    {
        var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        int dark = 1, round = 2, backdrop = 2; // dark mode, rounded corners, Mica
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));
            DwmSetWindowAttribute(hwnd, 38, ref backdrop, sizeof(int));
        }
        catch { /* older Windows: plain chrome */ }
    }

    // ---- small helpers --------------------------------------------------------------------

    private string SpoolWord(int n) => Pl ? "szpul" : (n == 1 ? "spool" : "spools");

    private string VariantWord(int n)
    {
        if (!Pl) return n == 1 ? "variant" : "variants";
        if (n == 1) return "wariant";
        var last = n % 10; var last2 = n % 100;
        return last is >= 2 and <= 4 && last2 is < 12 or > 14 ? "warianty" : "wariantów";
    }

    private static void StyleSoftButton(Button b)
    {
        b.Foreground = Ink;
        b.Background = new SolidColorBrush(Color.FromArgb(0x1E, 0xFF, 0xFF, 0xFF));
        b.BorderThickness = new Thickness(0);
        b.Cursor = Cursors.Hand;
    }
}
