using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using RodentFlow.Core.Figures;
using Windows.Foundation;
using Windows.Graphics.DirectX;
using Windows.Storage.Streams;

namespace RodentFlow.App.Figures;

/// <summary>
/// The figure canvas on Win2D: what CoreGraphics is to the Mac's figures. Used for the screen
/// (CanvasControl) and for PNG files (CanvasRenderTarget at the requested dpi).
/// </summary>
/// <remarks>
/// A null drawing session measures only. Geometries and stroke styles are created per call and disposed
/// at once; text formats are kept (they do not depend on the device).
/// </remarks>
internal sealed class Win2DCanvas : IFigureCanvas
{
    /// <summary>The interface font of Windows, as SF is the Mac's.</summary>
    public const string FontFamily = "Segoe UI";

    private readonly CanvasDrawingSession? _ds;
    private readonly ICanvasResourceCreator _resources;
    private readonly string _family;
    private readonly Stack<(CanvasActiveLayer Layer, CanvasGeometry Clip)> _layers = new();

    /// <param name="fontFamily">Publication figures pass "Arial": their layout was measured for Helvetica / Arial.</param>
    public Win2DCanvas(CanvasDrawingSession? session, ICanvasResourceCreator resources, string? fontFamily = null)
    {
        _ds = session;
        _resources = resources;
        _family = fontFamily ?? FontFamily;
    }

    /// <summary>Measures with the shared device, without a control (layout before the first draw).</summary>
    public static TextSize MeasureShared(string text, FontSpec font) => MeasureWith(CanvasDevice.GetSharedDevice(), text, font, FontFamily);

    public static Windows.UI.Color ToColor(Rgba c) => Windows.UI.Color.FromArgb(c.A8, c.R8, c.G8, c.B8);

    // ---------------------------------------------------------------- shapes

    private CanvasGeometry? Geometry(FigurePath p)
    {
        var figures = p.Figures;
        if (figures.Count == 0) return null;
        var builder = new CanvasPathBuilder(_resources);
        builder.SetFilledRegionDetermination(CanvasFilledRegionDetermination.Winding);
        for (int f = 0; f < figures.Count; f++)
        {
            var pts = figures[f];
            builder.BeginFigure((float)pts[0].X, (float)pts[0].Y);
            for (int i = 1; i < pts.Length; i++) builder.AddLine((float)pts[i].X, (float)pts[i].Y);
            builder.EndFigure(p.IsClosed(f) ? CanvasFigureLoop.Closed : CanvasFigureLoop.Open);
        }
        return CanvasGeometry.CreatePath(builder);
    }

    public void Fill(FigurePath path, Rgba color)
    {
        if (_ds is null || color.A <= 0) return;
        using var g = Geometry(path);
        if (g is not null) _ds.FillGeometry(g, ToColor(color));
    }

    public void Stroke(FigurePath path, Rgba color, double width, StrokeStyle? style = null)
    {
        if (_ds is null || color.A <= 0 || width <= 0) return;
        using var g = Geometry(path);
        if (g is null) return;
        using var s = new CanvasStrokeStyle { LineJoin = CanvasLineJoin.Round };
        if (style?.Round == true)
        {
            s.StartCap = CanvasCapStyle.Round;
            s.EndCap = CanvasCapStyle.Round;
            s.DashCap = CanvasCapStyle.Round;
        }
        // Direct2D measures dashes in stroke widths; the figures give them in drawing units.
        if (style?.Dash is { Length: > 0 } dash)
            s.CustomDashStyle = dash.Select(d => (float)(d / Math.Max(width, 0.01))).ToArray();
        _ds.DrawGeometry(g, ToColor(color), (float)width, s);
    }

    // ---------------------------------------------------------------- text

    private static readonly Dictionary<(string Family, FontSpec Font), CanvasTextFormat> Formats = new();
    private static readonly object FormatGate = new();

    private static CanvasTextFormat Format(FontSpec font, string family)
    {
        lock (FormatGate)
        {
            if (Formats.TryGetValue((family, font), out var f)) return f;
            f = new CanvasTextFormat
            {
                FontFamily = family,
                FontSize = (float)font.Size,
                FontWeight = font.Weight switch
                {
                    FigureWeight.Semibold => Microsoft.UI.Text.FontWeights.SemiBold,
                    FigureWeight.Medium => Microsoft.UI.Text.FontWeights.Medium,
                    _ => Microsoft.UI.Text.FontWeights.Normal,
                },
                WordWrapping = CanvasWordWrapping.NoWrap,
                HorizontalAlignment = CanvasHorizontalAlignment.Left,
                VerticalAlignment = CanvasVerticalAlignment.Top,
            };
            Formats[(family, font)] = f;
            return f;
        }
    }

    private static TextSize MeasureWith(ICanvasResourceCreator resources, string text, FontSpec font, string family)
    {
        if (string.IsNullOrEmpty(text)) return new TextSize(0, font.Size * 1.33, font.Size);
        using var layout = new CanvasTextLayout(resources, text, Format(font, family), 100000f, 10000f);
        var bounds = layout.LayoutBounds;
        var lines = layout.LineMetrics;
        double baseline = lines.Length > 0 ? lines[0].Baseline : font.Size;
        return new TextSize(bounds.Width, bounds.Height, baseline);
    }

    public TextSize Measure(string text, FontSpec font) => MeasureWith(_resources, text, font, _family);

    public void RotatedText(string text, double x, double y, FontSpec font, Rgba color, TextAnchor anchor, TextBaseline baseline,
                            double degrees)
    {
        if (_ds is null) return;
        var before = _ds.Transform;
        // Turned about the anchor point; the line is laid out as unturned text there.
        _ds.Transform = Matrix3x2.CreateRotation((float)(degrees * Math.PI / 180), new Vector2((float)x, (float)y)) * before;
        try { Text(text, x, y, font, color, anchor, baseline); }
        finally { _ds.Transform = before; }
    }

    public void Text(string text, double x, double y, FontSpec font, Rgba color,
                     TextAnchor anchor = TextAnchor.Start, TextBaseline baseline = TextBaseline.Top, Rgba? halo = null)
    {
        if (_ds is null || string.IsNullOrEmpty(text) || color.A <= 0) return;
        using var layout = new CanvasTextLayout(_resources, text, Format(font, _family), 100000f, 10000f);
        var bounds = layout.LayoutBounds;
        var lines = layout.LineMetrics;
        double ascent = lines.Length > 0 ? lines[0].Baseline : font.Size;
        double left = anchor switch
        {
            TextAnchor.Middle => x - bounds.Width / 2,
            TextAnchor.End => x - bounds.Width,
            _ => x,
        };
        double top = baseline switch
        {
            TextBaseline.Middle => y - bounds.Height / 2,
            TextBaseline.Baseline => y - ascent,
            TextBaseline.Bottom => y - bounds.Height,
            _ => y,
        };
        if (halo is { } h && h.A > 0)
        {
            // A soft outline: the text drawn around itself in the halo colour.
            var hc = ToColor(h.Opacity(0.55));
            for (int i = 0; i < 8; i++)
            {
                double a = i * Math.PI / 4;
                _ds.DrawTextLayout(layout, (float)(left + 1.3 * Math.Cos(a)), (float)(top + 1.3 * Math.Sin(a)), hc);
            }
        }
        _ds.DrawTextLayout(layout, (float)left, (float)top, ToColor(color));
    }

    // ---------------------------------------------------------------- clipping and images

    public void PushClip(FigurePath path)
    {
        if (_ds is null) return;
        var g = Geometry(path) ?? CanvasGeometry.CreateRectangle(_resources, 0, 0, 0, 0);
        _layers.Push((_ds.CreateLayer(1f, g), g));
    }

    public void PopClip()
    {
        if (_layers.Count == 0) return;
        var (layer, clip) = _layers.Pop();
        layer.Dispose();
        clip.Dispose();
    }

    /// <summary>Closes any clip left open (a figure that threw half way).</summary>
    public void Close()
    {
        while (_layers.Count > 0) PopClip();
    }

    public void Image(FigureImage image, double x, double y, double width, double height)
    {
        if (_ds is null) return;
        var device = _resources.Device;
        // One GPU copy of the frame per device; a lost device makes a new one.
        if (image.BackendCache is not BitmapCache cache || !ReferenceEquals(cache.Device, device))
        {
            byte[] tight = image.RowBytes == image.Width * 4 ? image.Bgra : Tight(image);
            var bitmap = CanvasBitmap.CreateFromBytes(device, tight, image.Width, image.Height,
                                                      DirectXPixelFormat.B8G8R8A8UIntNormalized);
            cache = new BitmapCache(device, bitmap);
            image.BackendCache = cache;
        }
        _ds.DrawImage(cache.Bitmap, new Rect(x, y, width, height), new Rect(0, 0, image.Width, image.Height), 1f,
                      CanvasImageInterpolation.Linear);
    }

    private sealed record BitmapCache(CanvasDevice Device, CanvasBitmap Bitmap);

    /// <summary>Frees the GPU copy of an image at once (the review shows a new frame many times a second).</summary>
    public static void ReleaseImage(FigureImage image)
    {
        if (image.BackendCache is BitmapCache cache) cache.Bitmap.Dispose();
        image.BackendCache = null;
    }

    private static byte[] Tight(FigureImage image)
    {
        var tight = new byte[image.Width * image.Height * 4];
        for (int row = 0; row < image.Height; row++)
            System.Buffer.BlockCopy(image.Bgra, row * image.RowBytes, tight, row * image.Width * 4, image.Width * 4);
        return tight;
    }
}

/// <summary>Figures rendered off screen into PNG files and the clipboard.</summary>
internal static class FigureRaster
{
    /// <summary>
    /// Renders <paramref name="draw"/> into a PNG <paramref name="width"/> × <paramref name="height"/> units large
    /// with <paramref name="pixelsPerUnit"/> pixels per unit. With <paramref name="dpi"/> the file says so
    /// (pHYs), as a print export should: 1 unit = 1/72 inch, so pixelsPerUnit = dpi / 72.
    /// </summary>
    public static async Task<byte[]> PngAsync(double width, double height, double pixelsPerUnit,
                                              Action<IFigureCanvas> draw, double? dpi = null, string? fontFamily = null)
    {
        var device = CanvasDevice.GetSharedDevice();
        // Win2D sizes are in DIPs (1/96 inch): at 96 × pixelsPerUnit "dpi" one unit becomes pixelsPerUnit pixels.
        using var target = new CanvasRenderTarget(device, (float)width, (float)height, (float)(96 * pixelsPerUnit));
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Microsoft.UI.Colors.Transparent);
            var canvas = new Win2DCanvas(ds, target, fontFamily);
            try { draw(canvas); }
            finally { canvas.Close(); }
        }
        using var stream = new InMemoryRandomAccessStream();
        await target.SaveAsync(stream, CanvasBitmapFileFormat.Png);
        var bytes = new byte[stream.Size];
        using (var reader = new DataReader(stream.GetInputStreamAt(0)))
        {
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(bytes);
        }
        return dpi is { } d ? PngEncoder.SetDpi(bytes, d) : bytes;
    }

    /// <summary>A PNG as a stream the clipboard can take.</summary>
    public static async Task<RandomAccessStreamReference> ClipboardImageAsync(byte[] png)
    {
        var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(png);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        return RandomAccessStreamReference.CreateFromStream(stream);
    }
}
