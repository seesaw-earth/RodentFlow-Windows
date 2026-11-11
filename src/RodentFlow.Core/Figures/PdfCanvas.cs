using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace RodentFlow.Core.Figures;

/// <summary>
/// A figure as a one-page vector PDF (the Mac's "Save as vector PDF"): shapes and text stay vector.
/// </summary>
/// <remarks>
/// Written by hand so the app needs no PDF library: PDF 1.4, the standard Helvetica fonts (no embedding,
/// WinAnsi encoding — figure files are in English, as on the Mac; a character outside WinAnsi is
/// replaced, ≥ by &gt;=), transparency through ExtGState, the calibration frame as a Flate-compressed RGB
/// image. The page's y axis is flipped once (<c>1 0 0 -1 0 h cm</c>) so drawing uses the same top-left
/// coordinates as the screen; text is flipped back by its own matrix.
/// </remarks>
public sealed class PdfCanvas : IFigureCanvas
{
    private readonly StringBuilder _ops = new();
    private readonly double _width, _height;
    private readonly string _title;
    private readonly List<double> _alphas = [];
    private readonly List<FigureImage> _images = [];
    private int _clipDepth;

    public PdfCanvas(double width, double height, string title = "")
    {
        _width = width;
        _height = height;
        _title = title;
        _ops.Append("1 0 0 -1 0 ").Append(N(height)).Append(" cm\n");
    }

    private static string N(double v)
    {
        if (!double.IsFinite(v)) v = 0;
        return Math.Round(v, 3).ToString("0.###", CultureInfo.InvariantCulture);
    }

    private string Alpha(double a)
    {
        double rounded = Math.Round(Math.Clamp(a, 0, 1), 3);
        int i = _alphas.IndexOf(rounded);
        if (i < 0)
        {
            _alphas.Add(rounded);
            i = _alphas.Count - 1;
        }
        return "/GS" + i.ToString(CultureInfo.InvariantCulture) + " gs ";
    }

    private static string Rgb(Rgba c) => $"{N(c.R)} {N(c.G)} {N(c.B)}";

    private void AppendPath(FigurePath p)
    {
        var figures = p.Figures;
        for (int f = 0; f < figures.Count; f++)
        {
            var pts = figures[f];
            _ops.Append(N(pts[0].X)).Append(' ').Append(N(pts[0].Y)).Append(" m\n");
            for (int i = 1; i < pts.Length; i++) _ops.Append(N(pts[i].X)).Append(' ').Append(N(pts[i].Y)).Append(" l\n");
            if (p.IsClosed(f)) _ops.Append("h\n");
        }
    }

    public void Fill(FigurePath path, Rgba color)
    {
        if (path.IsEmpty || color.A <= 0) return;
        _ops.Append("q ").Append(Alpha(color.A)).Append(Rgb(color)).Append(" rg\n");
        AppendPath(path);
        _ops.Append("f Q\n");
    }

    public void Stroke(FigurePath path, Rgba color, double width, StrokeStyle? style = null)
    {
        if (path.IsEmpty || color.A <= 0 || width <= 0) return;
        _ops.Append("q ").Append(Alpha(color.A)).Append(Rgb(color)).Append(" RG ").Append(N(width)).Append(" w ");
        _ops.Append(style?.Round == true ? "1 J 1 j " : "0 J 1 j ");
        if (style?.Dash is { Length: > 0 } dash)
            _ops.Append('[').Append(string.Join(" ", dash.Select(N))).Append("] 0 d ");
        _ops.Append('\n');
        AppendPath(path);
        _ops.Append("S Q\n");
    }

    public void Text(string text, double x, double y, FontSpec font, Rgba color,
                     TextAnchor anchor = TextAnchor.Start, TextBaseline baseline = TextBaseline.Top, Rgba? halo = null)
    {
        if (string.IsNullOrEmpty(text)) return;
        string encoded = Encode(text, out string plain);
        double w = HelveticaMetrics.Width(plain, font.Size, font.Bold);
        double tx = HelveticaMetrics.StartX(x, w, anchor);
        double ty = HelveticaMetrics.BaselineY(y, font, baseline);
        string face = font.Bold ? "/F2 " : "/F1 ";
        if (halo is { } h && h.A > 0)
        {
            _ops.Append("q ").Append(Alpha(h.A)).Append(Rgb(h)).Append(" RG 2.5 w 1 j BT ").Append(face).Append(N(font.Size))
                .Append(" Tf 1 Tr 1 0 0 -1 ").Append(N(tx)).Append(' ').Append(N(ty)).Append(" Tm ")
                .Append(encoded).Append(" Tj ET Q\n");
        }
        _ops.Append("q ").Append(Alpha(color.A)).Append(Rgb(color)).Append(" rg BT ").Append(face).Append(N(font.Size))
            .Append(" Tf 0 Tr 1 0 0 -1 ").Append(N(tx)).Append(' ').Append(N(ty)).Append(" Tm ")
            .Append(encoded).Append(" Tj ET Q\n");
    }

    public void RotatedText(string text, double x, double y, FontSpec font, Rgba color, TextAnchor anchor, TextBaseline baseline,
                            double degrees)
    {
        if (string.IsNullOrEmpty(text)) return;
        string encoded = Encode(text, out string plain);
        double w = HelveticaMetrics.Width(plain, font.Size, font.Bold);
        // Offsets of the line's start along the unturned line, then turned about (x, y) (y grows downwards).
        double dx = HelveticaMetrics.StartX(x, w, anchor) - x, dy = HelveticaMetrics.BaselineY(y, font, baseline) - y;
        double a = degrees * Math.PI / 180, cos = Math.Cos(a), sin = Math.Sin(a);
        double px = x + dx * cos - dy * sin, py = y + dx * sin + dy * cos;
        string face = font.Bold ? "/F2 " : "/F1 ";
        // Text x → (cos, sin), text up → (sin, −cos) on the flipped page: upright glyphs along the turned line.
        _ops.Append("q ").Append(Alpha(color.A)).Append(Rgb(color)).Append(" rg BT ").Append(face).Append(N(font.Size))
            .Append(" Tf 0 Tr ").Append(N(cos)).Append(' ').Append(N(sin)).Append(' ').Append(N(sin)).Append(' ').Append(N(-cos))
            .Append(' ').Append(N(px)).Append(' ').Append(N(py)).Append(" Tm ").Append(encoded).Append(" Tj ET Q\n");
    }

    public TextSize Measure(string text, FontSpec font)
    {
        Encode(text, out string plain);
        return HelveticaMetrics.Measure(plain, font);
    }

    public void PushClip(FigurePath path)
    {
        _ops.Append("q\n");
        _clipDepth++;
        if (path.IsEmpty)
        {
            _ops.Append("0 0 0 0 re W n\n");
            return;
        }
        AppendPath(path);
        _ops.Append("W n\n");
    }

    public void PopClip()
    {
        if (_clipDepth == 0) return;
        _clipDepth--;
        _ops.Append("Q\n");
    }

    public void Image(FigureImage image, double x, double y, double width, double height)
    {
        int i = _images.IndexOf(image);
        if (i < 0)
        {
            _images.Add(image);
            i = _images.Count - 1;
        }
        // The unit square's top row (t = 1) lands on y: the picture stays upright under the flipped page.
        _ops.Append("q ").Append(N(width)).Append(" 0 0 ").Append(N(-height)).Append(' ').Append(N(x)).Append(' ')
            .Append(N(y + height)).Append(" cm /Im").Append(i.ToString(CultureInfo.InvariantCulture)).Append(" Do Q\n");
    }

    // ---------------------------------------------------------------- text encoding

    /// <summary>
    /// A PDF string in WinAnsi, and the text as it will look (for measuring). Latin-1 maps through, the
    /// typographic characters WinAnsi has get their codes, a few others are spelled out, the rest becomes "?".
    /// </summary>
    private static string Encode(string text, out string plain)
    {
        var sb = new StringBuilder("(");
        var shown = new StringBuilder();
        foreach (char ch in text)
        {
            string? spelled = ch switch
            {
                '≥' => ">=",
                '≤' => "<=",
                '−' => "-",
                '→' => "->",
                '←' => "<-",
                '≈' => "~",
                '\u2009' or '\u202F' or '\u00A0' => " ",
                _ => null,
            };
            if (spelled is not null)
            {
                foreach (char s in spelled) Add(s, s);
                continue;
            }
            int code = ch switch
            {
                '€' => 0x80, '‚' => 0x82, '„' => 0x84, '…' => 0x85, '†' => 0x86, '‡' => 0x87, '‰' => 0x89,
                '‘' => 0x91, '’' => 0x92, '“' => 0x93, '”' => 0x94, '•' => 0x95, '–' => 0x96, '—' => 0x97,
                '™' => 0x99,
                _ => ch is >= ' ' and <= '~' || ch is >= '\u00A1' and <= '\u00FF' ? ch : '?',
            };
            Add((char)code, code == '?' && ch != '?' ? '?' : ch);
        }
        sb.Append(')');
        plain = shown.ToString();
        return sb.ToString();

        void Add(char code, char display)
        {
            shown.Append(display);
            switch (code)
            {
                case '(': sb.Append("\\("); break;
                case ')': sb.Append("\\)"); break;
                case '\\': sb.Append("\\\\"); break;
                default:
                    if (code < 0x20 || code > 0x7E) sb.Append('\\').Append(Convert.ToString(code, 8).PadLeft(3, '0'));
                    else sb.Append(code);
                    break;
            }
        }
    }

    // ---------------------------------------------------------------- the file

    /// <summary>The finished PDF.</summary>
    public byte[] Document()
    {
        while (_clipDepth > 0) PopClip();
        var objects = new List<byte[]>();
        int Add(string body) { objects.Add(Encoding.ASCII.GetBytes(body)); return objects.Count; }

        // Fixed numbering: 1 catalog, 2 pages, 3 page, 4 content, 5 / 6 fonts, then graphics states, images, info.
        objects.Add([]); objects.Add([]); objects.Add([]); objects.Add([]);
        Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
        Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>");
        var gs = new StringBuilder();
        for (int i = 0; i < _alphas.Count; i++)
        {
            int n = Add($"<< /Type /ExtGState /ca {N(_alphas[i])} /CA {N(_alphas[i])} >>");
            gs.Append(" /GS").Append(i).Append(' ').Append(n).Append(" 0 R");
        }
        var xo = new StringBuilder();
        for (int i = 0; i < _images.Count; i++)
        {
            var img = _images[i];
            byte[] data = Deflate(img.Rgb());
            var head = Encoding.ASCII.GetBytes(
                $"<< /Type /XObject /Subtype /Image /Width {img.Width} /Height {img.Height} /ColorSpace /DeviceRGB "
                + $"/BitsPerComponent 8 /Filter /FlateDecode /Length {data.Length} >>\nstream\n");
            var tail = Encoding.ASCII.GetBytes("\nendstream");
            objects.Add([.. head, .. data, .. tail]);
            xo.Append(" /Im").Append(i).Append(' ').Append(objects.Count).Append(" 0 R");
        }
        int info = Add("<< /Producer (RodentFlow for Windows) /Title " + Encode(_title, out _) + " >>");

        byte[] content = Deflate(Encoding.ASCII.GetBytes(_ops.ToString()));
        objects[3] = [.. Encoding.ASCII.GetBytes($"<< /Length {content.Length} /Filter /FlateDecode >>\nstream\n"),
                      .. content, .. Encoding.ASCII.GetBytes("\nendstream")];
        objects[0] = Encoding.ASCII.GetBytes("<< /Type /Catalog /Pages 2 0 R >>");
        objects[1] = Encoding.ASCII.GetBytes("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
        string resources = "<< /Font << /F1 5 0 R /F2 6 0 R >>"
                           + (gs.Length > 0 ? " /ExtGState <<" + gs + " >>" : "")
                           + (xo.Length > 0 ? " /XObject <<" + xo + " >>" : "") + " >>";
        objects[2] = Encoding.ASCII.GetBytes(
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {N(_width)} {N(_height)}] /Resources {resources} /Contents 4 0 R >>");

        using var ms = new MemoryStream();
        void Write(string s) { var b = Encoding.ASCII.GetBytes(s); ms.Write(b, 0, b.Length); }
        Write("%PDF-1.4\n");
        // A comment of high bytes: tells file-transfer tools that this file is binary.
        ms.Write([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
        var offsets = new long[objects.Count];
        for (int i = 0; i < objects.Count; i++)
        {
            offsets[i] = ms.Position;
            Write($"{i + 1} 0 obj\n");
            ms.Write(objects[i], 0, objects[i].Length);
            Write("\nendobj\n");
        }
        long xref = ms.Position;
        Write($"xref\n0 {objects.Count + 1}\n0000000000 65535 f \n");
        foreach (long o in offsets) Write(o.ToString("D10", CultureInfo.InvariantCulture) + " 00000 n \n");
        Write($"trailer\n<< /Size {objects.Count + 1} /Root 1 0 R /Info {info} 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return ms.ToArray();
    }

    private static byte[] Deflate(byte[] data)
    {
        using var ms = new MemoryStream();
        using (var z = new ZLibStream(ms, CompressionLevel.Optimal, leaveOpen: true)) z.Write(data, 0, data.Length);
        return ms.ToArray();
    }
}
