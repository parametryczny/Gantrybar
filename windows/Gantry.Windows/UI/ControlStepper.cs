using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>A setpoint the user nudges, drawn as one inset capsule [ − | value | + ] that belongs to
/// the tile it sits in. Mirrors macOS ControlStepperView: a 28 px capsule with 26 px ends, values
/// snapped to the step grid, holding a button repeats, the command goes out once the value settles
/// (0.6 s), and for 6 s telemetry still carrying the old setpoint is ignored so the number does not
/// jump back while the printer catches up.</summary>
internal sealed class ControlStepper : Border
{
    public const double CapsuleHeight = 28;
    public const double ButtonWidth = 26;
    public const double Radius = 8;
    private static readonly TimeSpan SettleDelay = TimeSpan.FromMilliseconds(600);
    private static readonly TimeSpan EchoWindow = TimeSpan.FromSeconds(6);

    public event Action<int>? Commit;
    private readonly int _min, _max, _step;
    private readonly bool _targetCaption;
    private readonly string _suffix;
    private readonly RepeatButton _minus, _plus;
    private readonly Path _minusGlyph, _plusGlyph;
    private readonly TextBlock _value;
    private readonly DispatcherTimer _settle;
    private DateTime _ignoreReportsUntil = DateTime.MinValue;
    private int _current;

    public ControlStepper(int min, int max, int step, bool targetCaption, string suffix)
    {
        _min = min; _max = max; _step = step; _targetCaption = targetCaption; _suffix = suffix;
        Height = CapsuleHeight;
        CornerRadius = new CornerRadius(Radius);
        BorderThickness = new Thickness(1);
        BorderBrush = GTheme.Brush(GTheme.Line);
        Background = GTheme.IsLight ? GTheme.Brush(GTheme.W(0.05)) : new SolidColorBrush(Color.FromArgb(0x3D, 0, 0, 0));
        // The hover fill of each end has to follow the rounded corners, not poke out past them.
        SizeChanged += (_, e) => Clip = new RectangleGeometry(new Rect(e.NewSize), Radius, Radius);

        (_minus, _minusGlyph) = StepButton("M0,5 L10,5", AppSettings.T("Decrease"));
        (_plus, _plusGlyph) = StepButton("M5,0 L5,10 M0,5 L10,5", AppSettings.T("Increase"));
        _minus.Click += (_, _) => Nudge(-1);
        _plus.Click += (_, _) => Nudge(1);
        _value = new TextBlock
        {
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(2, 0, 2, 0)
        };
        Typography.SetNumeralAlignment(_value, FontNumeralAlignment.Tabular);

        var grid = new Grid();
        foreach (var width in new[] { new GridLength(ButtonWidth), new GridLength(1), new GridLength(1, GridUnitType.Star), new GridLength(1), new GridLength(ButtonWidth) })
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        grid.Children.Add(_minus);
        var leftRule = Rule(); Grid.SetColumn(leftRule, 1); grid.Children.Add(leftRule);
        Grid.SetColumn(_value, 2); grid.Children.Add(_value);
        var rightRule = Rule(); Grid.SetColumn(rightRule, 3); grid.Children.Add(rightRule);
        Grid.SetColumn(_plus, 4); grid.Children.Add(_plus);
        Child = grid;

        _settle = new DispatcherTimer { Interval = SettleDelay };
        _settle.Tick += (_, _) => SendNow();
        // Closing the details right after a click must not swallow the change.
        Unloaded += (_, _) => { if (_settle.IsEnabled) SendNow(); };
        ApplyValue(min);
    }

    /// <summary>The printer's own setpoint. Held back while the user is still stepping and just after
    /// a command, unless the printer already reports the value that was sent.</summary>
    public void Show(int reported)
    {
        if (_settle.IsEnabled) return;
        if (DateTime.UtcNow < _ignoreReportsUntil)
        {
            if (Clamp(reported) == _current) _ignoreReportsUntil = DateTime.MinValue;
            return;
        }
        ApplyValue(reported);
    }

    /// <summary>A fan or the print speed as a tile: what it is on top, its capsule below. Same surface,
    /// border and radius as the temperature tiles, so the two cards read as one set.</summary>
    public static Border Tile(string title, string glyph, ControlStepper stepper)
    {
        var titleRow = new StackPanel
        {
            Orientation = Orientation.Horizontal, Margin = new Thickness(3, 1, 0, 7),
            Children =
            {
                new TextBlock { Text = glyph, FontSize = 10, Foreground = GTheme.Brush(GTheme.Muted), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) },
                new TextBlock { Text = title.ToUpper(CultureInfo.CurrentCulture), FontSize = 9, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(GTheme.Muted), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis }
            }
        };
        return new Border
        {
            Background = GTheme.Brush(GTheme.Surface), BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(GTheme.TileRadius), Padding = new Thickness(6),
            Child = new StackPanel { Children = { titleRow, stepper } }
        };
    }

    private void Nudge(int direction)
    {
        // Onto the step grid first, so 223° goes to 225° and 220°, not 228° and 218°.
        int next = direction > 0 ? (_current / _step + 1) * _step : ((_current + _step - 1) / _step - 1) * _step;
        ApplyValue(next);
        _settle.Stop();
        _settle.Start();
    }

    private void SendNow()
    {
        _settle.Stop();
        _ignoreReportsUntil = DateTime.UtcNow + EchoWindow;
        Commit?.Invoke(_current);
    }

    private int Clamp(int candidate) => Math.Min(_max, Math.Max(_min, candidate));

    private void ApplyValue(int candidate)
    {
        _current = Clamp(candidate);
        _minus.IsEnabled = _current > _min;
        _plus.IsEnabled = _current < _max;
        var live = GTheme.Brush(GTheme.Text);
        var spent = GTheme.Brush(GTheme.With(GTheme.Muted, 0.55));
        _minusGlyph.Stroke = _minus.IsEnabled ? live : spent;
        _plusGlyph.Stroke = _plus.IsEnabled ? live : spent;

        _value.Inlines.Clear();
        var caption = _targetCaption ? AppSettings.T("Target").ToLower(CultureInfo.CurrentCulture) + " " : "";
        if (caption.Length > 0)
            _value.Inlines.Add(new Run(caption) { FontSize = 9, FontWeight = FontWeights.Medium, Foreground = GTheme.Brush(GTheme.Secondary) });
        bool off = _targetCaption && _current == 0;
        var reading = off ? AppSettings.T("Off").ToLower(CultureInfo.CurrentCulture) : $"{_current}{_suffix}";
        _value.Inlines.Add(new Run(reading) { FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = GTheme.Brush(off ? GTheme.Secondary : GTheme.Text) });
        AutomationProperties.SetName(this, caption + reading);
    }

    private static (RepeatButton Button, Path Glyph) StepButton(string data, string label)
    {
        var glyph = new Path
        {
            Data = Geometry.Parse(data), Width = 10, Height = 10, StrokeThickness = 1.8,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, SnapsToDevicePixels = true
        };
        var button = new RepeatButton { Content = glyph, Delay = 400, Interval = 70, Cursor = Cursors.Hand, Template = StepTemplate() };
        AutomationProperties.SetName(button, label);
        return (button, glyph);
    }

    private static Rectangle Rule() => new() { Width = 1, Fill = GTheme.Brush(GTheme.Line), Margin = new Thickness(0, 6, 0, 6) };

    // Flat end: no chrome at rest, a faint fill on hover and a stronger one while pressed.
    private static ControlTemplate StepTemplate()
    {
        static string Hex(Color c) => $"#{c.A:X2}{c.R:X2}{c.G:X2}{c.B:X2}";
        var xaml = $@"<ControlTemplate xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation"" xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml"" TargetType=""RepeatButton"">
  <Border x:Name=""Bg"" Background=""Transparent""><ContentPresenter HorizontalAlignment=""Center"" VerticalAlignment=""Center""/></Border>
  <ControlTemplate.Triggers>
    <Trigger Property=""IsMouseOver"" Value=""True""><Setter TargetName=""Bg"" Property=""Background"" Value=""{Hex(GTheme.W(0.08))}""/></Trigger>
    <Trigger Property=""IsPressed"" Value=""True""><Setter TargetName=""Bg"" Property=""Background"" Value=""{Hex(GTheme.W(0.16))}""/></Trigger>
    <Trigger Property=""IsEnabled"" Value=""False""><Setter TargetName=""Bg"" Property=""Background"" Value=""Transparent""/></Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>";
        return (ControlTemplate)XamlReader.Parse(xaml);
    }
}
