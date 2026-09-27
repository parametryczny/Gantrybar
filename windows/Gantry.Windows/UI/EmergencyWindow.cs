using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Gantry.Services;

namespace Gantry.UI;

/// The emergency power-off question as a panic panel: red frame, the blinking siren from
/// design/emergency-siren.svg, the printers it will hit and one big red button (Enter), Esc to back out.
public sealed class EmergencyWindow : Window
{
    private static readonly Color Red = Color.FromRgb(0xE5, 0x48, 0x4D);
    private static readonly Color Ray = Color.FromRgb(0xFF, 0x45, 0x3A);

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

        var stack = new StackPanel { Width = 400 };
        stack.Children.Add(Siren());
        stack.Children.Add(new TextBlock
        {
            Text = AppSettings.T("Switch off every printer's power?").ToUpperInvariant(), FontSize = 19, FontWeight = FontWeights.Black,
            Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x66)), TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 6),
        });
        stack.Children.Add(new TextBlock
        {
            Text = AppSettings.T("{0} sockets are switched off at once. Running prints end and cannot be resumed.").Replace("{0}", printers.Count.ToString()),
            FontSize = 13, Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)), TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8),
        });
        stack.Children.Add(new TextBlock
        {
            Text = string.Join("\n", printers.Select(name => "•  " + name)), FontSize = 12, FontWeight = FontWeights.SemiBold,
            Foreground = Brushes.White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 16),
        });

        var go = new Button
        {
            Content = "⚡ " + AppSettings.T("Switch everything off").ToUpperInvariant(), IsDefault = true, Height = 54,
            FontSize = 17, FontWeight = FontWeights.Heavy, Foreground = Brushes.White, Cursor = Cursors.Hand,
            Template = PanicTemplate(),
        };
        go.Click += (_, _) => DialogResult = true;
        var cancel = new Button
        {
            Content = AppSettings.T("Cancel"), IsCancel = true, Padding = new Thickness(18, 5, 18, 5),
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 6),
        };
        stack.Children.Add(go);
        stack.Children.Add(cancel);
        stack.Children.Add(new TextBlock
        {
            Text = AppSettings.T("Return — switch off · Esc — cancel"), FontSize = 10.5,
            Foreground = new SolidColorBrush(Color.FromArgb(0x73, 0xFF, 0xFF, 0xFF)), TextAlignment = TextAlignment.Center,
        });

        Content = new Border
        {
            CornerRadius = new CornerRadius(22), BorderThickness = new Thickness(4), BorderBrush = new SolidColorBrush(Ray),
            Background = new SolidColorBrush(Color.FromArgb(0xFA, 0x1C, 0x12, 0x13)), Padding = new Thickness(30, 26, 30, 20),
            Margin = new Thickness(16), Child = stack,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Red, BlurRadius = 30, ShadowDepth = 0, Opacity = 0.7 },
        };
        Loaded += (_, _) => go.Focus();
    }

    private static ControlTemplate PanicTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(12));
        border.SetValue(Border.BackgroundProperty, new SolidColorBrush(Red));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        template.VisualTree = border;
        return template;
    }

    /// The same shapes as design/emergency-siren.svg: blinking rays, a glowing dome, a base.
    private static UIElement Siren()
    {
        var canvas = new Canvas { Width = 128, Height = 128 };
        var rays = new Path
        {
            Data = Geometry.Parse("M10,50 L24,56 M24,18 L35,31 M64,4 L64,19 M104,18 L93,31 M118,50 L104,56"),
            Stroke = new SolidColorBrush(Ray), StrokeThickness = 7, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
        rays.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.18, TimeSpan.FromMilliseconds(450))
        {
            AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever,
        });
        var dome = new Path
        {
            Data = Geometry.Parse("M34,94 V70 A30,30 0 0 1 94,70 V94 Z"), Fill = new SolidColorBrush(Red),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Red, BlurRadius = 22, ShadowDepth = 0, Opacity = 0.9 },
        };
        var shine = new Path
        {
            Data = Geometry.Parse("M46,70 A18,18 0 0 1 64,52"), Stroke = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
            StrokeThickness = 5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
        var base1 = new Rectangle { Width = 80, Height = 14, RadiusX = 4, RadiusY = 4, Fill = new SolidColorBrush(Color.FromRgb(0x8E, 0x1B, 0x1F)) };
        Canvas.SetLeft(base1, 24); Canvas.SetTop(base1, 94);
        var base2 = new Rectangle { Width = 96, Height = 10, RadiusX = 5, RadiusY = 5, Fill = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3C)) };
        Canvas.SetLeft(base2, 16); Canvas.SetTop(base2, 108);
        canvas.Children.Add(rays); canvas.Children.Add(dome); canvas.Children.Add(shine); canvas.Children.Add(base1); canvas.Children.Add(base2);
        return new Viewbox { Width = 104, Height = 104, Child = canvas, HorizontalAlignment = HorizontalAlignment.Center };
    }
}
