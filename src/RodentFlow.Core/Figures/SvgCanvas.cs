using System.Globalization;
using System.Text;

namespace RodentFlow.Core.Figures;

/// <summary>
/// Text widths of Helvetica / Arial (1/1000 em), as the engine's PubTextMetrics (Shared/Figures/PubFigure.swift)
/// uses them, so a figure laid out for a vector file fits the font the file names.
/// </summary>
public static class HelveticaMetrics
{
    private static readonly int[] Widths =
    [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,   // space … /
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,   // 0 … ?
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,  // @ … O
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,   // P … _
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,   // ` … o
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,        // p … ~
    ];

    /// <summary>Line box height and baseline as a fraction of the font size.</summary>
    public const double LineHeight = 1.15;
    public const double Ascent = 0.9;

    public static double Width(string text, double size, bool bold)
    {
        double units = 0;
        foreach (Rune r in text.EnumerateRunes())
        {
            int v = r.Value;
            if (v >= 32 && v <= 126) units += Widths[v - 32];
            else if (v is >= 0x3000 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF or >= 0xFF00 and <= 0xFFEF) units += 1000;
            else units += 600;
        }
        return units / 1000 * size * (bold ? 1.06 : 1);
    }

    public static TextSize Measure(string text, FontSpec font) =>
        new(Width(text, font.Size, font.Bold), font.Size * LineHeight, font.Size * Ascent);

    /// <summary>The baseline for a line whose <paramref name="baseline"/> part is at <paramref name="y"/>.</summary>
    public static double BaselineY(double y, FontSpec font, TextBaseline baseline) => baseline switch
    {
        TextBaseline.Top => y + font.Size * Ascent,
        TextBaseline.Middle => y - font.Size * LineHeight / 2 + font.Size * Ascent,
        TextBaseline.Bottom => y - font.Size * LineHeight + font.Size * Ascent,
        _ => y,
    };

    public static double StartX(double x, double width, TextAnchor anchor) => anchor switch
    {
        TextAnchor.Middle => x - width / 2,
        TextAnchor.End => x - width,
        _ => x,
    };
}

/// <summary>
/// A figure as an SVG document (vector; text stays text). Fonts: Arial / Helvetica, as the engine's
/// PubSVG writes them; sizes in points (the document is <c>width pt</c> wide).
/// </summary>
public sealed class SvgCanvas : IFigureCanvas
{
    private readonly StringBuilder _defs = new();
    private readonly StringBuilder _body = new();
    private readonly double _width, _height;
    private readonly string _title;
    private int _clips;
    private int _depth;
    private readonly Dictionary<FigureImage, string> _images = new();

    public SvgCanvas(double width, double height, string title = "")
    {
        _width = width;
        _height = height;
        _title = title;
    }

    private static string N(double v)
    {
        double r = Math.Round(v * 100) / 100;
        return r == Math.Round(r) ? r.ToString("0", CultureInfo.InvariantCulture) : r.ToString("0.##", CultureInfo.InvariantCulture);
    }

    private static string Escape(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    private static string PathData(FigurePath p)
    {
        var sb = new StringBuilder();
        var figures = p.Figures;
        for (int f = 0; f < figures.Count; f++)
        {
            var pts = figures[f];
            sb.Append('M').Append(N(pts[0].X)).Append(' ').Append(N(pts[0].Y));
            for (int i = 1; i < pts.Length; i++) sb.Append('L').Append(N(pts[i].X)).Append(' ').Append(N(pts[i].Y));
            if (p.IsClosed(f)) sb.Append('Z');
        }
        return sb.ToString();
    }

    private static string Paint(string attribute, Rgba c)
    {
        string s = $"{attribute}=\"{c.HexRgb}\"";
        if (c.A < 1) s += $" {attribute}-opacity=\"{N(c.A)}\"";
        return s;
    }

    public void Fill(FigurePath path, Rgba color)
    {
        if (path.IsEmpty || color.A <= 0) return;
        _body.Append("<path d=\"").Append(PathData(path)).Append("\" ").Append(Paint("fill", color)).Append("/>\n");
    }

    public void Stroke(FigurePath path, Rgba color, double width, StrokeStyle? style = null)
    {
        if (path.IsEmpty || color.A <= 0 || width <= 0) return;
        _body.Append("<path d=\"").Append(PathData(path)).Append("\" fill=\"none\" ").Append(Paint("stroke", color))
             .Append(" stroke-width=\"").Append(N(width)).Append('"');
        if (style?.Round == true) _body.Append(" stroke-linecap=\"round\" stroke-linejoin=\"round\"");
        else _body.Append(" stroke-linejoin=\"round\"");
        if (style?.Dash is { Length: > 0 } dash)
            _body.Append(" stroke-dasharray=\"").Append(string.Join(" ", dash.Select(N))).Append('"');
        _body.Append("/>\n");
    }

    public void Text(string text, double x, double y, FontSpec font, Rgba color,
                     TextAnchor anchor = TextAnchor.Start, TextBaseline baseline = TextBaseline.Top, Rgba? halo = null) =>
        TextElement(text, x, y, font, color, anchor, baseline, halo, 0);

    public void RotatedText(string text, double x, double y, FontSpec font, Rgba color, TextAnchor anchor, TextBaseline baseline,
                            double degrees) => TextElement(text, x, y, font, color, anchor, baseline, null, degrees);

    private void TextElement(string text, double x, double y, FontSpec font, Rgba color, TextAnchor anchor,
                             TextBaseline baseline, Rgba? halo, double degrees)
    {
        if (string.IsNullOrEmpty(text)) return;
        string a = anchor switch { TextAnchor.Middle => "middle", TextAnchor.End => "end", _ => "start" };
        double by = HelveticaMetrics.BaselineY(y, font, baseline);
        _body.Append("<text x=\"").Append(N(x)).Append("\" y=\"").Append(N(by))
             .Append("\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"").Append(N(font.Size))
             .Append("\" text-anchor=\"").Append(a).Append("\" ").Append(Paint("fill", color));
        if (font.Weight == FigureWeight.Semibold) _body.Append(" font-weight=\"bold\"");
        else if (font.Weight == FigureWeight.Medium) _body.Append(" font-weight=\"500\"");
        if (halo is { } h && h.A > 0)
        {
            _body.Append(' ').Append(Paint("stroke", h))
                 .Append(" stroke-width=\"2.5\" stroke-linejoin=\"round\" paint-order=\"stroke\"");
        }
        // Turned about the anchor point, as PubSVG writes PubText.rotation; the baseline offset turns with it.
        if (degrees != 0)
            _body.Append(" transform=\"rotate(").Append(N(degrees)).Append(' ').Append(N(x)).Append(' ').Append(N(y)).Append(")\"");
        _body.Append('>').Append(Escape(text)).Append("</text>\n");
    }

    public TextSize Measure(string text, FontSpec font) => HelveticaMetrics.Measure(text, font);

    public void PushClip(FigurePath path)
    {
        string id = "c" + (++_clips).ToString(CultureInfo.InvariantCulture);
        _defs.Append("<clipPath id=\"").Append(id).Append("\"><path d=\"").Append(PathData(path)).Append("\"/></clipPath>\n");
        _body.Append("<g clip-path=\"url(#").Append(id).Append(")\">\n");
        _depth++;
    }

    public void PopClip()
    {
        if (_depth == 0) return;
        _depth--;
        _body.Append("</g>\n");
    }

    public void Image(FigureImage image, double x, double y, double width, double height)
    {
        // One copy of each picture, used wherever it is drawn.
        if (!_images.TryGetValue(image, out var id))
        {
            id = "img" + (_images.Count + 1).ToString(CultureInfo.InvariantCulture);
            _images[image] = id;
            string data = Convert.ToBase64String(image.Png);
            _defs.Append("<image id=\"").Append(id).Append("\" width=\"").Append(image.Width).Append("\" height=\"")
                 .Append(image.Height).Append("\" preserveAspectRatio=\"none\" href=\"data:image/png;base64,")
                 .Append(data).Append("\" xlink:href=\"data:image/png;base64,").Append(data).Append("\"/>\n");
        }
        double sx = width / image.Width, sy = height / image.Height;
        _body.Append("<use href=\"#").Append(id).Append("\" xlink:href=\"#").Append(id)
             .Append("\" transform=\"translate(").Append(N(x)).Append(' ').Append(N(y)).Append(") scale(")
             .Append(sx.ToString("0.######", CultureInfo.InvariantCulture)).Append(' ')
             .Append(sy.ToString("0.######", CultureInfo.InvariantCulture)).Append(")\"/>\n");
    }

    /// <summary>The finished document.</summary>
    public string Document()
    {
        while (_depth > 0) PopClip();
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.Append("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"")
          .Append(N(_width)).Append("pt\" height=\"").Append(N(_height)).Append("pt\" viewBox=\"0 0 ")
          .Append(N(_width)).Append(' ').Append(N(_height)).Append("\">\n");
        if (_title.Length > 0) sb.Append("<title>").Append(Escape(_title)).Append("</title>\n");
        if (_defs.Length > 0) sb.Append("<defs>\n").Append(_defs).Append("</defs>\n");
        sb.Append(_body);
        sb.Append("</svg>\n");
        return sb.ToString();
    }
}
