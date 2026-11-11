using RodentFlow.Engine;

namespace RodentFlow.Core;

/// <summary>
/// Draws what the engine saw onto a decoded frame: the keypoints and skeleton it found, the region
/// it gave the model, and the arena the user calibrated.
/// </summary>
/// <remarks>
/// This is a debugging and review tool first. Looking at the skeleton on the picture is the only
/// way to catch the failure that confidence does not reveal — keypoints that sit still, or sit on
/// the bedding instead of the animal — which is why RodentFlow's own Box 1 asks for it.
///
/// Everything is drawn straight onto a 32-bit BGRA buffer, so there is no imaging dependency and
/// the same code can later back a live preview in the window.
/// </remarks>
public static class Annotation
{
    /// <summary>Keypoint colours, in the engine's keypoint order (Keypoints.swift).</summary>
    /// <remarks>nose, left ear, right ear, neck, body centre, tail base.</remarks>
    private static readonly (byte B, byte G, byte R)[] KeypointColours =
    [
        (60, 60, 240),    // nose — red
        (60, 160, 250),   // left ear — orange
        (80, 220, 250),   // right ear — yellow
        (90, 210, 90),    // neck — green
        (230, 220, 60),   // body centre — cyan
        (220, 70, 220),   // tail base — magenta
    ];

    /// <summary>The skeleton, as the engine defines it (`kBones` in Keypoints.swift).</summary>
    private static readonly (int A, int B)[] Bones =
        [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 5)];

    /// <summary>
    /// Keypoints below this confidence are treated as missing by the analysis
    /// (`AnalysisParams.kpConf`), so they are drawn hollow: you can see what was discarded.
    /// </summary>
    public const float WeakKeypoint = 0.5f;

    /// <summary>What to draw besides the animals.</summary>
    public sealed record Context
    {
        /// <summary>The region given to the model, in upright whole-frame pixels.</summary>
        public CropPixels? Crop { get; init; }
        /// <summary>The calibrated arena outline, in normalized frame coordinates.</summary>
        public NPoint[]? ArenaCorners { get; init; }
        /// <summary>Width and height of the upright whole frame the keypoints are expressed in.</summary>
        public required double FrameWidth { get; init; }
        public required double FrameHeight { get; init; }
    }

    /// <summary>
    /// Draws one frame in place.
    /// </summary>
    /// <param name="pixels">32-bit BGRA, <paramref name="rowBytes"/> per row.</param>
    /// <param name="animals">The animals of this frame, or empty when the frame was not analysed.</param>
    public static void Draw(
        Span<byte> pixels, int width, int height, int rowBytes,
        IReadOnlyList<PoseKeypoints> animals,
        Context context)
    {
        var canvas = new Canvas(pixels, width, height, rowBytes);

        // The buffer may be smaller than the frame the keypoints are measured in (reduced decode).
        double sx = context.FrameWidth > 0 ? width / context.FrameWidth : 1;
        double sy = context.FrameHeight > 0 ? height / context.FrameHeight : 1;

        if (context.ArenaCorners is { Length: >= 3 } corners)
        {
            // Normalized frame coordinates → buffer pixels.
            var points = corners
                .Select(p => (p.X * width, p.Y * height))
                .ToArray();
            for (int i = 0; i < points.Length; i++)
            {
                var (x0, y0) = points[i];
                var (x1, y1) = points[(i + 1) % points.Length];
                canvas.Line(x0, y0, x1, y1, (90, 200, 255), 1);   // amber: the calibrated arena
            }
        }

        if (context.Crop is { } crop)
        {
            canvas.Rectangle(crop.X * sx, crop.Y * sy, crop.Width * sx, crop.Height * sy,
                             (200, 200, 200), 1);                 // grey: what the model was given
        }

        bool anyDetected = false;
        foreach (var animal in animals)
        {
            if (!animal.Detected || animal.X.Length < KeypointColours.Length) continue;
            anyDetected = true;

            foreach (var (a, b) in Bones)
            {
                if (animal.Kconf[a] < WeakKeypoint || animal.Kconf[b] < WeakKeypoint) continue;
                canvas.Line(animal.X[a] * sx, animal.Y[a] * sy,
                            animal.X[b] * sx, animal.Y[b] * sy, (245, 245, 245), 1);
            }

            for (int k = 0; k < KeypointColours.Length; k++)
            {
                double x = animal.X[k] * sx, y = animal.Y[k] * sy;
                var colour = KeypointColours[k];
                if (animal.Kconf[k] >= WeakKeypoint) canvas.Disc(x, y, 3, colour);
                else canvas.Circle(x, y, 3, colour);              // hollow: the analysis drops it
            }
        }

        if (animals.Count > 0 && !anyDetected)
        {
            // Nothing found in a frame that was analysed. A red border makes those frames obvious
            // while scrubbing, instead of looking like an ordinary frame.
            canvas.Rectangle(0, 0, width - 1, height - 1, (60, 60, 240), 3);
        }
    }

    /// <summary>Minimal drawing onto a BGRA buffer: no imaging library, no allocation per shape.</summary>
    private readonly ref struct Canvas
    {
        private readonly Span<byte> _pixels;
        private readonly int _width;
        private readonly int _height;
        private readonly int _rowBytes;

        public Canvas(Span<byte> pixels, int width, int height, int rowBytes)
        {
            _pixels = pixels;
            _width = width;
            _height = height;
            _rowBytes = rowBytes;
        }

        private void Set(int x, int y, (byte B, byte G, byte R) c)
        {
            if (x < 0 || y < 0 || x >= _width || y >= _height) return;
            int at = y * _rowBytes + x * 4;
            if (at + 3 >= _pixels.Length) return;
            _pixels[at] = c.B;
            _pixels[at + 1] = c.G;
            _pixels[at + 2] = c.R;
            _pixels[at + 3] = 255;
        }

        public void Line(double x0, double y0, double x1, double y1, (byte, byte, byte) c, int thickness)
        {
            double dx = x1 - x0, dy = y1 - y0;
            int steps = (int)Math.Ceiling(Math.Max(Math.Abs(dx), Math.Abs(dy)));
            if (steps <= 0)
            {
                Dot((int)Math.Round(x0), (int)Math.Round(y0), c, thickness);
                return;
            }
            for (int i = 0; i <= steps; i++)
            {
                double t = (double)i / steps;
                Dot((int)Math.Round(x0 + dx * t), (int)Math.Round(y0 + dy * t), c, thickness);
            }
        }

        private void Dot(int x, int y, (byte, byte, byte) c, int thickness)
        {
            int r = Math.Max(0, thickness - 1);
            for (int dy = -r; dy <= r; dy++)
            for (int dx = -r; dx <= r; dx++)
                Set(x + dx, y + dy, c);
        }

        public void Rectangle(double x, double y, double w, double h, (byte, byte, byte) c, int thickness)
        {
            Line(x, y, x + w, y, c, thickness);
            Line(x + w, y, x + w, y + h, c, thickness);
            Line(x + w, y + h, x, y + h, c, thickness);
            Line(x, y + h, x, y, c, thickness);
        }

        public void Disc(double cx, double cy, int radius, (byte, byte, byte) c)
        {
            int x0 = (int)Math.Round(cx), y0 = (int)Math.Round(cy);
            for (int dy = -radius; dy <= radius; dy++)
            for (int dx = -radius; dx <= radius; dx++)
                if (dx * dx + dy * dy <= radius * radius)
                    Set(x0 + dx, y0 + dy, c);
        }

        public void Circle(double cx, double cy, int radius, (byte, byte, byte) c)
        {
            int x0 = (int)Math.Round(cx), y0 = (int)Math.Round(cy);
            for (int a = 0; a < 48; a++)
            {
                double t = a * Math.Tau / 48;
                Set(x0 + (int)Math.Round(radius * Math.Cos(t)),
                    y0 + (int)Math.Round(radius * Math.Sin(t)), c);
            }
        }
    }
}
