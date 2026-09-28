using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using Gantry.Services;

namespace Gantry.UI;

/// A small pill that sticks anywhere on the screen and opens into the filament stock.
///
/// It answers one question: how many rolls of this do I have, and I have just bought or opened one.
/// Spoolbase already does that, but it is a whole window — open it, find the row among the groups,
/// change the number, close it. Standing at a shelf with a box of new rolls, that is the wrong shape
/// of tool. This one is the size of a clock, sits over whatever is on screen and goes wherever it is
/// dragged, including half-tucked into a screen edge so only its nose shows.
///
/// Collapsed it is a dark capsule: a grip, the total number of rolls, and a ring around that number
/// coloured by the worst stock level it holds. A red ring means something is running out, which is
/// the one thing worth knowing without opening anything.
///
/// Open, it is one column grouped by material: a header with the material, its total and a plus,
/// then a card per filament with a swatch, the colour name, the count, minus and plus. No search, no
/// editing, no grouping options. The moment it grows a second job it stops being quicker than
/// Spoolbase, and being quicker than Spoolbase is its only reason to exist.
public sealed class FilamentPillWindow : Window
{
    private readonly FilamentStore _store;
    private readonly Border _shell = new();
    private readonly Grid _root = new();
    private readonly Border _capsule = new();
    private readonly StackPanel _panel = new();
    private readonly StackPanel _groups = new();
    private readonly ScrollViewer _scroll = new();
    private readonly TextBlock _total = new();
    private readonly Ellipse _ring = new();
    private bool _open;
    /// Zwijanie po zjechaniu myszą ma chwilę zwłoki: droga z wiersza na plus prowadzi przez kilka
    /// pikseli poza kontrolką i bez tego lista znikałaby w pół ruchu.
    private readonly DispatcherTimer _closeTimer = new() { Interval = TimeSpan.FromMilliseconds(280) };

    private const double PanelWidth = 264;
    private const double CapsuleWidth = 46;
    private const double CapsuleHeight = 34;
    /// Jak blisko krawędzi ekranu pastylka się do niej przykleja, i ile jej wtedy zostaje na wierzchu.
    private const double SnapDistance = 30;
    private const double SnapShowing = 22;

    private Edge _stuck = Edge.None;

    private enum Edge { None, Left, Right }

    public FilamentPillWindow(FilamentStore store)
    {
        _store = store;
        Title = AppSettings.T("Filament stock");
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;

        BuildCapsule();
        BuildPanel();
        _root.Children.Add(_capsule);
        _root.Children.Add(_shell);
        Content = _root;

        MouseEnter += (_, _) => { _closeTimer.Stop(); SetOpen(true); };
        MouseLeave += (_, _) => _closeTimer.Start();
        _closeTimer.Tick += (_, _) => { _closeTimer.Stop(); if (!IsMouseOver) SetOpen(false); };
        MouseLeftButtonDown += OnDrag;

        _store.Changed += (_, _) => Dispatcher.BeginInvoke(Rebuild);
        Rebuild();
        RestorePlace();
        LocationChanged += (_, _) => SavePlace();
    }

    // MARK: Zwinięta pastylka

    private void BuildCapsule()
    {
        _capsule.Width = CapsuleWidth;
        _capsule.Height = CapsuleHeight;
        _capsule.CornerRadius = new CornerRadius(CapsuleHeight / 2);
        _capsule.Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x16, 0x18, 0x1A));
        _capsule.Effect = new DropShadowEffect
        {
            BlurRadius = 14, ShadowDepth = 2, Direction = 270, Opacity = 0.5, Color = Colors.Black
        };

        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        // Uchwyt: trzy kropki, ta sama konwencja co wszędzie, gdzie coś się przeciąga.
        var grip = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 5, 0, 1)
        };
        for (var i = 0; i < 3; i++)
        {
            grip.Children.Add(new Ellipse
            {
                Width = 2.5, Height = 2.5, Margin = new Thickness(1.2, 0, 1.2, 0),
                Fill = new SolidColorBrush(Color.FromArgb(0x9C, 0xFF, 0xFF, 0xFF))
            });
        }
        stack.Children.Add(grip);

        var badge = new Grid { Width = 21, Height = 21, HorizontalAlignment = HorizontalAlignment.Center };
        _ring.Width = 21;
        _ring.Height = 21;
        _ring.StrokeThickness = 1.4;
        badge.Children.Add(_ring);
        _total.FontSize = 11;
        _total.FontWeight = FontWeights.SemiBold;
        _total.Foreground = Brushes.White;
        _total.HorizontalAlignment = HorizontalAlignment.Center;
        _total.VerticalAlignment = VerticalAlignment.Center;
        badge.Children.Add(_total);
        stack.Children.Add(badge);

        _capsule.Child = stack;
    }

    // MARK: Rozwinięty panel

    private void BuildPanel()
    {
        _shell.CornerRadius = new CornerRadius(20);
        // Bez prawdziwego rozmycia tła: okno z AllowsTransparency jest warstwowe, a systemowy akryl
        // działa tylko na zwykłym oknie, którego nie da się obciąć do kształtu kapsuły. Zamiast
        // udawać mrożoną szybę, panel jest przyciemnioną szybą: przepuszcza to, co pod nim, ale nie
        // rozmywa. Uczciwsze niż jednolita płyta udająca efekt, którego tu nie ma.
        _shell.Background = new SolidColorBrush(GantryTheme.IsLight
            ? Color.FromArgb(0xE8, 0xFA, 0xFA, 0xFB)
            : Color.FromArgb(0xE6, 0x1A, 0x1D, 0x20));
        _shell.BorderBrush = GantryTheme.Brush(GantryTheme.FleetCardLine);
        _shell.BorderThickness = new Thickness(1);
        _shell.Padding = new Thickness(10, 10, 10, 8);
        _shell.Width = PanelWidth;
        _shell.Visibility = Visibility.Collapsed;
        _shell.Effect = new DropShadowEffect
        {
            BlurRadius = 26, ShadowDepth = 5, Direction = 270, Opacity = 0.42, Color = Colors.Black
        };

        _scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        _scroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        _scroll.MaxHeight = 330;
        _scroll.Content = _groups;
        _panel.Children.Add(_scroll);

        var footer = new TextBlock
        {
            Text = AppSettings.T("Spoolbase — filament stock"),
            FontSize = 10.5,
            Margin = new Thickness(4, 8, 0, 0),
            Foreground = GantryTheme.Brush(GantryTheme.Muted),
            Cursor = Cursors.Hand,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        footer.MouseLeftButtonDown += (_, e) => { e.Handled = true; OpenSpoolbase?.Invoke(); };
        _panel.Children.Add(footer);
        _shell.Child = _panel;
    }

    /// <summary>Raised when the footer is clicked, so the host can open the full Spoolbase window.</summary>
    public Action? OpenSpoolbase { get; set; }

    private void SetOpen(bool open)
    {
        if (_open == open) return;
        _open = open;
        _shell.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        _capsule.Visibility = open ? Visibility.Collapsed : Visibility.Visible;
        // Przyklejona pastylka po otwarciu musi wrócić cała na ekran, bo inaczej panel wystawałby
        // poza krawędź i połowa listy byłaby nie do przeczytania.
        if (open && _stuck != Edge.None) Left = _stuck == Edge.Left ? 0 : SystemParameters.VirtualScreenWidth - PanelWidth;
        else if (!open && _stuck != Edge.None) StickTo(_stuck);
    }

    // MARK: Zawartość

    private void Rebuild()
    {
        var items = _store.Filaments.ToList();
        var lowest = items.Where(f => f.SpoolCount > 0).Select(f => f.SpoolCount).DefaultIfEmpty(0).Min();
        _total.Text = items.Sum(f => f.SpoolCount).ToString();
        // Pierścień mówi to jedno, co warto wiedzieć bez otwierania: czy coś się kończy. Progi te
        // same, co kolory zapasu w Spoolbase, więc pastylka i okno nie mogą mówić czegoś innego.
        _ring.Stroke = new SolidColorBrush(
            items.Count == 0 ? Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)
            : lowest <= StockLevels.RedMaximum ? Color.FromRgb(0xFF, 0x68, 0x57)
            : lowest <= StockLevels.BlueMaximum ? Color.FromRgb(0x5F, 0xA8, 0xEF)
            : Color.FromArgb(0x77, 0xFF, 0xFF, 0xFF));

        _groups.Children.Clear();
        if (items.Count == 0)
        {
            _groups.Children.Add(new TextBlock
            {
                Text = AppSettings.T("No filament in Spoolbase yet."),
                Foreground = GantryTheme.Brush(GantryTheme.Muted),
                FontSize = 11.5,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(4, 6, 4, 6)
            });
            return;
        }
        // Kolejność materiałów jak w katalogu, a to, czego nie ma na liście, na końcu alfabetycznie.
        var order = FilamentCatalogMeta.Types.ToList();
        foreach (var group in items.GroupBy(f => f.Type)
                     .OrderBy(g => order.IndexOf(g.Key) is var i && i >= 0 ? i : int.MaxValue)
                     .ThenBy(g => g.Key))
        {
            _groups.Children.Add(Header(group.Key, group.Sum(f => f.SpoolCount)));
            foreach (var filament in group.OrderByDescending(f => f.UpdatedAt)) _groups.Children.Add(Card(filament));
        }
    }

    private UIElement Header(string material, int count)
    {
        var grid = new Grid { Margin = new Thickness(4, 8, 2, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock
        {
            Text = material,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = GantryTheme.Brush(GantryTheme.Text),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(name, 0);
        grid.Children.Add(name);
        var sum = new TextBlock
        {
            Text = count.ToString(),
            FontSize = 11.5,
            Foreground = GantryTheme.Brush(GantryTheme.Muted),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(sum, 1);
        grid.Children.Add(sum);
        return grid;
    }

    private UIElement Card(Filament filament)
    {
        var card = new Border
        {
            CornerRadius = new CornerRadius(11),
            Background = GantryTheme.Brush(GantryTheme.Surface),
            Padding = new Thickness(8, 6, 6, 6),
            Margin = new Thickness(0, 0, 0, 4)
        };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var swatch = new Border
        {
            Width = 13, Height = 13, CornerRadius = new CornerRadius(6.5),
            Background = GantryTheme.Brush(Filament.ColorFromHex(filament.ColorHex)),
            BorderBrush = GantryTheme.Brush(GantryTheme.Line),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        };
        Grid.SetColumn(swatch, 0);
        grid.Children.Add(swatch);

        // Kolor pierwszy, nie nazwa produktu: przy jednej kolumnie to jedyne, co odróżnia dwie rolki
        // tego samego produktu, a „PLA Matte" powtórzone osiem razy nie rozstrzyga niczego.
        var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        label.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(filament.ColorName) ? filament.Name : filament.ColorName,
            Foreground = GantryTheme.Brush(GantryTheme.Text),
            FontSize = 12, FontWeight = FontWeights.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        label.Children.Add(new TextBlock
        {
            Text = $"{filament.Brand} · {filament.Name}",
            Foreground = GantryTheme.Brush(GantryTheme.Muted),
            FontSize = 10,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);

        var minus = StepButton("−", () => _store.Adjust(filament.Id, -1), filament.SpoolCount > 0);
        Grid.SetColumn(minus, 2);
        grid.Children.Add(minus);

        var count = new TextBlock
        {
            Text = filament.SpoolCount.ToString(),
            MinWidth = 20,
            TextAlignment = TextAlignment.Center,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            // Zero jest przygaszone: „nie mam" ma wyglądać inaczej niż „mam jedną".
            Foreground = GantryTheme.Brush(filament.SpoolCount > 0 ? GantryTheme.Text : GantryTheme.Muted),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(count, 3);
        grid.Children.Add(count);

        var plus = StepButton("+", () => _store.Adjust(filament.Id, 1), true);
        Grid.SetColumn(plus, 4);
        grid.Children.Add(plus);

        card.Child = grid;
        return card;
    }

    private UIElement StepButton(string glyph, Action run, bool enabled)
    {
        var border = new Border
        {
            Width = 21, Height = 21, CornerRadius = new CornerRadius(10.5),
            Background = GantryTheme.Brush(GantryTheme.W(0.07)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(2, 0, 2, 0),
            Cursor = enabled ? Cursors.Hand : Cursors.Arrow,
            Child = new TextBlock
            {
                Text = glyph,
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                Foreground = GantryTheme.Brush(enabled ? GantryTheme.Text : GantryTheme.Muted),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        if (!enabled) return border;
        border.MouseEnter += (_, _) => border.Background = GantryTheme.Brush(GantryTheme.W(0.16));
        border.MouseLeave += (_, _) => border.Background = GantryTheme.Brush(GantryTheme.W(0.07));
        // Obsłużone, więc kliknięcie w przycisk nie zaczyna przeciągania okna.
        border.MouseLeftButtonDown += (_, e) => { e.Handled = true; run(); };
        return border;
    }

    // MARK: Przeciąganie i przyklejanie

    /// Przeciąganie za dowolne miejsce, bo nie ma paska tytułu, za który dałoby się złapać.
    /// Po puszczeniu blisko krawędzi ekranu pastylka się do niej przykleja i chowa poza nią wszystko
    /// poza nosem, tak jak w pierwowzorze: ma zostać pod ręką, nie na wierzchu okna, w którym pracujesz.
    private void OnDrag(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed) return;
        try { DragMove(); } catch (InvalidOperationException) { return; }
        if (_open) return;
        var left = Left;
        var right = SystemParameters.VirtualScreenWidth - (Left + CapsuleWidth);
        if (left <= SnapDistance) StickTo(Edge.Left);
        else if (right <= SnapDistance) StickTo(Edge.Right);
        else StickTo(Edge.None);
    }

    private void StickTo(Edge edge)
    {
        _stuck = edge;
        var radius = CapsuleHeight / 2;
        _capsule.CornerRadius = edge switch
        {
            Edge.Left => new CornerRadius(0, radius, radius, 0),
            Edge.Right => new CornerRadius(radius, 0, 0, radius),
            _ => new CornerRadius(radius)
        };
        if (edge == Edge.Left) Left = SnapShowing - CapsuleWidth;
        else if (edge == Edge.Right) Left = SystemParameters.VirtualScreenWidth - SnapShowing;
    }

    // MARK: Gdzie stoi

    private const string PlaceKeyX = "filament-pill-x";
    private const string PlaceKeyY = "filament-pill-y";
    private const string PlaceKeyEdge = "filament-pill-edge";

    private void RestorePlace()
    {
        var x = Defaults.GetInt(PlaceKeyX, int.MinValue);
        var y = Defaults.GetInt(PlaceKeyY, int.MinValue);
        if (x == int.MinValue || y == int.MinValue)
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            return;
        }
        // Ekran mógł zniknąć albo zmienić rozdzielczość od poprzedniego uruchomienia; pastylka
        // postawiona poza obrazem byłaby nie do odzyskania inaczej niż przez plik ustawień. Przyklejona
        // wystaje poza krawędź celowo, więc przycinana jest tylko wtedy, gdy nie jest przyklejona.
        Top = Math.Min(Math.Max(y, 0), Math.Max(0, SystemParameters.VirtualScreenHeight - CapsuleHeight));
        var edge = (Edge)Defaults.GetInt(PlaceKeyEdge, (int)Edge.None);
        if (edge != Edge.None) { StickTo(edge); return; }
        Left = Math.Min(Math.Max(x, 0), Math.Max(0, SystemParameters.VirtualScreenWidth - CapsuleWidth));
    }

    private void SavePlace()
    {
        if (double.IsNaN(Left) || double.IsNaN(Top)) return;
        Defaults.SetInt(PlaceKeyX, (int)Math.Round(Left));
        Defaults.SetInt(PlaceKeyY, (int)Math.Round(Top));
        Defaults.SetInt(PlaceKeyEdge, (int)_stuck);
    }
}
