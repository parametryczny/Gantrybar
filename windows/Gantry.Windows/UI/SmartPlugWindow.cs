using System.Windows;
using System.Windows.Controls;
using Gantry.Models;
using Gantry.Services;

namespace Gantry.UI;

/// Setting up the socket that feeds one printer, with buttons that switch it for real, so a wrong IP
/// or outlet number shows up here rather than in an emergency. Mirrors the macOS window.
public sealed class SmartPlugWindow : Window
{
    private readonly PrinterStore _store;
    private readonly string _serial;
    private readonly ComboBox _kind = new();
    private readonly TextBox _host = new();
    private readonly TextBox _channel = new();
    private readonly TextBox _entity = new();
    private readonly TextBox _onUrl = new();
    private readonly TextBox _offUrl = new();
    private readonly TextBox _user = new();
    private readonly PasswordBox _secret = new();
    private readonly TextBox _autoOff = new();
    private readonly CheckBox _emergency = new();
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    private readonly Dictionary<FrameworkElement, (TextBlock Label, FrameworkElement Field)> _rows = new();
    private readonly Grid _grid = new();

    public SmartPlugWindow(PrinterStore store, string serial)
    {
        _store = store;
        _serial = serial;
        string name = store.Printers.FirstOrDefault(p => p.Serial == serial)?.Name ?? serial;
        Title = AppSettings.T("Smart socket — {0}").Replace("{0}", name);
        Width = 520; SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ResizeMode = ResizeMode.NoResize;
        Background = GTheme.Brush(GTheme.Canvas);
        Foreground = GTheme.Brush(GTheme.Text);
        GTheme.ApplyWindowTheme(this);

        var stack = new StackPanel { Margin = new Thickness(20) };
        stack.Children.Add(new TextBlock
        {
            Text = AppSettings.T("The socket or power-strip outlet this printer is plugged into. Gantry switches it from the card, from automations, from Telegram, and all at once with Emergency power-off."),
            TextWrapping = TextWrapping.Wrap, Foreground = GTheme.Brush(GTheme.Secondary), FontSize = 11.5, Margin = new Thickness(0, 0, 0, 12),
        });

        foreach (var kind in SmartPlug.Kinds) _kind.Items.Add(SmartPlug.KindTitle(kind));
        _kind.SelectionChanged += (_, _) => KindChanged();
        _channel.ToolTip = "1";
        _entity.ToolTip = "switch.p1s_zasilanie";
        _onUrl.ToolTip = "http://192.168.1.60/on";
        _offUrl.ToolTip = "http://192.168.1.60/off";
        _user.ToolTip = "admin";
        _autoOff.ToolTip = AppSettings.T("never");
        _emergency.Content = AppSettings.T("Include in Emergency power-off");
        _emergency.Foreground = GTheme.Brush(GTheme.Text);

        _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        AddRow(AppSettings.T("Type"), _kind);
        AddRow(AppSettings.T("Address"), _host);
        AddRow(AppSettings.T("Outlet"), _channel);
        AddRow(AppSettings.T("Entity"), _entity);
        AddRow(AppSettings.T("URL to switch on"), _onUrl);
        AddRow(AppSettings.T("URL to switch off"), _offUrl);
        AddRow(AppSettings.T("Login"), _user);
        AddRow(AppSettings.T("Password / token"), _secret);
        AddRow(AppSettings.T("Switch off after print (min)"), _autoOff);
        AddRow("", _emergency);
        stack.Children.Add(_grid);

        Button Make(string text, Action onClick, double left = 0)
        {
            var button = new Button { Content = text, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(left, 0, 0, 0) };
            button.Click += (_, _) => onClick();
            return button;
        }
        var tests = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        tests.Children.Add(Make(AppSettings.T("Switch on"), () => Run(true)));
        tests.Children.Add(Make(AppSettings.T("Switch off"), () => { if (ConfirmBusy()) Run(false); }, 6));
        tests.Children.Add(Make(AppSettings.T("Read state"), () => Run(null), 6));
        stack.Children.Add(tests);
        _status.Foreground = GTheme.Brush(GTheme.Secondary);
        stack.Children.Add(_status);

        var buttons = new DockPanel { Margin = new Thickness(0, 16, 0, 0), LastChildFill = false };
        var remove = Make(AppSettings.T("Remove socket"), () => { SmartPlugStore.Set(_serial, null, null); Close(); });
        DockPanel.SetDock(remove, Dock.Left);
        var save = Make(AppSettings.T("Save"), Save, 6);
        save.IsDefault = true;
        var close = Make(AppSettings.T("Close"), Close);
        close.IsCancel = true;
        DockPanel.SetDock(save, Dock.Right);
        DockPanel.SetDock(close, Dock.Right);
        buttons.Children.Add(remove);
        buttons.Children.Add(save);
        buttons.Children.Add(close);
        stack.Children.Add(buttons);

        PanelWindow.Wrap(this, AppSettings.T("Smart socket — {0}").Replace("{0}", name), stack);
        Load();
    }

    private void AddRow(string label, FrameworkElement field)
    {
        int row = _grid.RowDefinitions.Count;
        _grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var text = new TextBlock
        {
            Text = label, Foreground = GTheme.Brush(GTheme.Secondary), VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Right,
        };
        field.Margin = new Thickness(0, 4, 0, 4);
        Grid.SetRow(text, row); Grid.SetRow(field, row); Grid.SetColumn(field, 1);
        _grid.Children.Add(text); _grid.Children.Add(field);
        _rows[field] = (text, field);
    }

    private void Show(FrameworkElement field, bool visible)
    {
        var (label, element) = _rows[field];
        label.Visibility = element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
    }

    private string SelectedKind => SmartPlug.Kinds[Math.Max(0, _kind.SelectedIndex)];

    private void KindChanged()
    {
        string kind = SelectedKind;
        bool device = kind is "tasmota" or "shelly" or "shellyRPC";
        Show(_host, kind != "http");
        Show(_channel, device);
        Show(_entity, kind == "homeAssistant");
        Show(_onUrl, kind == "http");
        Show(_offUrl, kind == "http");
        Show(_user, device);
        Show(_secret, kind != "http");
        _rows[_host].Label.Text = kind == "homeAssistant" ? AppSettings.T("Home Assistant URL") : AppSettings.T("Address");
        _host.ToolTip = kind == "homeAssistant" ? "http://192.168.1.10:8123" : "192.168.1.60";
        _rows[_secret].Label.Text = kind == "homeAssistant" ? AppSettings.T("Access token") : AppSettings.T("Password");
    }

    private void Load()
    {
        var plug = SmartPlugStore.Plug(_serial) ?? new SmartPlug();
        _kind.SelectedIndex = Math.Max(0, Array.IndexOf(SmartPlug.Kinds, plug.Kind));
        _host.Text = plug.Host;
        _channel.Text = plug.Channel.ToString();
        _entity.Text = plug.EntityId ?? "";
        _onUrl.Text = plug.OnUrl ?? "";
        _offUrl.Text = plug.OffUrl ?? "";
        _user.Text = plug.Username ?? "";
        _secret.Password = SmartPlugStore.Secret(_serial) ?? "";
        _autoOff.Text = plug.AutoOffMinutes?.ToString() ?? "";
        _emergency.IsChecked = plug.IncludeInEmergency;
        KindChanged();
        if (SmartPlugStore.Plug(_serial) is null) _status.Text = AppSettings.T("No socket saved yet.");
    }

    private SmartPlug Current()
    {
        static string? Text(TextBox box) => string.IsNullOrWhiteSpace(box.Text) ? null : box.Text.Trim();
        return new SmartPlug
        {
            Kind = SelectedKind,
            Host = Text(_host) ?? "",
            Channel = int.TryParse(_channel.Text.Trim(), out var channel) ? Math.Max(1, channel) : 1,
            EntityId = Text(_entity),
            OnUrl = Text(_onUrl),
            OffUrl = Text(_offUrl),
            Username = Text(_user),
            AutoOffMinutes = int.TryParse(_autoOff.Text.Trim(), out var minutes) && minutes > 0 ? minutes : null,
            IncludeInEmergency = _emergency.IsChecked == true,
        };
    }

    private bool ConfirmBusy()
    {
        bool busy = _store.Telemetry.TryGetValue(_serial, out var t) && t.State is PrinterState.Printing or PrinterState.Paused;
        if (!busy) return true;
        return MessageBox.Show(this, AppSettings.T("Switching the socket off now ends the print."), AppSettings.T("The printer is printing"),
                               MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) == MessageBoxResult.OK;
    }

    private async void Run(bool? on)
    {
        var plug = Current();
        if (plug.Problem is { } problem) { _status.Text = problem; return; }
        string secret = _secret.Password;
        _status.Text = AppSettings.T("Talking to the socket…");
        try
        {
            bool? state = await Task.Run(() => plug.SendAsync(on, secret));
            _status.Text = state switch
            {
                true => AppSettings.T("The socket reports: on."),
                false => AppSettings.T("The socket reports: off."),
                null => on is null ? AppSettings.T("The socket answered but did not say whether it is on.")
                                   : AppSettings.T("Sent. The socket did not report its state."),
            };
        }
        catch (Exception ex) { _status.Text = ex.Message; }
    }

    private void Save()
    {
        var plug = Current();
        if (plug.Problem is { } problem) { _status.Text = problem; return; }
        SmartPlugStore.Set(_serial, plug, _secret.Password);
        Close();
    }
}
