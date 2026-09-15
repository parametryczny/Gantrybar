using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace Gantry.UI;

/// <summary>One line of text that scrolls to its end while hovered instead of being cut off, used for the
/// printer name and the file name on a card. Clipped at rest; while the pointer is over it the text slides
/// to its end and back, pausing at each end. Nothing moves unless someone points at it. Mirrors the macOS
/// MarqueeLabel and the GNU/Linux MarqueeLabel, step for step.</summary>
internal sealed class MarqueeText : Border
{
    private const double Step = 0.7;
    private const int StartPause = 18, EndPause = 22;
    private readonly TranslateTransform _shift = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1.0 / 60) };
    private double _offset, _direction = -1;
    private int _pause;

    /// <summary>The line itself, for its font, weight and colour.</summary>
    public TextBlock Label { get; } = new() { TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center };

    public MarqueeText()
    {
        ClipToBounds = true;
        Background = Brushes.Transparent;   // hit-testable across its whole width, not only over glyphs
        VerticalAlignment = VerticalAlignment.Center;
        Label.RenderTransform = _shift;
        // A horizontal StackPanel measures its child without a width limit, so the text keeps its full
        // length and the border clips it, instead of the text block trimming itself to the space.
        Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { Label } };
        MouseEnter += (_, _) => Start();
        MouseLeave += (_, _) => Reset();
        Unloaded += (_, _) => Reset();   // never leave a timer running for a card that went away
        _timer.Tick += (_, _) => Tick();
    }

    public string Text
    {
        get => Label.Text;
        set
        {
            if (Label.Text == value) return;
            Label.Text = value;
            Reset();
        }
    }

    private double Overflow => Math.Max(0, Label.ActualWidth - ActualWidth);

    private void Start()
    {
        if (_timer.IsEnabled || Overflow <= 4) return;
        _pause = StartPause;
        _timer.Start();
    }

    private void Tick()
    {
        if (_pause > 0) { _pause--; return; }
        double limit = Overflow;
        _offset += _direction * Step;
        if (_offset <= -limit) { _offset = -limit; _direction = 1; _pause = EndPause; }
        else if (_offset >= 0) { _offset = 0; _direction = -1; _pause = EndPause; }
        _shift.X = _offset;
    }

    private void Reset()
    {
        _timer.Stop();
        _offset = 0;
        _direction = -1;
        _pause = 0;
        _shift.X = 0;
    }
}
