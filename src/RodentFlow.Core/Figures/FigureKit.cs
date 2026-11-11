using System.Globalization;
using RodentFlow.Core.Text;

namespace RodentFlow.Core.Figures;

/// <summary>
/// The type scale of the figures. The Mac's text styles (caption, caption2 …) set one size larger, as
/// Windows text runs a little smaller than macOS's at the same nominal size; the sizes the Mac gives
/// explicitly on its canvases (11 pt zone labels, 9 pt ring values) are kept as they are.
/// </summary>
public static class FigureFonts
{
    public static readonly FontSpec Caption = new(12);
    public static readonly FontSpec CaptionMedium = new(12, FigureWeight.Medium);
    public static readonly FontSpec CaptionSemibold = new(12, FigureWeight.Semibold);
    public static readonly FontSpec Caption2 = new(11);
    public static readonly FontSpec Caption2Medium = new(11, FigureWeight.Medium);
    public static readonly FontSpec Caption2Semibold = new(11, FigureWeight.Semibold);
    public static readonly FontSpec Footnote = new(12);
    public static readonly FontSpec Headline = new(14, FigureWeight.Semibold);
    public static readonly FontSpec Label11Semibold = new(11, FigureWeight.Semibold);
    public static readonly FontSpec Label11Medium = new(11, FigureWeight.Medium);
    public static readonly FontSpec Tiny9Medium = new(9, FigureWeight.Medium);
}

/// <summary>ReportFmt / RPFmt (ReportPalette.swift): the number formats figures use.</summary>
public static class Fmt
{
    /// <summary>m:ss, or h:mm:ss from an hour; "—" when not finite.</summary>
    public static string Clock(double seconds)
    {
        if (!double.IsFinite(seconds)) return "—";
        long s = Math.Max(0, (long)Math.Round(seconds, MidpointRounding.AwayFromZero));
        return s >= 3600
            ? string.Create(CultureInfo.InvariantCulture, $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{s / 60}:{s % 60:00}");
    }

    /// <summary>%.Nf, point as decimal separator; "—" when not finite.</summary>
    public static string Number(double v, int decimals = 1) =>
        double.IsFinite(v) ? v.ToString("F" + Math.Max(0, decimals), CultureInfo.InvariantCulture) : "—";

    /// <summary>Swift's <c>x.rounded()</c>: half away from zero.</summary>
    public static double Round(double v) => Math.Round(v, MidpointRounding.AwayFromZero);
}

/// <summary>An axis: its domain and the tick values on it.</summary>
public readonly record struct Axis(double Min, double Max, double[] Ticks)
{
    public double Span => Max - Min;

    /// <summary>Position of <paramref name="v"/> between <paramref name="a"/> (at Min) and <paramref name="b"/> (at Max).</summary>
    public double Map(double v, double a, double b) => Span > 0 ? a + (v - Min) / Span * (b - a) : (a + b) / 2;

    /// <summary>Tick label with as many decimals as the step needs.</summary>
    public string Label(double v)
    {
        double step = Ticks.Length > 1 ? Math.Abs(Ticks[1] - Ticks[0]) : Math.Abs(Span);
        int decimals = step >= 1 || step <= 0 ? 0 : Math.Min(6, (int)Math.Ceiling(-Math.Log10(step) - 1e-9));
        if (Math.Abs(v) < step * 1e-9) v = 0;
        return v.ToString("F" + decimals, CultureInfo.InvariantCulture);
    }

    /// <summary>A domain covering lo…hi on round numbers (1, 2, 2.5, 5 × 10ⁿ), about <paramref name="target"/> ticks.</summary>
    public static Axis Nice(double lo, double hi, int target = 5)
    {
        if (!double.IsFinite(lo) || !double.IsFinite(hi)) { lo = 0; hi = 1; }
        if (hi < lo) (lo, hi) = (hi, lo);
        if (hi - lo < 1e-12)
        {
            double pad = Math.Abs(hi) > 1e-12 ? Math.Abs(hi) * 0.1 : 1;
            lo -= pad;
            hi += pad;
        }
        double raw = (hi - lo) / Math.Max(1, target - 1);
        double mag = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        double norm = raw / mag;
        double step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
        double min = Math.Floor(lo / step + 1e-9) * step;
        double max = Math.Ceiling(hi / step - 1e-9) * step;
        var ticks = new List<double>();
        for (double t = min; t <= max + step * 1e-6; t += step) ticks.Add(Math.Abs(t) < step * 1e-9 ? 0 : t);
        return new Axis(min, max, ticks.ToArray());
    }

    /// <summary>A fixed domain (an explicit y range) with round ticks inside it.</summary>
    public static Axis Fixed(double lo, double hi, int target = 5)
    {
        var nice = Nice(lo, hi, target);
        var inside = nice.Ticks.Where(t => t >= lo - 1e-9 && t <= hi + 1e-9).ToArray();
        return new Axis(lo, hi, inside);
    }
}

/// <summary>Text fitting, wrapping and legends: the pieces every figure uses.</summary>
public static class FigureKit
{
    /// <summary>The text, cut with an ellipsis to fit <paramref name="maxWidth"/> (SwiftUI lineLimit(1)).</summary>
    public static string Fit(IFigureCanvas c, string text, FontSpec font, double maxWidth)
    {
        if (maxWidth <= 0 || c.Measure(text, font).Width <= maxWidth) return text;
        int lo = 0, hi = text.Length;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) / 2;
            if (c.Measure(text[..mid].TrimEnd() + "…", font).Width <= maxWidth) lo = mid;
            else hi = mid - 1;
        }
        return lo == 0 ? "…" : text[..lo].TrimEnd() + "…";
    }

    /// <summary>Lines of at most <paramref name="maxWidth"/>: at spaces, or between characters for Chinese.</summary>
    public static List<string> Wrap(IFigureCanvas c, string text, FontSpec font, double maxWidth)
    {
        var lines = new List<string>();
        foreach (string paragraph in text.Split('\n'))
        {
            bool words = paragraph.Contains(' ') && !HasHan(paragraph);
            var tokens = words ? paragraph.Split(' ').ToList() : paragraph.Select(ch => ch.ToString()).ToList();
            string current = "";
            foreach (string token in tokens)
            {
                string candidate = current.Length == 0 ? token : current + (words ? " " : "") + token;
                if (current.Length > 0 && c.Measure(candidate, font).Width > maxWidth)
                {
                    lines.Add(current);
                    current = token;
                }
                else
                {
                    current = candidate;
                }
            }
            lines.Add(current);
        }
        return lines;
    }

    /// <summary>Wrapped text drawn from (x, y); returns its height.</summary>
    public static double Paragraph(IFigureCanvas c, string text, double x, double y, double width, FontSpec font,
                                   Rgba color, TextAnchor anchor = TextAnchor.Start)
    {
        if (string.IsNullOrEmpty(text)) return 0;
        double lineH = c.Measure("Ag", font).Height;
        var lines = Wrap(c, text, font, width);
        double ax = anchor switch
        {
            TextAnchor.Middle => x + width / 2,
            TextAnchor.End => x + width,
            _ => x,
        };
        for (int i = 0; i < lines.Count; i++) c.Text(lines[i], ax, y + i * lineH, font, color, anchor);
        return lines.Count * lineH;
    }

    public static bool HasHan(string text) =>
        text.Any(ch => ch is >= '\u3400' and <= '\u9FFF' or >= '\uF900' and <= '\uFAFF');

    // ---------------------------------------------------------------- legends

    public enum Glyph { Bar, Dot, Line, Dashed, Ring, Square, Hatched, None }

    /// <summary>One legend entry (LegendItem): a swatch and a label in secondary ink.</summary>
    public sealed record LegendEntry(Rgba Color, string Title, Glyph Shape = Glyph.Bar);

    private static double GlyphWidth(Glyph g) => g switch
    {
        Glyph.Bar or Glyph.Ring => 10,
        Glyph.Dot or Glyph.Square => 9,
        Glyph.Line or Glyph.Dashed => 14,
        Glyph.Hatched => 8,
        _ => 0,
    };

    private static void DrawGlyph(IFigureCanvas c, Glyph g, Rgba color, double x, double cy)
    {
        switch (g)
        {
            case Glyph.Bar:
                c.Fill(FigurePath.RoundedRect(x, cy - 5, 10, 10, 2), color);
                break;
            case Glyph.Dot:
                c.Fill(FigurePath.Circle(x + 4.5, cy, 4.5), color);
                break;
            case Glyph.Ring:
                // Start marker as drawn on the plot: dark with a light halo.
                c.Stroke(FigurePath.Circle(x + 5, cy, 5), Rgba.White.Opacity(0.9), 2);
                c.Stroke(FigurePath.Circle(x + 5, cy, 4.1), color, 1.8);
                break;
            case Glyph.Square:
                c.Fill(FigurePath.Rect(x, cy - 4.5, 9, 9), color);
                c.Stroke(FigurePath.Rect(x, cy - 4.5, 9, 9), Rgba.White.Opacity(0.9), 1.5);
                break;
            case Glyph.Line:
                c.Fill(FigurePath.RoundedRect(x, cy - 1.5, 14, 3, 1.5), color);
                break;
            case Glyph.Dashed:
                for (int i = 0; i < 3; i++) c.Fill(FigurePath.RoundedRect(x + i * 5 + 0.5, cy - 1, 3, 2, 1), color);
                break;
            case Glyph.Hatched:
                Hatch(c, FigurePath.RoundedRect(x + 0.5, cy - 3.5, 7, 7, 2), x + 0.5, cy - 3.5, 7, 7, color);
                break;
        }
    }

    /// <summary>
    /// Entries left to right, wrapping (WrapLayout); returns the height used. With <paramref name="centred"/>
    /// each row is centred in the width.
    /// </summary>
    public static double Legend(IFigureCanvas c, FigureTheme theme, IReadOnlyList<LegendEntry> entries,
                                double x, double y, double width, double spacing, bool centred = false)
    {
        if (entries.Count == 0) return 0;
        var font = FigureFonts.Caption;
        var sizes = entries.Select(e =>
        {
            var t = c.Measure(e.Title, font);
            double gw = GlyphWidth(e.Shape);
            return (W: gw + (gw > 0 ? 5 : 0) + t.Width, H: Math.Max(t.Height, 10.0));
        }).ToList();

        // Rows first, so that a row can be centred.
        var rows = new List<(int From, int To, double W, double H)>();
        int start = 0;
        double rowW = 0, rowH = 0;
        for (int i = 0; i < entries.Count; i++)
        {
            double add = (i > start ? spacing : 0) + sizes[i].W;
            if (i > start && rowW + add > width)
            {
                rows.Add((start, i, rowW, rowH));
                start = i;
                rowW = sizes[i].W;
                rowH = sizes[i].H;
            }
            else
            {
                rowW += add;
                rowH = Math.Max(rowH, sizes[i].H);
            }
        }
        rows.Add((start, entries.Count, rowW, rowH));

        double cy = y;
        foreach (var row in rows)
        {
            double cx = centred ? x + Math.Max(0, (width - row.W) / 2) : x;
            for (int i = row.From; i < row.To; i++)
            {
                var e = entries[i];
                double mid = cy + row.H / 2;
                double gw = GlyphWidth(e.Shape);
                if (gw > 0) DrawGlyph(c, e.Shape, e.Color, cx, mid);
                c.Text(e.Title, cx + gw + (gw > 0 ? 5 : 0), mid, font, theme.Secondary, TextAnchor.Start, TextBaseline.Middle);
                cx += sizes[i].W + spacing;
            }
            cy += row.H + spacing;
        }
        return cy - spacing - y;
    }

    /// <summary>
    /// "Moments to check": outlined, diagonally hatched blocks (TimelineHatch). <paramref name="rowX"/> …
    /// is the row the stripes run across.
    /// </summary>
    public static void Hatch(IFigureCanvas c, FigurePath bars, double rowX, double rowY, double rowW, double rowH, Rgba color)
    {
        if (bars.IsEmpty) return;
        c.Fill(bars, color.Opacity(0.18));
        c.PushClip(bars);
        var stripes = new FigurePath();
        for (double sx = rowX - rowH; sx < rowX + rowW; sx += 4)
            stripes.MoveTo(sx, rowY + rowH).LineTo(sx + rowH, rowY);
        c.Stroke(stripes, color.Opacity(0.85), 1);
        c.PopClip();
        c.Stroke(bars, color.Opacity(0.9), 1);
    }

    /// <summary>
    /// The heat-map scale (HeatLegend): "less", the ramp, "more" and "dwell time (square-root scale)".
    /// Returns its height.
    /// </summary>
    public static double HeatLegend(IFigureCanvas c, FigureTheme theme, double x, double y, double width, bool english)
    {
        var font = FigureFonts.Caption;
        string less = Tr.T("少", english), more = Tr.T("多", english), what = Tr.T("停留时间（平方根标度）", english);
        var tl = c.Measure(less, font);
        var tm = c.Measure(more, font);
        var tw = c.Measure(what, font);
        double h = Math.Max(tl.Height, 8);
        double mid = y + h / 2;
        double cx = x;
        c.Text(less, cx, mid, font, theme.Secondary, TextAnchor.Start, TextBaseline.Middle);
        cx += tl.Width + 8;
        var capsule = FigurePath.RoundedRect(cx, mid - 4, 110, 8, 4);
        c.PushClip(capsule);
        const int slices = 44;
        for (int i = 0; i < slices; i++)
            c.Fill(FigurePath.Rect(cx + i * 110.0 / slices, mid - 4, 110.0 / slices + 0.6, 8), Palette.Heat((i + 0.5) / slices));
        c.PopClip();
        cx += 110 + 8;
        c.Text(more, cx, mid, font, theme.Secondary, TextAnchor.Start, TextBaseline.Middle);
        cx += tm.Width + 8;
        if (cx + tw.Width <= x + width)
        {
            c.Text(what, cx, mid, font, theme.Secondary, TextAnchor.Start, TextBaseline.Middle);
            return h;
        }
        // Too narrow for one line: the explanation goes under the ramp.
        return h + 4 + Paragraph(c, what, x, y + h + 4, width, font, theme.Secondary);
    }

    /// <summary>A reference line's label on the card colour, so it stays legible over the marks (ReferenceLabel).</summary>
    public static void ReferenceLabel(IFigureCanvas c, FigureTheme theme, string text, double x, double bottom, TextAnchor anchor)
    {
        var font = FigureFonts.Caption2;
        var size = c.Measure(text, font);
        double w = size.Width + 6;
        double left = anchor switch
        {
            TextAnchor.End => x - w,
            TextAnchor.Middle => x - w / 2,
            _ => x,
        };
        c.Fill(FigurePath.RoundedRect(left, bottom - size.Height, w, size.Height, 3), theme.Card.Opacity(0.85));
        c.Text(text, left + 3, bottom - size.Height, font, theme.Secondary);
    }
}
