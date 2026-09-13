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
/// thing it had opened. Mirrors macOS PanelWindowController and Linux panelwindow.PanelWindow.</summary>
internal sealed class PanelWindow : Window
{
    private readonly Action? _cleanup;

    /// <param name="scrolls">true only for content with no scroll viewer of its own. Wrapping content
    /// that already scrolls in a second scroll viewer hands the inner one infinite height, so it
    /// never scrolls and the outer one drags the panel's header off the top instead.</param>
    public PanelWindow(Window owner, FrameworkElement content, string title,
                       double width = 470, double height = 650, bool scrolls = false,
                       Action? cleanup = null)
    {
        _cleanup = cleanup;
        Title = title;
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
        if (scrolls)
        {
            Content = new ScrollViewer
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
            Content = content;
        }
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
    public static PanelWindow Present(Window owner, FrameworkElement content, string title,
                                      double width = 470, double height = 650, bool scrolls = false,
                                      Action? cleanup = null)
    {
        var window = new PanelWindow(owner, content, title, width, height, scrolls, cleanup);
        window.Show();
        window.Activate();
        return window;
    }
}
