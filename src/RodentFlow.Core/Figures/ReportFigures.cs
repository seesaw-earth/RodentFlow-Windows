using RodentFlow.Core.Text;
using RodentFlow.Engine;
using static RodentFlow.Core.Figures.FigureKit;

namespace RodentFlow.Core.Figures;

/// <summary>How a figure is drawn: theme, language of its own labels, layer choice, the frame behind it.</summary>
public sealed class FigureOptions
{
    public FigureTheme Theme { get; init; } = FigureTheme.Light;
    /// <summary>The figure's own labels ("Start", "Heat map" …) in English, as for files.</summary>
    public bool English { get; init; }
    public FigureStyle Style { get; init; } = new();
    /// <summary>The calibration frame, for heat maps on / next to the original picture.</summary>
    public FigureImage? Backdrop { get; init; }
    /// <summary>Line charts: the x value under the pointer, for the read-out (chartXSelection).</summary>
    public double? HoverX { get; set; }
    /// <summary>Set by the line chart while drawing: where its plot is, to turn a pointer position into x.</summary>
    public ChartFrame? Plot { get; set; }

    internal string T(string source) => Tr.T(source, English);

    internal string F(string template, params object[] args) =>
        Printf.Format(Tr.T(template, English), args);
}

/// <summary>A line chart's plot area and x domain.</summary>
public sealed record ChartFrame(double Left, double Top, double Width, double Height, double XMin, double XMax)
{
    public double XAt(double px) => Width > 0 ? XMin + (px - Left) / Width * (XMax - XMin) : XMin;
}

/// <summary>
/// The figures of a report, drawn as Shared/PoseUI/ReportFigures.swift draws them (ArenaFigureView,
/// ArenaPlotView, FrameFigureView, TimelineChart, BarsChart, LineChartView, PolarPlotView,
/// TableBlockView). Each method draws with its top-left at (x, y), <c>width</c> wide, and returns the
/// height it used; the Mac's SwiftUI frame sizes are kept (380 high at most for arena plots, 200 for
/// bars, 220 for lines, 300 wide at most for polar plots).
/// </summary>
public static class ReportFigures
{
    public static double Paint(IFigureCanvas c, ReportBlock b, double x, double y, double width, FigureOptions o) =>
        b.Kind switch
        {
            "arena" when b.Arena is { } a => Arena(c, a, x, y, width, o),
            "timeline" when b.Timeline is { } t => Timeline(c, t, x, y, width, o),
            "bars" when b.Bars is { } bars => Bars(c, bars, x, y, width, o),
            "line" when b.Line is { } line => Line(c, line, x, y, width, o),
            "polar" when b.Polar is { } p => Polar(c, p, x, y, width, o),
            "table" when b.Table is { } t => Table(c, t, x, y, width, o),
            _ => 0,
        };

    /// <summary>The width a table needs (it scrolls sideways on screen when wider than its card); null for the others.</summary>
    public static double? NaturalWidth(IFigureCanvas c, ReportBlock b) =>
        b.Kind == "table" && b.Table is { } t ? TableWidth(c, t).Total : null;

    /// <summary>Export width of a card: wider when the original frame is shown next to the heat map.</summary>
    public static double ExportWidth(ReportBlock b, FigureOptions o) =>
        b.Arena is { Heat: not null, Frame.IsMetric: true } && o.Backdrop is not null
        && o.Style.Backdrop == HeatBackdrops.SideBySide
            ? 640 : 420;

    // ================================================================ arena

    /// <summary>ArenaFigureView: the plot alone, or a heat map on / next to the calibration frame.</summary>
    public static double Arena(IFigureCanvas c, ReportArena a, double x, double y, double width, FigureOptions o)
    {
        var style = o.Style;
        bool onFrame = a.Heat is not null && o.Backdrop is not null && a.Frame is { IsMetric: true }
                       && style.Backdrop != HeatBackdrops.None;
        if (!onFrame) return ArenaPlot(c, a, x, y, width, o, showsLegend: true);

        double h;
        if (style.Backdrop == HeatBackdrops.Overlay)
        {
            h = FrameFigure(c, a, x, y, width, o, drawsHeat: true);
        }
        else
        {
            double col = (width - 10) / 2;
            double captionH = c.Measure("Ag", FigureFonts.Caption).Height;
            double h1 = ArenaPlot(c, a, x, y, col, o, showsLegend: false);
            c.Text(o.T("热图"), x + col / 2, y + h1 + 4, FigureFonts.Caption, o.Theme.Secondary, TextAnchor.Middle);
            double h2 = FrameFigure(c, a, x + col + 10, y, col, o, drawsHeat: false);
            c.Text(o.T("原图（标定帧）"), x + col + 10 + col / 2, y + h2 + 4, FigureFonts.Caption, o.Theme.Secondary,
                   TextAnchor.Middle);
            h = Math.Max(h1, h2) + 4 + captionH;
        }
        if (style.Shows(FigureLayers.Legend)) h += 8 + HeatLegend(c, o.Theme, x, y + h + 8, width, o.English);
        return h;
    }

    private static bool HasStartEnd(ReportArena a, FigureStyle style) =>
        style.Shows(FigureLayers.Trajectory) && style.Shows(FigureLayers.StartEnd)
        && a.Paths.Any(p => p.Segments.Length > 0 && p.Opacity > 0.6);

    /// <summary>ArenaPlotView: the plot at its aspect ratio (at most 380 high), with its legend under it.</summary>
    public static double ArenaPlot(IFigureCanvas c, ReportArena a, double x, double y, double width, FigureOptions o,
                                   bool showsLegend)
    {
        double aspect = Math.Max(a.Width, 1) / Math.Max(a.Height, 1);
        double w = Math.Min(width, 380 * aspect), h = w / aspect;
        DrawArenaPlot(c, a, x + (width - w) / 2, y, w, h, o);

        var style = o.Style;
        bool startEnd = HasStartEnd(a, style);
        if (!showsLegend || !style.Shows(FigureLayers.Legend) || (a.Heat is null && !startEnd)) return h;
        if (a.Heat is not null) return h + 8 + HeatLegend(c, o.Theme, x, y + h + 8, width, o.English);
        var entries = new List<LegendEntry>
        {
            new(Rgba.Black, o.T("起点"), Glyph.Ring),
            new(Rgba.Black, o.T("终点"), Glyph.Square),
        };
        return h + 8 + Legend(c, o.Theme, entries, x, y + h + 8, width, 12);
    }

    private static FigurePath Polygon(double[] flat, Func<double, double, Pt> map)
    {
        var pts = new List<Pt>(flat.Length / 2);
        for (int i = 0; i + 1 < flat.Length; i += 2)
        {
            if (double.IsFinite(flat[i]) && double.IsFinite(flat[i + 1])) pts.Add(map(flat[i], flat[i + 1]));
        }
        return new FigurePath().AddPolyline(pts, closed: true);
    }

    private static void DrawArenaPlot(IFigureCanvas c, ReportArena a, double X, double Y, double w, double h, FigureOptions o)
    {
        var theme = o.Theme;
        var style = o.Style;
        double ex = Math.Max(a.Width, 1), ey = Math.Max(a.Height, 1);
        const double pad = 8;
        double bottom = style.Shows(FigureLayers.ScaleBar) ? 16 : 0; // room for the scale bar label
        double s = Math.Min((w - 2 * pad) / ex, (h - 2 * pad - bottom) / ey);
        if (!(s > 0)) return;
        double ox = X + (w - a.Width * s) / 2, oy = Y + (h - bottom - a.Height * s) / 2;
        Pt Vp(double px, double py) => new(ox + px * s, oy + py * s);

        // Arena.
        if (style.Shows(FigureLayers.ArenaOutline) && a.Arena is { Role: "arena" } arena)
        {
            var path = Polygon(arena.Outline, Vp);
            c.Fill(path, theme.Inset);
            c.Stroke(path, theme.Secondary.Opacity(0.5), 1);
        }

        // Heat map: cells grouped by colour step, one fill per step.
        if (a.Heat is { } heat)
        {
            double maxV = MaxFinite(heat.Values);
            if (maxV > 0)
            {
                double cw = heat.Cell * s;
                var empty = new FigurePath();
                var steps = new FigurePath?[Palette.HeatStepCount + 1];
                for (int r = 0; r < heat.Rows; r++)
                {
                    for (int col = 0; col < heat.Columns; col++)
                    {
                        int i = r * heat.Columns + col;
                        if (i >= heat.Values.Length) continue;
                        double v = heat.Values[i];
                        if (!double.IsFinite(v)) continue;
                        double rx = ox + col * cw, ry = oy + r * cw;
                        if (v <= 0)
                        {
                            empty.AddRect(rx, ry, cw + 0.5, cw + 0.5);
                        }
                        else
                        {
                            int k = Palette.HeatStep(Math.Sqrt(v / maxV));
                            (steps[k] ??= new FigurePath()).AddRect(rx, ry, cw + 0.5, cw + 0.5);
                        }
                    }
                }
                if (!empty.IsEmpty) c.Fill(empty, Palette.Heat(0).Opacity(0.85));
                for (int k = 0; k < steps.Length; k++)
                {
                    if (steps[k] is { IsEmpty: false } p) c.Fill(p, Palette.Heat(Palette.HeatStepValue(k)));
                }
            }
        }

        // Zones.
        foreach (var z in a.Zones)
        {
            if (z.Role == "arena" || !style.Shows(z)) continue;
            var path = Polygon(z.Outline, Vp);
            var color = Palette.Zone(z.Role, theme);
            if (!z.OutlineOnly && z.Role != "hole" && a.Heat is null)
                c.Fill(path, color.Opacity(z.Role == "dark" ? 0.22 : 0.14));
            c.Stroke(path, a.Heat is null ? color.Opacity(0.85) : Rgba.White.Opacity(0.85),
                     z.OutlineOnly ? 0.8 : 1.2, z.OutlineOnly ? new StrokeStyle([3, 3]) : null);
        }

        // Paths: all segments of a path in one stroke.
        if (style.Shows(FigureLayers.Trajectory))
        {
            foreach (var p in a.Paths)
            {
                var path = new FigurePath();
                foreach (var seg in p.Segments)
                {
                    if (seg.Length < 4) continue;
                    var pts = new List<Pt>(seg.Length / 2);
                    for (int i = 0; i + 1 < seg.Length; i += 2) pts.Add(Vp(seg[i], seg[i + 1]));
                    path.AddPolyline(pts, closed: false);
                }
                if (path.IsEmpty) continue;
                c.Stroke(path, Palette.Color(p.Color, theme).Opacity(p.Opacity), p.Width, StrokeStyle.RoundCaps);
            }
        }

        // Start: open circle; end: filled square — black with a white halo, so they never read as the coloured
        // event dots.
        if (HasStartEnd(a, style))
        {
            var first = a.Paths.First(p => p.Segments.Length > 0 && p.Opacity > 0.6);
            const double r = 4.5;
            var firstSeg = first.Segments[0];
            if (firstSeg.Length >= 2)
            {
                var pc = Vp(firstSeg[0], firstSeg[1]);
                var ring = FigurePath.Circle(pc.X, pc.Y, r);
                c.Stroke(ring, Rgba.White, 4);
                c.Stroke(ring, Rgba.Black, 2);
            }
            var lastSeg = first.Segments[^1];
            if (lastSeg.Length >= 2)
            {
                var pc = Vp(lastSeg[^2], lastSeg[^1]);
                var square = FigurePath.Rect(pc.X - r, pc.Y - r, 2 * r, 2 * r);
                c.Stroke(square, Rgba.White, 3);
                c.Fill(square, Rgba.Black);
            }
        }

        // Dots: one fill per colour, in the order the colours first appear.
        if (style.Shows(FigureLayers.Dots) && a.Dots.Length > 0)
        {
            var order = new List<string>();
            var byColor = new Dictionary<string, FigurePath>();
            foreach (var d in a.Dots)
            {
                if (!double.IsFinite(d.X) || !double.IsFinite(d.Y)) continue;
                if (!byColor.TryGetValue(d.Color, out var path))
                {
                    order.Add(d.Color);
                    byColor[d.Color] = path = new FigurePath();
                }
                var pc = Vp(d.X, d.Y);
                path.AddCircle(pc.X, pc.Y, d.Radius, 12);
            }
            foreach (var key in order) c.Fill(byColor[key], Palette.Color(key, theme).Opacity(0.85));
        }

        if (style.Shows(FigureLayers.Arrows))
        {
            foreach (var ar in a.Arrows)
            {
                if (ar.From.Length < 2 || ar.To.Length < 2) continue;
                var p0 = Vp(ar.From[0], ar.From[1]);
                var p1 = Vp(ar.To[0], ar.To[1]);
                double ang = Math.Atan2(p1.Y - p0.Y, p1.X - p0.X);
                const double head = 4;
                var path = new FigurePath()
                    .MoveTo(p0.X, p0.Y).LineTo(p1.X, p1.Y)
                    .MoveTo(p1.X, p1.Y).LineTo(p1.X - head * Math.Cos(ang - 0.5), p1.Y - head * Math.Sin(ang - 0.5))
                    .MoveTo(p1.X, p1.Y).LineTo(p1.X - head * Math.Cos(ang + 0.5), p1.Y - head * Math.Sin(ang + 0.5));
                c.Stroke(path, Palette.Color(ar.Color, theme).Opacity(0.75), 1.1, StrokeStyle.RoundCaps);
            }
        }

        // Zone labels on top, with a halo so they stay legible on the heat map and paths.
        if (style.Shows(FigureLayers.ZoneLabels))
        {
            foreach (var z in a.Zones)
            {
                if (z.Role == "arena" || !z.ShowsLabel || z.Title.Length == 0 || !style.Shows(z) || z.Center.Length < 2) continue;
                var pc = Vp(z.Center[0], z.Center[1]);
                c.Text(z.Title, pc.X, pc.Y, FigureFonts.Label11Semibold, theme.Primary, TextAnchor.Middle,
                       TextBaseline.Middle, halo: theme.Card.Opacity(0.9));
            }
        }

        // Scale bar.
        string unit = a.Unit;
        double barLen = unit == "cm" ? (a.Width > 60 ? 20 : 10) : Fmt.Round(a.Width / 5);
        if (style.Shows(FigureLayers.ScaleBar) && barLen > 0)
        {
            double yb = Y + h - 6;
            c.Stroke(FigurePath.Segment(ox, yb, ox + barLen * s, yb), theme.Secondary, 2);
            c.Text($"{(long)barLen} {unit}", ox + barLen * s + 5, yb, FigureFonts.Label11Medium, theme.Secondary,
                   TextAnchor.Start, TextBaseline.Middle);
        }
    }

    /// <summary>
    /// FrameFigureView: the calibration frame, cropped to the arena, with the zones and (optionally) the heat
    /// map mapped into the picture through the calibration.
    /// </summary>
    public static double FrameFigure(IFigureCanvas c, ReportArena a, double x, double y, double width, FigureOptions o,
                                     bool drawsHeat)
    {
        if (a.Frame is not { } frame || o.Backdrop is not { } image) return 0;
        var crop = frame.Crop ?? new ReportBox { X = 0, Y = 0, W = frame.FrameWidth, H = frame.FrameHeight };
        double aspect = Math.Max(crop.W, 1) / Math.Max(crop.H, 1);
        double w = Math.Min(width, 380 * aspect), h = w / aspect;
        double X = x + (width - w) / 2, Y = y;
        double s = Math.Min(w / Math.Max(crop.W, 1), h / Math.Max(crop.H, 1));
        double ox = X + (w - crop.W * s) / 2 - crop.X * s;
        double oy = Y + (h - crop.H * s) / 2 - crop.Y * s;
        Pt Vp(double px, double py) => new(ox + px * s, oy + py * s);
        var theme = o.Theme;
        var style = o.Style;

        c.PushClip(FigurePath.Rect(ox + crop.X * s, oy + crop.Y * s, crop.W * s, crop.H * s));
        // The frame, scaled so that video pixels map onto the canvas.
        c.Image(image, ox, oy, frame.FrameWidth * s, frame.FrameHeight * s);

        if (drawsHeat && a.Heat is { } heat)
        {
            double maxV = MaxFinite(heat.Values);
            if (maxV > 0)
            {
                var steps = new FigurePath?[Palette.HeatStepCount + 1];
                var cells = frame.HeatCells;
                for (int i = 0; i + 8 < cells.Length; i += 9)
                {
                    int index = (int)cells[i];
                    if (index < 0 || index >= heat.Values.Length) continue;
                    double v = heat.Values[index];
                    if (!double.IsFinite(v) || v <= 0) continue;
                    var quad = new Pt[4];
                    bool finite = true;
                    for (int k = 0; k < 4; k++)
                    {
                        double px = cells[i + 1 + 2 * k], py = cells[i + 2 + 2 * k];
                        finite &= double.IsFinite(px) && double.IsFinite(py);
                        quad[k] = Vp(px, py);
                    }
                    if (!finite) continue;
                    int step = Palette.HeatStep(Math.Sqrt(v / maxV));
                    (steps[step] ??= new FigurePath()).AddPolyline(quad, closed: true);
                }
                for (int k = 0; k < steps.Length; k++)
                {
                    if (steps[k] is { IsEmpty: false } p)
                        c.Fill(p, Palette.Heat(Palette.HeatStepValue(k)).Opacity(style.OverlayOpacity));
                }
            }
        }

        // Arena and zones in the picture.
        if (style.Shows(FigureLayers.ArenaOutline) && a.Arena is { Role: "arena", Image: { } arenaImage })
            c.Stroke(Polygon(arenaImage, Vp), Rgba.White.Opacity(0.9), 1.2);
        foreach (var z in a.Zones)
        {
            if (z.Role == "arena" || !style.Shows(z) || z.Image is not { } outline) continue;
            c.Stroke(Polygon(outline, Vp), Palette.Zone(z.Role, theme).Opacity(0.95), z.OutlineOnly ? 0.8 : 1.4,
                     z.OutlineOnly ? new StrokeStyle([3, 3]) : null);
        }
        if (style.Shows(FigureLayers.ZoneLabels))
        {
            foreach (var z in a.Zones)
            {
                if (z.Role == "arena" || !z.ShowsLabel || z.Title.Length == 0 || !style.Shows(z)
                    || z.ImageCenter is not { Length: >= 2 } center) continue;
                var pc = Vp(center[0], center[1]);
                c.Text(z.Title, pc.X, pc.Y, FigureFonts.Label11Semibold, Rgba.White, TextAnchor.Middle,
                       TextBaseline.Middle, halo: Rgba.Black.Opacity(0.9));
            }
        }
        c.PopClip();
        return h;
    }

    private static double MaxFinite(double[] values)
    {
        double max = 0;
        foreach (double v in values)
        {
            if (double.IsFinite(v) && v > max) max = v;
        }
        return max;
    }

    // ================================================================ timeline

    /// <summary>TimelineChart: one row per behaviour, a label column as wide as the longest label (at most 130).</summary>
    public static double Timeline(IFigureCanvas c, ReportTimeline t, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        var font = FigureFonts.Caption;
        const double rowHeight = 20, hSpacing = 8, vSpacing = 6;
        double span = Math.Max(t.End - t.Start, 1e-6);
        double label = 0;
        foreach (var track in t.Tracks) label = Math.Max(label, 8 + 5 + c.Measure(track.Name, font).Width);
        label = Math.Min(130, label);
        double bx = x + label + hSpacing, bw = Math.Max(1, width - label - hSpacing);
        double cy = y;

        foreach (var track in t.Tracks)
        {
            var color = MarkColor(track, theme);
            double mid = cy + rowHeight / 2;
            if (track.IsFlag) Hatch(c, FigurePath.RoundedRect(x + 0.5, mid - 3.5, 7, 7, 2), x + 0.5, mid - 3.5, 7, 7, color);
            else c.Fill(FigurePath.RoundedRect(x, mid - 4, 8, 8, 2), color);
            c.Text(Fit(c, track.Name, font, label - 13), x + 13, mid, font, theme.Primary, TextAnchor.Start, TextBaseline.Middle);
            DrawTrack(c, t, track, bx, cy, bw, rowHeight, span, theme);
            cy += rowHeight + vSpacing;
        }

        // Time axis.
        var f2 = FigureFonts.Caption2;
        double lineH = c.Measure("0:00", f2).Height;
        c.Text(Fmt.Clock(0), bx, cy, f2, theme.Secondary);
        c.Text(Fmt.Clock(span / 2), bx + bw / 2, cy, f2, theme.Secondary, TextAnchor.Middle);
        c.Text(Fmt.Clock(span), bx + bw, cy, f2, theme.Secondary, TextAnchor.End);
        cy += lineH + 1;
        cy += Paragraph(c, o.T("距分析起点的时间（m:ss）"), bx, cy, bw, f2, theme.Secondary, TextAnchor.Middle);

        // Sub-bout names (e.g. "Clinch") and the epochs.
        var entries = new List<LegendEntry>();
        foreach (var track in t.Tracks)
        {
            if (track.Inner.Length > 0 && track.InnerName is { } name)
                entries.Add(new LegendEntry(Palette.Color(track.InnerColor, theme), name));
        }
        var seen = new HashSet<string>();
        foreach (var e in t.Epochs)
        {
            if (seen.Add(e.Name)) entries.Add(new LegendEntry(Palette.Color(e.Color, theme).Opacity(0.35), e.Name));
        }
        if (entries.Count > 0)
        {
            cy += vSpacing;
            cy += Legend(c, theme, entries, bx, cy, bw, 10);
        }
        return cy - y;
    }

    /// <summary>Neutral "moments to check" use the secondary ink (visible in light and dark).</summary>
    private static Rgba MarkColor(ReportTrack t, FigureTheme theme) =>
        t.IsFlag && t.Color == "neutral" ? theme.Secondary : Palette.Color(t.Color, theme);

    /// <summary>One row of the ethogram; also used under the review player.</summary>
    public static void DrawTrack(IFigureCanvas c, ReportTimeline t, ReportTrack track, double x0, double y0,
                                 double width, double height, double span, FigureTheme theme)
    {
        double X(double time) => (time - t.Start) / span * width;
        c.Fill(FigurePath.RoundedRect(x0, y0, width, height, 4), theme.Inset);
        foreach (var e in t.Epochs)
        {
            double ex0 = X(e.Start), ex1 = X(e.End);
            c.Fill(FigurePath.Rect(x0 + ex0, y0, Math.Max(1.5, ex1 - ex0), height), Palette.Color(e.Color, theme).Opacity(0.18));
        }
        var color = MarkColor(track, theme);
        (double X, double W)? Span(double start, double end)
        {
            double a = Math.Max(0, X(start)), b = Math.Min(width, X(end));
            if (!(b > a - 0.5)) return null;
            return (a, Math.Max(1.2, b - a));
        }
        if (!track.IsFlag)
        {
            for (int i = 0; i + 1 < track.Bouts.Length; i += 2)
            {
                if (Span(track.Bouts[i], track.Bouts[i + 1]) is { } r)
                    c.Fill(FigurePath.RoundedRect(x0 + r.X, y0 + 2, r.W, height - 4, 2), color);
            }
            // Sub-bouts (e.g. clinch inside attacks) as a darker band.
            var inner = Palette.Color(track.InnerColor, theme);
            for (int i = 0; i + 1 < track.Inner.Length; i += 2)
            {
                if (Span(track.Inner[i], track.Inner[i + 1]) is { } r)
                    c.Fill(FigurePath.Rect(x0 + r.X, y0 + 6, r.W, height - 12), inner);
            }
        }
        else
        {
            var bars = new FigurePath();
            for (int i = 0; i + 1 < track.Bouts.Length; i += 2)
            {
                if (Span(track.Bouts[i], track.Bouts[i + 1]) is { } r) bars.AddRect(x0 + r.X, y0 + 2, r.W, height - 4);
            }
            Hatch(c, bars, x0, y0, width, height, color);
        }
    }

    // ================================================================ chart axes (Swift Charts' defaults)

    /// <summary>Horizontal grid lines and tick labels on the trailing side, as Swift Charts draws a y axis.</summary>
    private static void YAxis(IFigureCanvas c, Axis axis, double left, double top, double plotW, double plotH, FigureTheme theme)
    {
        var f2 = FigureFonts.Caption2;
        foreach (double tick in axis.Ticks)
        {
            double ty = axis.Map(tick, top + plotH, top);
            c.Stroke(FigurePath.Segment(left, ty, left + plotW, ty), theme.Secondary.Opacity(0.3), 0.5);
            c.Text(axis.Label(tick), left + plotW + 5, ty, f2, theme.Secondary, TextAnchor.Start, TextBaseline.Middle);
        }
    }

    private static double TickWidth(IFigureCanvas c, Axis axis) =>
        axis.Ticks.Length == 0 ? 0 : axis.Ticks.Max(t => c.Measure(axis.Label(t), FigureFonts.Caption2).Width) + 8;

    private static Axis ValueAxis(IEnumerable<double> values, double? reference, int target = 5)
    {
        var all = values.Where(double.IsFinite).ToList();
        if (reference is { } r && double.IsFinite(r)) all.Add(r);
        double lo = all.Count > 0 ? Math.Min(0, all.Min()) : 0;
        double hi = all.Count > 0 ? Math.Max(0, all.Max()) : 1;
        return Axis.Nice(lo, hi, target);
    }

    // ================================================================ bars

    /// <summary>BarsChart: vertical, horizontal or grouped bars, with an optional dashed reference line.</summary>
    public static double Bars(IFigureCanvas c, ReportBars d, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        if (d.Items.Length == 0)
        {
            c.Text(o.T("没有数据"), x, y, FigureFonts.Footnote, theme.Secondary);
            return c.Measure("Ag", FigureFonts.Footnote).Height;
        }
        if (d.Items.Any(i => i.Group is not null)) return GroupedBars(c, d, x, y, width, o);
        return d.Horizontal ? HorizontalBars(c, d, x, y, width, o) : VerticalBars(c, d, x, y, width, o);
    }

    private static string BarLabel(ReportBars d, double v) => Fmt.Number(v, d.Decimals);

    /// <summary>The reference line's own label, or its value with the unit.</summary>
    private static string ReferenceText(ReportBars d, double reference) =>
        d.ReferenceLabel ?? Fmt.Number(reference, reference == Fmt.Round(reference) ? 0 : 1) + (d.Unit == "%" ? "%" : " " + d.Unit);

    private static double VerticalBars(IFigureCanvas c, ReportBars d, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        var f2 = FigureFonts.Caption2;
        const double height = 200;
        double lineH = c.Measure("Ag", f2).Height;
        var axis = ValueAxis(d.Items.Select(i => i.Value), d.ReferenceLine);
        double tickW = TickWidth(c, axis);
        double top = y + lineH + 4;                 // y axis label
        bool annotate = d.Items.Length <= 8;
        double plotTop = top + (annotate ? lineH + 3 : 0);
        double plotBottom = y + height - lineH - 4; // category labels
        double plotH = plotBottom - plotTop, plotW = width - tickW;
        if (d.Unit.Length > 0) c.Text(d.Unit, x + width, y, f2, theme.Secondary, TextAnchor.End);
        YAxis(c, axis, x, plotTop, plotW, plotH, theme);

        double band = plotW / d.Items.Length, barW = band * 0.6;
        double zero = axis.Map(0, plotBottom, plotTop);
        for (int i = 0; i < d.Items.Length; i++)
        {
            var item = d.Items[i];
            double cx = x + band * (i + 0.5);
            double vy = axis.Map(item.Value, plotBottom, plotTop);
            double t0 = Math.Min(vy, zero), t1 = Math.Max(vy, zero);
            if (t1 - t0 > 0.1) c.Fill(FigurePath.RoundedRect(cx - barW / 2, t0, barW, t1 - t0, 4), Palette.Color(item.Color, theme));
            if (annotate)
            {
                c.Text(BarLabel(d, item.Value), cx, item.Value >= 0 ? t0 - 3 : t1 + 3, FigureFonts.Caption2Medium, theme.Secondary,
                       TextAnchor.Middle, item.Value >= 0 ? TextBaseline.Bottom : TextBaseline.Top);
            }
            c.Text(Fit(c, item.Label, f2, band - 2), cx, plotBottom + 4, f2, theme.Secondary, TextAnchor.Middle);
        }
        if (d.ReferenceLine is { } reference && double.IsFinite(reference))
        {
            double ry = axis.Map(reference, plotBottom, plotTop);
            c.Stroke(FigurePath.Segment(x, ry, x + plotW, ry), theme.Secondary, 1, new StrokeStyle([4, 3]));
            FigureKit.ReferenceLabel(c, theme, ReferenceText(d, reference), x + plotW, ry - 2, TextAnchor.End);
        }
        return height;
    }

    private static double HorizontalBars(IFigureCanvas c, ReportBars d, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        var f2 = FigureFonts.Caption2;
        double height = Math.Max(3, d.Items.Length) * 30 + 30;
        double lineH = c.Measure("Ag", f2).Height;
        double labelW = Math.Min(width * 0.4, d.Items.Max(i => c.Measure(i.Label, f2).Width) + 8);
        var axis = ValueAxis(d.Items.Select(i => i.Value), d.ReferenceLine);
        double valueW = d.Items.Max(i => c.Measure(BarLabel(d, i.Value), FigureFonts.Caption2Medium).Width) + 6;
        double left = x + labelW, plotW = Math.Max(10, width - labelW - valueW);
        double plotTop = y + lineH + 4, plotBottom = y + height - 2 * lineH - 6;
        double band = (plotBottom - plotTop) / d.Items.Length, barH = band * 0.6;
        double zero = axis.Map(0, left, left + plotW);

        foreach (double tick in axis.Ticks)
        {
            double tx = axis.Map(tick, left, left + plotW);
            c.Stroke(FigurePath.Segment(tx, plotTop, tx, plotBottom), theme.Secondary.Opacity(0.3), 0.5);
            c.Text(axis.Label(tick), tx, plotBottom + 3, f2, theme.Secondary, TextAnchor.Middle);
        }
        if (d.Unit.Length > 0) c.Text(d.Unit, left + plotW, plotBottom + lineH + 5, f2, theme.Secondary, TextAnchor.End);

        for (int i = 0; i < d.Items.Length; i++)
        {
            var item = d.Items[i];
            double cy = plotTop + band * (i + 0.5);
            double vx = axis.Map(item.Value, left, left + plotW);
            double x0 = Math.Min(vx, zero), x1 = Math.Max(vx, zero);
            if (x1 - x0 > 0.1) c.Fill(FigurePath.RoundedRect(x0, cy - barH / 2, x1 - x0, barH, 4), Palette.Color(item.Color, theme));
            c.Text(Fit(c, item.Label, f2, labelW - 6), left - 6, cy, f2, theme.Secondary, TextAnchor.End, TextBaseline.Middle);
            c.Text(BarLabel(d, item.Value), x1 + 4, cy, FigureFonts.Caption2Medium, theme.Secondary, TextAnchor.Start, TextBaseline.Middle);
        }
        if (d.ReferenceLine is { } reference && double.IsFinite(reference))
        {
            double rx = axis.Map(reference, left, left + plotW);
            c.Stroke(FigurePath.Segment(rx, plotTop, rx, plotBottom), theme.Secondary, 1, new StrokeStyle([4, 3]));
            FigureKit.ReferenceLabel(c, theme, ReferenceText(d, reference), rx, plotTop - 1, TextAnchor.Start);
        }
        return height;
    }

    private static double GroupedBars(IFigureCanvas c, ReportBars d, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        var f2 = FigureFonts.Caption2;
        const double chartHeight = 220;
        // Legend on top, leading (chartLegend(position: .top, alignment: .leading)): one entry per label.
        var labels = new List<string>();
        var colors = new Dictionary<string, Rgba>();
        foreach (var item in d.Items)
        {
            if (colors.ContainsKey(item.Label)) continue;
            labels.Add(item.Label);
            colors[item.Label] = Palette.Color(item.Color, theme);
        }
        double legendH = Legend(c, theme, labels.Select(l => new LegendEntry(colors[l], l)).ToList(), x, y, width, 12);
        double cy = y + legendH + 8;
        double height = chartHeight - legendH - 8;

        var groups = new List<string>();
        foreach (var item in d.Items)
        {
            string g = item.Group ?? "";
            if (!groups.Contains(g)) groups.Add(g);
        }
        double lineH = c.Measure("Ag", f2).Height;
        var axis = ValueAxis(d.Items.Select(i => i.Value), d.ReferenceLine);
        double tickW = TickWidth(c, axis);
        double plotTop = cy + lineH + 4, plotBottom = cy + height - lineH - 4;
        double plotW = width - tickW, plotH = plotBottom - plotTop;
        if (d.Unit.Length > 0) c.Text(d.Unit, x + width, cy, f2, theme.Secondary, TextAnchor.End);
        YAxis(c, axis, x, plotTop, plotW, plotH, theme);

        double band = plotW / Math.Max(1, groups.Count);
        double sub = band * 0.8 / Math.Max(1, labels.Count);
        double zero = axis.Map(0, plotBottom, plotTop);
        foreach (var item in d.Items)
        {
            int g = groups.IndexOf(item.Group ?? ""), k = labels.IndexOf(item.Label);
            double bx = x + band * g + band * 0.1 + sub * k;
            double vy = axis.Map(item.Value, plotBottom, plotTop);
            double t0 = Math.Min(vy, zero), t1 = Math.Max(vy, zero);
            if (t1 - t0 > 0.1) c.Fill(FigurePath.RoundedRect(bx + 0.5, t0, Math.Max(1, sub - 1), t1 - t0, 3), colors[item.Label]);
        }
        for (int g = 0; g < groups.Count; g++)
            c.Text(Fit(c, groups[g], f2, band - 2), x + band * (g + 0.5), plotBottom + 4, f2, theme.Secondary, TextAnchor.Middle);
        if (d.ReferenceLine is { } reference && double.IsFinite(reference))
        {
            double ry = axis.Map(reference, plotBottom, plotTop);
            c.Stroke(FigurePath.Segment(x, ry, x + plotW, ry), theme.Secondary, 1, new StrokeStyle([4, 3]));
            FigureKit.ReferenceLabel(c, theme, ReferenceText(d, reference), x + plotW, ry - 2, TextAnchor.End);
        }
        return chartHeight;
    }

    // ================================================================ lines

    /// <summary>
    /// LineChartView. Many repeated traces (more than four, e.g. one per looming trial) are drawn as thin
    /// neutral lines with their mean emphasized. A pointer over the plot shows the values under it.
    /// </summary>
    public static double Line(IFigureCanvas c, ReportLine d, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        var f2 = FigureFonts.Caption2;
        const double chartHeight = 220;
        bool trials = d.Series.Length > 4;
        var finite = new List<(int Series, double X, double Y)>();
        for (int s = 0; s < d.Series.Length; s++)
        {
            var pts = d.Series[s].Points;
            for (int i = 0; i + 1 < pts.Length; i += 2)
            {
                if (double.IsFinite(pts[i]) && double.IsFinite(pts[i + 1])) finite.Add((s, pts[i], pts[i + 1]));
            }
        }
        var mean = trials ? MeanSeries(finite) : new List<Pt>();
        double lineH = c.Measure("Ag", f2).Height;

        // Legend of the series (Swift Charts: under the chart, leading) — inside the chart's 220.
        double legendH = 0;
        List<LegendEntry>? seriesLegend = null;
        if (!trials && d.Series.Length > 1)
        {
            seriesLegend = d.Series.Select(s => new LegendEntry(Palette.Color(s.Color, theme), s.Name, Glyph.Dot)).ToList();
            legendH = Legend(new MeasureCanvas(c.Measure), theme, seriesLegend, x, 0, width, 12) + 6;
        }

        double xMin = finite.Count > 0 ? finite.Min(p => p.X) : 0, xMax = finite.Count > 0 ? finite.Max(p => p.X) : 1;
        var xAxis = Axis.Nice(xMin, xMax, 6);
        var ys = finite.Select(p => p.Y).ToList();
        if (d.ReferenceY is { } refY && double.IsFinite(refY)) ys.Add(refY);
        Axis yAxis;
        if (d.YRange is [var lo, var hi] && double.IsFinite(lo) && double.IsFinite(hi) && hi > lo) yAxis = Axis.Fixed(lo, hi);
        else if (ys.Count == 0) yAxis = Axis.Nice(0, 1);
        else
        {
            double ylo = ys.Min(), yhi = ys.Max();
            if (ylo >= 0) ylo = 0;
            else if (yhi <= 0) yhi = 0;
            yAxis = Axis.Nice(ylo, yhi);
        }

        double tickW = TickWidth(c, yAxis);
        double plotTop = y + lineH + 4;
        double plotBottom = y + chartHeight - legendH - 2 * lineH - 8;
        double plotW = Math.Max(10, width - tickW), plotH = Math.Max(10, plotBottom - plotTop);
        double left = x;
        o.Plot = new ChartFrame(left, plotTop, plotW, plotH, xAxis.Min, xAxis.Max);
        double Px(double v) => xAxis.Map(v, left, left + plotW);
        double Py(double v) => yAxis.Map(v, plotTop + plotH, plotTop);

        if (d.YLabel.Length > 0) c.Text(Fit(c, d.YLabel, f2, plotW), left, y, f2, theme.Secondary);
        YAxis(c, yAxis, left, plotTop, plotW, plotH, theme);
        foreach (double tick in xAxis.Ticks)
        {
            double tx = Px(tick);
            c.Stroke(FigurePath.Segment(tx, plotTop + plotH, tx, plotTop + plotH + 3), theme.Secondary.Opacity(0.5), 0.5);
            c.Text(xAxis.Label(tick), tx, plotTop + plotH + 4, f2, theme.Secondary, TextAnchor.Middle);
        }
        if (d.XLabel.Length > 0)
            c.Text(Fit(c, d.XLabel, f2, plotW), left + plotW, plotTop + plotH + 4 + lineH + 2, f2, theme.Secondary, TextAnchor.End);

        c.PushClip(FigurePath.Rect(left, plotTop, plotW, plotH));
        foreach (var e in d.Epochs)
        {
            double e0 = Px(e.Start), e1 = Px(e.End);
            c.Fill(FigurePath.Rect(Math.Min(e0, e1), plotTop, Math.Abs(e1 - e0), plotH), Palette.Color(e.Color, theme).Opacity(0.14));
        }
        for (int s = 0; s < d.Series.Length; s++)
        {
            var pts = finite.Where(p => p.Series == s).Select(p => new Pt(Px(p.X), Py(p.Y))).ToList();
            if (pts.Count < 2) continue;
            var path = new FigurePath().AddPolyline(pts, closed: false);
            if (trials) c.Stroke(path, theme.Secondary.Opacity(0.35), 1, StrokeStyle.RoundCaps);
            else c.Stroke(path, Palette.Color(d.Series[s].Color, theme), 2, StrokeStyle.RoundCaps);
        }
        if (trials && mean.Count > 1)
            c.Stroke(new FigurePath().AddPolyline(mean.Select(p => new Pt(Px(p.X), Py(p.Y))).ToList(), closed: false),
                     theme.Accent, 2.5, StrokeStyle.RoundCaps);
        c.PopClip();

        if (d.ReferenceY is { } ry && double.IsFinite(ry))
        {
            double py = Py(ry);
            c.Stroke(FigurePath.Segment(left, py, left + plotW, py), theme.Secondary.Opacity(0.7), 1, new StrokeStyle([4, 3]));
            string label = d.ReferenceYLabel ?? Fmt.Number(ry, ry == Fmt.Round(ry) ? 0 : 1) + " " + d.YLabel;
            FigureKit.ReferenceLabel(c, theme, label, left + plotW, py - 2, TextAnchor.End);
        }
        if (d.ReferenceX is { } rx && double.IsFinite(rx))
        {
            double px = Px(rx);
            c.Stroke(FigurePath.Segment(px, plotTop, px, plotTop + plotH), theme.Secondary.Opacity(0.7), 1, new StrokeStyle([4, 3]));
            string label = d.ReferenceXLabel ?? Fmt.Number(rx, rx == Fmt.Round(rx) ? 0 : 1) + " " + d.XLabel;
            FigureKit.ReferenceLabel(c, theme, label, px + 2, plotTop + c.Measure("Ag", f2).Height + 1, TextAnchor.Start);
        }

        if (seriesLegend is not null)
            Legend(c, theme, seriesLegend, x, y + chartHeight - legendH + 6, width, 12);

        if (o.HoverX is { } hx && hx >= xAxis.Min && hx <= xAxis.Max)
            HoverCard(c, d, finite, mean, trials, hx, Px(hx), plotTop, plotH, x, width, o);

        double h = chartHeight;
        if (trials)
        {
            var entries = new List<LegendEntry>
            {
                new(theme.Secondary.Opacity(0.5), o.F("单次（%d）", d.Series.Length), Glyph.Line),
                new(theme.Accent, o.T("平均"), Glyph.Line),
            };
            h += 8 + Legend(c, theme, entries, x, y + h + 8, width, 14);
        }
        return h;
    }

    /// <summary>The mean of many traces in 80 bins (LineChartView.mean).</summary>
    private static List<Pt> MeanSeries(List<(int Series, double X, double Y)> pts)
    {
        var mean = new List<Pt>();
        if (pts.Count == 0) return mean;
        double lo = pts.Min(p => p.X), hi = pts.Max(p => p.X);
        if (!(hi > lo)) return mean;
        const int bins = 80;
        double w = (hi - lo) / bins;
        var sum = new double[bins];
        var n = new int[bins];
        foreach (var p in pts)
        {
            int b = Math.Min(bins - 1, Math.Max(0, (int)((p.X - lo) / w)));
            sum[b] += p.Y;
            n[b]++;
        }
        for (int b = 0; b < bins; b++)
        {
            if (n[b] > 0) mean.Add(new Pt(lo + (b + 0.5) * w, sum[b] / n[b]));
        }
        return mean;
    }

    /// <summary>The read-out under the pointer: the value of each series nearest to x (selectionCard).</summary>
    private static void HoverCard(IFigureCanvas c, ReportLine d, List<(int Series, double X, double Y)> finite, List<Pt> mean,
                                  bool trials, double hx, double px, double plotTop, double plotH, double chartX,
                                  double chartW, FigureOptions o)
    {
        var theme = o.Theme;
        c.Stroke(FigurePath.Segment(px, plotTop, px, plotTop + plotH), theme.Primary.Opacity(0.35), 1);
        var rows = new List<(string Name, double Value, Rgba Color)>();
        if (trials)
        {
            if (mean.Count > 0)
            {
                var near = mean.MinBy(p => Math.Abs(p.X - hx));
                rows.Add((o.T("平均"), near.Y, theme.Accent));
            }
        }
        else
        {
            for (int s = 0; s < d.Series.Length && rows.Count < 4; s++)
            {
                var candidates = finite.Where(p => p.Series == s).ToList();
                if (candidates.Count == 0) continue;
                var near = candidates.MinBy(p => Math.Abs(p.X - hx));
                rows.Add((d.Series[s].Name, near.Y, Palette.Color(d.Series[s].Color, theme)));
            }
        }
        var f2 = FigureFonts.Caption2;
        var f2b = FigureFonts.Caption2Semibold;
        string head = $"{d.XLabel} {Fmt.Number(hx, 2)}";
        double lineH = c.Measure("Ag", f2).Height + 3;
        double w = c.Measure(head, f2b).Width;
        foreach (var r in rows)
            w = Math.Max(w, 15 + c.Measure(r.Name, f2).Width + 5 + c.Measure(Fmt.Number(r.Value, 2), f2b).Width);
        w += 16;
        double h = 12 + lineH * (1 + rows.Count);
        double left = Math.Clamp(px - w / 2, chartX, Math.Max(chartX, chartX + chartW - w));
        double top = plotTop + 4;
        var card = FigurePath.RoundedRect(left, top, w, h, 8);
        c.Fill(FigurePath.RoundedRect(left, top + 2, w, h, 8), Rgba.Black.Opacity(0.06));
        c.Fill(card, theme.Card);
        c.Stroke(card, theme.Hairline, 0.5);
        c.Text(head, left + 8, top + 6, f2b, theme.Secondary);
        for (int i = 0; i < rows.Count; i++)
        {
            double ry = top + 6 + lineH * (i + 1);
            double mid = ry + (lineH - 3) / 2;
            c.Fill(FigurePath.RoundedRect(left + 8, mid - 1.5, 10, 3, 1.5), rows[i].Color);
            c.Text(rows[i].Name, left + 23, mid, f2, theme.Secondary, TextAnchor.Start, TextBaseline.Middle);
            c.Text(Fmt.Number(rows[i].Value, 2), left + w - 8, mid, f2b, theme.Primary, TextAnchor.End, TextBaseline.Middle);
        }
    }

    // ================================================================ polar

    /// <summary>PolarPlotView: wedges on a square-root radius scale, rings at 25 / 50 / 100 % of the largest bin.</summary>
    public static double Polar(IFigureCanvas c, ReportPolar d, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        double size = Math.Min(width, 300);
        double cx = x + width / 2, cy = y + size / 2;
        double R = size / 2 - 24;
        int n = Math.Max(1, d.Values.Length);
        double maxV = Math.Max(d.Values.Where(double.IsFinite).DefaultIfEmpty(0).Max(), 1e-9);
        Pt P(double deg, double r)
        {
            double a = deg * Math.PI / 180;
            return new Pt(cx + r * Math.Cos(a), cy - r * Math.Sin(a));
        }

        double[] rings = [0.25, 0.5, 1.0];
        foreach (double f in rings)
        {
            double r = R * Math.Sqrt(f);
            c.Stroke(FigurePath.Circle(cx, cy, r), theme.Secondary.Opacity(f == 1 ? 0.45 : 0.18), f == 1 ? 1 : 0.7);
        }
        for (double deg = 0; deg < 360; deg += 45)
        {
            var p = P(deg, R);
            c.Stroke(FigurePath.Segment(cx, cy, p.X, p.Y), theme.Secondary.Opacity(0.18), 0.7);
        }
        // Wedges.
        var color = Palette.Color(d.Color, theme);
        double binWidth = 360.0 / n;
        for (int i = 0; i < d.Values.Length; i++)
        {
            double v = d.Values[i];
            if (!(v > 0)) continue;
            double r = R * Math.Sqrt(v / maxV);
            double a0 = i * binWidth, a1 = a0 + binWidth;
            var wedge = new FigurePath().MoveTo(cx, cy);
            for (int k = 0; k <= 4; k++)
            {
                var p = P(a0 + (a1 - a0) * k / 4, r);
                wedge.LineTo(p.X, p.Y);
            }
            wedge.Close();
            c.Fill(wedge, color.Opacity(0.75));
            c.Stroke(wedge, color, 0.5);
        }
        // Mean direction only (to the outer ring): its length is not a time.
        if (d.MeanAngle is { } m && double.IsFinite(m))
        {
            var tip = P(m, R);
            c.Stroke(FigurePath.Segment(cx, cy, tip.X, tip.Y), theme.Primary, 2.2, StrokeStyle.RoundCaps);
            c.Fill(FigurePath.Circle(tip.X, tip.Y, 3), theme.Primary);
        }
        if (d.ReferenceAngle is { } reference && double.IsFinite(reference))
        {
            var tip = P(reference, R);
            c.Stroke(FigurePath.Segment(cx, cy, tip.X, tip.Y), Palette.Amber, 1.5, new StrokeStyle([4, 3]));
        }
        foreach (var (deg, text) in new[] { (0.0, "0°"), (90.0, "90°"), (180.0, "180°"), (270.0, "270°") })
        {
            var p = P(deg, R + 13);
            c.Text(text, p.X, p.Y, FigureFonts.Label11Medium, theme.Secondary, TextAnchor.Middle, TextBaseline.Middle);
        }
        // Ring values along the 22.5° direction (between two spokes).
        if (d.Values.Any(v => v > 0))
        {
            foreach (double f in rings)
            {
                double v = maxV * f;
                string text = Fmt.Number(v, v >= 10 ? 0 : 1) + (d.Unit == "s" ? " s" : " " + d.Unit);
                var p = P(22.5, R * Math.Sqrt(f));
                c.Text(text, p.X, p.Y, FigureFonts.Tiny9Medium, theme.Secondary, TextAnchor.Start, TextBaseline.Bottom);
            }
        }

        double h = size + 8;
        var entries = new List<LegendEntry>();
        if (d.MeanAngle is { } mean && double.IsFinite(mean))
            entries.Add(new LegendEntry(theme.Primary, o.F("平均方向 %.0f°", mean), Glyph.Line));
        if (d.ResultantLength is { } rl && double.IsFinite(rl))
            entries.Add(new LegendEntry(theme.Secondary, o.F("平均向量长度 %.2f（0–1）", rl), Glyph.None));
        if (d.ReferenceAngle is not null) entries.Add(new LegendEntry(Palette.Amber, o.T("参考方向"), Glyph.Dashed));
        if (entries.Count > 0) h += Legend(c, theme, entries, x, y + h, width, 14, centred: true) + 8;
        string unit = d.Unit == "s" ? o.T("停留时间（s）") : d.Unit;
        h += Paragraph(c, o.F("半径按平方根标度：圈上数字为每格的%@", unit), x, y + h, width, FigureFonts.Caption2,
                       theme.Secondary, TextAnchor.Middle);
        return h;
    }

    // ================================================================ table

    private static (double[] Columns, double Total, double RowH) TableWidth(IFigureCanvas c, ReportTable t)
    {
        int cols = Math.Max(t.Columns.Length, t.Rows.Length == 0 ? 0 : t.Rows.Max(r => r.Length));
        var widths = new double[cols];
        for (int j = 0; j < t.Columns.Length; j++)
            widths[j] = c.Measure(t.Columns[j], FigureFonts.CaptionSemibold).Width;
        for (int i = 0; i < t.Rows.Length; i++)
        {
            bool dot = i < t.RowColors.Length && t.RowColors[i] is not null;
            for (int j = 0; j < t.Rows[i].Length; j++)
            {
                double w = c.Measure(t.Rows[i][j], FigureFonts.Caption).Width + (j == 0 && dot ? 10 : 0);
                widths[j] = Math.Max(widths[j], w);
            }
        }
        double total = widths.Sum() + 14 * Math.Max(0, cols - 1);
        return (widths, total, c.Measure("Ag", FigureFonts.Caption).Height);
    }

    /// <summary>TableBlockView: a header, a divider and the rows; columns as wide as their widest cell.</summary>
    public static double Table(IFigureCanvas c, ReportTable t, double x, double y, double width, FigureOptions o)
    {
        var theme = o.Theme;
        var (cols, total, rowH) = TableWidth(c, t);
        double cy = y + 2;
        double cx = x;
        for (int j = 0; j < t.Columns.Length; j++)
        {
            c.Text(t.Columns[j], cx, cy, FigureFonts.CaptionSemibold, theme.Secondary);
            cx += cols[j] + 14;
        }
        cy += rowH + 6;
        c.Stroke(FigurePath.Segment(x, cy, x + Math.Max(total, 1), cy), theme.Hairline, 1);
        cy += 6;
        for (int i = 0; i < t.Rows.Length; i++)
        {
            cx = x;
            string? colorKey = i < t.RowColors.Length ? t.RowColors[i] : null;
            for (int j = 0; j < t.Rows[i].Length && j < cols.Length; j++)
            {
                double tx = cx;
                if (j == 0 && colorKey is not null)
                {
                    c.Fill(FigurePath.Circle(cx + 3, cy + rowH / 2, 3), Palette.Color(colorKey, theme));
                    tx += 10;
                }
                c.Text(t.Rows[i][j], tx, cy, FigureFonts.Caption, theme.Primary);
                cx += cols[j] + 14;
            }
            cy += rowH + 6;
        }
        return cy - 6 + 2 - y;
    }

    // ================================================================ headline scale

    /// <summary>
    /// RPScaleBar: the headline value on its scale, filled from the reference point (or the low end), the
    /// reference as a tick, the ends and the reference labelled. Returns its height.
    /// </summary>
    public static double ScaleBar(IFigureCanvas c, ReportMetricScale scale, double value, Rgba fill, double x, double y,
                                  double width, FigureTheme theme)
    {
        double span = scale.High - scale.Low;
        double Frac(double v) => span > 0 ? Math.Clamp((v - scale.Low) / span, 0, 1) : 0;
        double origin = Frac(scale.Reference ?? scale.Low), xv = Frac(value);
        c.Fill(FigurePath.RoundedRect(x, y + 4, width, 8, 4), theme.Inset);
        double segW = Math.Max(2, Math.Abs(xv - origin) * width);
        c.Fill(FigurePath.RoundedRect(x + Math.Min(xv, origin) * width, y + 4, segW, 8, 4), fill);
        if (scale.Reference is not null)
            c.Fill(FigurePath.Rect(x + origin * width - 0.75, y, 1.5, 16), theme.Primary.Opacity(0.55));
        double kx = x + xv * width;
        c.Fill(FigurePath.Circle(kx, y + 8, 7), fill);
        c.Stroke(FigurePath.Circle(kx, y + 8, 6), theme.Card, 2);
        var f2 = FigureFonts.Caption2;
        double ly = y + 20;
        c.Text(scale.LowLabel, x, ly, f2, theme.Secondary);
        if (scale.ReferenceLabel is { Length: > 0 } label) c.Text(label, x + width / 2, ly, f2, theme.Secondary, TextAnchor.Middle);
        c.Text(scale.HighLabel, x + width, ly, f2, theme.Secondary, TextAnchor.End);
        return 20 + c.Measure("Ag", f2).Height;
    }
}
