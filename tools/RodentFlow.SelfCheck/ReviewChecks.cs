using RodentFlow.Core.Figures;
using RodentFlow.Core.Review;
using RodentFlow.Engine;

namespace RodentFlow.SelfCheck;

/// <summary>
/// The review's drawing rules, checked against the Mac's: the two-animal glyph (AnimalGlyph.make), the frame shown at
/// a time (the review's stride tolerance), the rows of the review timeline, and that a frame draws into SVG.
/// </summary>
internal static class ReviewChecks
{
    public static void Run(Action<bool, string> report)
    {
        Console.WriteLine("\n16. review: glyphs, frames at a time, timeline rows");
        Glyphs(report);
        Frames(report);
        Timeline(report);
    }

    private static bool Near(Pt? p, double x, double y) => p is { } q && Math.Abs(q.X - x) < 1e-9 && Math.Abs(q.Y - y) < 1e-9;

    private static void Glyphs(Action<bool, string> report)
    {
        // nose (10, 0); ears (6, 4) and (14, 4): ear midpoint (10, 4), head length 4 → nose line to (10, -4).
        var pts = new Dictionary<int, Pt> { [0] = new(10, 0), [1] = new(6, 4), [2] = new(14, 4), [3] = new(10, 8), [4] = new(10, 14), [5] = new(10, 22) };
        var full = PoseOverlay.Glyph(k => pts.TryGetValue(k, out var p) ? p : null, 0);
        report(full.Triangle is { Length: 3 } && full.NoseLine is { Length: 2 } line && Near(line[0], 10, 0) && Near(line[1], 10, -4)
               && Near(full.Anchor, 10, 14) && Near(full.TailBase, 10, 22) && full.HeadDots.Length == 0,
               "   all keypoints: head triangle, nose line one head length, badge at the body centre");
        var longer = PoseOverlay.Glyph(k => pts.TryGetValue(k, out var p) ? p : null, 10);
        report(longer.NoseLine is { Length: 2 } l2 && Near(l2[1], 10, -10), "   the nose line is at least the minimum length");
        var noEars = PoseOverlay.Glyph(k => k is 0 or 3 ? pts[k] : null, 0);
        // neck (10, 8) → nose (10, 0): 8 long, × 0.6 = 4.8.
        report(noEars.Triangle is null && noEars.HeadDots.Length == 1 && noEars.NoseLine is { Length: 2 } l3 && Near(l3[1], 10, -4.8)
               && Near(noEars.Anchor, 10, 8),
               "   without the ears: a head dot, direction from the neck (0.6 of neck → nose), badge at the neck");
        var tailOnly = PoseOverlay.Glyph(k => k == 5 ? pts[5] : null, 0);
        report(tailOnly.Triangle is null && tailOnly.NoseLine is null && Near(tailOnly.Anchor, 10, 22), "   only the tail base: badge there");
        report(PoseOverlay.Letter(0, 2) == "A" && PoseOverlay.Letter(1, 2) == "B" && PoseOverlay.Letter(2, 5) == "3",
               "   letters: A / B for a pair, numbers in a group");
    }

    private static void Frames(Action<bool, string> report)
    {
        // Every second frame analysed (stride 2) at 30 fps: tolerance 2/30 × 0.75 + 0.02 = 0.07 s.
        double[] times = Enumerable.Range(0, 10).Select(i => i * 2 / 30.0).ToArray();
        int n = times.Length, animals = 2, k = ReviewTrack.Keypoints;
        var x = new float[n * animals * k];
        var y = new float[n * animals * k];
        var c = new float[n * animals * k];
        var conf = new float[n * animals];
        for (int i = 0; i < n; i++)
        {
            for (int a = 0; a < animals; a++)
            {
                conf[i * animals + a] = 0.9f;
                for (int j = 0; j < k; j++)
                {
                    int b = (i * animals + a) * k + j;
                    x[b] = 100 + 200 * a + 5 * j;
                    y[b] = 100 + 3 * j + i;
                    c[b] = j == 2 ? 0.2f : 0.95f;
                }
            }
        }
        var track = ReviewTrack.Synthetic(times, animals, x, y, c, conf, stride: 2);
        // Frames 1/15 s apart are always within that tolerance of one another; only past the end (or across a gap)
        // is there no analysed frame to show.
        report(track.NearestIndex(0.07) == 1 && track.IndexAt(times[3] + 0.02) == 3 && track.IndexAt(times[9] + 0.06) == 9
               && track.IndexAt(times[9] + 0.5) is null,
               "   the analysed frame at a time: nearest, within ¾ of a stride + 20 ms");
        report(track.Point(0, 0, 2, 0.5f) is null && track.Point(0, 0, 0, 0.5f) is not null && track.BodyPoint(0, 1, 0.5f) is { X: 320 },
               "   keypoints below the threshold are missing; the body point is the body centre");
        var svg = new SvgCanvas(640, 480);
        PoseOverlay.Draw(svg, track, 3, (px, py) => new Pt(px, py), 1, 0.5f, FigureTheme.Light);
        PoseOverlay.DrawTrail(svg, track, 9, 0, (px, py) => new Pt(px, py), Palette.Animal(0), 0.5f);
        string doc = svg.Document();
        report(doc.Contains(">A</text>") && doc.Contains(">B</text>") && doc.Contains("<path"),
               "   two animals draw as lettered glyphs (A, B), with a trail");
    }

    private static void Timeline(Action<bool, string> report)
    {
        var review = new ReportReview
        {
            Qc =
            [
                new ReviewEvent { Kind = "lowConfidence", Title = "Low confidence", Start = 3, End = 4 },
                new ReviewEvent { Kind = "noDetection", Title = "No detection", Start = 1, End = 1 },
                new ReviewEvent { Kind = "noDetection", Title = "No detection", Start = 7, End = 8 },
            ],
            Tracks = [new ReportTrack { Name = "Rearing", Color = "accent", Bouts = [2, 3] }],
        };
        var rows = ReviewTimeline.Rows(review);
        report(rows.Count == 3 && rows[0].Name == "No detection" && rows[0].IsFlag && rows[0].Bouts.Length == 4
               && rows[0].Bouts[1] > rows[0].Bouts[0] && rows[1].Name == "Low confidence" && rows[2].Name == "Rearing" && !rows[2].IsFlag,
               "   rows: moments to check by kind (a one-frame moment still has a width), then behaviours");
        var svg = new SvgCanvas(600, 200);
        var (height, frame) = ReviewTimeline.Paint(svg, rows, [], 0, 10, 5, 600, FigureTheme.Light);
        report(height > 50 && Math.Abs(frame.TimeAt(frame.Left + frame.Width / 2) - 5) < 1e-9 && frame.TimeAt(-100) == 0 && frame.TimeAt(10000) == 10,
               "   pointer positions turn into times (clamped to the timeline)");
    }
}
