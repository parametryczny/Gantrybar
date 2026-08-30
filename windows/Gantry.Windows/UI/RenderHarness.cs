using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>Renders Spoolbase windows to PNG off-screen (WPF RenderTargetBitmap), so the Windows look
/// can be reviewed on CI without a desktop session. Invoked with: Gantry.exe --render &lt;out-dir&gt;
/// This is the WPF counterpart of the Linux offscreen render scripts.</summary>
internal static class RenderHarness
{
    public static void RenderAll(string outDir)
    {
        Directory.CreateDirectory(outDir);

        var store = new FilamentStore();
        Seed(store);

        Safe(() => RenderWindow(new SpoolbaseEditWindow(store, null, false), Path.Combine(outDir, "win-editor.png")));
        Safe(() => RenderWindow(new SpoolbaseWindow(), Path.Combine(outDir, "win-spoolbase.png")));
        Safe(() => RenderWindow(new DashboardWindow(new PrinterStore(a => a())), Path.Combine(outDir, "win-dashboard.png")));
    }

    private static void Safe(System.Action action)
    {
        try { action(); } catch { /* one render failing should not block the others */ }
    }

    private static void Seed(FilamentStore store)
    {
        if (store.Filaments.Count > 0) return;
        void add(string brand, string name, string type, string colorName, string hex, int count) =>
            store.Add(new Filament { Brand = brand, Name = name, Type = type, ColorName = colorName, ColorHex = hex, SpoolCount = count });
        add("Bambu Lab", "PLA Matte", "PLA", "Różowy", "E89CC6", 2);
        add("Bambu Lab", "PLA Basic", "PLA", "Czarny", "111111", 1);
        add("Polymaker", "PolyTerra", "PLA", "Szary", "8E8E93", 0);
        add("Bambu Lab", "PETG HF", "PETG", "Zielony", "1A9E5A", 3);
        add("eSUN", "ABS+", "ABS", "Biały", "F2F2F2", 1);
    }

    private static void RenderWindow(Window window, string path)
    {
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -20000;
        window.Top = -20000;
        window.ShowInTaskbar = false;
        window.Show();
        window.UpdateLayout();
        // Let the layout settle (SizeToContent, templates, popups) before capturing.
        window.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Loaded);

        var root = window.Content as FrameworkElement;
        double w = root?.ActualWidth > 0 ? root.ActualWidth : window.ActualWidth;
        double h = root?.ActualHeight > 0 ? root.ActualHeight : window.ActualHeight;
        int width = System.Math.Max(1, (int)System.Math.Ceiling(w));
        int height = System.Math.Max(1, (int)System.Math.Ceiling(h));

        var rtb = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(window);   // renders the window's client content (dark background + controls)

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(rtb));
        using (var fs = File.Create(path)) encoder.Save(fs);
        window.Close();
    }
}
