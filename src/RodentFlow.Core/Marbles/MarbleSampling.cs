using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using RodentFlow.Engine;

namespace RodentFlow.Core.Marbles;

/// <summary>
/// The marble readings of a marble-burying session (MarbleSamples, Shared/PoseEngine/AnalyzersMarble.swift): per
/// marble and reading, the mean luminance inside 0.8 × its radius and of the bedding ring 1.3–2 × the radius.
/// </summary>
/// <remarks>
/// Saved next to the pose data as <c>marble_samples.json</c> in the Mac's own form (MarbleSampler.save: keys
/// key / times / inner / ring, a non-finite number written as "nan", "inf" or "-inf"), so a file from the phone or the
/// Mac is read here as it is, and the engine reads what is sent as it reads that file.
/// </remarks>
public sealed class MarbleSamples
{
    public const string FileName = "marble_samples.json";

    public string Key { get; init; } = "";
    public double[] Times { get; init; } = [];
    public float[][] Inner { get; init; } = [];
    public float[][] Ring { get; init; } = [];

    private static string Number(double v) =>
        double.IsNaN(v) ? "\"nan\"" : double.IsPositiveInfinity(v) ? "\"inf\"" : double.IsNegativeInfinity(v) ? "\"-inf\""
            : v.ToString("R", CultureInfo.InvariantCulture);

    private static string Number(float v) =>
        float.IsNaN(v) ? "\"nan\"" : float.IsPositiveInfinity(v) ? "\"inf\"" : float.IsNegativeInfinity(v) ? "\"-inf\""
            : v.ToString("R", CultureInfo.InvariantCulture);

    /// <summary>The Mac's JSON form.</summary>
    public string ToJson()
    {
        var sb = new StringBuilder();
        sb.Append("{\"key\":").Append(JsonSerializer.Serialize(Key));
        sb.Append(",\"times\":[").Append(string.Join(",", Times.Select(Number))).Append(']');
        void Rows(string name, float[][] rows)
        {
            sb.Append(",\"").Append(name).Append("\":[");
            for (int i = 0; i < rows.Length; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append('[').Append(string.Join(",", rows[i].Select(Number))).Append(']');
            }
            sb.Append(']');
        }
        Rows("inner", Inner);
        Rows("ring", Ring);
        sb.Append('}');
        return sb.ToString();
    }

    /// <summary>For rf_analyze's "marbles".</summary>
    public JsonObject ToJsonObject() => JsonNode.Parse(ToJson())!.AsObject();

    public void Save(string folder)
    {
        string path = Path.Combine(folder, FileName), tmp = path + ".tmp";
        File.WriteAllText(tmp, ToJson());
        File.Move(tmp, path, overwrite: true);
    }

    /// <summary>The saved readings of a run folder when they were read with <paramref name="key"/>; null otherwise.</summary>
    public static MarbleSamples? Load(string folder, string key)
    {
        string path = Path.Combine(folder, FileName);
        if (!File.Exists(path)) return null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            if (root.GetProperty("key").GetString() != key) return null;
            static double Read(JsonElement e) => e.ValueKind switch
            {
                JsonValueKind.Number => e.GetDouble(),
                JsonValueKind.String => e.GetString() switch
                {
                    "inf" => double.PositiveInfinity,
                    "-inf" => double.NegativeInfinity,
                    _ => double.NaN,
                },
                _ => double.NaN,
            };
            float[][] Rows(string name) => root.GetProperty(name).EnumerateArray()
                .Select(r => r.EnumerateArray().Select(v => (float)Read(v)).ToArray()).ToArray();
            return new MarbleSamples
            {
                Key = key,
                Times = root.GetProperty("times").EnumerateArray().Select(Read).ToArray(),
                Inner = Rows("inner"),
                Ring = Rows("ring"),
            };
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or IOException)
        {
            return null;
        }
    }
}

/// <summary>
/// Reads the marbles from the video (MarbleSampler.sample, Shared/Vision/MarbleSampler.swift): the same points inside
/// and around each marble (thinned to about 300 each), the same luminance (0.114 B + 0.587 G + 0.299 R).
/// </summary>
/// <remarks>
/// The Mac decodes every frame and takes the first at or after each reading time. Here ffmpeg's fps filter hands over
/// one frame per interval (the last frame at or before each reading time, <c>round=up</c>), so a reading may come from
/// the frame before the Mac's — 1/30 s at 30 fps, against readings 0.5 s apart.
/// </remarks>
public static class MarbleSampling
{
    /// <summary>Points (dx, dy) at distances r0…r1 from the centre, on a grid thinned to about 300 points.</summary>
    public static List<(int Dx, int Dy)> Offsets(double r0, double r1)
    {
        int reach = (int)Math.Ceiling(r1);
        double area = Math.PI * (r1 * r1 - r0 * r0);
        int step = Math.Max(1, (int)Math.Round(Math.Sqrt(area / 300), MidpointRounding.AwayFromZero));
        var out_ = new List<(int, int)>();
        for (int dy = -reach; dy <= reach; dy += step)
        {
            for (int dx = -reach; dx <= reach; dx += step)
            {
                double d = Math.Sqrt(dx * dx + dy * dy);
                if (d >= r0 && d <= r1) out_.Add((dx, dy));
            }
        }
        return out_;
    }

    /// <summary>Mean luminance of the points around (cx, cy) inside the frame; NaN when none is.</summary>
    public static float Mean(byte[] bgra, int width, int height, int rowBytes, double x, double y, List<(int Dx, int Dy)> offsets)
    {
        float s = 0;
        int n = 0;
        int cx = (int)Math.Round(x, MidpointRounding.AwayFromZero), cy = (int)Math.Round(y, MidpointRounding.AwayFromZero);
        foreach (var (dx, dy) in offsets)
        {
            int px = cx + dx, py = cy + dy;
            if (px < 0 || py < 0 || px >= width || py >= height) continue;
            int i = py * rowBytes + px * 4; // B, G, R, A
            s += 0.114f * bgra[i] + 0.587f * bgra[i + 1] + 0.299f * bgra[i + 2];
            n++;
        }
        return n > 0 ? s / n : float.NaN;
    }

    public static MarbleSamples Sample(VideoInfo info, FFmpegTools tools, MarblePlan plan,
                                       IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        double radius = plan.Radius;
        var inner = Offsets(0, Math.Max(1, radius * 0.8));
        var ring = Offsets(radius * 1.3, Math.Max(radius * 1.3 + 1, radius * 2));
        var centers = plan.Centers.Where(c => c.Length >= 2).ToArray();
        int width = info.Width, height = info.Height, rowBytes = width * 4;
        double interval = Math.Max(0.1, plan.Interval);
        double start = info.FrameTimes.Count > 0 ? info.FrameTimes[0] : 0;

        var args = new List<string>
        {
            "-v", "error", "-nostdin", "-i", info.Path, "-map", "0:v:0",
            "-vf", "fps=fps=" + (1 / interval).ToString("0.######", CultureInfo.InvariantCulture) + ":round=up",
            "-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1",
        };
        using var process = FFmpegTools.Start(tools.FFmpeg, args, binaryOut: true);
        using var stop = cancel.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(); }
            catch (Exception) { /* it ended on its own */ }
        });
        var errors = Task.Run(() => process.StandardError.ReadToEnd(), CancellationToken.None);
        var stream = process.StandardOutput.BaseStream;
        var frame = new byte[rowBytes * height];
        var times = new List<double>();
        var innerRows = centers.Select(_ => new List<float>()).ToArray();
        var ringRows = centers.Select(_ => new List<float>()).ToArray();
        for (int k = 0; ; k++)
        {
            cancel.ThrowIfCancellationRequested();
            int filled = 0;
            while (filled < frame.Length)
            {
                int got = stream.Read(frame, filled, frame.Length - filled);
                if (got <= 0) break;
                filled += got;
            }
            if (filled < frame.Length) break;
            double t = start + k * interval;
            if (info.Duration > 0 && t > info.Duration + interval) break;
            times.Add(t);
            for (int j = 0; j < centers.Length; j++)
            {
                innerRows[j].Add(Mean(frame, width, height, rowBytes, centers[j][0], centers[j][1], inner));
                ringRows[j].Add(Mean(frame, width, height, rowBytes, centers[j][0], centers[j][1], ring));
            }
            if (info.Duration > 0) progress?.Report(Math.Min(1, (t - start) / info.Duration));
        }
        process.WaitForExit();
        cancel.ThrowIfCancellationRequested();
        if (times.Count < 2)
        {
            string wrote = errors.IsCompletedSuccessfully ? errors.Result.Trim() : "";
            throw new InvalidOperationException("Could not read the marbles from " + Path.GetFileName(info.Path)
                                                + (wrote.Length > 0 ? ": " + wrote : "."));
        }
        return new MarbleSamples
        {
            Key = plan.Key,
            Times = times.ToArray(),
            Inner = innerRows.Select(r => r.ToArray()).ToArray(),
            Ring = ringRows.Select(r => r.ToArray()).ToArray(),
        };
    }
}
