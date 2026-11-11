using RodentFlow.Engine;

namespace RodentFlow.Core.Review;

/// <summary>
/// A finished pose.mpt in memory, for the review: every analysed frame's time, the animals' keypoints and the
/// identity flags (rf_track_frames, read in chunks). About 70 bytes per animal and frame — a 10-minute 30 fps
/// two-animal run is 2.5 MB.
/// </summary>
public sealed class ReviewTrack
{
    public const int Keypoints = 6;

    public required string PoseFile { get; init; }
    public int Count { get; private init; }
    public int Animals { get; private init; }
    public double FrameWidth { get; private init; }
    public double FrameHeight { get; private init; }
    public double Fps { get; private init; }
    public int Stride { get; private init; }

    public double[] Time { get; private init; } = [];
    public byte[] Flags { get; private init; } = [];
    /// <summary>Detection score per frame and animal: [i × Animals + a]; 0 = not detected.</summary>
    public float[] Conf { get; private init; } = [];
    /// <summary>Keypoints per frame, animal and keypoint: [(i × Animals + a) × 6 + k].</summary>
    public float[] X { get; private init; } = [];
    public float[] Y { get; private init; } = [];
    public float[] C { get; private init; } = [];

    /// <summary>IdentityFlag bits (IdentityTracking.swift).</summary>
    public const byte FlagSwapped = 1, FlagMerged = 2, FlagUncertain = 4, FlagLocked = 8, FlagSuspect = 16;

    public static ReviewTrack Load(string poseFile, IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        var info = Engine.Engine.TrackInfo(poseFile);
        int n = info.Frames, animals = Math.Max(1, info.AnimalCount);
        var t = new ReviewTrack
        {
            PoseFile = poseFile,
            Count = n,
            Animals = animals,
            FrameWidth = info.FrameWidth,
            FrameHeight = info.FrameHeight,
            Fps = info.Fps > 0 ? info.Fps : 30,
            Stride = Math.Max(1, info.FrameStride),
            Time = new double[n],
            Flags = new byte[n],
            Conf = new float[n * animals],
            X = new float[n * animals * Keypoints],
            Y = new float[n * animals * Keypoints],
            C = new float[n * animals * Keypoints],
        };
        const int chunk = 2000;
        for (int from = 0; from < n; from += chunk)
        {
            cancel.ThrowIfCancellationRequested();
            var frames = Engine.Engine.TrackFrames(poseFile, from, Math.Min(chunk, n - from)).Frames;
            foreach (var f in frames)
            {
                int i = f.Index;
                if (i < 0 || i >= n) continue;
                t.Time[i] = f.Time;
                t.Flags[i] = (byte)f.Flags;
                for (int a = 0; a < animals && a < f.Animals.Length; a++)
                {
                    var p = f.Animals[a];
                    t.Conf[i * animals + a] = p.Detected ? p.Conf : 0;
                    int b = (i * animals + a) * Keypoints;
                    for (int k = 0; k < Keypoints && k < p.X.Length && k < p.Y.Length && k < p.Kconf.Length; k++)
                    {
                        t.X[b + k] = p.X[k];
                        t.Y[b + k] = p.Y[k];
                        t.C[b + k] = p.Detected ? p.Kconf[k] : 0;
                    }
                }
            }
            progress?.Report(Math.Min(1, (from + chunk) / (double)Math.Max(1, n)));
        }
        return t;
    }

    /// <summary>
    /// A track made from arrays, for checks and tests: <paramref name="times"/> per frame; keypoints
    /// [(i × animals + a) × 6 + k] and scores [i × animals + a].
    /// </summary>
    public static ReviewTrack Synthetic(double[] times, int animals, float[] x, float[] y, float[] c, float[] conf,
                                        double frameWidth = 640, double frameHeight = 480, double fps = 30, int stride = 1,
                                        byte[]? flags = null) => new()
    {
        PoseFile = "",
        Count = times.Length,
        Animals = animals,
        FrameWidth = frameWidth,
        FrameHeight = frameHeight,
        Fps = fps,
        Stride = stride,
        Time = times,
        Flags = flags ?? new byte[times.Length],
        Conf = conf,
        X = x,
        Y = y,
        C = c,
    };

    /// <summary>Index of the analysed frame closest to <paramref name="time"/> (PoseTrack.nearestIndex).</summary>
    public int? NearestIndex(double time)
    {
        if (Count == 0) return null;
        int lo = 0, hi = Count - 1;
        while (lo < hi)
        {
            int mid = (lo + hi) / 2;
            if (Time[mid] < time) lo = mid + 1;
            else hi = mid;
        }
        if (lo > 0 && Math.Abs(Time[lo - 1] - time) < Math.Abs(Time[lo] - time)) return lo - 1;
        return lo;
    }

    /// <summary>
    /// The analysed frame shown at <paramref name="time"/>, or null between analysed frames (a stride above 1)
    /// — the Mac review's rule: within ¾ of a stride, plus 20 ms.
    /// </summary>
    public int? IndexAt(double time)
    {
        if (NearestIndex(time) is not { } i) return null;
        double tolerance = Stride / Fps * 0.75 + 0.02;
        return Math.Abs(Time[i] - time) <= tolerance ? i : null;
    }

    public bool Detected(int i, int a) => Conf[i * Animals + a] > 0;

    public bool HasFlag(int i, byte flag) => i >= 0 && i < Count && (Flags[i] & flag) != 0;

    /// <summary>Keypoint <paramref name="k"/> of animal <paramref name="a"/> in frame pixels, or null below <paramref name="minConf"/>.</summary>
    public (double X, double Y)? Point(int i, int a, int k, float minConf)
    {
        if (!Detected(i, a)) return null;
        int b = (i * Animals + a) * Keypoints + k;
        if (C[b] < minConf || !float.IsFinite(X[b]) || !float.IsFinite(Y[b])) return null;
        return (X[b], Y[b]);
    }

    /// <summary>The tracked body point: the body centre, or the mean of the confident keypoints (ArenaBounds.bodyPoint).</summary>
    public (double X, double Y)? BodyPoint(int i, int a, float minConf)
    {
        if (Point(i, a, 4, minConf) is { } body) return body;
        double sx = 0, sy = 0;
        int n = 0;
        for (int k = 0; k < Keypoints; k++)
        {
            if (Point(i, a, k, minConf) is not { } p) continue;
            sx += p.X;
            sy += p.Y;
            n++;
        }
        return n > 0 ? (sx / n, sy / n) : null;
    }
}
