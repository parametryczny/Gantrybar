using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Gantry.Models;
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
        Safe(() => RenderDashboard(Path.Combine(outDir, "win-dashboard.png")));
        Safe(() => RenderAssignPanel(Path.Combine(outDir, "win-assign.png")));
    }

    private static void RenderDashboard(string path)
    {
        SavedPrinterStore.Save(new()
        {
            new SavedPrinter { Serial = "X1", Name = "Bambu 3058", Host = "1.2.3.4", Kind = PrinterKind.Bambu },
            new SavedPrinter { Serial = "P1S", Name = "P1S", Host = "1.2.3.5", Kind = PrinterKind.Bambu },
        });
        var store = new PrinterStore(a => a());

        FilamentSlot S(string label, string? mat, string? hex, int? pct, bool active) =>
            new() { Label = label, Material = mat, ColorHex = hex, RemainingPercent = pct, IsActive = active };
        store.Telemetry["X1"] = new PrinterTelemetry
        {
            State = PrinterState.Printing, Progress = 76, JobName = "benchy.3mf",
            BedTemperature = 60, BedTargetTemperature = 60, ChamberTemperature = 38,
            CurrentLayer = 185, TotalLayers = 240,
            Nozzles = { new NozzleTelemetry { Position = NozzlePosition.Single, CurrentTemperature = 220, TargetTemperature = 220 } },
            FilamentGroups =
            {
                new FilamentGroup { DisplayName = "AMS A", DeclaredCapacity = 4, HumidityPercent = 19, TemperatureCelsius = 47,
                    Slots = { S("A1", null, null, null, false), S("A2", "PLA", "E8C848", 60, false),
                              S("A3", "PETG", "111111", 8, true), S("A4", null, null, null, false) } },
                new FilamentGroup { DisplayName = "EXT", DeclaredCapacity = 1, IsExternal = true,
                    Slots = { S("EXT", "TPU", "1A9E5A", 100, true) } },
            },
        };
        store.Telemetry["P1S"] = new PrinterTelemetry
        {
            State = PrinterState.Printing, Progress = 42, JobName = "bracket_v3.3mf",
            BedTemperature = 55, BedTargetTemperature = 60, ChamberTemperature = 33,
            CurrentLayer = 113, TotalLayers = 276,
            Nozzles = { new NozzleTelemetry { Position = NozzlePosition.Single, CurrentTemperature = 180, TargetTemperature = 220 } },
            FilamentGroups =
            {
                new FilamentGroup { DisplayName = "AMS HT", DeclaredCapacity = 1, HumidityPercent = 33, TemperatureCelsius = 33,
                    Slots = { S("A1", "PETG", "DCDCE0", 90, true) } },
                new FilamentGroup { DisplayName = "EXT", DeclaredCapacity = 1, IsExternal = true,
                    Slots = { S("EXT", "PETG", "161616", 100, false) } },
            },
        };
        RenderWindow(new DashboardWindow(store), path);
    }

    private static void RenderAssignPanel(string path)
    {
        var fils = SpoolbaseShared.Filaments.Filaments;
        if (fils.Count > 0 && SpoolbaseShared.Spools.Spools.Count == 0)
        {
            int i = 1;
            foreach (var f in fils.Take(4))
            {
                // Put a couple on another printer so the "existing rolls" (movable) section shows up;
                // the rest stay in storage (now hidden from the assign list).
                var spoolLoc = i <= 2 ? SpoolLocation.At("X2", SpoolFeeder.Ams, 0, i - 1) : SpoolLocation.Storage();
                SpoolbaseShared.Spools.Add(new PhysicalSpool
                {
                    Id = SpoolbaseShared.Spools.NextSpoolId(),
                    FilamentDefinitionId = f.Id,
                    NominalWeightGrams = 1000,
                    RemainingWeightGrams = 1000 - i * 130,
                    Status = i <= 2 ? SpoolStatus.Active : SpoolStatus.Stored,
                    Location = spoolLoc
                });
                i++;
            }
        }
        var loc = SpoolLocation.At("X1", SpoolFeeder.Ams, 0, 1);
        var panel = SpoolAssignPanel.Build(loc, "AMS A2", "PLA", "E89CC6", () => { });
        var win = new Window
        {
            Width = 340,
            SizeToContent = SizeToContent.Height,
            Background = new SolidColorBrush(Color.FromRgb(0x0C, 0x0D, 0x0E)),
            Content = panel
        };
        RenderWindow(win, path);
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
