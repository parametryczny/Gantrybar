using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;
using ZXing;
using ZXing.Common;
using Gantry.Services;

namespace Gantry.UI;

/// <summary>Native Windows webcam scanner used by Spoolbase. MediaCapture supplies CPU-backed BGRA
/// frames and ZXing reads EAN/UPC/Code/QR/DataMatrix/PDF417/Aztec without an external process.</summary>
public sealed class BarcodeScannerWindow : Window
{
    private readonly Action<string> _onCode;
    private readonly Image _preview = new() { Stretch = Stretch.UniformToFill };
    private readonly TextBlock _status = new() { FontSize = 11, TextWrapping = TextWrapping.Wrap };
    private readonly TextBox _manual = new() { MinWidth = 210, Padding = new Thickness(8, 5, 8, 5) };
    private readonly BarcodeReaderGeneric _decoder = new()
    {
        AutoRotate = true,
        Options = new DecodingOptions
        {
            TryHarder = true,
            PossibleFormats = new List<BarcodeFormat>
            {
                BarcodeFormat.EAN_8, BarcodeFormat.EAN_13, BarcodeFormat.UPC_A, BarcodeFormat.UPC_E,
                BarcodeFormat.CODE_39, BarcodeFormat.CODE_128, BarcodeFormat.QR_CODE,
                BarcodeFormat.DATA_MATRIX, BarcodeFormat.PDF_417, BarcodeFormat.AZTEC
            }
        }
    };
    private MediaCapture? _capture;
    private MediaFrameReader? _reader;
    private int _processing;
    private bool _handled;

    public BarcodeScannerWindow(Action<string> onCode)
    {
        _onCode = onCode;
        Title = AppSettings.Text("Skanuj kod filamentu", "Scan filament code");
        Width = 520; Height = 410;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        Background = GTheme.Brush(GTheme.Canvas);
        Foreground = GTheme.Brush(GTheme.Text);
        FontFamily = new FontFamily("Segoe UI Variable, Segoe UI");
        SourceInitialized += (_, _) => SpoolbaseChrome.ApplyDark(this);

        var root = new DockPanel { Margin = new Thickness(18, 16, 18, 14) };
        var heading = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        heading.Children.Add(new TextBlock
        {
            Text = AppSettings.Text("Skanuj kod z etykiety szpuli", "Scan the code on the spool label"),
            FontSize = 17, FontWeight = FontWeights.SemiBold
        });
        _status.Text = AppSettings.Text("Wypełnij kodem ramkę i przytrzymaj etykietę nieruchomo",
                                        "Fill the frame with the code and hold the label still");
        _status.Foreground = GTheme.Brush(GTheme.Secondary);
        heading.Children.Add(_status);
        DockPanel.SetDock(heading, Dock.Top); root.Children.Add(heading);

        var bottom = new Grid { Margin = new Thickness(0, 10, 0, 0) };
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _manual.Background = GTheme.Brush(GTheme.Surface); _manual.Foreground = GTheme.Brush(GTheme.Text);
        _manual.CaretBrush = GTheme.Brush(GTheme.Text); _manual.BorderBrush = GTheme.Brush(GTheme.Line);
        _manual.ToolTip = AppSettings.Text("Kod ręcznie", "Enter code manually");
        bottom.Children.Add(_manual);
        var use = new Button { Content = AppSettings.Text("Użyj kodu", "Use code"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 5, 12, 5), IsDefault = true };
        use.Click += (_, _) => Complete(_manual.Text);
        Grid.SetColumn(use, 1); bottom.Children.Add(use);
        var cancel = new Button { Content = AppSettings.Text("Anuluj", "Cancel"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 5, 12, 5), IsCancel = true };
        cancel.Click += (_, _) => Close();
        Grid.SetColumn(cancel, 2); bottom.Children.Add(cancel);
        DockPanel.SetDock(bottom, Dock.Bottom); root.Children.Add(bottom);

        var camera = new Grid { ClipToBounds = true };
        camera.Children.Add(_preview);
        camera.Children.Add(new Border
        {
            Width = 280, Height = 105, CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(2), BorderBrush = new SolidColorBrush(Color.FromArgb(0xC0, 0xFF, 0xFF, 0xFF)),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        });
        root.Children.Add(new Border
        {
            Background = GTheme.Brush(GTheme.Card), CornerRadius = new CornerRadius(14),
            BorderBrush = GTheme.Brush(GTheme.Line), BorderThickness = new Thickness(1), Child = camera
        });
        Content = root;
        GTheme.ApplyWindowTheme(this);

        Loaded += async (_, _) => await StartAsync();
        Closed += async (_, _) => await StopAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            _capture = new MediaCapture();
            await _capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                StreamingCaptureMode = StreamingCaptureMode.Video,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                SharingMode = MediaCaptureSharingMode.SharedReadOnly
            });
            var source = _capture.FrameSources.Values.FirstOrDefault(value =>
                value.Info.SourceKind == MediaFrameSourceKind.Color);
            if (source is null) throw new InvalidOperationException(AppSettings.Text("Nie znaleziono kamery.", "No camera found."));
            _reader = await _capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
            _reader.FrameArrived += FrameArrived;
            var started = await _reader.StartAsync();
            if (started != MediaFrameReaderStartStatus.Success)
                throw new InvalidOperationException(AppSettings.Text("Nie można uruchomić kamery.", "Could not start the camera."));
        }
        catch (Exception ex)
        {
            _status.Text = AppSettings.Text("Nie można uruchomić skanera: ", "Could not start scanner: ") + ex.Message;
            _manual.Focus();
        }
    }

    private void FrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (_handled || Interlocked.Exchange(ref _processing, 1) != 0) return;
        try
        {
            using var frame = sender.TryAcquireLatestFrame();
            var original = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (original is null) return;
            using var bitmap = original.BitmapPixelFormat == BitmapPixelFormat.Bgra8
                ? SoftwareBitmap.Copy(original)
                : SoftwareBitmap.Convert(original, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            int width = bitmap.PixelWidth, height = bitmap.PixelHeight;
            var buffer = new Windows.Storage.Streams.Buffer((uint)(width * height * 4));
            bitmap.CopyToBuffer(buffer);
            using var dataReader = DataReader.FromBuffer(buffer);
            var pixels = new byte[buffer.Length];
            dataReader.ReadBytes(pixels);

            var preview = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
            preview.Freeze();
            Dispatcher.BeginInvoke(new Action(() => _preview.Source = preview));

            var result = _decoder.Decode(pixels, width, height, RGBLuminanceSource.BitmapFormat.BGRA32);
            if (result?.Text is { Length: > 0 } code)
                Dispatcher.BeginInvoke(new Action(() => Complete(code)));
        }
        catch { /* a damaged frame is expected occasionally; the next one will replace it */ }
        finally { Interlocked.Exchange(ref _processing, 0); }
    }

    private void Complete(string value)
    {
        var code = value.Trim();
        if (_handled || code.Length == 0) return;
        _handled = true;
        Close();
        Dispatcher.BeginInvoke(new Action(() => _onCode(code)));
    }

    private async Task StopAsync()
    {
        if (_reader is not null)
        {
            _reader.FrameArrived -= FrameArrived;
            try { await _reader.StopAsync(); } catch { }
            _reader.Dispose(); _reader = null;
        }
        _capture?.Dispose(); _capture = null;
    }
}
