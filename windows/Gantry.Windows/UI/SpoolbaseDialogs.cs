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
        int dark = 1, round = 2;
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

    private static readonly Brush Ink = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF7));
    private static bool Pl => AppSettings.Polish;

    public SpoolbaseCatalogWindow(FilamentStore store)
    {
        _store = store;
        _catalog = FilamentCatalog.Load();
        Title = Pl ? "Dodaj filament" : "Add filament";
        Width = 460; Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = new SolidColorBrush(Color.FromRgb(0x24, 0x24, 0x26));
        Foreground = Ink;
        FontFamily = new FontFamily("Segoe UI Variable, Segoe UI");
        SourceInitialized += (_, _) => SpoolbaseChrome.ApplyDark(this);

        var root = new DockPanel { Margin = new Thickness(14) };

        _search.FontSize = 13; _search.Padding = new Thickness(8, 6, 8, 6);
        _search.Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF));
        _search.Foreground = Ink; _search.CaretBrush = Ink; _search.BorderThickness = new Thickness(0);
        _search.Margin = new Thickness(0, 0, 0, 10);
        _search.TextChanged += (_, _) => ApplyFilter();
        DockPanel.SetDock(_search, Dock.Top);
        root.Children.Add(_search);

        var addManual = new Button { Content = Pl ? "Dodaj ręcznie…" : "Add manually…", Height = 32, Margin = new Thickness(0, 10, 0, 0) };
        addManual.Click += (_, _) => { var e = new SpoolbaseEditWindow(_store, null, false) { Owner = this }; if (e.ShowDialog() == true) Close(); };
        DockPanel.SetDock(addManual, Dock.Bottom);
        root.Children.Add(addManual);

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
        _store.Add(item.InventoryItem(1));
        Close();
    }

    private static DataTemplate BuildRowTemplate()
    {
        const string xaml =
            "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
            "<Grid Margin='2,5,2,5'>" +
            "<Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>" +
            "<Border Width='26' Height='26' CornerRadius='13' Background='{Binding SwatchBrush}' BorderThickness='0.5' BorderBrush='#55FFFFFF' VerticalAlignment='Center'/>" +
            "<StackPanel Grid.Column='1' Margin='10,0,0,0' VerticalAlignment='Center'>" +
            "<TextBlock Text='{Binding Display}' FontSize='12.5' FontWeight='SemiBold' Foreground='#F5F5F7'/>" +
            "<TextBlock Text='{Binding Sub}' FontSize='10.5' Foreground='#9A9A9E'/>" +
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

    private static readonly Brush Ink = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF7));
    private static bool Pl => AppSettings.Polish;

    public SpoolbaseEditWindow(FilamentStore store, Filament? filament, bool countOnly)
    {
        _store = store;
        _isNew = filament == null;
        _original = filament ?? new Filament { Type = "PLA", ColorName = Pl ? "Nowy" : "New", ColorHex = "8E8E93" };

        Title = _isNew ? (Pl ? "Nowy filament" : "New filament")
                       : (countOnly ? (Pl ? "Liczba szpul" : "Spool count") : (Pl ? "Edytuj filament" : "Edit filament"));
        // Grow to fit the fields instead of a fixed height that clipped the form (the manufacturer code,
        // spool count and the buttons fell off the bottom). Cap the height and scroll on a small screen.
        Width = 400;
        SizeToContent = SizeToContent.Height;
        MaxHeight = 720;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.CanResize;
        Background = new SolidColorBrush(Color.FromRgb(0x24, 0x24, 0x26));
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
            if (SpoolbaseChrome.DarkCombo is { } comboStyle) _type.Style = comboStyle;
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
            Background = new SolidColorBrush(Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF)),
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
        Text = text, FontSize = 10.5, Foreground = new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0x9E)), Margin = new Thickness(2, 0, 0, 3)
    };
}
