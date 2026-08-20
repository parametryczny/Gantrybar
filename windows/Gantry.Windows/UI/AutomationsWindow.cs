using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// Per-printer automations editor: rules of trigger → action, including custom commands and scripts.
/// Mirrors the macOS AutomationsWindow. Saves on the "Zapisz" button.
public sealed class AutomationsWindow : Window
{
    private readonly PrinterStore _store;
    private readonly string _serial;
    private readonly bool _pl;
    private readonly StackPanel _list = new();
    private readonly List<Row> _rows = new();

    private static readonly (string pl, string en)[] TriggerNames =
        { ("Ręczny", "Manual"), ("Po warstwie", "At layer"), ("Po %", "At %"), ("Gdy stan", "On state") };
    private static readonly string[] TriggerKinds = { "manual", "layer", "progress", "state" };
    private static readonly (string pl, string en)[] ActionNames =
        { ("Światło wł.", "Light on"), ("Światło wył.", "Light off"), ("Pauza", "Pause"), ("Wznów", "Resume"),
          ("Stop", "Stop"), ("Powiadomienie", "Notification"), ("Własna komenda", "Custom command"), ("Skrypt", "Script") };
    private static readonly string[] ActionKinds = { "lightOn", "lightOff", "pause", "resume", "stop", "notify", "command", "script" };
    private static readonly PrinterState[] StateOptions =
        { PrinterState.Printing, PrinterState.Paused, PrinterState.Finished, PrinterState.Error, PrinterState.Idle };

    public AutomationsWindow(PrinterStore store, string serial)
    {
        _store = store;
        _serial = serial;
        _pl = AppSettings.Polish;
        Title = (_pl ? "Automatyzacje — " : "Automations — ") + (store.Printers.FirstOrDefault(p => p.Serial == serial)?.Name ?? serial);
        Width = 600; Height = 640; MinWidth = 520; MinHeight = 420;
        Background = new SolidColorBrush(Color.FromRgb(0x16, 0x16, 0x18));
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new DockPanel { Margin = new Thickness(16) };

        var addButton = new Button { Content = _pl ? "＋ Dodaj automatyzację" : "＋ Add automation", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 6, 12, 6) };
        addButton.Click += (_, _) => { AddRow(new PrinterAutomation { Name = _pl ? "Nowa automatyzacja" : "New automation", TriggerKind = "layer", TriggerValue = 1, ActionKind = "lightOff" }); };
        var saveButton = new Button { Content = _pl ? "Zapisz" : "Save", HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(14, 6, 14, 6) };
        saveButton.Click += (_, _) => Save();

        var header = new StackPanel();
        header.Children.Add(new TextBlock { Text = _pl ? "Automatyzacje" : "Automations", FontSize = 15, FontWeight = FontWeights.Bold, Foreground = White() });
        header.Children.Add(new TextBlock { Text = _pl ? "Wyzwalacz → akcja. Reguły warunkowe odpalają się raz na wydruk. Skrypty działają z Twoimi uprawnieniami." : "Trigger → action. Conditional rules fire once per print. Scripts run with your privileges.", FontSize = 11, Foreground = Muted(), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 8) });
        var topButtons = new Grid();
        topButtons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topButtons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topButtons.Children.Add(addButton);
        Grid.SetColumn(saveButton, 1); topButtons.Children.Add(saveButton);
        header.Children.Add(topButtons);
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _list, Margin = new Thickness(0, 10, 0, 0) };
        root.Children.Add(scroll);
        Content = root;

        foreach (var auto in AutomationStore.For(serial)) AddRow(auto);
    }

    private sealed class Row
    {
        public Border Root = null!;
        public string Id = "";
        public CheckBox Enabled = null!;
        public TextBox Name = null!;
        public ComboBox Trigger = null!;
        public TextBox TriggerValue = null!;
        public ComboBox State = null!;
        public ComboBox Action = null!;
        public TextBox ActionText = null!;

        public PrinterAutomation ToModel() => new()
        {
            Id = Id,
            Name = string.IsNullOrWhiteSpace(Name.Text) ? "Automatyzacja" : Name.Text,
            Enabled = Enabled.IsChecked == true,
            TriggerKind = TriggerKinds[Math.Max(0, Trigger.SelectedIndex)],
            TriggerValue = int.TryParse(TriggerValue.Text, out var v) ? v : 0,
            TriggerState = StateOptions[Math.Max(0, State.SelectedIndex)].ToString(),
            ActionKind = ActionKinds[Math.Max(0, Action.SelectedIndex)],
            ActionText = ActionText.Text
        };
    }

    private void AddRow(PrinterAutomation auto)
    {
        var row = new Row { Id = auto.Id };
        var stack = new StackPanel();

        row.Enabled = new CheckBox { IsChecked = auto.Enabled, VerticalAlignment = VerticalAlignment.Center };
        row.Name = new TextBox { Text = auto.Name, MinWidth = 180, VerticalAlignment = VerticalAlignment.Center };
        var runButton = new Button { Content = _pl ? "Uruchom" : "Run", Padding = new Thickness(10, 3, 10, 3) };
        runButton.Click += (_, _) => RunRow(row);
        var deleteButton = new Button { Content = "🗑", Padding = new Thickness(8, 3, 8, 3) };
        deleteButton.Click += (_, _) => { _list.Children.Remove(row.Root); _rows.Remove(row); Save(); };
        var topRow = new StackPanel { Orientation = Orientation.Horizontal };
        topRow.Children.Add(row.Enabled);
        topRow.Children.Add(new TextBlock { Text = " ", Width = 6 });
        topRow.Children.Add(row.Name);
        topRow.Children.Add(new TextBlock { Text = " ", Width = 8 });
        topRow.Children.Add(runButton);
        topRow.Children.Add(new TextBlock { Text = " ", Width = 4 });
        topRow.Children.Add(deleteButton);
        stack.Children.Add(topRow);

        row.Trigger = Combo(TriggerNames, Array.IndexOf(TriggerKinds, auto.TriggerKind));
        row.TriggerValue = new TextBox { Text = auto.TriggerValue.ToString(), Width = 70, VerticalAlignment = VerticalAlignment.Center };
        row.State = Combo(StateOptions.Select(s => (s.Label(_pl), s.Label(false))).ToArray(), Math.Max(0, Array.IndexOf(StateOptions.Select(s => s.ToString()).ToArray(), auto.TriggerState)));
        var trigRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        trigRow.Children.Add(new TextBlock { Text = _pl ? "Wyzwalacz: " : "Trigger: ", Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center });
        trigRow.Children.Add(row.Trigger);
        trigRow.Children.Add(new TextBlock { Text = " ", Width = 6 });
        trigRow.Children.Add(row.TriggerValue);
        trigRow.Children.Add(new TextBlock { Text = " ", Width = 6 });
        trigRow.Children.Add(row.State);
        stack.Children.Add(trigRow);

        row.Action = Combo(ActionNames, Array.IndexOf(ActionKinds, auto.ActionKind));
        var actRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        actRow.Children.Add(new TextBlock { Text = _pl ? "Akcja: " : "Action: ", Foreground = Muted(), VerticalAlignment = VerticalAlignment.Center });
        actRow.Children.Add(row.Action);
        stack.Children.Add(actRow);

        row.ActionText = new TextBox { Text = auto.ActionText, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 44, MaxHeight = 120, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 6, 0, 0), FontFamily = new FontFamily("Consolas") };
        stack.Children.Add(row.ActionText);

        row.Root = new Border { Background = new SolidColorBrush(Color.FromArgb(0x48, 0x3A, 0x3A, 0x3C)), CornerRadius = new CornerRadius(12), Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 12), Child = stack };
        _rows.Add(row);
        _list.Children.Add(row.Root);
    }

    private void RunRow(Row row)
    {
        var auto = row.ToModel();
        if (auto.IsScript && !ScriptRunner.IsRunning(auto.Id))
        {
            var confirm = MessageBox.Show(this,
                _pl ? "Skrypt uruchomi się z Twoimi uprawnieniami." : "The script will run with your privileges.",
                _pl ? $"Uruchomić skrypt „{auto.Name}”?" : $"Run script “{auto.Name}”?",
                MessageBoxButton.OKCancel);
            if (confirm != MessageBoxResult.OK) return;
        }
        if (auto.IsScript && ScriptRunner.IsRunning(auto.Id)) ScriptRunner.Stop(auto.Id);
        else _store.RunAutomation(auto, _serial);
    }

    private void Save()
    {
        AutomationStore.Set(_serial, _rows.Select(r => r.ToModel()).ToList());
    }

    private static ComboBox Combo((string pl, string en)[] items, int index)
    {
        bool pl = AppSettings.Polish;
        var box = new ComboBox { VerticalAlignment = VerticalAlignment.Center, MinWidth = 130 };
        foreach (var (p, e) in items) box.Items.Add(pl ? p : e);
        box.SelectedIndex = index < 0 ? 0 : index;
        return box;
    }

    private static Brush White() => new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF7));
    private static Brush Muted() => new SolidColorBrush(Color.FromRgb(0x8E, 0x8E, 0x93));
}
