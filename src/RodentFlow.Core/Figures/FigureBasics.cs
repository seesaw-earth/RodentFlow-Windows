using System.Globalization;

namespace RodentFlow.Core.Figures;

// The result figures are drawn once, against IFigureCanvas, and that one drawing goes to three places:
// the screen (Win2D, in the app), SVG and PDF (vector files, here). It plays the part CoreGraphics plays
// on the Mac, where the same SwiftUI Canvas code draws the screen and renders into PDF / PNG.
//
// Paths are polylines only (circles and rounded corners are sampled), so every backend draws exactly
// the same shapes. Coordinates are DIPs on screen and points in files; y grows downwards.

/// <summary>sRGB colour with alpha, 0–1.</summary>
public readonly record struct Rgba(double R, double G, double B, double A = 1)
{
    public static Rgba Hex(uint rgb, double alpha = 1) =>
        new(((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, alpha);

    public static Rgba Gray(double v, double alpha = 1) => new(v, v, v, alpha);

    public static readonly Rgba Black = new(0, 0, 0);
    public static readonly Rgba White = new(1, 1, 1);
    public static readonly Rgba Clear = new(0, 0, 0, 0);

    /// <summary>SwiftUI's <c>.opacity(x)</c>: multiplies the alpha.</summary>
    public Rgba Opacity(double factor) => this with { A = Math.Clamp(A * factor, 0, 1) };

    public byte R8 => To8(R);
    public byte G8 => To8(G);
    public byte B8 => To8(B);
    public byte A8 => To8(A);

    /// <summary>#rrggbb, alpha left out.</summary>
    public string HexRgb => string.Create(CultureInfo.InvariantCulture, $"#{R8:x2}{G8:x2}{B8:x2}");

    private static byte To8(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255, MidpointRounding.AwayFromZero);
}

public readonly record struct Pt(double X, double Y);

/// <summary>A set of polylines, each open or closed, filled with the non-zero winding rule.</summary>
public sealed class FigurePath
{
    private readonly List<Pt[]> _figures = [];
    private readonly List<bool> _closed = [];
    private List<Pt>? _open;

    public IReadOnlyList<Pt[]> Figures
    {
        get
        {
            Flush();
            return _figures;
        }
    }

    public bool IsClosed(int figure) => _closed[figure];

    public bool IsEmpty
    {
        get
        {
            Flush();
            return _figures.Count == 0;
        }
    }

    public FigurePath MoveTo(double x, double y)
    {
        Flush();
        _open = [new Pt(x, y)];
        return this;
    }

    public FigurePath LineTo(double x, double y)
    {
        if (_open is null) _open = [new Pt(x, y)];
        else _open.Add(new Pt(x, y));
        return this;
    }

    public FigurePath Close()
    {
        if (_open is { Count: > 1 })
        {
            _figures.Add(_open.ToArray());
            _closed.Add(true);
        }
        _open = null;
        return this;
    }

    private void Flush()
    {
        if (_open is { Count: > 1 })
        {
            _figures.Add(_open.ToArray());
            _closed.Add(false);
        }
        _open = null;
    }

    public FigurePath AddPolyline(IReadOnlyList<Pt> points, bool closed)
    {
        Flush();
        if (points.Count < 2) return this;
        _figures.Add(points.ToArray());
        _closed.Add(closed);
        return this;
    }

    public FigurePath AddRect(double x, double y, double w, double h) =>
        AddPolyline([new(x, y), new(x + w, y), new(x + w, y + h), new(x, y + h)], closed: true);

    /// <summary>Rounded rectangle; the radius is limited to half the shorter side.</summary>
    public FigurePath AddRoundedRect(double x, double y, double w, double h, double radius)
    {
        double r = Math.Max(0, Math.Min(radius, Math.Min(w, h) / 2));
        if (r < 0.01) return AddRect(x, y, w, h);
        var pts = new List<Pt>(28);
        void Corner(double cx, double cy, double from)
        {
            for (int i = 0; i <= 6; i++)
            {
                double a = from + i * Math.PI / 12;
                pts.Add(new Pt(cx + r * Math.Cos(a), cy + r * Math.Sin(a)));
            }
        }
        Corner(x + w - r, y + r, -Math.PI / 2);
        Corner(x + w - r, y + h - r, 0);
        Corner(x + r, y + h - r, Math.PI / 2);
        Corner(x + r, y + r, Math.PI);
        return AddPolyline(pts, closed: true);
    }

    public FigurePath AddEllipse(double cx, double cy, double rx, double ry, int segments = 0)
    {
        int n = segments > 0 ? segments : Math.Clamp((int)(Math.Max(rx, ry) * 2.2), 12, 96);
        var pts = new Pt[n];
        for (int i = 0; i < n; i++)
        {
            double a = 2 * Math.PI * i / n;
            pts[i] = new Pt(cx + rx * Math.Cos(a), cy + ry * Math.Sin(a));
        }
        return AddPolyline(pts, closed: true);
    }

    public FigurePath AddCircle(double cx, double cy, double r, int segments = 0) => AddEllipse(cx, cy, r, r, segments);

    public static FigurePath Rect(double x, double y, double w, double h) => new FigurePath().AddRect(x, y, w, h);

    public static FigurePath RoundedRect(double x, double y, double w, double h, double r) =>
        new FigurePath().AddRoundedRect(x, y, w, h, r);

    public static FigurePath Circle(double cx, double cy, double r) => new FigurePath().AddCircle(cx, cy, r);

    public static FigurePath Segment(double x0, double y0, double x1, double y1) =>
        new FigurePath().MoveTo(x0, y0).LineTo(x1, y1);
}

public enum FigureWeight { Regular, Medium, Semibold }

/// <summary>Size in DIPs / points, and weight. Digits are drawn tabular where the font allows it.</summary>
public readonly record struct FontSpec(double Size, FigureWeight Weight = FigureWeight.Regular)
{
    public bool Bold => Weight == FigureWeight.Semibold;
}

/// <summary>Size of one line of text; <see cref="Baseline"/> is the distance from its top to the baseline.</summary>
public readonly record struct TextSize(double Width, double Height, double Baseline);

public enum TextAnchor { Start, Middle, End }

/// <summary>Which part of the line box sits at the y given to <see cref="IFigureCanvas.Text"/>.</summary>
public enum TextBaseline { Top, Middle, Baseline, Bottom }

/// <summary>Dash lengths are in drawing units, as in SwiftUI's StrokeStyle.</summary>
public sealed record StrokeStyle(double[]? Dash = null, bool Round = false)
{
    public static readonly StrokeStyle RoundCaps = new(Round: true);
}

/// <summary>Where a figure is drawn: the screen, an SVG file or a PDF page.</summary>
public interface IFigureCanvas
{
    void Fill(FigurePath path, Rgba color);

    void Stroke(FigurePath path, Rgba color, double width, StrokeStyle? style = null);

    /// <summary>One line of text with its anchor at (x, y). <paramref name="halo"/>: a 2-unit outline behind it.</summary>
    void Text(string text, double x, double y, FontSpec font, Rgba color,
              TextAnchor anchor = TextAnchor.Start, TextBaseline baseline = TextBaseline.Top, Rgba? halo = null);

    TextSize Measure(string text, FontSpec font);

    /// <summary>
    /// Text turned <paramref name="degrees"/> clockwise about its anchor (y-axis titles of publication figures,
    /// PubText.rotation); the anchor and baseline are taken along the turned line.
    /// </summary>
    void RotatedText(string text, double x, double y, FontSpec font, Rgba color, TextAnchor anchor, TextBaseline baseline,
                     double degrees);

    /// <summary>Drawing after this is clipped to the path until the matching <see cref="PopClip"/>.</summary>
    void PushClip(FigurePath path);

    void PopClip();

    /// <summary>The whole image stretched into the rectangle.</summary>
    void Image(FigureImage image, double x, double y, double width, double height);
}

/// <summary>Measures like another canvas and draws nothing: used to lay a figure out before drawing it.</summary>
public sealed class MeasureCanvas(Func<string, FontSpec, TextSize> measure) : IFigureCanvas
{
    public void Fill(FigurePath path, Rgba color) { }
    public void Stroke(FigurePath path, Rgba color, double width, StrokeStyle? style = null) { }
    public void Text(string text, double x, double y, FontSpec font, Rgba color,
                     TextAnchor anchor = TextAnchor.Start, TextBaseline baseline = TextBaseline.Top, Rgba? halo = null) { }
    public TextSize Measure(string text, FontSpec font) => measure(text, font);
    public void RotatedText(string text, double x, double y, FontSpec font, Rgba color, TextAnchor anchor, TextBaseline baseline,
                            double degrees) { }
    public void PushClip(FigurePath path) { }
    public void PopClip() { }
    public void Image(FigureImage image, double x, double y, double width, double height) { }
}

/// <summary>
/// The video frame behind arena figures (the session's calibration frame), 32-bit BGRA, upright.
/// It may be a scaled copy: figures stretch it over the whole frame size the report gives.
/// </summary>
public sealed class FigureImage
{
    public FigureImage(byte[] bgra, int width, int height, int rowBytes)
    {
        if (width <= 0 || height <= 0 || rowBytes < width * 4 || bgra.Length < rowBytes * height)
            throw new ArgumentException("The image buffer does not match its size.");
        Bgra = bgra;
        Width = width;
        Height = height;
        RowBytes = rowBytes;
    }

    public byte[] Bgra { get; }
    public int Width { get; }
    public int Height { get; }
    public int RowBytes { get; }

    /// <summary>A backend's own copy (a GPU bitmap on screen), keyed by whatever the backend needs.</summary>
    public object? BackendCache { get; set; }

    private byte[]? _png;

    /// <summary>The image as an RGB PNG (for SVG files), made once.</summary>
    public byte[] Png => _png ??= PngEncoder.EncodeBgra(Bgra, Width, Height, RowBytes, alpha: false);

    /// <summary>Tightly packed 8-bit RGB rows (for PDF files).</summary>
    public byte[] Rgb()
    {
        var rgb = new byte[Width * Height * 3];
        for (int y = 0; y < Height; y++)
        {
            int s = y * RowBytes, d = y * Width * 3;
            for (int x = 0; x < Width; x++, s += 4, d += 3)
            {
                rgb[d] = Bgra[s + 2];
                rgb[d + 1] = Bgra[s + 1];
                rgb[d + 2] = Bgra[s];
            }
        }
        return rgb;
    }
}
