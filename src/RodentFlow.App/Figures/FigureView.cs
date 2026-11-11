using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using RodentFlow.Core.Figures;

namespace RodentFlow.App.Figures;

/// <summary>
/// One figure on screen: a Win2D CanvasControl sized to what the figure needs at the width it is given
/// (the Mac's Canvas inside a frame of fixed height or aspect ratio).
/// </summary>
/// <remarks>
/// <para>The paint function draws the figure at a width and returns its height. It runs twice per layout:
/// once on a measuring canvas to size the control, then in the control's Draw event.</para>
/// <para>Win2D controls must be released explicitly from .NET (RemoveFromVisualTree and dropping every
/// reference), or the control and its GPU resources leak: a reference cycle between the C++ control and
/// the managed event handler. The result page replaces its figures every time the results change, so
/// <see cref="Release"/> is called for each figure it takes down.</para>
/// </remarks>
internal sealed class FigureView : Grid
{
    private static readonly IFigureCanvas Measurer = new MeasureCanvas(Win2DCanvas.MeasureShared);
    private readonly string? _fontFamily;

    private CanvasControl? _canvas;
    private readonly Func<IFigureCanvas, double, double> _paint;
    private readonly double? _fixedWidth;
    private double _laidOutFor = -1;

    /// <summary>The pointer over the figure (DIPs), or null when it leaves; for line-chart read-outs.</summary>
    public Action<Windows.Foundation.Point?>? PointerAt { get; set; }

    /// <summary>A press on the figure, then every move while the button is held (scrubbing a timeline).</summary>
    public Action<Windows.Foundation.Point>? PointerDown { get; set; }

    private bool _dragging;

    public FigureView(Func<IFigureCanvas, double, double> paint, double? fixedWidth = null, string? fontFamily = null)
    {
        _paint = paint;
        _fixedWidth = fixedWidth;
        _fontFamily = fontFamily;
        _canvas = new CanvasControl { ClearColor = Microsoft.UI.Colors.Transparent };
        if (fixedWidth is { } w)
        {
            _canvas.Width = Math.Ceiling(w);
            HorizontalAlignment = HorizontalAlignment.Left;
        }
        _canvas.Draw += OnDraw;
        _canvas.PointerMoved += OnPointerMoved;
        _canvas.PointerExited += OnPointerExited;
        _canvas.PointerPressed += OnPointerPressed;
        _canvas.PointerReleased += OnPointerReleased;
        _canvas.PointerCaptureLost += OnPointerReleased;
        Children.Add(_canvas);
        SizeChanged += OnSizeChanged;
    }

    private double PaintWidth => _fixedWidth ?? ActualWidth;

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        // The height follows the width; a change of height alone (our own doing) needs nothing.
        if (Math.Abs(e.NewSize.Width - _laidOutFor) > 0.5) Relayout();
    }

    /// <summary>Lays the figure out again (its data or style changed) and redraws it.</summary>
    public void Relayout()
    {
        if (_canvas is null) return;
        double w = PaintWidth;
        if (!(w > 0)) return;
        _laidOutFor = ActualWidth;
        double h;
        try { h = _paint(Measurer, w); }
        catch (Exception) { h = 0; }
        _canvas.Height = Math.Max(1, Math.Ceiling(h));
        _canvas.Invalidate();
    }

    /// <summary>Redraws without laying out again (the pointer moved).</summary>
    public void Redraw() => _canvas?.Invalidate();

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var canvas = new Win2DCanvas(args.DrawingSession, sender, _fontFamily);
        try
        {
            _paint(canvas, _fixedWidth ?? sender.ActualWidth);
        }
        catch (Exception)
        {
            // A figure that cannot be drawn leaves its card empty rather than taking the page down.
        }
        finally
        {
            canvas.Close();
        }
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_canvas is null) return;
        var position = e.GetCurrentPoint(_canvas).Position;
        if (_dragging) PointerDown?.Invoke(position);
        PointerAt?.Invoke(position);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (PointerDown is null || _canvas is null) return;
        _dragging = _canvas.CapturePointer(e.Pointer);
        PointerDown(e.GetCurrentPoint(_canvas).Position);
        e.Handled = true;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        _canvas?.ReleasePointerCaptures();
    }

    private void OnPointerExited(object sender, PointerRoutedEventArgs e) => PointerAt?.Invoke(null);

    /// <summary>Takes the Win2D control down for good (see the remarks).</summary>
    public void Release()
    {
        if (_canvas is null) return;
        SizeChanged -= OnSizeChanged;
        _canvas.Draw -= OnDraw;
        _canvas.PointerMoved -= OnPointerMoved;
        _canvas.PointerExited -= OnPointerExited;
        _canvas.PointerPressed -= OnPointerPressed;
        _canvas.PointerReleased -= OnPointerReleased;
        _canvas.PointerCaptureLost -= OnPointerReleased;
        _canvas.RemoveFromVisualTree();
        _canvas = null;
        PointerAt = null;
        PointerDown = null;
    }
}
