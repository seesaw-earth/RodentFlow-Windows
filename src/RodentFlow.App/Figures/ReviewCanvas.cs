using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RodentFlow.Core.Figures;

namespace RodentFlow.App.Figures;

/// <summary>
/// The review picture: the decoded frame, fitted into the control, with the overlay (skeletons, trail, zones)
/// drawn in the same pass, so they can never be a frame apart — the Mac draws its skeleton layer over AVPlayer's
/// layer from the player's clock for the same reason.
/// </summary>
/// <remarks>The control lives as long as the window; each new frame frees the previous frame's GPU copy.</remarks>
internal sealed class ReviewCanvas
{
    private readonly CanvasControl _canvas;
    private FigureImage? _frame;

    /// <summary>Size of the upright video frame in pixels: the overlay's coordinates.</summary>
    public double FrameWidth { get; set; } = 1280;
    public double FrameHeight { get; set; } = 720;

    /// <summary>Draws over the frame: the canvas, frame pixels → drawing coordinates, and the line scale (1.3 when large).</summary>
    public Action<IFigureCanvas, Func<double, double, Pt>, double>? Overlay { get; set; }

    public ReviewCanvas(Border host)
    {
        _canvas = new CanvasControl { ClearColor = Microsoft.UI.Colors.Black };
        _canvas.Draw += OnDraw;
        _canvas.SizeChanged += (_, _) => _canvas.Invalidate();
        host.Child = _canvas;
    }

    /// <summary>Shows a new frame (the previous one's GPU bitmap is freed).</summary>
    public void Show(FigureImage? frame)
    {
        var old = _frame;
        _frame = frame;
        if (old is not null && !ReferenceEquals(old, frame)) Win2DCanvas.ReleaseImage(old);
        _canvas.Invalidate();
    }

    public void Invalidate() => _canvas.Invalidate();

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        double w = sender.ActualWidth, h = sender.ActualHeight;
        if (!(w > 0 && h > 0 && FrameWidth > 0 && FrameHeight > 0)) return;
        double s = Math.Min(w / FrameWidth, h / FrameHeight);
        double rw = FrameWidth * s, rh = FrameHeight * s;
        double ox = (w - rw) / 2, oy = (h - rh) / 2;
        var canvas = new Win2DCanvas(args.DrawingSession, sender);
        try
        {
            if (_frame is { } image) canvas.Image(image, ox, oy, rw, rh);
            Overlay?.Invoke(canvas, (x, y) => new Pt(ox + x * s, oy + y * s), rw > 700 ? 1.3 : 1);
        }
        catch (Exception)
        {
            // An overlay that cannot be drawn leaves the picture alone.
        }
        finally
        {
            canvas.Close();
        }
    }
}
