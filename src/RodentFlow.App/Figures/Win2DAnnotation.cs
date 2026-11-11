using Microsoft.Graphics.Canvas;
using RodentFlow.Core;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Review;
using RodentFlow.Engine;
using Windows.Graphics.DirectX;

namespace RodentFlow.App.Figures;

/// <summary>
/// The marks of the review video, drawn as the Mac's AnnotatedVideoExporter draws them: one animal as its skeleton
/// with coloured keypoints; two or more as head triangles, nose lines and tail-base dots in each animal's colour with
/// an A / B (or numbered) badge; the calibrated arena and the region the model was given; a red border on a frame with
/// nothing detected. Marks grow with the picture (1 at 540 pixels on the short side). Each frame goes through the GPU
/// once (draw, read back), which is fast next to encoding it.
/// </summary>
internal static class Win2DAnnotation
{
    /// <summary>The Mac exporter's keypoint threshold (AnnotatedVideoExporter.valid).</summary>
    private const float MinConfidence = 0.35f;

    /// <summary>
    /// The GPU bitmap and render target of the last frame size, reused for every frame of the video: creating them per
    /// frame cost more than drawing. One set per drawing thread (the writer draws on one).
    /// </summary>
    [ThreadStatic] private static (CanvasDevice Device, int Width, int Height, CanvasBitmap Frame, CanvasRenderTarget Target)? _cache;

    public static void Draw(byte[] pixels, int width, int height, int rowBytes, IReadOnlyList<PoseKeypoints> animals,
                            Annotation.Context context)
    {
        var device = CanvasDevice.GetSharedDevice();
        byte[] tight = rowBytes == width * 4 ? pixels : Tight(pixels, width, height, rowBytes);
        if (_cache is not { } cache || !ReferenceEquals(cache.Device, device) || cache.Width != width || cache.Height != height)
        {
            if (_cache is { } old)
            {
                old.Frame.Dispose();
                old.Target.Dispose();
            }
            var bitmap = CanvasBitmap.CreateFromBytes(device, tight, width, height, DirectXPixelFormat.B8G8R8A8UIntNormalized, 96);
            cache = (device, width, height, bitmap, new CanvasRenderTarget(device, width, height, 96));
            _cache = cache;
        }
        else
        {
            cache.Frame.SetPixelBytes(tight);
        }
        var frame = cache.Frame;
        var target = cache.Target;
        using (var ds = target.CreateDrawingSession())
        {
            ds.DrawImage(frame, 0, 0);
            var c = new Win2DCanvas(ds, target);
            double sx = context.FrameWidth > 0 ? width / context.FrameWidth : 1;
            double sy = context.FrameHeight > 0 ? height / context.FrameHeight : 1;
            double scale = Math.Max(1, Math.Min(width, height) / 540.0);

            if (context.ArenaCorners is { Length: >= 3 } corners)
            {
                var outline = new FigurePath().AddPolyline(corners.Select(p => new Pt(p.X * width, p.Y * height)).ToList(), closed: true);
                c.Stroke(outline, new Rgba(1, 0.78, 0.35, 0.9), 1.2 * scale);
            }
            if (context.Crop is { } crop)
                c.Stroke(FigurePath.Rect(crop.X * sx, crop.Y * sy, crop.Width * sx, crop.Height * sy), Rgba.Gray(0.8, 0.8), scale,
                         new StrokeStyle([6 * scale, 4 * scale]));

            PoseOverlay.DrawPoses(c, animals, (x, y) => new Pt(x * sx, y * sy), scale, MinConfidence, FigureTheme.DarkTheme);

            if (animals.Count > 0 && !animals.Any(a => a.Detected))
                c.Stroke(FigurePath.Rect(2 * scale, 2 * scale, width - 4 * scale, height - 4 * scale), new Rgba(0.92, 0.26, 0.24), 4 * scale);
            c.Close();
        }
        byte[] drawn = target.GetPixelBytes();
        if (rowBytes == width * 4)
        {
            System.Buffer.BlockCopy(drawn, 0, pixels, 0, Math.Min(drawn.Length, pixels.Length));
            return;
        }
        for (int y = 0; y < height; y++)
            System.Buffer.BlockCopy(drawn, y * width * 4, pixels, y * rowBytes, width * 4);
    }

    private static byte[] Tight(byte[] pixels, int width, int height, int rowBytes)
    {
        var tight = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
            System.Buffer.BlockCopy(pixels, y * rowBytes, tight, y * width * 4, width * 4);
        return tight;
    }
}
