using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gantry.Models;
using Gantry.Services;
using Microsoft.Win32;

namespace Gantry.UI;

/// Farm: sliced 3MF files for Bambu Lab and G-code for Klipper, PrusaLink and OctoPrint, sent and
/// started after an explicit check, plus the queue that hands copies to printers marked with an empty
/// bed. Mirrors the macOS Farm window.
public sealed class FarmWindow : Window
{
    private static FarmWindow? _current;

    public static void ShowFor(PrinterStore store)
    {
        if (_current is { IsLoaded: true }) { _current.Activate(); return; }
        // The same library the control panel sends from, so the two never write index.json over each other.
        _current = new FarmWindow(FarmStore.Shared(store));
        _current.Closed += (_, _) => _current = null;
        _current.Show();
    }

    private readonly FarmStore _farmStore;
    private readonly StackPanel _library = new();
    private readonly StackPanel _details = new();
    private readonly StackPanel _destinations = new();
    private readonly StackPanel _history = new();
    private readonly TextBlock _notice = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11 };
    private Guid? _selected;
    private int _plateIndex = 1;
    private int _copies = 1;
    private readonly Dictionary<string, CheckBox> _targets = new();
    private readonly Dictionary<string, Dictionary<int, ComboBox>> _mappings = new();
    private readonly Dictionary<Guid, TextBlock> _progressLabels = new();
    private List<string> _printerIds = new();

    private FarmWindow(FarmStore farm)
    {
        _farmStore = farm;
        Title = "Farma";
        Width = 1080; Height = 700; MinWidth = 940; MinHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = GTheme.Brush(GTheme.Canvas);
        Foreground = GTheme.Brush(GTheme.Text);
        GTheme.ApplyWindowTheme(this);
        AllowDrop = true;
        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) _ = ImportAsync(paths);
        };

        var root = new DockPanel { Margin = new Thickness(16) };
        var intro = new TextBlock
        {
            Text = "Wybierz plik i drukarki. Wyślij teraz — rozpocznij druk, gdy stół będzie gotowy. Albo dodaj do kolejki. 3MF trafia na Bambu Lab, G-code na Klipper, Prusa i OctoPrint.",
            Foreground = GTheme.Brush(GTheme.Secondary), FontSize = 11, Margin = new Thickness(0, 0, 0, 10),
        };
        DockPanel.SetDock(intro, Dock.Top); root.Children.Add(intro);

        _notice.Foreground = GTheme.Brush(GTheme.Secondary);
        _notice.Margin = new Thickness(0, 8, 0, 0);
        DockPanel.SetDock(_notice, Dock.Bottom); root.Children.Add(_notice);

        var jobs = Card(Scroll(_history));
        jobs.Height = 220;
        DockPanel.SetDock(jobs, Dock.Bottom); root.Children.Add(jobs);

        var actions = new DockPanel { Margin = new Thickness(0, 10, 0, 10), LastChildFill = false };
        var add = MakeButton("＋ Dodaj pliki…", ChooseFiles);
        var send = MakeButton("Wyślij do zaznaczonych", SendSelected);
        var refresh = MakeButton("Odśwież AMS", RefreshDetails);
        DockPanel.SetDock(add, Dock.Left);
        actions.Children.Add(add);
        actions.Children.Add(new TextBlock { Text = "  Przeciągnij pocięty plik .3mf lub .gcode do tego okna", Foreground = GTheme.Brush(GTheme.Muted),
                                             FontSize = 10.5, VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(send, Dock.Right); DockPanel.SetDock(refresh, Dock.Right);
        actions.Children.Add(send); actions.Children.Add(refresh);
        DockPanel.SetDock(actions, Dock.Bottom); root.Children.Add(actions);

        var columns = new Grid();
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        var left = Card(Scroll(_library)); var middle = Card(Scroll(_details)); var right = Card(Scroll(_destinations));
        middle.Margin = new Thickness(10, 0, 10, 0);
        Grid.SetColumn(middle, 1); Grid.SetColumn(right, 2);
        columns.Children.Add(left); columns.Children.Add(middle); columns.Children.Add(right);
        root.Children.Add(columns);

        Content = root;
        _farmStore.Changed += OnChanged;
        Closed += (_, _) => _farmStore.Changed -= OnChanged;
        _farmStore.Printers.Updated += OnPrintersUpdated;
        Closed += (_, _) => _farmStore.Printers.Updated -= OnPrintersUpdated;
        RefreshFiles(); RefreshDetails(); RefreshHistory();
    }

    private void OnChanged()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(OnChanged); return; }
        _notice.Text = _farmStore.Notice;
        foreach (var (id, value) in _farmStore.Progress)
            if (_progressLabels.TryGetValue(id, out var label)) label.Text = $"Wysyłanie: {(int)(value * 100)}%";
        RefreshHistory();
    }

    private void OnPrintersUpdated(object? sender, EventArgs e)
    {
        var ids = _farmStore.Printers.Printers.Where(p => PrinterFileTransfer.FarmSupports(p.Kind)).Select(p => p.Serial).ToList();
        if (!ids.SequenceEqual(_printerIds)) RefreshDetails();
    }

    // Building blocks

    private static Button MakeButton(string text, Action onClick)
    {
        var button = new Button { Content = text, Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(4, 0, 0, 0), FontSize = 11.5 };
        button.Click += (_, _) => onClick();
        return button;
    }

    private static TextBlock Label(string text, double size = 12, bool bold = false) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 2),
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = GTheme.Brush(bold ? GTheme.Text : GTheme.Secondary),
    };

    private static TextBlock Section(string text) => new()
    {
        Text = text, FontSize = 10, FontWeight = FontWeights.Bold, Foreground = GTheme.Brush(GTheme.Muted),
        Margin = new Thickness(0, 4, 0, 6),
    };

    private static ScrollViewer Scroll(StackPanel content) => new()
    {
        Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
    };

    private static Border Card(UIElement child) => new()
    {
        Background = GTheme.Brush(GTheme.CardTranslucent), BorderBrush = GTheme.Brush(GTheme.Line),
        BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(12), Child = child,
    };

    private static Border Box(UIElement child) => new()
    {
        BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8),
        Padding = new Thickness(10), Margin = new Thickness(0, 0, 0, 8), Child = child,
    };

    // Files

    private void ChooseFiles()
    {
        var dialog = new OpenFileDialog { Multiselect = true, Filter = "3MF, G-code|*.3mf;*.gcode;*.gco;*.g;*.bgcode|3MF|*.3mf|G-code|*.gcode;*.gco;*.g;*.bgcode" };
        if (dialog.ShowDialog(this) == true) _ = ImportAsync(dialog.FileNames);
    }

    private async Task ImportAsync(IEnumerable<string> paths)
    {
        foreach (var path in paths) await _farmStore.ImportAsync(path);
        _selected = _farmStore.Files.LastOrDefault()?.Id;
        _plateIndex = _farmStore.Files.LastOrDefault()?.Plates.FirstOrDefault()?.Index ?? 1;
        RefreshFiles(); RefreshDetails();
    }

    private void RefreshFiles()
    {
        _library.Children.Clear();
        _library.Children.Add(Section("PLIKI"));
        _selected ??= _farmStore.Files.FirstOrDefault()?.Id;
        foreach (var file in _farmStore.Files)
        {
            var button = new Button
            {
                Content = (_selected == file.Id ? "● " : "") + file.Name, HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(8, 5, 8, 5), ToolTip = file.Name, FontWeight = _selected == file.Id ? FontWeights.SemiBold : FontWeights.Normal,
            };
            var id = file.Id;
            button.Click += (_, _) => { _selected = id; _plateIndex = file.Plates.FirstOrDefault()?.Index ?? 1; RefreshFiles(); RefreshDetails(); };
            _library.Children.Add(button);
            _library.Children.Add(Label((file.IsGcode ? "G-code" : $"Płyty: {file.Plates.Count}") + $" · {file.Bytes / 1024.0 / 1024.0:0.0} MB", 11));
        }
        if (_farmStore.Files.Count == 0) _library.Children.Add(Label("Dodaj plik z Bambu Studio:\nPlik → Eksportuj → Eksportuj pociętą płytę.\nAlbo G-code z PrusaSlicera, Orki lub Cury."));
    }

    private (FarmFile File, FarmPlate Plate)? Selection
    {
        get
        {
            var file = _farmStore.Files.FirstOrDefault(f => f.Id == _selected);
            var plate = file?.Plates.FirstOrDefault(p => p.Index == _plateIndex) ?? file?.Plates.FirstOrDefault();
            return file is null || plate is null ? null : (file, plate);
        }
    }

    // Plate and printers

    private void RefreshDetails()
    {
        _details.Children.Clear(); _destinations.Children.Clear(); _targets.Clear(); _mappings.Clear();
        _printerIds = _farmStore.Printers.Printers.Where(p => PrinterFileTransfer.FarmSupports(p.Kind)).Select(p => p.Serial).ToList();
        _details.Children.Add(Section("PODGLĄD PŁYTY"));
        if (Selection is not { } selection)
        {
            _details.Children.Add(Label("Dodaj pocięty plik 3MF lub G-code, aby zobaczyć płytę, materiały i czas druku."));
            return;
        }
        var (file, plate) = selection;
        _plateIndex = plate.Index;
        _details.Children.Add(Label(file.Name, 13, true));
        var plates = new ComboBox { Margin = new Thickness(0, 4, 0, 6) };
        foreach (var p in file.Plates) plates.Items.Add($"Płyta {p.Index}");
        plates.SelectedIndex = file.Plates.FindIndex(p => p.Index == plate.Index);
        plates.SelectionChanged += (_, _) => { if (plates.SelectedIndex >= 0) { _plateIndex = file.Plates[plates.SelectedIndex].Index; RefreshDetails(); } };
        if (!file.IsGcode) _details.Children.Add(plates);
        string preview = _farmStore.PreviewPath(file.Id, plate.Index);
        if (File.Exists(preview))
        {
            try
            {
                var image = new BitmapImage();
                image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.UriSource = new Uri(preview); image.EndInit();
                _details.Children.Add(new Image { Source = image, Height = 170, Stretch = Stretch.Uniform, Margin = new Thickness(0, 4, 0, 6) });
            }
            catch { _details.Children.Add(Label("Plik nie zawiera miniatury tej płyty.")); }
        }
        else _details.Children.Add(Label("Plik nie zawiera miniatury tej płyty."));
        if (plate.Seconds is { } seconds) _details.Children.Add(Label($"Czas według slicera: {seconds / 3600} h {seconds % 3600 / 60} min"));
        _details.Children.Add(Label($"Profil: {plate.PrinterModel ?? "nie podano"} · dysza: {(plate.Nozzle is { } n ? n.ToString(CultureInfo.InvariantCulture) + " mm" : "nie podano")}"));
        foreach (var f in plate.Filaments) _details.Children.Add(Label($"Filament {f.Id}: {f.Material} · {f.Color} · {f.Grams:0.0} g"));

        _details.Children.Add(Section("KOLEJKA"));
        var copies = new TextBox { Text = _copies.ToString(CultureInfo.InvariantCulture), Width = 44, TextAlignment = TextAlignment.Center, Margin = new Thickness(6, 0, 6, 0) };
        copies.TextChanged += (_, _) => { if (int.TryParse(copies.Text, out var value)) _copies = Math.Clamp(value, 1, 99); };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new TextBlock { Text = "Kopie:", VerticalAlignment = VerticalAlignment.Center, Foreground = GTheme.Brush(GTheme.Text) });
        row.Children.Add(copies);
        row.Children.Add(MakeButton("Dodaj do kolejki…", ConfirmEnqueue));
        _details.Children.Add(row);
        _details.Children.Add(Label(file.IsGcode
            ? "Kolejka wysyła kopie G-code tylko na zaznaczone drukarki oznaczone „Stół pusty” i sama uruchamia druk."
            : "Kolejka wysyła kopie na drukarki oznaczone „Stół pusty”, z pasującym materiałem i kolorem w AMS, i sama uruchamia druk.", 11));

        _destinations.Children.Add(Section("DRUKARKI"));
        foreach (var printer in _farmStore.Printers.Printers.Where(p => PrinterFileTransfer.FarmSupports(p.Kind) && PrinterFileTransfer.Accepts(p.Kind, file.FileExtension)))
        {
            var box = new StackPanel();
            var check = new CheckBox { Content = printer.Name, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Text) };
            _targets[printer.Serial] = check;
            box.Children.Add(check);
            _farmStore.Printers.Telemetry.TryGetValue(printer.Serial, out var t);
            box.Children.Add(Label(t?.State.ToString() ?? "Offline", 11));
            var arm = new CheckBox { Content = "Stół pusty — kolejka może startować", IsChecked = _farmStore.Armed.Contains(printer.Serial),
                                     Foreground = GTheme.Brush(GTheme.Text), FontSize = 11, Margin = new Thickness(0, 2, 0, 4) };
            string serial = printer.Serial;
            arm.Click += (_, _) =>
            {
                if (arm.IsChecked == true)
                {
                    try { _farmStore.Arm(serial); }
                    catch (Exception ex) { arm.IsChecked = false; _notice.Text = ex.Message; }
                }
                else _farmStore.Disarm(serial);
            };
            box.Children.Add(arm);
            var choices = new Dictionary<int, ComboBox>();
            // G-code carries its own filament choice: there is no AMS slot to pick.
            foreach (var f in file.IsGcode ? new List<FarmFilament>() : plate.Filaments)
            {
                box.Children.Add(Label($"Filament {f.Id} · {f.Material}", 11));
                var combo = new ComboBox { Margin = new Thickness(0, 0, 0, 4) };
                combo.Items.Add(new ComboBoxItem { Content = "Wybierz źródło…", Tag = -2 });
                if (plate.Filaments.Count == 1) combo.Items.Add(new ComboBoxItem { Content = "Szpula zewnętrzna", Tag = -1 });
                foreach (var slot in t?.AmsSlots ?? new List<AmsSlot>())
                    if (FarmRules.SlotIndex(slot.Id) is { } index && slot.Material != "—")
                        combo.Items.Add(new ComboBoxItem { Content = $"{slot.Label} · {slot.Material} · {slot.ColorHex[..Math.Min(6, slot.ColorHex.Length)]}", Tag = index });
                combo.SelectedIndex = 0;
                choices[f.Id] = combo;
                box.Children.Add(combo);
            }
            _mappings[printer.Serial] = choices;
            _destinations.Children.Add(Box(box));
        }
        if (!_farmStore.Printers.Printers.Any(p => PrinterFileTransfer.Accepts(p.Kind, file.FileExtension)))
            _destinations.Children.Add(Label(file.IsGcode ? "Dodaj drukarkę Klipper, Prusa lub OctoPrint w Gantry." : "Dodaj drukarkę Bambu Lab w Gantry."));
    }

    private void SendSelected()
    {
        if (Selection is not { } selection) return;
        var (file, plate) = selection;
        var targets = _farmStore.Printers.Printers.Where(p => _targets.TryGetValue(p.Serial, out var c) && c.IsChecked == true).ToList();
        if (targets.Count == 0) { _notice.Text = "Zaznacz co najmniej jedną drukarkę."; return; }
        var plans = new List<(SavedPrinter Printer, List<int> Mapping)>();
        foreach (var printer in targets)
        {
            var options = _mappings.TryGetValue(printer.Serial, out var m) ? m : new Dictionary<int, ComboBox>();
            if (options.Values.Any(c => (c.SelectedItem as ComboBoxItem)?.Tag is -2)) { _notice.Text = $"Wybierz źródła filamentów dla {printer.Name}."; return; }
            var mapping = Enumerable.Repeat(-1, file.IsGcode || plate.Filaments.Count == 0 ? 0 : plate.Filaments.Max(f => f.Id)).ToList();
            foreach (var f in file.IsGcode ? new List<FarmFilament>() : plate.Filaments)
                mapping[f.Id - 1] = options.TryGetValue(f.Id, out var combo) && (combo.SelectedItem as ComboBoxItem)?.Tag is int tag ? tag : -1;
            if (mapping.All(v => v == -1)) mapping = new List<int>();
            plans.Add((printer, mapping));
        }
        var errors = new List<string>();
        foreach (var (printer, mapping) in plans)
        {
            try { _farmStore.Upload(file, plate, printer, mapping); }
            catch (Exception ex) { errors.Add($"{printer.Name}: {ex.Message}"); }
        }
        _notice.Text = errors.Count == 0 ? $"Rozpoczęto wysyłanie do {plans.Count} drukarek. Druk uruchomisz osobno." : string.Join("\n", errors);
    }

    private void ConfirmEnqueue()
    {
        if (Selection is not { } selection) return;
        var (file, plate) = selection;
        var targets = _farmStore.Printers.Printers.Where(p => PrinterFileTransfer.Accepts(p.Kind, file.FileExtension) && _targets.TryGetValue(p.Serial, out var c) && c.IsChecked == true).ToList();
        if (file.IsGcode && targets.Count == 0) { _notice.Text = "Zaznacz drukarki, pod które pocięto ten G-code."; return; }
        string where = targets.Count == 0 ? "dowolna drukarka Bambu Lab" : "tylko: " + string.Join(", ", targets.Select(p => p.Name));
        if (!Confirm($"Dodać do kolejki {_copies} × {file.Name}?",
                     (file.IsGcode ? "G-code · " : $"Płyta {plate.Index} · ") + where + (file.IsGcode
                         ? "\nKopia trafi na drukarkę dopiero, gdy oznaczysz jej stół jako pusty. Druk startuje wtedy sam."
                         : "\nKopia trafi na drukarkę dopiero, gdy oznaczysz jej stół jako pusty, a w AMS będzie ten sam materiał w podobnym kolorze. Druk startuje wtedy sam."),
                     "Dodaj do kolejki", new[] { "Profil pliku i dysza pasują do tych drukarek" })) return;
        try { _farmStore.Enqueue(file, plate, _copies, targets.Select(p => p.Serial).ToList()); }
        catch (Exception ex) { _notice.Text = ex.Message; }
    }

    /// A question with checkboxes that all have to be ticked before the action button works.
    private bool Confirm(string title, string detail, string action, string[] checks)
    {
        var dialog = new Window
        {
            Title = title, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = GTheme.Brush(GTheme.Canvas),
        };
        var stack = new StackPanel { Margin = new Thickness(18), MaxWidth = 440 };
        stack.Children.Add(Label(title, 14, true));
        stack.Children.Add(Label(detail));
        var boxes = checks.Select(text => new CheckBox { Content = text, Foreground = GTheme.Brush(GTheme.Text), Margin = new Thickness(0, 6, 0, 0) }).ToList();
        boxes.ForEach(box => stack.Children.Add(box));
        var ok = new Button { Content = action, IsDefault = true, Padding = new Thickness(12, 4, 12, 4), IsEnabled = false };
        var cancel = new Button { Content = "Anuluj", IsCancel = true, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(6, 0, 0, 0) };
        foreach (var box in boxes) box.Click += (_, _) => ok.IsEnabled = boxes.All(b => b.IsChecked == true);
        ok.Click += (_, _) => dialog.DialogResult = true;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(ok); buttons.Children.Add(cancel);
        stack.Children.Add(buttons);
        dialog.Content = stack;
        GTheme.ApplyWindowTheme(dialog);
        return dialog.ShowDialog() == true;
    }

    // Queue and jobs

    private void RefreshHistory()
    {
        _history.Children.Clear(); _progressLabels.Clear();
        if (_farmStore.Queue.Count > 0)
        {
            _history.Children.Add(Section($"KOLEJKA · {_farmStore.Queue.Sum(item => item.Copies)} SZT."));
            var names = _farmStore.Printers.Printers.GroupBy(p => p.Serial).ToDictionary(g => g.Key, g => g.First().Name);
            for (int i = 0; i < _farmStore.Queue.Count; i++)
            {
                var item = _farmStore.Queue[i];
                string where = item.Printers.Count == 0 ? "dowolna drukarka" : string.Join(", ", item.Printers.Select(s => names.TryGetValue(s, out var n) ? n : s));
                var row = new DockPanel();
                var remove = MakeButton("Usuń", () => _farmStore.RemoveFromQueue(item.Id));
                var up = MakeButton("↑", () => _farmStore.MoveUp(item.Id)); up.IsEnabled = i > 0;
                DockPanel.SetDock(remove, Dock.Right); DockPanel.SetDock(up, Dock.Right);
                row.Children.Add(remove); row.Children.Add(up);
                row.Children.Add(Label($"{i + 1}. {item.FileName} · płyta {item.Plate.Index} × {item.Copies} · {where}", 12, true));
                _history.Children.Add(Box(row));
            }
        }
        _history.Children.Add(Section("TRANSFERY I WYDRUKI"));
        if (_farmStore.Jobs.Count == 0) _history.Children.Add(Label("Tutaj pojawią się wysłane pliki i potwierdzenia uruchomienia."));
        foreach (var job in _farmStore.Jobs.Take(100))
        {
            var box = new StackPanel();
            box.Children.Add(Label($"{job.PrinterName} · {job.FileName} · płyta {job.Plate.Index}", 13, true));
            var message = Label(job.Message);
            _progressLabels[job.Id] = message;
            box.Children.Add(message);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            if (job.State == FarmJobState.Uploaded) buttons.Children.Add(MakeButton("Rozpocznij druk…", () => ConfirmStart(job)));
            if (job.State == FarmJobState.Uploading) buttons.Children.Add(MakeButton("Anuluj transfer", () => _farmStore.Cancel(job.Id)));
            if (job.State == FarmJobState.Uncertain) buttons.Children.Add(MakeButton("Sprawdziłem drukarkę…", () =>
            {
                if (Confirm("Zamknąć niepotwierdzone zadanie?", $"Potwierdź, że sprawdziłeś stan {job.PrinterName}. Nie wyślemy ponownie polecenia startu.",
                            "Sprawdziłem — zamknij zadanie", Array.Empty<string>())) _farmStore.Resolve(job.Id);
            }));
            if (buttons.Children.Count > 0) box.Children.Add(buttons);
            _history.Children.Add(Box(box));
        }
    }

    private void ConfirmStart(FarmJob job)
    {
        if (_farmStore.BlockReason(job) is { } reason) { _notice.Text = reason; return; }
        if (!Confirm($"Rozpocząć druk na {job.PrinterName}?",
                     $"{job.FileName} · płyta {job.Plate.Index}\nPrzed startem sprawdź materiał oraz profil modelu i dyszy. Poziomowanie stołu: włączone.",
                     "Rozpocznij druk", new[] { "Stół jest pusty i przygotowany", "Profil pliku, dysza i materiał pasują do drukarki" })) return;
        try { _farmStore.Start(job.Id, true, true); } catch (Exception ex) { _notice.Text = ex.Message; }
    }
}
