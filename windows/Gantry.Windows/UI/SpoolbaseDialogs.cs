using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>Shared dark chrome (immersive dark title bar + rounded corners) and a dark ComboBox style,
/// so the Spoolbase dialogs match the macOS look instead of a plain white WPF form.</summary>
internal static class SpoolbaseChrome
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public static void ApplyDark(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        int dark = GTheme.IsLight ? 0 : 1, round = 2;
        try
        {
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int));   // DWMWA_USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));  // DWMWA_WINDOW_CORNER_PREFERENCE
        }
        catch { /* older Windows: plain title bar is fine */ }
    }

    private static System.Windows.Style? _combo;
    private static bool _comboTried;
    public static System.Windows.Style? DarkCombo
    {
        get
        {
            if (_comboTried) return _combo;
            _comboTried = true;
            try { _combo = (System.Windows.Style)XamlReader.Parse(ComboXaml); }
            catch { _combo = null; }
            return _combo;
        }
    }

    private const string ComboXaml = @"
<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
       xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='ComboBox'>
  <Setter Property='Foreground' Value='#F5F5F7'/>
  <Setter Property='ItemContainerStyle'>
    <Setter.Value>
      <Style TargetType='ComboBoxItem'>
        <Setter Property='Foreground' Value='#F5F5F7'/>
        <Setter Property='Padding' Value='9,6'/>
        <Setter Property='Template'>
          <Setter.Value>
            <ControlTemplate TargetType='ComboBoxItem'>
              <Border x:Name='b' Background='Transparent' Padding='{TemplateBinding Padding}'>
                <ContentPresenter/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property='IsHighlighted' Value='True'>
                  <Setter TargetName='b' Property='Background' Value='#22FFFFFF'/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Style>
    </Setter.Value>
  </Setter>
  <Setter Property='Template'>
    <Setter.Value>
      <ControlTemplate TargetType='ComboBox'>
        <Grid>
          <ToggleButton Focusable='False' ClickMode='Press'
              IsChecked='{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}'>
            <ToggleButton.Template>
              <ControlTemplate TargetType='ToggleButton'>
                <Border CornerRadius='8' Background='#22FFFFFF' Padding='9,6'>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/>
                    </Grid.ColumnDefinitions>
                    <ContentPresenter VerticalAlignment='Center'
                        Content='{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType=ComboBox}}'/>
                    <Path Grid.Column='1' VerticalAlignment='Center' Margin='6,0,0,0'
                        Data='M0,0 L7,0 L3.5,4 Z' Fill='#9A9A9E'/>
                  </Grid>
                </Border>
              </ControlTemplate>
            </ToggleButton.Template>
          </ToggleButton>
          <Popup IsOpen='{TemplateBinding IsDropDownOpen}' Placement='Bottom' AllowsTransparency='True'
                 Focusable='False' PopupAnimation='Fade'>
            <Border CornerRadius='8' Background='#FF2A2A2C' BorderBrush='#33FFFFFF' BorderThickness='1'
                    Margin='0,3,0,0' MinWidth='{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}'>
              <ScrollViewer MaxHeight='240'><ItemsPresenter/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>";
}

/// <summary>Searchable catalog picker — add a filament from the bundled catalog to the inventory.</summary>
public sealed class SpoolbaseCatalogWindow : Window
{
    private readonly FilamentStore _store;
    private readonly List<CatalogFilament> _catalog;
    private readonly ListBox _listBox = new();
    private readonly TextBox _search = new();
    private readonly TextBox _qty = new() { Text = "1", Width = 48, TextAlignment = TextAlignment.Center };
    private readonly TextBox _weight = new() { Text = "1000", Width = 60, TextAlignment = TextAlignment.Center };

    private static Brush Ink => GTheme.Brush(GTheme.Text);
    private static bool Pl => AppSettings.Polish;

    public SpoolbaseCatalogWindow(FilamentStore store)
    {
        _store = store;
        _catalog = FilamentCatalog.Load();
        Title = Pl ? "Dodaj filament" : "Add filament";
        Width = 460; Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = GTheme.Brush(GTheme.Canvas);
        Foreground = Ink;
        FontFamily = new FontFamily("Segoe UI Variable, Segoe UI");
        SourceInitialized += (_, _) => SpoolbaseChrome.ApplyDark(this);

        var root = new DockPanel { Margin = new Thickness(14) };

        _search.FontSize = 13; _search.Padding = new Thickness(8, 6, 8, 6);
        _search.Background = GTheme.Brush(GTheme.Surface);
        _search.Foreground = Ink; _search.CaretBrush = Ink; _search.BorderThickness = new Thickness(0);
        _search.Margin = new Thickness(0);
        _search.TextChanged += (_, _) => ApplyFilter();
        var codeButton = new Button
        {
            Content = Pl ? "▣  Skanuj kod…" : "▣  Scan code…", MinWidth = 105, Margin = new Thickness(8, 0, 0, 0)
        };
        codeButton.Click += (_, _) => ScanManufacturerCode();
        var searchRow = new Grid { Margin = new Thickness(0, 0, 0, 10) };
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        searchRow.Children.Add(_search); Grid.SetColumn(codeButton, 1); searchRow.Children.Add(codeButton);
        DockPanel.SetDock(searchRow, Dock.Top); root.Children.Add(searchRow);

        var addManual = new Button { Content = Pl ? "Dodaj ręcznie…" : "Add manually…", Height = 32, Margin = new Thickness(0, 10, 0, 0) };
        addManual.Click += (_, _) => { var e = new SpoolbaseEditWindow(_store, null, false) { Owner = this }; if (e.ShowDialog() == true) Close(); };
        DockPanel.SetDock(addManual, Dock.Bottom);
        root.Children.Add(addManual);

        // Quantity + per-roll weight: each spool added becomes a real physical roll (SP-xxxxx) in storage
        // with this weight from the moment the filament is added (spec §1-2). Full roll = 1000 g.
        foreach (var box in new[] { _qty, _weight })
        {
            box.FontSize = 13; box.Padding = new Thickness(6, 4, 6, 4);
            box.Background = GTheme.Brush(GTheme.Surface);
            box.Foreground = Ink; box.CaretBrush = Ink; box.BorderThickness = new Thickness(0);
        }
        var addBtn = new Button { Content = Pl ? "Dodaj do moich" : "Add to mine", Height = 32, Margin = new Thickness(10, 0, 0, 0), Padding = new Thickness(10, 0, 10, 0) };
        addBtn.Click += (_, _) => AddSelected();
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        footer.Children.Add(new TextBlock { Text = Pl ? "Liczba szpul" : "Spools", Foreground = GTheme.Brush(GTheme.Secondary), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) });
        footer.Children.Add(_qty);
        footer.Children.Add(new TextBlock { Text = Pl ? "Waga (g)" : "Weight (g)", Foreground = GTheme.Brush(GTheme.Secondary), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 6, 0) });
        footer.Children.Add(_weight);
        footer.Children.Add(addBtn);
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);

        _listBox.Background = Brushes.Transparent;
        _listBox.BorderThickness = new Thickness(0);
        _listBox.ItemTemplate = BuildRowTemplate();
        _listBox.MouseDoubleClick += (_, _) => AddSelected();
        ScrollViewer.SetHorizontalScrollBarVisibility(_listBox, ScrollBarVisibility.Disabled);
        root.Children.Add(_listBox);

        Content = root;
        ApplyFilter();
    }

    private void ApplyFilter()
    {
        var q = _search.Text.Trim().ToLowerInvariant();
        IEnumerable<CatalogFilament> items = _catalog;
        if (q.Length > 0)
        {
            items = _catalog.Where(c =>
                $"{c.Brand} {c.Name} {c.Type} {c.ColorName} {c.ColorHex} {c.ManufacturerCode}".ToLowerInvariant().Contains(q));
        }
        _listBox.ItemsSource = items.Take(400).ToList();
    }

    private void AddSelected()
    {
        if (_listBox.SelectedItem is not CatalogFilament item) return;
        int qty = int.TryParse(_qty.Text.Trim(), out var q) ? Math.Max(1, q) : 1;
        double weight = double.TryParse(_weight.Text.Trim(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var w) && w > 0 ? w : 1000;
        _store.Add(item.InventoryItem(qty));
        // Match the definition by catalog id (Add may have merged into an existing entry) and mint the
        // physical rolls, so the roll and its weight exist from the moment the filament is added.
        var def = _store.Filaments.FirstOrDefault(f => f.CatalogId == item.Id);
        if (def is not null) SpoolbaseShared.Spools.CreateRolls(def.Id, qty, weight);
        Close();
    }

    private void ScanManufacturerCode()
    {
        var scanner = new BarcodeScannerWindow(HandleManufacturerCode) { Owner = this };
        scanner.ShowDialog();
    }

    private static string NormalizeBarcode(string value) =>
        new(value.ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());

    private void HandleManufacturerCode(string scanned)
    {
        var code = scanned.Trim();
        if (code.Length == 0) return;
        var normalized = NormalizeBarcode(code);
        var exact = _catalog.FirstOrDefault(item =>
            NormalizeBarcode(item.ManufacturerCode) == normalized);
        _search.Text = exact?.ManufacturerCode ?? code;
        if (exact is not null)
        {
            _listBox.SelectedItem = exact;
            _listBox.ScrollIntoView(exact);
            return;
        }

        var add = MessageBox.Show(this,
            AppSettings.Text($"Odczytany kod: {code}\n\nNie znaleziono go w bazie. Dodać własny filament z tym kodem?",
                             $"Scanned code: {code}\n\nIt was not found in the catalog. Add a custom filament with this code?"),
            AppSettings.Text("Nie znaleziono kodu", "Code not found"),
            MessageBoxButton.YesNo, MessageBoxImage.Information);
        if (add == MessageBoxResult.Yes)
        {
            var editor = new SpoolbaseEditWindow(_store, null, false, code) { Owner = this };
            if (editor.ShowDialog() == true) Close();
        }
    }

    private static DataTemplate BuildRowTemplate()
    {
        var ink = GTheme.IsLight ? "#1C1C1E" : "#F5F5F7";
        var muted = GTheme.IsLight ? "#6D716E" : "#9A9A9E";
        var xaml =
            "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
            "<Grid Margin='2,5,2,5'>" +
            "<Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
            "<Border Width='26' Height='26' CornerRadius='13' Background='{Binding SwatchBrush}' BorderThickness='0.5' BorderBrush='#55FFFFFF' VerticalAlignment='Center'/>" +
            "<StackPanel Grid.Column='1' Margin='10,0,0,0' VerticalAlignment='Center'>" +
            $"<TextBlock Text='{{Binding Display}}' FontSize='12.5' FontWeight='SemiBold' Foreground='{ink}'/>" +
            $"<TextBlock Text='{{Binding Sub}}' FontSize='10.5' Foreground='{muted}'/>" +
            "</StackPanel></Grid></DataTemplate>";
        return (DataTemplate)XamlReader.Parse(xaml);
    }
}

/// <summary>Edit an inventory item (all fields), a count-only quick change, or add a manual filament.</summary>
public sealed class SpoolbaseEditWindow : Window
{
    private readonly FilamentStore _store;
    private readonly Filament _original;
    private readonly bool _isNew;

    private readonly TextBox _brand = new();
    private readonly TextBox _name = new();
    private readonly ComboBox _type = new();
    private readonly TextBox _colorName = new();
    private readonly TextBox _colorHex = new();
    private readonly TextBox _code = new();
    private readonly TextBox _count = new();
    private readonly TextBox _weight = new();

    private static Brush Ink => GTheme.Brush(GTheme.Text);
    private static bool Pl => AppSettings.Polish;

    public SpoolbaseEditWindow(FilamentStore store, Filament? filament, bool countOnly,
                               string? prefilledManufacturerCode = null)
    {
        _store = store;
        _isNew = filament == null;
        _original = filament ?? new Filament { Type = "PLA", ColorName = Pl ? "Nowy" : "New", ColorHex = "8E8E93",
                                               ManufacturerCode = prefilledManufacturerCode ?? "" };

        Title = _isNew ? (Pl ? "Nowy filament" : "New filament")
                       : (countOnly ? (Pl ? "Liczba szpul" : "Spool count") : (Pl ? "Edytuj filament" : "Edit filament"));
        // Grow to fit the fields instead of a fixed height that clipped the form (the manufacturer code,
        // spool count and the buttons fell off the bottom). Cap the height and scroll on a small screen.
        Width = 400;
        SizeToContent = SizeToContent.Height;
        MaxHeight = 720;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.CanResize;
        Background = GTheme.Brush(GTheme.Canvas);
        Foreground = Ink;
        FontFamily = new FontFamily("Segoe UI Variable, Segoe UI");
        SourceInitialized += (_, _) => SpoolbaseChrome.ApplyDark(this);

        var stack = new StackPanel { Margin = new Thickness(16) };

        if (countOnly)
        {
            stack.Children.Add(Label($"{_original.ColorName} · {_original.Brand}"));
            Prepare(_count, _original.SpoolCount.ToString());
            _count.FontSize = 20; _count.TextAlignment = TextAlignment.Center;
            stack.Children.Add(_count);
        }
        else
        {
            foreach (var v in FilamentCatalogMeta.Types) _type.Items.Add(v);
            _type.SelectedItem = FilamentCatalogMeta.Types.Contains(_original.Type) ? _original.Type : "PLA";
            if (!GTheme.IsLight && SpoolbaseChrome.DarkCombo is { } comboStyle) _type.Style = comboStyle;
            else _type.Foreground = Brushes.Black;   // fallback: readable on the default light combo
            _type.Margin = new Thickness(0, 0, 0, 8);

            stack.Children.Add(Field(Pl ? "Marka" : "Brand", _brand, _original.Brand));
            stack.Children.Add(Field(Pl ? "Nazwa" : "Name", _name, _original.Name));
            stack.Children.Add(Label(Pl ? "Typ" : "Type"));
            stack.Children.Add(_type);
            stack.Children.Add(Field(Pl ? "Kolor" : "Colour", _colorName, _original.ColorName));
            stack.Children.Add(Field("Hex", _colorHex, _original.ColorHex));
            stack.Children.Add(Field(Pl ? "Kod producenta" : "Manufacturer code", _code, _original.ManufacturerCode));
            stack.Children.Add(Field(Pl ? "Liczba szpul" : "Spool count", _count, _original.SpoolCount.ToString()));
            if (_isNew) stack.Children.Add(Field(Pl ? "Waga rolki (g)" : "Roll weight (g)", _weight, "1000"));
        }

        var save = new Button { Content = Pl ? "Zapisz" : "Save", Height = 32, Width = 100 };
        save.Click += (_, _) => Commit(countOnly);
        var cancel = new Button { Content = Pl ? "Anuluj" : "Cancel", Height = 32, Width = 100, Margin = new Thickness(8, 0, 0, 0) };
        cancel.Click += (_, _) => { DialogResult = false; Close(); };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(save); buttons.Children.Add(cancel);
        stack.Children.Add(buttons);

        Content = new ScrollViewer
        {
            Content = stack,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
        };
    }

    private void Commit(bool countOnly)
    {
        int count = int.TryParse(_count.Text.Trim(), out var c) ? Math.Max(0, c) : _original.SpoolCount;
        var updated = new Filament
        {
            Id = _original.Id,
            CatalogId = _original.CatalogId,
            Brand = countOnly ? _original.Brand : _brand.Text.Trim(),
            Name = countOnly ? _original.Name : _name.Text.Trim(),
            Type = countOnly ? _original.Type : (_type.SelectedItem as string ?? _original.Type),
            ColorName = countOnly ? _original.ColorName : _colorName.Text.Trim(),
            ColorHex = countOnly ? _original.ColorHex : Filament.NormalizedHex(_colorHex.Text),
            ManufacturerCode = countOnly ? _original.ManufacturerCode : _code.Text.Trim(),
            SpoolCount = count,
            Notes = _original.Notes,
            UpdatedAt = DateTime.UtcNow
        };

        if (_isNew)
        {
            updated.CatalogId ??= "custom-" + Guid.NewGuid().ToString("N");
            _store.Add(updated);
            // Mint physical rolls so the roll and its weight exist from the moment it is added (spec §1).
            double weight = double.TryParse(_weight.Text.Trim(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var w) && w > 0 ? w : 1000;
            var def = _store.Filaments.FirstOrDefault(f => f.Id == updated.Id) ?? updated;
            SpoolbaseShared.Spools.CreateRolls(def.Id, count, weight);
        }
        else
        {
            if (!countOnly) UpsertCatalog(updated);
            _store.Update(updated);
        }
        DialogResult = true;
        Close();
    }

    private static void UpsertCatalog(Filament f)
    {
        var catalog = FilamentCatalog.Load();
        var catalogId = f.CatalogId ?? "custom-" + Guid.NewGuid().ToString("N");
        f.CatalogId = catalogId;
        var item = new CatalogFilament
        {
            Id = catalogId, Brand = f.Brand, Name = f.Name, Type = f.Type,
            ColorName = f.ColorName, ColorHex = f.ColorHex, ManufacturerCode = f.ManufacturerCode
        };
        var idx = catalog.FindIndex(c => c.Id == catalogId);
        if (idx >= 0) catalog[idx] = item; else catalog.Add(item);
        FilamentCatalog.Save(catalog);
    }

    private UIElement Field(string label, TextBox box, string value)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        panel.Children.Add(Label(label));
        Prepare(box, value);
        // A rounded dark surface around the field, like the macOS inputs.
        panel.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = GTheme.Brush(GTheme.Surface),
            Child = box
        });
        return panel;
    }

    private static void Prepare(TextBox box, string value)
    {
        box.Text = value;
        box.FontSize = 13;
        box.Padding = new Thickness(9, 6, 9, 6);
        box.Background = Brushes.Transparent;
        box.Foreground = Ink;
        box.CaretBrush = Ink;
        box.BorderThickness = new Thickness(0);
    }

    private static TextBlock Label(string text) => new()
    {
        Text = text, FontSize = 10.5, Foreground = GTheme.Brush(GTheme.Muted), Margin = new Thickness(2, 0, 0, 3)
    };
}
