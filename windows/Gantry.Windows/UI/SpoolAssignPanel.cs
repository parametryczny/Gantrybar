using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>The AMS/EXT slot spool-assignment panel, styled to match Gantry (tokens, section headers,
/// card rows, pills). Mirrors the macOS SpoolAssignPopoverViewController. Shown as an in-window overlay.</summary>
internal sealed class SpoolAssignPanel
{
    private readonly SpoolLocation _loc;
    private readonly string _title;
    private readonly string? _material;
    private readonly string? _colorHex;
    private readonly Action _onClose;
    private readonly Border _root;
    private readonly PhysicalSpoolStore _spools = SpoolbaseShared.Spools;
    private readonly FilamentStore _filaments = SpoolbaseShared.Filaments;

    public static FrameworkElement Build(SpoolLocation loc, string title, string? material, string? colorHex, Action onClose)
    {
        var p = new SpoolAssignPanel(loc, title, material, colorHex, onClose);
        p.ShowMain();
        return p._root;
    }

    private SpoolAssignPanel(SpoolLocation loc, string title, string? material, string? colorHex, Action onClose)
    {
        _loc = loc; _title = title;
        _material = string.IsNullOrEmpty(material) ? null : material;
        _colorHex = colorHex; _onClose = onClose;
        _root = new Border
        {
            Width = 300, MaxHeight = 440,
            Background = new SolidColorBrush(Color.FromRgb(0x15, 0x17, 0x19)),
            CornerRadius = new CornerRadius(14),
            BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
    }

    private static string T(string pl, string en) => AppSettings.Text(pl, en);

    private void Set(StackPanel content)
    {
        content.Margin = new Thickness(16);
        _root.Child = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = content };
    }

    // MARK: screens

    private void ShowMain()
    {
        var stack = Column();
        stack.Children.Add(Header(_title, T($"AMS: {_material ?? "nieznany"}", $"AMS: {_material ?? "unknown"}"), null));

        stack.Children.Add(SectionHeader(T("PRZYPISANA ROLKA", "ASSIGNED SPOOL")));
        var assigned = _spools.SpoolAt(_loc);
        if (assigned is not null)
        {
            var def = _filaments.Filaments.FirstOrDefault(f => f.Id == assigned.FilamentDefinitionId);
            stack.Children.Add(Row(def != null ? ParseHex(def.ColorHex) : (Color?)null,
                def != null ? $"{def.Brand} {def.Name}".Trim() : assigned.Id,
                $"{assigned.Id} · {(int)assigned.RemainingWeightGrams} g · {assigned.Percent}%",
                T("Odepnij", "Unassign"), false, () => { _spools.Assign(assigned.Id, SpoolLocation.Storage()); ShowMain(); }));
        }
        else stack.Children.Add(Muted(T("Brak", "None")));

        stack.Children.Add(Pill(T("+ Nowa rolka", "+ New roll"), true, ShowPickFilament));

        stack.Children.Add(SectionHeader(T("ROLKI", "SPOOLS")));
        var available = _spools.Spools
            .Where(s => s.Status != SpoolStatus.Archived && !s.Location.SameSlot(_loc))
            .OrderByDescending(MatchesSpool).ThenBy(s => s.Id).ToList();
        if (available.Count == 0) stack.Children.Add(Muted(T("Brak rolek. Utwórz nową powyżej.", "No spools yet. Create one above.")));
        foreach (var s in available)
        {
            var def = _filaments.Filaments.FirstOrDefault(f => f.Id == s.FilamentDefinitionId);
            var name = def != null ? $"{def.Brand} {def.Name}".Trim() : s.Id;
            var place = s.Location.IsStorage ? T("Magazyn", "Storage") : T("w drukarce", "on a printer");
            var spool = s;
            stack.Children.Add(Row(def != null ? ParseHex(def.ColorHex) : (Color?)null,
                string.IsNullOrEmpty(name) ? s.Id : name,
                $"{s.Id} · {(int)s.RemainingWeightGrams} g · {s.Percent}% · {place}",
                null, MatchesSpool(s), () => AssignSpool(spool)));
        }
        Set(stack);
    }

    private void ShowPickFilament()
    {
        var stack = Column();
        stack.Children.Add(Header(T("Nowa rolka", "New roll"), T("Wybierz filament", "Pick a filament"), ShowMain));

        if (_material is { } mat)
            stack.Children.Add(Row(_colorHex != null ? ParseHex(_colorHex) : (Color?)null,
                T("Nowa definicja z AMS", "New definition from AMS"), mat, null, true,
                () => ShowPickGrams(EnsureDefinition())));

        var defs = _filaments.Filaments.OrderByDescending(MatchesDef).ThenBy(d => $"{d.Brand}{d.Name}").ToList();
        foreach (var d in defs)
        {
            var def = d;
            var name = $"{d.Brand} {d.Name}".Trim();
            stack.Children.Add(Row(ParseHex(d.ColorHex), string.IsNullOrEmpty(name) ? d.Type : name,
                $"{d.Type} · {(string.IsNullOrEmpty(d.ColorName) ? "#" + d.ColorHex : d.ColorName)}",
                null, MatchesDef(d), () => ShowPickGrams(def)));
        }
        if (defs.Count == 0 && _material == null)
            stack.Children.Add(Muted(T("Brak filamentów w Spoolbase. Dodaj je w oknie Spoolbase.",
                                       "No filaments in Spoolbase yet. Add them in the Spoolbase window.")));
        Set(stack);
    }

    private void ShowPickGrams(Filament def)
    {
        var stack = Column();
        stack.Children.Add(Header(T("Początkowa ilość", "Starting amount"),
            $"{def.Brand} {def.Name} · {def.Type}".Trim(), ShowPickFilament));

        var presets = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var g in new[] { 1000.0, 750, 500 })
        {
            var grams = g;
            presets.Children.Add(Pill($"{(int)g} g", false, () => CreateAndAssign(def, grams)));
        }
        stack.Children.Add(presets);

        var field = new TextBox { Width = 100, Margin = new Thickness(0, 0, 6, 0), Background = new SolidColorBrush(Color.FromRgb(0x2C, 0x2C, 0x2E)), Foreground = GTheme.Brush(GTheme.Text), BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1) };
        var create = Pill(T("Utwórz", "Create"), true, () =>
        {
            if (double.TryParse(field.Text.Replace(',', '.'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var g) && g > 0)
                CreateAndAssign(def, g);
        });
        var custom = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        custom.Children.Add(field); custom.Children.Add(create);
        stack.Children.Add(custom);
        Set(stack);
    }

    // MARK: actions

    private void AssignSpool(PhysicalSpool spool)
    {
        if (!spool.Location.IsStorage && !spool.Location.SameSlot(_loc))
        {
            var res = MessageBox.Show(T($"Rolka {spool.Id} jest w innym miejscu. Przenieść tutaj?",
                                        $"Spool {spool.Id} is elsewhere. Move it here?"),
                "Gantry", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (res != MessageBoxResult.Yes) return;
        }
        _spools.Assign(spool.Id, _loc);
        _onClose();
    }

    private void CreateAndAssign(Filament def, double grams)
    {
        _spools.Add(new PhysicalSpool
        {
            Id = _spools.NextSpoolId(), FilamentDefinitionId = def.Id,
            NominalWeightGrams = grams, RemainingWeightGrams = grams,
            Status = SpoolStatus.Active, Location = _loc
        });
        _onClose();
    }

    private Filament EnsureDefinition()
    {
        var existing = _filaments.Filaments.FirstOrDefault(MatchesDef);
        if (existing is not null) return existing;
        var material = _material ?? "PLA";
        var def = new Filament { Brand = "", Name = material, Type = material, ColorName = "", ColorHex = (_colorHex ?? "8E8E93").Replace("#", "") };
        _filaments.Add(def);
        return _filaments.Filaments.FirstOrDefault(f => f.Id == def.Id) ?? def;
    }

    private bool MatchesDef(Filament def)
    {
        if (_material is null) return false;
        bool material = string.Equals(def.Type, _material, StringComparison.OrdinalIgnoreCase);
        bool color = _colorHex is null || Norm(def.ColorHex) == Norm(_colorHex);
        return material && color;
    }

    private bool MatchesSpool(PhysicalSpool s) =>
        _filaments.Filaments.FirstOrDefault(f => f.Id == s.FilamentDefinitionId) is { } def && MatchesDef(def);

    private static string Norm(string hex) => hex.Replace("#", "").ToUpperInvariant().PadRight(6).Substring(0, 6);

    // MARK: styled components

    private static StackPanel Column() => new() { Orientation = Orientation.Vertical };

    private FrameworkElement Header(string title, string subtitle, Action? back)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        if (back is not null) stack.Children.Add(Link(T("‹ Wróć", "‹ Back"), back));
        stack.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.Bold, Foreground = GTheme.Brush(GTheme.Text) });
        stack.Children.Add(new TextBlock { Text = subtitle, FontSize = 11, Foreground = GTheme.Brush(GTheme.Secondary) });
        return stack;
    }

    private static TextBlock SectionHeader(string text) => new()
    { Text = text, FontSize = 9, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Muted), Margin = new Thickness(0, 8, 0, 4) };

    private static TextBlock Muted(string text) => new()
    { Text = text, FontSize = 11, Foreground = GTheme.Brush(GTheme.Muted), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 4) };

    private static FrameworkElement Link(string text, Action action)
    {
        var tb = new TextBlock { Text = text, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Secondary), Cursor = Cursors.Hand, Margin = new Thickness(0, 0, 0, 4) };
        tb.MouseLeftButtonUp += (_, _) => action();
        return tb;
    }

    private FrameworkElement Pill(string text, bool filled, Action action)
    {
        var border = new Border
        {
            CornerRadius = new CornerRadius(8), Height = 30, Margin = new Thickness(0, 4, 6, 4),
            Background = filled ? GTheme.Brush(GTheme.Accent) : GTheme.Brush(GTheme.Surface),
            BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(filled ? 0 : 1),
            Padding = new Thickness(12, 0, 12, 0), Cursor = Cursors.Hand,
            Child = new TextBlock { Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Foreground = filled ? new SolidColorBrush(Color.FromRgb(0x15, 0x17, 0x19)) : GTheme.Brush(GTheme.Text) }
        };
        border.MouseLeftButtonUp += (_, _) => action();
        return border;
    }

    private FrameworkElement Row(Color? dot, string title, string subtitle, string? trailing, bool highlight, Action action)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // Always show a swatch so a row is never bare — a spool with no linked filament gets a neutral grey.
        var c = dot ?? Color.FromRgb(0x5A, 0x5A, 0x5E);
        var sw = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = new SolidColorBrush(c), BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 9, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(sw, 0); grid.Children.Add(sw);
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Text), TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock { Text = subtitle, FontSize = 10, Foreground = GTheme.Brush(highlight ? GTheme.Humidity : GTheme.Secondary), TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        if (trailing is not null)
        {
            var tl = new TextBlock { Text = trailing, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.StatusPrinting), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(tl, 2); grid.Children.Add(tl);
        }
        var border = new Border
        {
            CornerRadius = new CornerRadius(8), Background = GTheme.Brush(GTheme.Surface),
            BorderBrush = GTheme.Brush(Color.FromArgb(0x80, 0x73, 0xCF, 0xAD)), BorderThickness = new Thickness(highlight ? 1 : 0),
            Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(0, 0, 0, 4), Cursor = Cursors.Hand, Child = grid
        };
        border.MouseLeftButtonUp += (_, _) => action();
        return border;
    }

    private static Color ParseHex(string hex)
    {
        hex = hex.Replace("#", "");
        try
        {
            if (hex.Length >= 6)
                return Color.FromRgb(Convert.ToByte(hex.Substring(0, 2), 16), Convert.ToByte(hex.Substring(2, 2), 16), Convert.ToByte(hex.Substring(4, 2), 16));
        }
        catch { }
        return Color.FromRgb(0x8E, 0x8E, 0x93);
    }
}
