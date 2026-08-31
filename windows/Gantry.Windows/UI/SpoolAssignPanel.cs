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
    // Names of saved printers, so a roll loaded elsewhere shows *where* right on its row.
    private static readonly System.Collections.Generic.Dictionary<string, string> PrinterNames =
        SavedPrinterStore.Load().GroupBy(p => p.Serial).ToDictionary(g => g.Key, g => g.First().Name);

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
            Width = 360, MaxHeight = 440,
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

        // 1. Assigned roll + per-roll actions. Weight and history live on the roll, not the slot, so
        // unassigning only moves it to storage (its grams are kept).
        stack.Children.Add(SectionHeader(T("PRZYPISANA ROLKA", "ASSIGNED SPOOL")));
        var assigned = _spools.SpoolAt(_loc);
        if (assigned is not null)
        {
            var adef = _filaments.Filaments.FirstOrDefault(f => f.Id == assigned.FilamentDefinitionId);
            stack.Children.Add(Row(adef != null ? ParseHex(adef.ColorHex) : (Color?)null,
                adef != null ? $"{adef.Brand} {adef.Name}".Trim() : assigned.Id,
                $"{assigned.Id} · {(int)assigned.RemainingWeightGrams} g · {assigned.Percent}%",
                null, false, () => { }));
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            actions.Children.Add(Pill(T("Skoryguj", "Weigh"), false, () => ShowCorrectWeight(assigned)));
            actions.Children.Add(Pill(T("Zeruj", "Reset"), false, () => ConfirmReset(assigned)));
            actions.Children.Add(Pill(T("Odepnij", "Unassign"), false, () => { _spools.Assign(assigned.Id, SpoolLocation.Storage()); ShowMain(); }));
            stack.Children.Add(actions);
        }
        else stack.Children.Add(Muted(T("Brak", "None")));

        // 2. Existing physical rolls to move here (storage + other printers), matching filament first.
        // Clicking one only moves it: its remembered grams are never re-asked or reset (spec §3-4).
        stack.Children.Add(SectionHeader(T("DOSTĘPNE ROLKI", "AVAILABLE ROLLS")));
        var assignedId = assigned?.Id;
        var available = _spools.Spools
            .Where(s => s.Status != SpoolStatus.Archived && !s.Location.SameSlot(_loc) && s.Id != assignedId)
            .OrderByDescending(MatchesSpool).ThenByDescending(s => s.Location.IsStorage).ThenBy(s => s.Id).ToList();
        if (available.Count == 0)
            stack.Children.Add(Muted(T("Brak wolnych rolek. Utwórz nową poniżej.", "No spare rolls. Create one below.")));
        foreach (var s in available)
        {
            var def = _filaments.Filaments.FirstOrDefault(f => f.Id == s.FilamentDefinitionId);
            var name = def != null ? $"{def.Brand} {def.Name}".Trim() : s.Id;
            var spool = s;
            stack.Children.Add(Row(def != null ? ParseHex(def.ColorHex) : (Color?)null,
                string.IsNullOrEmpty(name) ? s.Id : name,
                $"{s.Id} · {(int)s.RemainingWeightGrams} g · {PlaceLabel(s.Location)}",
                null, MatchesSpool(s), () => AssignSpool(spool),
                onDelete: () => { _spools.Delete(spool.Id); ShowMain(); }));
        }

        // 3. Create a new roll: guided button + the whole catalog grouped by type. Picking a filament
        // asks for the starting grams (spec §2).
        stack.Children.Add(Pill(T("+ Utwórz nową rolkę", "+ Create new roll"), false, ShowPickFilament));
        stack.Children.Add(SectionHeader(T("FILAMENTY (NOWA ROLKA)", "FILAMENTS (NEW ROLL)")));
        var defs = _filaments.Filaments
            .OrderBy(d => d.Type).ThenByDescending(MatchesDef).ThenBy(d => $"{d.Brand}{d.Name}").ToList();
        if (defs.Count == 0)
            stack.Children.Add(Muted(T("Magazyn pusty. Dodaj filamenty w oknie Spoolbase.",
                                       "Empty. Add filaments in the Spoolbase window.")));
        string? lastType = null;
        foreach (var d in defs)
        {
            if (d.Type != lastType) { stack.Children.Add(TypeLabel(d.Type)); lastType = d.Type; }
            var def = d;
            var name = $"{d.Brand} {d.Name}".Trim();
            var colour = string.IsNullOrEmpty(d.ColorName) ? "#" + d.ColorHex : d.ColorName;
            stack.Children.Add(Row(ParseHex(d.ColorHex), string.IsNullOrEmpty(name) ? d.Type : name,
                $"{d.Type} · {colour}", null, MatchesDef(d), () => ShowPickGrams(def)));
        }
        Set(stack);
    }

    /// <summary>Weigh screen (spec §5): a fresh net reading, or gross + the empty-spool tare (subtracted
    /// for you). The tare is remembered on the roll for next time.</summary>
    private void ShowCorrectWeight(PhysicalSpool spool)
    {
        var stack = Column();
        stack.Children.Add(Header(T("Skoryguj wagę", "Correct weight"),
            $"{spool.Id} · {T("nominał", "nominal")} {(int)spool.NominalWeightGrams} g", ShowMain));

        var net = Input(((int)spool.RemainingWeightGrams).ToString());
        var gross = Input("");
        var tare = Input(spool.TareGrams is { } tg ? ((int)tg).ToString() : "");
        stack.Children.Add(LabeledField(T("Netto (g)", "Net (g)"), net));
        stack.Children.Add(LabeledField(T("Brutto (g)", "Gross (g)"), gross));
        stack.Children.Add(LabeledField(T("Tara szpuli (g)", "Spool tare (g)"), tare));
        stack.Children.Add(Muted(T("Wpisz wagę netto, albo brutto + tarę pustej szpuli (aplikacja odejmie tarę).",
                                   "Enter net weight, or gross + empty-spool tare (the app subtracts it).")));
        stack.Children.Add(Pill(T("Zapisz", "Save"), true, () =>
        {
            static double? Num(TextBox t) => double.TryParse(t.Text.Replace(',', '.'),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : null;
            var tareV = Num(tare);
            double? netV = (Num(gross) is { } g && tareV is { } tv) ? Math.Max(0, g - tv) : Num(net);
            if (netV is not { } nv) return;
            _spools.CorrectWeight(spool.Id, nv, string.IsNullOrWhiteSpace(tare.Text) ? null : tareV);
            ShowMain();
        }));
        Set(stack);
    }

    /// <summary>Reset a spent roll back to full (spec §6): same physical roll, refilled. Clears history.</summary>
    private void ConfirmReset(PhysicalSpool spool)
    {
        var res = MessageBox.Show(
            T($"Wyzerować rolkę {spool.Id}? Ustawia pełny stan {(int)spool.NominalWeightGrams} g i czyści historię zużycia tej rolki.",
              $"Reset roll {spool.Id}? Sets a full {(int)spool.NominalWeightGrams} g and clears this roll's usage history."),
            "Gantry", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (res != MessageBoxResult.Yes) return;
        _spools.ResetToFull(spool.Id);
        ShowMain();
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

    /// A short location for a roll: "magazyn", or "&lt;printer&gt; · A2" / "&lt;printer&gt; · EXT".
    private static string PlaceLabel(SpoolLocation loc)
    {
        if (loc.IsStorage) return T("magazyn", "storage");
        var name = loc.PrinterSerial != null && PrinterNames.TryGetValue(loc.PrinterSerial, out var n) && !string.IsNullOrEmpty(n)
            ? n : loc.PrinterSerial ?? T("drukarka", "printer");
        string slot;
        if (loc.Feeder == SpoolFeeder.Ext) slot = "EXT";
        else if (loc.Slot is { } s) slot = (loc.AmsIndex ?? 0) == 0 ? $"A{s + 1}" : $"AMS{(loc.AmsIndex ?? 0) + 1} {s + 1}";
        else slot = "AMS";
        return $"{name} · {slot}";
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

    /// A quiet caption heading each material group in the catalog list (PLA, PETG, …).
    private static TextBlock TypeLabel(string text) => new()
    { Text = text.ToUpperInvariant(), FontSize = 8, FontWeight = FontWeights.Bold, Foreground = GTheme.Brush(GTheme.Secondary), Margin = new Thickness(0, 6, 0, 2) };

    private static TextBox Input(string text) => new()
    {
        Text = text, Width = 120, VerticalContentAlignment = VerticalAlignment.Center,
        Background = new SolidColorBrush(Color.FromRgb(0x2C, 0x2C, 0x2E)), Foreground = GTheme.Brush(GTheme.Text),
        BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1), Padding = new Thickness(6, 3, 6, 3)
    };

    private static FrameworkElement LabeledField(string label, TextBox field)
    {
        var g = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tb = new TextBlock { Text = label, FontSize = 11, Foreground = GTheme.Brush(GTheme.Secondary), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(tb, 0); g.Children.Add(tb);
        Grid.SetColumn(field, 1); g.Children.Add(field);
        return g;
    }

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

    private FrameworkElement Row(Color? dot, string title, string subtitle, string? trailing, bool highlight, Action action, Action? onDelete = null)
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
        else if (onDelete is not null)
        {
            var del = new TextBlock
            {
                Text = "🗑", FontSize = 12, Foreground = GTheme.Brush(GTheme.Muted), Cursor = Cursors.Hand,
                VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(6, 2, 2, 2),
                ToolTip = T("Usuń rolkę", "Delete roll")
            };
            del.MouseLeftButtonUp += (_, e) => { e.Handled = true; onDelete(); };
            Grid.SetColumn(del, 2); grid.Children.Add(del);
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
