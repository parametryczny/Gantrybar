using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Gantry.Services;

namespace Gantry.UI;

/// The emergency power-off question as a panic panel, the same look as macOS and GNU/Linux: a dark
/// card with a red glow from the top and a warning-stripe band, the siren from design/emergency-siren.svg
/// (glossy dome, blinking rays, breathing halo), the printers as chips, one big red button (Enter)
/// and a quiet Cancel (Esc).
public sealed class EmergencyWindow : Window
{
    private static readonly Color Red = Color.FromRgb(0xE5, 0x48, 0x4D);
    private static readonly Color RedDeep = Color.FromRgb(0x9E, 0x1F, 0x24);
    private static readonly Color Ray = Color.FromRgb(0xFF, 0x54, 0x4A);
    private static readonly Color Card = Color.FromRgb(0x16, 0x14, 0x15);

    public static bool Confirm(IReadOnlyList<string> printers)
    {
        var window = new EmergencyWindow(printers);
        return window.ShowDialog() == true;
    }

    private EmergencyWindow(IReadOnlyList<string> printers)
    {
        Title = AppSettings.T("Emergency power-off");
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        MouseLeftButtonDown += (_, _) => { try { DragMove(); } catch (InvalidOperationException) { } };

        var stack = new StackPanel { Width = 380 };
        stack.Children.Add(Siren());
        stack.Children.Add(Text(AppSettings.T("Emergency power-off").ToUpperInvariant(), 11, FontWeights.Heavy,
            Color.FromRgb(0xFF, 0x6B, 0x62), new Thickness(0, 6, 0, 6), spacing: 200));
        stack.Children.Add(Text(AppSettings.T("Switch off every printer's power?"), 21, FontWeights.Heavy, Colors.White,
            new Thickness(0, 0, 0, 8)));
        stack.Children.Add(Text(
            AppSettings.T("{0} sockets are switched off at once. Running prints end and cannot be resumed.").Replace("{0}", printers.Count.ToString()),
            13, FontWeights.Normal, Color.FromArgb(0x9E, 0xFF, 0xFF, 0xFF), new Thickness(0, 0, 0, 12)));

        var chips = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 20) };
        foreach (var name in printers)
        {
            chips.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x12, 0xFF, 0xFF, 0xFF)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12), Padding = new Thickness(11, 4, 11, 4), Margin = new Thickness(3),
                Child = new TextBlock { Text = "🖨  " + name, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF2)) },
            });
        }
        stack.Children.Add(chips);

        var go = new Button
        {
            Content = "⏻  " + AppSettings.T("Switch everything off"), IsDefault = true, Height = 56,
            FontSize = 17, FontWeight = FontWeights.Heavy, Foreground = Brushes.White, Cursor = Cursors.Hand,
            Template = PanicTemplate(),
            Effect = new DropShadowEffect { Color = Red, BlurRadius = 24, ShadowDepth = 8, Direction = 270, Opacity = 0.45 },
        };
        go.Click += (_, _) => DialogResult = true;
        var cancel = new Button
        {
            Content = AppSettings.T("Cancel"), IsCancel = true, Padding = new Thickness(16, 6, 16, 6), Cursor = Cursors.Hand,
            FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Color.FromArgb(0xB8, 0xFF, 0xFF, 0xFF)),
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 4), Template = QuietTemplate(),
        };
        stack.Children.Add(go);
        stack.Children.Add(cancel);
        stack.Children.Add(Text(AppSettings.T("Return — switch off · Esc — cancel"), 11, FontWeights.Normal,
            Color.FromArgb(0x61, 0xFF, 0xFF, 0xFF), new Thickness(0)));

        // Card: dark fill, red glow from above, a warning band on top, a thin red outline, a red glow around.
        var glow = new RadialGradientBrush
        {
            Center = new Point(0.5, -0.08), GradientOrigin = new Point(0.5, -0.08), RadiusX = 0.9, RadiusY = 0.75,
            GradientStops = { new GradientStop(Color.FromArgb(0x6B, Red.R, Red.G, Red.B), 0), new GradientStop(Color.FromArgb(0, Red.R, Red.G, Red.B), 1) },
        };
        var body = new Grid();
        body.Children.Add(new Border { Background = glow });
        body.Children.Add(new Border
        {
            Height = 8, VerticalAlignment = VerticalAlignment.Top, Background = Stripes(),
        });
        body.Children.Add(new Border { Padding = new Thickness(46, 40, 46, 30), Child = stack });

        var card = new Border
        {
            CornerRadius = new CornerRadius(24), Background = new SolidColorBrush(Card), Margin = new Thickness(14),
            BorderThickness = new Thickness(1.5), BorderBrush = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0x5C, 0x54)),
            Effect = new DropShadowEffect { Color = Red, BlurRadius = 28, ShadowDepth = 0, Opacity = 0.55 },
        };
        // Clip the glow and the band to the rounded card.
        var clipped = new Border { CornerRadius = new CornerRadius(23), ClipToBounds = true, Child = body };
        clipped.SizeChanged += (_, e) => clipped.Clip = new RectangleGeometry(new Rect(e.NewSize), 23, 23);
        card.Child = clipped;
        Content = card;
        Loaded += (_, _) => go.Focus();
    }

    private static TextBlock Text(string text, double size, FontWeight weight, Color color, Thickness margin, int spacing = 0) => new TextBlock
    {
        Text = text, FontSize = size, FontWeight = weight, Foreground = new SolidColorBrush(color), TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap, Margin = margin,
    }.Kerned(spacing);

    private static Brush Stripes()
    {
        var tile = new DrawingGroup();
        tile.Children.Add(new GeometryDrawing(new SolidColorBrush(Color.FromRgb(0x1F, 0x0D, 0x0F)), null, new RectangleGeometry(new Rect(0, 0, 17.6, 8))));
        tile.Children.Add(new GeometryDrawing(new SolidColorBrush(Color.FromArgb(0xF2, Red.R, Red.G, Red.B)), null,
            Geometry.Parse("M0,8 L8,0 L16,0 L8,8 Z")));
        return new DrawingBrush(tile)
        {
            TileMode = TileMode.Tile, Viewport = new Rect(0, 0, 17.6, 8), ViewportUnits = BrushMappingMode.Absolute,
            Viewbox = new Rect(0, 0, 17.6, 8), ViewboxUnits = BrushMappingMode.Absolute, Stretch = Stretch.None,
        };
    }

    private static ControlTemplate PanicTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border), "chrome");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(14));
        border.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        border.SetValue(Border.BorderBrushProperty, new SolidColorBrush(Color.FromArgb(0x2E, 0xFF, 0xFF, 0xFF)));
        border.SetValue(Border.BackgroundProperty, Vertical(Color.FromRgb(0xFF, 0x5A, 0x52), Color.FromRgb(0xD9, 0x30, 0x36)));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        template.VisualTree = border;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Vertical(Color.FromRgb(0xFF, 0x6A, 0x62), Color.FromRgb(0xE2, 0x3A, 0x40)), "chrome"));
        var pressed = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(Border.BackgroundProperty, Vertical(Color.FromRgb(0xD9, 0x30, 0x36), Color.FromRgb(0xB3, 0x26, 0x2B)), "chrome"));
        template.Triggers.Add(hover);
        template.Triggers.Add(pressed);
        return template;
    }

    private static ControlTemplate QuietTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border), "chrome");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(8));
        border.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        border.SetValue(Border.PaddingProperty, new Thickness(16, 6, 16, 6));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        border.AppendChild(content);
        template.VisualTree = border;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0x10, 0xFF, 0xFF, 0xFF)), "chrome"));
        template.Triggers.Add(hover);
        return template;
    }

    private static LinearGradientBrush Vertical(Color top, Color bottom) => new(top, bottom, new Point(0, 0), new Point(0, 1));

    /// The same shapes as design/emergency-siren.svg: breathing halo, blinking rays, glossy dome, base.
    private static UIElement Siren()
    {
        var canvas = new Canvas { Width = 128, Height = 128 };
        var halo = new Ellipse
        {
            Width = 96, Height = 96, RenderTransformOrigin = new Point(0.5, 0.5),
            Fill = new RadialGradientBrush(Color.FromArgb(0x8C, Red.R, Red.G, Red.B), Color.FromArgb(0, Red.R, Red.G, Red.B)),
            RenderTransform = new ScaleTransform(0.7, 0.7),
        };
        Canvas.SetLeft(halo, 16); Canvas.SetTop(halo, 24);
        var grow = new DoubleAnimation(0.7, 1.0, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever };
        halo.RenderTransform.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
        halo.RenderTransform.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        halo.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever });

        var rays = new Path
        {
            Data = Geometry.Parse("M10,50 L24,56 M24,18 L35,31 M64,4 L64,19 M104,18 L93,31 M118,50 L104,56"),
            Stroke = new SolidColorBrush(Ray), StrokeThickness = 7, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
        var blink = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(1), RepeatBehavior = RepeatBehavior.Forever };
        blink.KeyFrames.Add(new DiscreteDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        blink.KeyFrames.Add(new DiscreteDoubleKeyFrame(0.16, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(500))));
        rays.BeginAnimation(OpacityProperty, blink);

        var dome = new Path
        {
            Data = Geometry.Parse("M34,94 V70 A30,30 0 0 1 94,70 V94 Z"),
            Fill = new LinearGradientBrush(Color.FromRgb(0xFF, 0x73, 0x6B), RedDeep, new Point(0, 0), new Point(0, 1)),
        };
        var shine = new Path
        {
            Data = Geometry.Parse("M46,70 A18,18 0 0 1 64,52"), Stroke = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
            StrokeThickness = 5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
        var base1 = new Rectangle { Width = 80, Height = 14, RadiusX = 4, RadiusY = 4, Fill = new SolidColorBrush(Color.FromRgb(0x73, 0x17, 0x1C)) };
        Canvas.SetLeft(base1, 24); Canvas.SetTop(base1, 94);
        var base2 = new Rectangle { Width = 96, Height = 10, RadiusX = 5, RadiusY = 5, Fill = new SolidColorBrush(Color.FromRgb(0x33, 0x33, 0x36)) };
        Canvas.SetLeft(base2, 16); Canvas.SetTop(base2, 108);
        foreach (var part in new UIElement[] { halo, rays, dome, shine, base1, base2 })
            canvas.Children.Add(part);
        return new Viewbox { Width = 112, Height = 112, Child = canvas, HorizontalAlignment = HorizontalAlignment.Center };
    }
}

internal static class TextBlockSpacing
{
    /// Letter-spacing for a short uppercase line: WPF TextBlock has none, so hair spaces go between letters.
    public static TextBlock Kerned(this TextBlock block, int spacing)
    {
        if (spacing > 0)
            block.Text = string.Join(" ", block.Text.ToCharArray());
        return block;
    }
}
