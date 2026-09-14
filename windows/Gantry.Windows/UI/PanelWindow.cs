using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Gantry.UI;

/// <summary>One auxiliary panel in a window of its own, centred on the screen.
///
/// Slot assignment and maintenance were dimmed overlays inside the fleet panel. That cost more than
/// it bought: the panel could never be larger than its host, it blurred and disabled the cards the
/// user had just come to read, and the fleet panel had to be told by hand not to hide from under the
/// thing it had opened. Mirrors macOS PanelWindowController and Linux panelwindow.PanelWindow.
///
/// Every panel window follows the panelWindow contract in design/gantry-card-layout.impl.json: the
/// fleet panel's own identity, GANTRY · name, in a header strip under the system title bar, the
/// panel's own controls at its trailing end, and "Gantry · name" as the window title. The panels no
/// longer draw a title or a close button of their own.</summary>
internal sealed class PanelWindow : Window
{
    private readonly Action? _cleanup;

    /// <summary>"Gantry · Spoolbase". Title bar, taskbar and Alt+Tab all show this string; the header
    /// draws the same two parts with the wordmark. A middle dot, as in the fleet header.</summary>
    public static string WindowTitle(string name) => $"Gantry · {name}";

    /// <summary>The shared header strip: GANTRY · name on the leading edge, accessories trailing, a
    /// hairline under it.</summary>
    public static FrameworkElement Header(string name, IReadOnlyList<UIElement>? accessories = null)
    {
        var identity = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        // The fleet header's wordmark, a size down: this one shares the window with a title bar.
        identity.Children.Add(new TextBlock
        {
            Text = "GANTRY", FontSize = 15, FontWeight = FontWeights.Black,
            FontFamily = new FontFamily("Segoe UI Black, Segoe UI"),
            Foreground = GTheme.Brush(GTheme.Text), VerticalAlignment = VerticalAlignment.Center,
        });
        identity.Children.Add(new TextBlock
        {
            Text = "·", FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(7, 0, 7, 0),
            Foreground = GTheme.Brush(GTheme.Secondary), VerticalAlignment = VerticalAlignment.Center,
        });
        identity.Children.Add(new TextBlock
        {
            Text = name, FontSize = 14, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = GTheme.Brush(GTheme.Text), VerticalAlignment = VerticalAlignment.Center,
        });
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (accessories is not null)
            foreach (var accessory in accessories) trailing.Children.Add(accessory);
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(identity);
        Grid.SetColumn(trailing, 1);
        row.Children.Add(trailing);
        return new Border
        {
            Padding = new Thickness(16, 9, 12, 9), MinHeight = 44,
            BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(0, 0, 0, 1),
            Child = row,
        };
    }

    /// <summary>Puts the shared header above <paramref name="body"/> in <paramref name="window"/> and
    /// sets its title. For panels that were already Windows of their own (diagnostics, statistics,
    /// Spoolbase), so they wear exactly the frame a PanelWindow does.</summary>
    public static void Wrap(Window window, string name, FrameworkElement body, IReadOnlyList<UIElement>? accessories = null)
    {
        window.Title = WindowTitle(name);
        var header = Header(name, accessories);
        DockPanel.SetDock(header, Dock.Top);
        window.Content = new DockPanel { LastChildFill = true, Children = { header, body } };
    }

    /// <param name="scrolls">true only for content with no scroll viewer of its own. Wrapping content
    /// that already scrolls in a second scroll viewer hands the inner one infinite height, so it
    /// never scrolls and the outer one drags the panel's header off the top instead.</param>
    public PanelWindow(Window owner, FrameworkElement content, string name,
                       double width = 470, double height = 650, bool scrolls = false,
                       Action? cleanup = null, IReadOnlyList<UIElement>? accessories = null)
    {
        _cleanup = cleanup;
        Width = width;
        Height = height;
        MinWidth = Math.Min(360, width);
        MinHeight = Math.Min(240, height);
        // Centred on the screen, not on the owner: a panel centred on the fleet panel opens straight
        // on top of the cards, which is the thing the overlay did wrong.
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;
        // Owned by the fleet panel for two reasons: it always draws above it, and the panel's
        // Deactivated handler walks OwnedWindows and refuses to hide while any of them is visible.
        // Owner is only legal once the owner itself has been shown.
        if (owner.IsLoaded) Owner = owner;

        // The panel drew its own rounded card because it floated in a whole window's worth of dimmed
        // space. Here it is the window's content, so it fills it and the window carries the surface.
        content.Margin = new Thickness(0);
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        content.VerticalAlignment = VerticalAlignment.Stretch;
        // An explicit Width, Height or Max* beats Stretch in WPF, and both overlay panels pinned one
        // (maintenance 470x560, slot assignment its longest name and 440 tall). In a window they fill.
        content.Width = double.NaN;
        content.Height = double.NaN;
        content.MaxWidth = double.PositiveInfinity;
        content.MaxHeight = double.PositiveInfinity;
        if (content is Border card)
        {
            card.CornerRadius = new CornerRadius(0);
            card.BorderThickness = new Thickness(0);
        }
        FrameworkElement body;
        if (scrolls)
        {
            body = new ScrollViewer
            {
                Content = content,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                // Off on purpose, the same as the overlay it replaces: content slightly wider than
                // the window should lay out narrower, not grow a scrollbar across the bottom.
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Background = Brushes.Transparent,
                Padding = new Thickness(0),
            };
        }
        else
        {
            body = content;
        }
        Wrap(this, name, body, accessories);
        // After Content, not before: ApplyWindowTheme also walks the tree to theme fields and
        // buttons, and with Content still null there is nothing to walk.
        GTheme.ApplyWindowTheme(this);

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            Close();
        };
        Closed += (_, _) => _cleanup?.Invoke();
    }

    /// <summary>Shows the panel and brings it forward.</summary>
    public static PanelWindow Present(Window owner, FrameworkElement content, string name,
                                      double width = 470, double height = 650, bool scrolls = false,
                                      Action? cleanup = null, IReadOnlyList<UIElement>? accessories = null)
    {
        var window = new PanelWindow(owner, content, name, width, height, scrolls, cleanup, accessories);
        window.Show();
        window.Activate();
        return window;
    }
}
