using RodentFlow.Core.Figures;
using RodentFlow.Engine;

namespace RodentFlow.Core.Review;

/// <summary>
/// What the review draws over the video, as the Mac's review does (MacPoseDrawing, VideoReviewView.swift; AnimalGlyph
/// and its drawing, Shared/PoseEngine/AnimalGlyph.swift, Shared/PoseUI/AnimalGlyphDrawing.swift):
/// one animal as its skeleton with coloured keypoints; two or more as head triangles with a nose line, a tail-base
/// dot and a lettered badge (A blue, B red …); a fading 2-second trail; the report's zones.
/// </summary>
public static class PoseOverlay
{
    /// <summary>The skeleton (kBones, Keypoints.swift).</summary>
    private static readonly (int A, int B)[] Bones = [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 5)];

    /// <summary>
    /// Draws frame <paramref name="i"/>. <paramref name="map"/> turns frame pixels into drawing coordinates;
    /// <paramref name="scale"/> is 1.3 on a large picture, as on the Mac.
    /// </summary>
    public static void Draw(IFigureCanvas c, ReviewTrack t, int i, Func<double, double, Pt> map, double scale,
                            float minConf, FigureTheme theme) =>
        DrawAnimals(c, t.Animals, a => t.Detected(i, a), (a, k, m) => t.Point(i, a, k, m), map, scale, minConf, theme);

    /// <summary>
    /// The model's latest keypoints (the live picture while it runs, and the review video), drawn as the Mac's live view
    /// and review video draw them (NativeTrackingCanvas, AnnotatedVideoExporter): the same rules as the review.
    /// </summary>
    public static void DrawPoses(IFigureCanvas c, IReadOnlyList<PoseKeypoints> animals, Func<double, double, Pt> map,
                                 double scale, float minConf, FigureTheme theme)
    {
        (double X, double Y)? Point(int a, int k, float min)
        {
            var p = animals[a];
            if (!p.Detected || k >= p.X.Length || k >= p.Y.Length || k >= p.Kconf.Length) return null;
            if (p.Kconf[k] < min || !float.IsFinite(p.X[k]) || !float.IsFinite(p.Y[k])) return null;
            return (p.X[k], p.Y[k]);
        }
        DrawAnimals(c, animals.Count, a => animals[a].Detected, Point, map, scale, minConf, theme);
    }

    private static void DrawAnimals(IFigureCanvas c, int animals, Func<int, bool> detected,
                                    Func<int, int, float, (double X, double Y)?> point, Func<double, double, Pt> map,
                                    double scale, float minConf, FigureTheme theme)
    {
        bool multi = animals > 1;
        for (int a = 0; a < animals; a++)
        {
            if (!detected(a)) continue;
            int animal = a;
            Pt? P(int k) => point(animal, k, minConf) is { } p ? map(p.X, p.Y) : null;
            if (multi)
            {
                DrawGlyph(c, Glyph(P, 10 * scale), Palette.Animal(a), Letter(a, animals), scale);
                continue;
            }
            var bones = new FigurePath();
            foreach (var (b0, b1) in Bones)
            {
                if (P(b0) is { } p0 && P(b1) is { } p1) bones.MoveTo(p0.X, p0.Y).LineTo(p1.X, p1.Y);
            }
            if (!bones.IsEmpty)
            {
                c.Stroke(bones, Rgba.Black.Opacity(0.45), 4 * scale, StrokeStyle.RoundCaps);
                c.Stroke(bones, Rgba.White, 2 * scale, StrokeStyle.RoundCaps);
            }
            for (int k = 0; k < ReviewTrack.Keypoints; k++)
            {
                double r = 4.2 * scale;
                var color = theme.Keypoint(k);
                if (P(k) is { } q)
                {
                    c.Fill(FigurePath.Circle(q.X, q.Y, r), color);
                    c.Stroke(FigurePath.Circle(q.X, q.Y, r), Rgba.White, scale);
                }
                else if (point(animal, k, 0) is { } weak)
                {
                    // Below the analysis threshold: hollow, so what was discarded is visible.
                    var w = map(weak.X, weak.Y);
                    c.Stroke(FigurePath.Circle(w.X, w.Y, r), color.Opacity(0.6), scale);
                }
            }
        }
    }

    /// <summary>A / B for a pair, a number in a group (AnimalColors.letter).</summary>
    public static string Letter(int a, int animals) => animals > 2 ? (a + 1).ToString() : (a % 2 == 0 ? "A" : "B");

    /// <summary>AnimalGlyph: head triangle, nose line, head dots, tail base, the badge anchor.</summary>
    public sealed record AnimalGlyph(Pt[]? Triangle, Pt[]? NoseLine, Pt[] HeadDots, Pt? TailBase, Pt? Anchor);

    /// <summary>AnimalGlyph.make: <paramref name="point"/>(k) is keypoint k in drawing coordinates, or null.</summary>
    public static AnimalGlyph Glyph(Func<int, Pt?> point, double minimumExtension)
    {
        Pt? nose = point(0), left = point(1), right = point(2), neck = point(3), body = point(4), tail = point(5);
        Pt[]? triangle = null, noseLine = null;
        var headDots = new List<Pt>();
        if (nose is { } n && left is { } l && right is { } r)
        {
            triangle = [n, l, r];
            noseLine = Extend(new Pt((l.X + r.X) / 2, (l.Y + r.Y) / 2), n, 1, minimumExtension);
        }
        else
        {
            foreach (var p in new[] { nose, left, right })
            {
                if (p is { } q) headDots.Add(q);
            }
            // Without both ears the direction comes from the neck (neck → nose is about 1.6 head lengths).
            if (nose is { } n2 && neck is { } k) noseLine = Extend(k, n2, 0.6, minimumExtension);
        }
        Pt? head = triangle is not null ? Centroid(triangle) : headDots.Count > 0 ? Centroid(headDots) : null;
        return new AnimalGlyph(triangle, noseLine, headDots.ToArray(), tail, body ?? neck ?? head ?? tail);
    }

    private static Pt[]? Extend(Pt from, Pt nose, double factor, double minimum)
    {
        double dx = nose.X - from.X, dy = nose.Y - from.Y;
        double length = Math.Sqrt(dx * dx + dy * dy);
        if (!double.IsFinite(length) || length <= 1e-6) return null;
        double reach = Math.Max(length * factor, minimum);
        return [nose, new Pt(nose.X + dx / length * reach, nose.Y + dy / length * reach)];
    }

    private static Pt Centroid(IReadOnlyCollection<Pt> pts) =>
        new(pts.Sum(p => p.X) / Math.Max(1, pts.Count), pts.Sum(p => p.Y) / Math.Max(1, pts.Count));

    /// <summary>AnimalGlyph.draw (GlyphMetrics: outline 2, halo 4.2, nose 1.9 / 3.8, dots 3.2 / 4.6, badge 7.5 at 13).</summary>
    public static void DrawGlyph(IFigureCanvas c, AnimalGlyph g, Rgba color, string? letter, double scale)
    {
        var halo = Rgba.Black.Opacity(0.55);
        if (g.Triangle is { } tri)
        {
            var path = new FigurePath().AddPolyline(tri, closed: true);
            c.Fill(path, color.Opacity(0.28));
            c.Stroke(path, halo, 4.2 * scale, StrokeStyle.RoundCaps);
            c.Stroke(path, color, 2.0 * scale, StrokeStyle.RoundCaps);
        }
        if (g.NoseLine is { Length: 2 } line)
        {
            var path = FigurePath.Segment(line[0].X, line[0].Y, line[1].X, line[1].Y);
            c.Stroke(path, halo, 3.8 * scale, StrokeStyle.RoundCaps);
            c.Stroke(path, color, 1.9 * scale, StrokeStyle.RoundCaps);
        }
        foreach (var p in g.HeadDots) Dot(c, p, 3.2 * scale, color, scale);
        if (g.TailBase is { } tail) Dot(c, tail, 4.6 * scale, color, scale);
        if (letter is not null && g.Anchor is { } anchor)
        {
            var at = new Pt(anchor.X + 13 * scale, anchor.Y - 13 * scale);
            var badge = FigurePath.Circle(at.X, at.Y, 7.5 * scale);
            c.Fill(badge, color);
            c.Stroke(badge, Rgba.White.Opacity(0.95), 1.3 * scale);
            c.Text(letter, at.X, at.Y, new FontSpec(10 * scale, FigureWeight.Semibold), Rgba.White, TextAnchor.Middle, TextBaseline.Middle);
        }
    }

    private static void Dot(IFigureCanvas c, Pt p, double r, Rgba color, double scale)
    {
        double outer = r + 1.3 * scale;
        c.Fill(FigurePath.Circle(p.X, p.Y, outer + 1), Rgba.Black.Opacity(0.45));
        c.Fill(FigurePath.Circle(p.X, p.Y, outer), Rgba.White);
        c.Fill(FigurePath.Circle(p.X, p.Y, r), color);
    }

    /// <summary>
    /// The body point's path over the last 2 s up to frame <paramref name="end"/>, fading toward the past in four
    /// bands, broken at gaps longer than half a second (MacPoseDrawing.drawTrail).
    /// </summary>
    public static void DrawTrail(IFigureCanvas c, ReviewTrack t, int end, int animal, Func<double, double, Pt> map,
                                 Rgba color, float minConf, double seconds = 2, double width = 2.2)
    {
        if (end < 0 || end >= t.Count) return;
        int first = end;
        while (first > 0 && t.Time[end] - t.Time[first - 1] <= seconds) first--;
        if (end - first < 1) return;
        FigurePath Segment(int a, int b)
        {
            var path = new FigurePath();
            bool open = false;
            double lastTime = double.NaN;
            for (int j = a; j <= b; j++)
            {
                if (t.BodyPoint(j, animal, minConf) is not { } q)
                {
                    open = false;
                    continue;
                }
                var p = map(q.X, q.Y);
                if (open && t.Time[j] - lastTime <= 0.5) path.LineTo(p.X, p.Y);
                else path.MoveTo(p.X, p.Y);
                open = true;
                lastTime = t.Time[j];
            }
            return path;
        }
        c.Stroke(Segment(first, end), Rgba.Black.Opacity(0.35), width + 2, StrokeStyle.RoundCaps);
        const int bands = 4;
        int span = end - first;
        for (int b = 0; b < bands; b++)
        {
            int a0 = first + span * b / bands, a1 = first + span * (b + 1) / bands;
            if (a1 <= a0) continue;
            c.Stroke(Segment(a0, a1), color.Opacity(0.2 + 0.7 * (b + 1) / bands), width, StrokeStyle.RoundCaps);
        }
    }

    /// <summary>The report's zones over the video (their outlines in frame pixels), as the Mac's review draws them.</summary>
    public static void DrawZones(IFigureCanvas c, ReportArena? arena, Func<double, double, Pt> map, FigureTheme theme)
    {
        if (arena is null) return;
        foreach (var z in arena.Zones)
        {
            if (z.Role == "arena" || z.Image is not { Length: >= 6 } outline) continue;
            var pts = new List<Pt>();
            for (int i = 0; i + 1 < outline.Length; i += 2)
            {
                if (double.IsFinite(outline[i]) && double.IsFinite(outline[i + 1])) pts.Add(map(outline[i], outline[i + 1]));
            }
            if (pts.Count < 3) continue;
            var path = new FigurePath().AddPolyline(pts, closed: true);
            var color = Palette.Zone(z.Role, theme);
            if (!z.OutlineOnly && z.Role != "hole") c.Fill(path, color.Opacity(0.14));
            c.Stroke(path, color.Opacity(0.9), 1.2, z.OutlineOnly ? new StrokeStyle([4, 3]) : null);
            if (z.ShowsLabel && z.Title.Length > 0 && z.ImageCenter is { Length: >= 2 } centre)
            {
                var at = map(centre[0], centre[1]);
                c.Text(z.Title, at.X, at.Y, FigureFonts.Label11Semibold, Rgba.White, TextAnchor.Middle, TextBaseline.Middle,
                       halo: Rgba.Black.Opacity(0.9));
            }
        }
    }
}

/// <summary>Where the review timeline put its rows, to turn a pointer position into a time.</summary>
public sealed record ReviewTimelineFrame(double Left, double Width, double Start, double End)
{
    public double TimeAt(double x) => Width > 0 ? Start + Math.Clamp((x - Left) / Width, 0, 1) * (End - Start) : Start;
}

/// <summary>
/// The timeline under the review video: the moments to check (hatched, one row per kind) and the behaviours of the
/// report (solid bars), the epochs behind them, and the play head — the Mac's review rows (MacTimelineBars).
/// </summary>
public static class ReviewTimeline
{
    private static string Color(string kind) => kind switch
    {
        "noDetection" or "outsideArena" => "error",
        "animalMissing" or "lowConfidence" or "identitySuspect" => "warning",
        _ => "neutral",
    };

    /// <summary>The rows: one per kind of moment to check (in a fixed order), then the report's behaviours.</summary>
    public static List<ReportTrack> Rows(ReportReview review, string? feedingTitle = null)
    {
        string[] order = ["noDetection", "animalMissing", "outsideArena", "identitySuspect", "identityUncertain", "overlapping", "lowConfidence"];
        var rows = new List<ReportTrack>();
        foreach (string kind in order)
        {
            var events = review.Qc.Where(e => e.Kind == kind).ToList();
            if (events.Count == 0) continue;
            var bouts = new double[events.Count * 2];
            for (int i = 0; i < events.Count; i++)
            {
                bouts[2 * i] = events[i].Start;
                bouts[2 * i + 1] = Math.Max(events[i].End, events[i].Start + 0.04);
            }
            rows.Add(new ReportTrack { Name = events[0].Title, Color = Color(kind), Style = "flag", Bouts = bouts });
        }
        // Novelty-suppressed feeding: the candidate bouts to check for the first bite.
        if (feedingTitle is not null && review.FeedingCandidates.Length >= 2)
            rows.Add(new ReportTrack { Name = feedingTitle, Color = "target", Bouts = review.FeedingCandidates });
        rows.AddRange(review.Tracks);
        return rows;
    }

    /// <summary>Draws the timeline <paramref name="width"/> wide; returns its height and where the rows are.</summary>
    public static (double Height, ReviewTimelineFrame Frame) Paint(IFigureCanvas c, IReadOnlyList<ReportTrack> rows,
                                                                    ReportEpoch[] epochs, double start, double end,
                                                                    double playhead, double width, FigureTheme theme)
    {
        const double rowHeight = 16, spacing = 4;
        var font = FigureFonts.Caption2;
        double label = 0;
        foreach (var r in rows) label = Math.Max(label, 13 + c.Measure(r.Name, font).Width);
        label = Math.Min(150, Math.Max(60, label));
        double bx = label + 8, bw = Math.Max(10, width - bx);
        double span = Math.Max(end - start, 1e-6);
        var timeline = new ReportTimeline { Start = start, End = end, Epochs = epochs };
        double y = 0;
        foreach (var r in rows)
        {
            var color = r.IsFlag && r.Color == "neutral" ? theme.Secondary : Palette.Color(r.Color, theme);
            double mid = y + rowHeight / 2;
            if (r.IsFlag) FigureKit.Hatch(c, FigurePath.RoundedRect(0.5, mid - 3.5, 7, 7, 2), 0.5, mid - 3.5, 7, 7, color);
            else c.Fill(FigurePath.RoundedRect(0, mid - 4, 8, 8, 2), color);
            c.Text(FigureKit.Fit(c, r.Name, font, label - 13), 13, mid, font, theme.Primary, TextAnchor.Start, TextBaseline.Middle);
            ReportFigures.DrawTrack(c, timeline, r, bx, y, bw, rowHeight, span, theme);
            y += rowHeight + spacing;
        }
        if (rows.Count == 0)
        {
            c.Fill(FigurePath.RoundedRect(bx, 0, bw, rowHeight, 4), theme.Inset);
            y = rowHeight + spacing;
        }
        double lineH = c.Measure("0:00", font).Height;
        c.Text(Fmt.Clock(0), bx, y, font, theme.Secondary);
        c.Text(Fmt.Clock(span / 2), bx + bw / 2, y, font, theme.Secondary, TextAnchor.Middle);
        c.Text(Fmt.Clock(span), bx + bw, y, font, theme.Secondary, TextAnchor.End);
        double height = y + lineH;
        // The play head over every row.
        double px = bx + Math.Clamp((playhead - start) / span, 0, 1) * bw;
        c.Stroke(FigurePath.Segment(px, 0, px, y - spacing), theme.Accent, 2);
        c.Fill(FigurePath.Circle(px, 0, 3.5), theme.Accent);
        return (height, new ReviewTimelineFrame(bx, bw, start, end));
    }
}
