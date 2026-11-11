using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using RodentFlow.Core.Figures;
using RodentFlow.Engine;

namespace RodentFlow.SelfCheck;

/// <summary>
/// Stage D without the engine: the publication-figure items as the engine writes them (GroupABI.figure) drawn into
/// SVG and PDF (curves, dashes, a turned y-axis title), "nan" in a reply, and the keys of a session sent to
/// rf_group_analysis (GroupABI.SessionInput).
/// </summary>
internal static class GroupChecks
{
    private const string FigureJson = """
    {
      "width": 200, "height": 150, "background": [1, 1, 1, 1],
      "items": [
        { "kind": "shape", "ops": [["M", 20, 130], ["L", 180, 130], ["C", 180, 100, 150, 60, 120, 40], ["Z"]],
          "fill": [0.0, 0.447, 0.698, 0.3], "stroke": { "color": [0, 0, 0, 1], "width": 0.75, "dash": [2, 2] } },
        { "kind": "text", "text": "Time in centre (%)", "x": 8, "y": 75, "size": 7, "bold": false, "color": [0, 0, 0, 1],
          "anchor": "middle", "baseline": "hanging", "rotation": -90 },
        { "kind": "text", "text": "WT", "x": 60, "y": 142, "size": 7, "bold": true, "color": [0.2, 0.2, 0.2, 1],
          "anchor": "middle", "baseline": "alphabetic", "rotation": 0 }
      ]
    }
    """;

    public static void Run(Action<bool, string> report)
    {
        Console.WriteLine("\n18. group comparison: the figure, numbers, the session sent");
        try
        {
            var figure = EngineJson.Read<PubFigureData>(FigureJson);
            var ops = figure.Items[0].Ops!;
            var path = PubFigurePainter.Path(ops, 2, 10, 0);
            var pts = path.Figures[0];
            report(path.Figures.Count == 1 && path.IsClosed(0) && Math.Abs(pts[^1].X - (10 + 120 * 2)) < 1e-9
                   && Math.Abs(pts[^1].Y - 80) < 1e-9 && pts.Length == 2 + 12,
                   "   path: move, line, a cubic curve in 12 steps ending on its end point, closed; scaled and moved");

            var svg = new SvgCanvas(figure.Width, figure.Height);
            PubFigurePainter.Paint(svg, figure);
            string doc = svg.Document();
            report(doc.Contains("rotate(-90 8 75)") && doc.Contains("stroke-dasharray=\"2 2\"") && doc.Contains(">WT</text>")
                   && doc.Contains("font-weight=\"bold\""),
                   "   into SVG: the y-axis title turned −90° about its anchor, dashed stroke, bold group label");
            var pdf = new PdfCanvas(figure.Width, figure.Height);
            PubFigurePainter.Paint(pdf, figure);
            string pdfText = Encoding.Latin1.GetString(pdf.Document());
            report(pdfText.StartsWith("%PDF-1.4") && pdfText.TrimEnd().EndsWith("%%EOF"), "   into PDF (the turned title as a turned text matrix)");

            var d = EngineJson.Read<GroupDescriptives>("""{"group":"WT","n":1,"mean":3.5,"sd":"nan","sem":"nan","median":3.5,"q1":3.5,"q3":3.5,"min":3.5,"max":3.5}""");
            report(double.IsNaN(d.Sd) && d.Mean == 3.5 && d.N == 1, "   \"nan\" in a reply reads as NaN (an SD of one animal)");

            var input = new GroupSessionInput(Guid.NewGuid(), "M1", "M1", "WT", "Test", null, null, 1, "2026-10-17", false, null, "F",
                                              false, new JsonObject { ["phase"] = "Test" });
            using var json = JsonDocument.Parse(EngineJson.Write(input));
            var names = json.RootElement.EnumerateObject().Select(p => p.Name).ToHashSet();
            report(names.SetEquals(["id", "subjectID", "subjectKey", "group", "phase", "session", "date", "excluded", "sex", "trackingProblem", "summary"]),
                   "   a session is sent with the engine's field names (null fields left out): " + string.Join(", ", names.Order()));
        }
        catch (Exception e)
        {
            report(false, "   group check failed: " + e);
        }
    }
}
