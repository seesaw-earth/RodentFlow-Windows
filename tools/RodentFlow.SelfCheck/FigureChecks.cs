using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Xml;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Text;
using RodentFlow.Engine;

namespace RodentFlow.SelfCheck;

/// <summary>
/// Checks of the result figures that need no engine and no window: the report JSON as the engine writes it
/// (ABI/ReportView.swift, nulls for NaN included), every kind of figure drawn into SVG and PDF, the PNG
/// writer and its dpi stamp, the printf subset used for the Mac's format strings, the palette and the axes.
/// </summary>
internal static class FigureChecks
{
    public static void Run(Action<bool, string> report)
    {
        Console.WriteLine("\n8. format strings (the Mac's String(format:) templates)");
        Formats(report);
        Console.WriteLine("\n9. palette, heat steps, clock and axes");
        Scales(report);
        Console.WriteLine("\n10. the report as the engine writes it");
        var sample = Read(report);
        Console.WriteLine("\n11. every figure kind drawn into SVG and PDF");
        if (sample is not null) Drawing(report, sample);
        Console.WriteLine("\n12. PNG writer and the dpi stamp");
        Png(report);
        Console.WriteLine("\n13. figure styles are remembered");
        Styles(report);
    }

    // ---------------------------------------------------------------- 8

    private static void Formats(Action<bool, string> report)
    {
        // No exact half-way values: printf rounds those to even and .NET away from zero (the one place the two
        // differ; the numbers on the cards come formatted from the engine, so it never shows there).
        var cases = new (string Template, object[] Args, string Expected)[]
        {
            ("%d notes", new object[] { 3 }, "3 notes"),
            ("Detection rate %.1f%%", new object[] { 97.26 }, "Detection rate 97.3%"),
            ("Mean direction %.0f°", new object[] { 44.7 }, "Mean direction 45°"),
            ("Mean resultant length %.2f (0–1)", new object[] { 0.4567 }, "Mean resultant length 0.46 (0–1)"),
            ("the ring labels give the %@ per bin", new object[] { "time spent (s)" }, "the ring labels give the time spent (s) per bin"),
            ("Bouts: %d; total %.1f s", new object[] { 4, 12.34 }, "Bouts: 4; total 12.3 s"),
            ("%5.1f|%-4d|%+d", new object[] { 3.14159, 7, 2 }, "  3.1|7   |+2"),
            ("%g / %g / %g", new object[] { 0.00012, 123456.0, 1234567.0 }, "0.00012 / 123456 / 1.23457e+06"),
        };
        foreach (var c in cases)
        {
            string got = Printf.Format(c.Template, c.Args);
            report(got == c.Expected, $"   \"{c.Template}\" → \"{got}\"" + (got == c.Expected ? "" : $"   expected \"{c.Expected}\""));
        }
        // With no translator the source text comes back, filled in.
        var saved = Tr.Translator;
        Tr.Translator = null;
        Tr.Reset();
        string text = Tr.F("%d 条提示", 2);
        report(text == "2 条提示", $"   Tr.F without the engine → \"{text}\"");
        Tr.Translator = saved;
        Tr.Reset();
    }

    // ---------------------------------------------------------------- 9

    private static void Scales(Action<bool, string> report)
    {
        bool Near(Rgba a, double r, double g, double b) => Math.Abs(a.R - r) < 1e-9 && Math.Abs(a.G - g) < 1e-9 && Math.Abs(a.B - b) < 1e-9;
        report(Near(Palette.Heat(0), 0.12, 0.10, 0.36) && Near(Palette.Heat(1), 0.99, 0.88, 0.22)
               && Near(Palette.Heat(0.5), 0.13, 0.62, 0.60),
               "   heat ramp ends and middle are ReportPalette.heatStops");
        report(Palette.HeatStep(1) == 64 && Palette.HeatStep(0) == 0 && Palette.HeatStep(0.5 / 64) == 1,
               "   heat steps: 64 steps, half way rounds up as Swift's rounded() does");
        report(Palette.Color("animalA", FigureTheme.Light).R8 == 30 && Palette.Color("social", FigureTheme.Light).HexRgb == "#f26b61",
               "   ColorKey colours as ReportPalette.color (animal A blue, social coral)");
        report(Fmt.Clock(0) == "0:00" && Fmt.Clock(59.5) == "1:00" && Fmt.Clock(3725) == "1:02:05",
               $"   clock: {Fmt.Clock(0)}, {Fmt.Clock(59.5)}, {Fmt.Clock(3725)}");
        foreach (var (lo, hi) in new[] { (0.0, 97.0), (-0.8, 0.6), (12.0, 12.0), (0.0, 0.00042), (3.0, 1.0e6) })
        {
            var axis = Axis.Nice(lo, hi);
            double step = axis.Ticks.Length > 1 ? axis.Ticks[1] - axis.Ticks[0] : 0;
            double mantissa = step / Math.Pow(10, Math.Floor(Math.Log10(step)));
            bool round = new[] { 1.0, 2.0, 2.5, 5.0, 10.0 }.Any(m => Math.Abs(m - mantissa) < 1e-6);
            bool ok = axis.Min <= lo && axis.Max >= hi && axis.Ticks.Length is >= 2 and <= 12 && round
                      && axis.Ticks.Zip(axis.Ticks.Skip(1)).All(p => p.Second > p.First);
            report(ok, $"   axis {lo}…{hi} → {axis.Min}…{axis.Max}, ticks {string.Join(" ", axis.Ticks.Select(axis.Label))}");
        }
        report(FigureCards.Slug("Trajectory and zones (cm)") == "trajectory_and_zones_cm", "   file-name slug");
    }

    // ---------------------------------------------------------------- 10

    /// <summary>A report as ReportView.json writes it: flat point lists, null for NaN, every block kind.</summary>
    private const string SampleJson = """
    {
      "ok": true, "outDir": "x", "written": [], "paradigm": "open_field", "task": "Open field", "model": "m",
      "animalCount": 1, "frames": 900, "fps": 30, "windowStart": 0, "metrics": [], "warnings": [], "notes": [],
      "report": {
        "language": "en", "category": "anxiety", "primaryKey": "center_pct", "keyNote": "Note",
        "metrics": [
          { "key": "center_pct", "title": "Center time", "unit": "%", "value": 12.5, "decimals": 1, "highlight": true,
            "display": "12.5", "displayUnit": "%", "scale": { "low": 0, "high": 100, "lowLabel": "0%", "highLabel": "100%" } },
          { "key": "latency", "title": "Latency", "unit": "s", "value": 300, "decimals": 1, "highlight": false,
            "display": "≥ 300.0", "displayUnit": "s", "censored": "no entry" },
          { "key": "missing", "title": "Missing", "unit": "s", "value": null, "decimals": 1, "highlight": false,
            "display": "—", "displayUnit": "" }
        ],
        "warnings": ["Detection below 90 %."], "methods": ["One.", "Two."], "methodsText": "One. Two.",
        "quality": { "frames": 900, "framesInWindow": 880, "windowSeconds": 29.3, "detectionRate": 0.97,
                     "keypointRates": [0.9, 0.8, 0.85, null, 0.99, 0.7], "headDirectionRate": 0.8, "sampleRate": 30,
                     "pxPerUnit": 12.3, "unit": "cm", "outsideArenaFraction": [0.004], "animalLetters": ["A"],
                     "keypoints": [ {"title": "Nose", "short": "N"} ] },
        "layerTitles": { "trajectory": "Trajectory" }, "backdropTitles": { "none": "Heat map only" },
        "review": { "tracks": [], "epochs": [], "feedingCandidates": [] },
        "blocks": [
          { "index": 0, "title": "Trajectory and zones", "kind": "arena", "styleKey": "open_field.Trajectory and zones",
            "arena": { "extent": [40, 40], "unit": "cm",
              "arena": { "id": "arena", "title": "", "role": "arena", "family": "arena", "showsLabel": false, "outlineOnly": false,
                         "outline": [0,0, 40,0, 40,40, 0,40], "center": [20,20], "image": [100,50, 500,50, 500,450, 100,450], "imageCenter": [300,250] },
              "zones": [ { "id": "center", "title": "Center", "role": "center", "family": "center", "showsLabel": true, "outlineOnly": false,
                           "outline": [10,10, 30,10, 30,30, 10,30], "center": [20,20], "image": [200,150, 400,150, 400,350, 200,350], "imageCenter": [300,250] },
                         { "id": "cupL_sniff", "title": "", "role": "interaction", "family": "cup", "showsLabel": false, "outlineOnly": true,
                           "outline": [5,5, 8,5, 8,8, 5,8], "center": [6.5,6.5] } ],
              "paths": [ { "color": "accent", "width": 1.2, "opacity": 0.8, "segments": [[1,1, 5,8, 12,20, null,3], [20,20, 30,35]] } ],
              "dots": [ { "x": 3, "y": 4, "color": "target", "radius": 1.6 }, { "x": null, "y": 4, "color": "error", "radius": 1.6 } ],
              "arrows": [ { "from": [10,10], "to": [12,12], "color": "warning" } ],
              "layers": ["arenaOutline", "zoneLabels", "investigationRings", "trajectory", "startEnd", "dots", "arrows", "scaleBar", "legend"],
              "zoneFamilies": [ { "key": "center", "title": "Center" } ] } },
          { "index": 1, "title": "Heat map", "kind": "arena", "styleKey": "open_field.Heat map",
            "arena": { "extent": [40, 40], "unit": "cm", "zones": [], "paths": [], "dots": [], "arrows": [],
              "heat": { "columns": 2, "rows": 2, "cell": 20, "values": [0, 3.5, null, 12] },
              "frame": { "isMetric": true, "frameWidth": 640, "frameHeight": 480, "crop": { "x": 60, "y": 20, "w": 480, "h": 460 },
                         "heatCells": [1, 300,50, 500,50, 500,250, 300,250, 3, 300,250, 500,250, 500,450, 300,450] },
              "layers": ["scaleBar", "legend"], "zoneFamilies": [] } },
          { "index": 2, "title": "Ethogram", "kind": "timeline", "styleKey": "k", "csv": "behavior,start_s\n",
            "timeline": { "start": 0, "end": 300,
              "tracks": [ { "name": "Freezing", "color": "freezing", "style": "behavior", "bouts": [10, 40, 100, 101], "inner": [], "innerColor": "neutral" },
                          { "name": "Check", "color": "neutral", "style": "flag", "bouts": [200, 230], "inner": [], "innerColor": "neutral" },
                          { "name": "Attack", "color": "attack", "style": "behavior", "bouts": [50, 80], "inner": [55, 60], "innerColor": "clinch", "innerName": "Clinch" } ],
              "epochs": [ { "name": "CS", "start": 120, "end": 150, "color": "warning" } ] } },
          { "index": 3, "title": "Zones", "kind": "bars", "styleKey": "k",
            "bars": { "items": [ {"label": "Center", "value": 12.5, "color": "center"}, {"label": "Periphery", "value": 87.5, "color": "periphery"} ],
                      "unit": "%", "decimals": 1, "horizontal": false, "referenceLine": 25, "referenceLabel": "chance 25%" } },
          { "index": 4, "title": "Arms", "kind": "bars", "styleKey": "k",
            "bars": { "items": [ {"label": "Open", "value": -3, "color": "open"}, {"label": "Closed", "value": 9, "color": "closed"} ],
                      "unit": "s", "decimals": 0, "horizontal": true } },
          { "index": 5, "title": "By minute", "kind": "bars", "styleKey": "k",
            "bars": { "items": [ {"label": "A", "value": 1, "color": "series1", "group": "1"}, {"label": "B", "value": 2, "color": "series2", "group": "1"},
                                 {"label": "A", "value": 3, "color": "series1", "group": "2"} ], "unit": "s", "decimals": 1, "horizontal": false } },
          { "index": 6, "title": "Speed", "kind": "line", "styleKey": "k",
            "line": { "series": [ {"name": "Speed", "color": "series1", "points": [0,1, 1,2, 2,null, 3,1.5], "dashed": false},
                                  {"name": "Other", "color": "series2", "points": [0,0.5, 3,0.7], "dashed": true} ],
                      "xLabel": "Time (min)", "yLabel": "cm/s", "referenceY": 1, "epochs": [ {"name": "CS", "start": 1, "end": 2, "color": "warning"} ] } },
          { "index": 7, "title": "Trials", "kind": "line", "styleKey": "k",
            "line": { "series": [ {"name": "1", "color": "series1", "points": [0,1, 1,2], "dashed": false}, {"name": "2", "color": "series1", "points": [0,2, 1,1], "dashed": false},
                                  {"name": "3", "color": "series1", "points": [0,1, 1,1], "dashed": false}, {"name": "4", "color": "series1", "points": [0,3, 1,2], "dashed": false},
                                  {"name": "5", "color": "series1", "points": [0,1, 1,0], "dashed": false} ],
                      "xLabel": "s", "yLabel": "speed", "yRange": [0, 4], "referenceX": 0.5, "epochs": [] } },
          { "index": 8, "title": "Heading", "kind": "polar", "styleKey": "k",
            "polar": { "values": [1, 2, 0, 4, null, 1, 0, 2], "unit": "s", "color": "accent", "meanAngle": 45, "resultantLength": 0.4, "referenceAngle": 90 } },
          { "index": 9, "title": "Bouts", "kind": "table", "styleKey": "k",
            "table": { "columns": ["Behaviour", "Count"], "rows": [["Freezing", "4"], ["Rearing, wall", "12"]], "rowColors": ["freezing", null] } }
        ]
      }
    }
    """;

    private static DisplayReport? Read(Action<bool, string> report)
    {
        try
        {
            var result = EngineJson.Read<AnalysisResult>(SampleJson);
            var r = result.Report;
            report(r is not null, "   rf_analyze reply with a report decodes");
            if (r is null) return null;
            var heat = r.Blocks[1].Arena?.Heat;
            report(heat is not null && double.IsNaN(heat.Values[2]) && heat.Values[3] == 12,
                   "   null in a list of numbers reads as NaN (a heat cell outside the arena)");
            report(double.IsNaN(r.Quality.KeypointRates[3]), "   null keypoint rate reads as NaN");
            report(r.Metrics[2].Value is null && r.Primary?.Key == "center_pct", "   a missing value stays null; the primary measure is found");
            report(r.Blocks.Length == 10 && r.Blocks.All(b => b.Kind switch
            {
                "arena" => b.Arena is not null,
                "timeline" => b.Timeline is not null,
                "bars" => b.Bars is not null,
                "line" => b.Line is not null,
                "polar" => b.Polar is not null,
                "table" => b.Table is not null,
                _ => false,
            }), "   every block carries the payload of its kind");
            report(r.Blocks[9].Table?.RowColors[1] is null, "   a null row colour stays null");
            // Writing is unchanged: NaN as the named literal, as before the lenient reader.
            string written = EngineJson.Write(new VideoMeta { Duration = double.NaN });
            report(written.Contains("\"duration\":\"NaN\""), $"   NaN is still written as \"NaN\" ({written})");
            return r;
        }
        catch (Exception e)
        {
            report(false, "   the sample report does not decode: " + e.Message);
            return null;
        }
    }

    // ---------------------------------------------------------------- 11

    private static FigureImage Frame(int w, int h)
    {
        var px = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                px[i] = (byte)x; px[i + 1] = (byte)y; px[i + 2] = 128; px[i + 3] = 255;
            }
        return new FigureImage(px, w, h, w * 4);
    }

    private static void Drawing(Action<bool, string> report, DisplayReport r)
    {
        var frame = Frame(64, 48);
        var styles = new[]
        {
            ("plain", new FigureStyle()),
            ("overlay", new FigureStyle { Backdrop = HeatBackdrops.Overlay }),
            ("side by side", new FigureStyle { Backdrop = HeatBackdrops.SideBySide }),
            ("layers off", new FigureStyle
            {
                Hidden = [FigureLayers.Trajectory, FigureLayers.ScaleBar, FigureLayers.Legend, FigureLayers.ZoneLabels],
                HiddenZones = ["center"],
            }),
        };
        foreach (var b in r.Blocks)
        {
            foreach (var (name, style) in b.Kind == "arena" ? styles : styles.Take(1))
            {
                var o = new FigureOptions { Theme = FigureTheme.Light, English = true, Style = style, Backdrop = frame, HoverX = b.Kind == "line" ? 1.2 : null };
                try
                {
                    double cw = FigureCards.ContentWidth(HelveticaMetrics.Measure, b, o);
                    var (w, h) = FigureCards.PageSize(HelveticaMetrics.Measure, b, o, cw);
                    var svg = new SvgCanvas(w, h, b.Title);
                    FigureCards.Draw(svg, b, o, cw, h, Rgba.White);
                    string doc = svg.Document();
                    var xml = new XmlDocument();
                    xml.LoadXml(doc);
                    bool drew = doc.Contains("<path") && doc.Contains("<text");
                    var pdf = new PdfCanvas(w, h, b.Title);
                    FigureCards.Draw(pdf, b, o, cw, h, Rgba.White);
                    string? pdfProblem = PdfProblem(pdf.Document());
                    bool expectWide = b.Kind == "arena" && name == "side by side" && b.Arena?.Heat is not null;
                    bool widthOk = !expectWide || Math.Abs(cw - 640) < 1e-9;
                    report(drew && h > 40 && pdfProblem is null && widthOk,
                           $"   {b.Kind,-8} {b.Title,-22} {name,-13} {w:F0} × {h:F0} pt"
                           + (pdfProblem is null ? "" : "   PDF: " + pdfProblem)
                           + (widthOk ? "" : "   expected the 640-wide card"));
                }
                catch (Exception e)
                {
                    report(false, $"   {b.Kind} {b.Title} {name}: {e.GetType().Name}: {e.Message}");
                }
            }
        }
        // The frame of the side-by-side heat map appears once as an image in the SVG.
        var heatBlock = r.Blocks[1];
        var side = new FigureOptions { Style = new FigureStyle { Backdrop = HeatBackdrops.SideBySide }, Backdrop = frame, English = true };
        var s2 = new SvgCanvas(700, 500);
        ReportFigures.Paint(s2, heatBlock, 0, 0, 640, side);
        string d2 = s2.Document();
        report(d2.Split("<image ").Length == 2 && d2.Contains("data:image/png;base64,"), "   the calibration frame is embedded once, as PNG");
        // Without a frame the heat map is drawn alone, whatever the style says.
        var none = new FigureOptions { Style = new FigureStyle { Backdrop = HeatBackdrops.Overlay }, English = true };
        var s3 = new SvgCanvas(500, 500);
        ReportFigures.Paint(s3, heatBlock, 0, 0, 420, none);
        report(!s3.Document().Contains("<image"), "   no calibration frame: the heat map alone");
    }

    /// <summary>Null when the PDF's cross-reference table points at every object; else what is wrong.</summary>
    private static string? PdfProblem(byte[] pdf)
    {
        string text = Encoding.Latin1.GetString(pdf);
        if (!text.StartsWith("%PDF-1.4")) return "no header";
        int startxref = text.LastIndexOf("startxref", StringComparison.Ordinal);
        if (startxref < 0 || !text.TrimEnd().EndsWith("%%EOF")) return "no trailer";
        long xref = long.Parse(text[(startxref + 9)..].Trim().Split('\n')[0]);
        if (!text[(int)xref..].StartsWith("xref")) return "startxref does not point at the xref table";
        var lines = text[(int)xref..].Split('\n');
        int count = int.Parse(lines[1].Split(' ')[1]);
        for (int i = 1; i < count; i++)
        {
            long offset = long.Parse(lines[2 + i][..10]);
            if (!text[(int)offset..].StartsWith($"{i} 0 obj")) return $"object {i} is not at offset {offset}";
        }
        // Every content stream inflates.
        int at = 0;
        while ((at = text.IndexOf("/FlateDecode", at, StringComparison.Ordinal)) >= 0)
        {
            int lengthAt = text.LastIndexOf("/Length ", Math.Min(at + 60, text.Length - 1), StringComparison.Ordinal);
            int streamAt = text.IndexOf("stream\n", at, StringComparison.Ordinal) + 7;
            int length = int.Parse(new string(text[(lengthAt + 8)..].TakeWhile(char.IsDigit).ToArray()));
            try
            {
                using var z = new ZLibStream(new MemoryStream(pdf, streamAt, length), CompressionMode.Decompress);
                z.CopyTo(Stream.Null);
            }
            catch (Exception e)
            {
                return "a stream does not inflate: " + e.Message;
            }
            at = streamAt + length;
        }
        return null;
    }

    // ---------------------------------------------------------------- 12

    private static void Png(Action<bool, string> report)
    {
        var frame = Frame(5, 3);
        byte[] png = frame.Png;
        report(PngEncoder.Verify(png, out string problem), "   RGB PNG: signature, chunks and CRCs" + (problem.Length > 0 ? " — " + problem : ""));

        // The pixels inflate back to what was written (filter 0, RGB order).
        int at = 8;
        byte[]? idat = null;
        while (at + 12 <= png.Length)
        {
            int length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            if (Encoding.ASCII.GetString(png, at + 4, 4) == "IDAT") idat = png[(at + 8)..(at + 8 + length)];
            at += 12 + length;
        }
        var raw = new MemoryStream();
        if (idat is not null)
        {
            using var z = new ZLibStream(new MemoryStream(idat), CompressionMode.Decompress);
            z.CopyTo(raw);
        }
        byte[] rows = raw.ToArray();
        bool same = rows.Length == 3 * (1 + 5 * 3) && rows[0] == 0 && rows[1] == 128 && rows[2] == 0 && rows[3] == 0
                    && rows[1 + 3 * 4] == 128 && rows[1 + 3 * 4 + 2] == 4;
        report(same, "   pixels come back as written (BGRA in, RGB rows out)");

        byte[] stamped = PngEncoder.SetDpi(png, 300);
        double? dpi = PngEncoder.ReadDpi(stamped);
        report(PngEncoder.Verify(stamped, out problem) && dpi is { } d && Math.Abs(d - 300) < 0.05,
               $"   SetDpi(300) → pHYs says {dpi:F2} dpi" + (problem.Length > 0 ? " — " + problem : ""));
        byte[] again = PngEncoder.SetDpi(stamped, 600);
        int count = Encoding.ASCII.GetString(again).Split("pHYs").Length - 1;
        report(count == 1 && PngEncoder.ReadDpi(again) is { } d6 && Math.Abs(d6 - 600) < 0.05,
               "   SetDpi again replaces the stamp instead of adding a second one");
    }

    // ---------------------------------------------------------------- 13

    private static void Styles(Action<bool, string> report)
    {
        string saved = FigureStyleStore.FilePath;
        string file = Path.Combine(Path.GetTempPath(), $"rf-styles-{Guid.NewGuid():N}.json");
        try
        {
            FigureStyleStore.FilePath = file;
            var style = new FigureStyle { Hidden = [FigureLayers.Legend], HiddenZones = ["cup"], Backdrop = HeatBackdrops.Overlay, OverlayOpacity = 0.35 };
            FigureStyleStore.Save("three_chamber.Trajectory and zones", style);
            string json = File.ReadAllText(file);
            var back = FigureStyleStore.Load("three_chamber.Trajectory and zones");
            report(back.Hidden.Contains(FigureLayers.Legend) && back.HiddenZones.Contains("cup") && back.Backdrop == "overlay"
                   && Math.Abs(back.OverlayOpacity - 0.35) < 1e-9 && json.Contains("\"hiddenZones\""),
                   "   saved and read back in the Mac's form ({hidden, hiddenZones, backdrop, overlayOpacity})");
            FigureStyleStore.Save("three_chamber.Trajectory and zones", new FigureStyle());
            report(FigureStyleStore.Load("three_chamber.Trajectory and zones").IsDefault, "   a style back to default is forgotten");
        }
        finally
        {
            FigureStyleStore.FilePath = saved;
            try { File.Delete(file); } catch (IOException) { }
        }
    }
}
