using System.Text.Json;
using RodentFlow.Engine;

namespace RodentFlow.Core.Figures;

/// <summary>
/// Draws a publication figure built by the engine (PubFigure: PubGroupFigure for group comparisons) — what the
/// Mac's PubFigureView and PubRender draw. Shapes are the engine's paths (cubic curves flattened into short lines),
/// texts keep their size, weight, anchor, baseline and rotation. Coordinates are points; <c>scale</c> and the offset
/// place the figure on the canvas.
/// </summary>
public static class PubFigurePainter
{
    private static Rgba Color(double[]? c) =>
        c is { Length: >= 3 } ? new Rgba(c[0], c[1], c[2], c.Length >= 4 && double.IsFinite(c[3]) ? c[3] : 1) : Rgba.Black;

    private static double Num(JsonElement e) => e.ValueKind == JsonValueKind.Number ? e.GetDouble() : double.NaN;

    /// <summary>The engine's path operations as polylines.</summary>
    public static FigurePath Path(JsonElement[] ops, double scale, double ox, double oy)
    {
        var path = new FigurePath();
        double cx = 0, cy = 0, sx = 0, sy = 0;
        bool started = false;
        Pt Map(double x, double y) => new(ox + x * scale, oy + y * scale);
        foreach (var op in ops)
        {
            if (op.ValueKind != JsonValueKind.Array || op.GetArrayLength() == 0) continue;
            var a = op.EnumerateArray().ToArray();
            string kind = a[0].GetString() ?? "";
            switch (kind)
            {
                case "M" when a.Length >= 3:
                {
                    cx = sx = Num(a[1]);
                    cy = sy = Num(a[2]);
                    var p = Map(cx, cy);
                    path.MoveTo(p.X, p.Y);
                    started = true;
                    break;
                }
                case "L" when a.Length >= 3:
                {
                    cx = Num(a[1]);
                    cy = Num(a[2]);
                    var p = Map(cx, cy);
                    if (started) path.LineTo(p.X, p.Y);
                    else path.MoveTo(p.X, p.Y);
                    started = true;
                    break;
                }
                case "C" when a.Length >= 7:
                {
                    double x1 = Num(a[1]), y1 = Num(a[2]), x2 = Num(a[3]), y2 = Num(a[4]), x3 = Num(a[5]), y3 = Num(a[6]);
                    const int steps = 12;
                    for (int i = 1; i <= steps; i++)
                    {
                        double t = (double)i / steps, u = 1 - t;
                        double x = u * u * u * cx + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3;
                        double y = u * u * u * cy + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3;
                        var p = Map(x, y);
                        path.LineTo(p.X, p.Y);
                    }
                    cx = x3;
                    cy = y3;
                    started = true;
                    break;
                }
                case "Z":
                    path.Close();
                    cx = sx;
                    cy = sy;
                    started = false;
                    break;
            }
        }
        return path;
    }

    /// <summary>Draws <paramref name="figure"/> with its top-left at (ox, oy), <paramref name="scale"/> drawing units per point.</summary>
    public static void Paint(IFigureCanvas c, PubFigureData figure, double scale = 1, double ox = 0, double oy = 0,
                             bool background = true)
    {
        if (background && figure.Background is { } bg)
            c.Fill(FigurePath.Rect(ox, oy, figure.Width * scale, figure.Height * scale), Color(bg));
        foreach (var item in figure.Items)
        {
            if (item.Kind == "shape" && item.Ops is { } ops)
            {
                var path = Path(ops, scale, ox, oy);
                if (path.IsEmpty) continue;
                if (item.Fill is { } fill) c.Fill(path, Color(fill));
                if (item.Stroke is { } s && s.Width > 0)
                {
                    var dash = s.Dash.Length > 0 ? s.Dash.Select(d => d * scale).ToArray() : null;
                    c.Stroke(path, Color(s.Color), s.Width * scale, new StrokeStyle(dash, Round: true));
                }
            }
            else if (item.Kind == "text" && item.Text.Length > 0)
            {
                var font = new FontSpec(item.Size * scale, item.Bold ? FigureWeight.Semibold : FigureWeight.Regular);
                var anchor = item.Anchor switch { "middle" => TextAnchor.Middle, "end" => TextAnchor.End, _ => TextAnchor.Start };
                var baseline = item.Baseline switch
                {
                    "middle" => TextBaseline.Middle,
                    "hanging" => TextBaseline.Top,
                    _ => TextBaseline.Baseline,
                };
                double x = ox + item.X * scale, y = oy + item.Y * scale;
                var color = Color(item.Color);
                if (Math.Abs(item.Rotation) > 1e-9) c.RotatedText(item.Text, x, y, font, color, anchor, baseline, item.Rotation);
                else c.Text(item.Text, x, y, font, color, anchor, baseline);
            }
        }
    }
}
