using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace RodentFlow.App.Results;

/// <summary>
/// As many equal columns as fit at <see cref="MinItemWidth"/> or wider, rows as tall as their tallest item:
/// the Mac's <c>LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10)</c>
/// for the measure tiles.
/// </summary>
internal sealed class AdaptiveGridPanel : Panel
{
    public double MinItemWidth { get; set; } = 148;
    public double Spacing { get; set; } = 10;

    private int Columns(double width) =>
        Math.Max(1, (int)Math.Floor((width + Spacing) / (MinItemWidth + Spacing)));

    private double _itemWidth;
    private readonly List<double> _rowHeights = [];

    protected override Size MeasureOverride(Size availableSize)
    {
        double width = double.IsInfinity(availableSize.Width) ? 4 * MinItemWidth + 3 * Spacing : availableSize.Width;
        int cols = Columns(width);
        _itemWidth = Math.Max(0, (width - (cols - 1) * Spacing) / cols);
        _rowHeights.Clear();
        double rowH = 0;
        for (int i = 0; i < Children.Count; i++)
        {
            var child = Children[i];
            child.Measure(new Size(_itemWidth, double.PositiveInfinity));
            rowH = Math.Max(rowH, child.DesiredSize.Height);
            if (i % cols == cols - 1 || i == Children.Count - 1)
            {
                _rowHeights.Add(rowH);
                rowH = 0;
            }
        }
        double height = _rowHeights.Sum() + Spacing * Math.Max(0, _rowHeights.Count - 1);
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        int cols = Columns(finalSize.Width);
        double itemW = Math.Max(0, (finalSize.Width - (cols - 1) * Spacing) / cols);
        double y = 0;
        for (int i = 0; i < Children.Count; i++)
        {
            int row = i / cols, col = i % cols;
            if (col == 0 && row > 0) y += (row - 1 < _rowHeights.Count ? _rowHeights[row - 1] : 0) + Spacing;
            double h = row < _rowHeights.Count ? _rowHeights[row] : Children[i].DesiredSize.Height;
            Children[i].Arrange(new Rect(col * (itemW + Spacing), y, itemW, h));
        }
        return finalSize;
    }
}
