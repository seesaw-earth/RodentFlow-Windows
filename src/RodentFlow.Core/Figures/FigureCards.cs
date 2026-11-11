using RodentFlow.Engine;

namespace RodentFlow.Core.Figures;

/// <summary>
/// A figure card as it is saved to a file: the card with the figure's title, caption and figure, on a page
/// with a 12-unit margin — the Mac's FigureExport (RPReportBlockView.exportView rendered 420 wide, 640 when
/// the calibration frame is shown next to a heat map; light appearance). Units are points in files.
/// </summary>
public static class FigureCards
{
    public const double PageMargin = 12;
    public const double CardPadding = 16;
    public const double CardRadius = 12;

    /// <summary>
    /// Width of the card for a file: the Mac's export width, or wider for a table that would not fit
    /// (the Mac's table scrolls sideways; a file cannot).
    /// </summary>
    public static double ContentWidth(Func<string, FontSpec, TextSize> measure, ReportBlock b, FigureOptions o)
    {
        double width = ReportFigures.ExportWidth(b, o);
        if (ReportFigures.NaturalWidth(new MeasureCanvas(measure), b) is { } natural)
            width = Math.Max(width, natural + 2 * CardPadding);
        return width;
    }

    /// <summary>Size of the page for a card of <paramref name="contentWidth"/>.</summary>
    public static (double Width, double Height) PageSize(Func<string, FontSpec, TextSize> measure, ReportBlock b,
                                                         FigureOptions o, double contentWidth)
    {
        double cardH = Card(new MeasureCanvas(measure), b, o, PageMargin, PageMargin, contentWidth);
        return (contentWidth + 2 * PageMargin, cardH + 2 * PageMargin);
    }

    /// <summary>The page: background, card, title, caption, figure.</summary>
    public static void Draw(IFigureCanvas c, ReportBlock b, FigureOptions o, double contentWidth, double pageHeight, Rgba page)
    {
        if (page.A > 0) c.Fill(FigurePath.Rect(0, 0, contentWidth + 2 * PageMargin, pageHeight), page);
        Card(c, b, o, PageMargin, PageMargin, contentWidth);
    }

    private static double Card(IFigureCanvas c, ReportBlock b, FigureOptions o, double x, double y, double width)
    {
        double inner = width - 2 * CardPadding;
        var m = new MeasureCanvas(c.Measure);
        double headerH = Header(m, b, o, 0, 0, inner);
        double figureH = ReportFigures.Paint(m, b, 0, 0, inner, o);
        double cardH = CardPadding + headerH + 12 + figureH + CardPadding;

        var card = FigurePath.RoundedRect(x, y, width, cardH, CardRadius);
        c.Fill(card, o.Theme.Card);
        c.Stroke(card, o.Theme.Hairline.Opacity(0.6), 0.5);
        Header(c, b, o, x + CardPadding, y + CardPadding, inner);
        ReportFigures.Paint(c, b, x + CardPadding, y + CardPadding + headerH + 12, inner, o);
        return cardH;
    }

    /// <summary>FigureCardHeader: the title, and the caption under it in secondary ink.</summary>
    private static double Header(IFigureCanvas c, ReportBlock b, FigureOptions o, double x, double y, double width)
    {
        double h = FigureKit.Paragraph(c, b.Title, x, y, width, FigureFonts.Headline, o.Theme.Primary);
        if (b.Caption is { Length: > 0 } caption)
            h += 2 + FigureKit.Paragraph(c, caption, x, y + h + 2, width, FigureFonts.Footnote, o.Theme.Secondary);
        return h;
    }

    /// <summary>A file-name-safe slug of an English title (FigureExport.slug).</summary>
    public static string Slug(string text)
    {
        var sb = new System.Text.StringBuilder();
        foreach (char ch in text.ToLowerInvariant())
        {
            if (ch < 128 && char.IsLetterOrDigit(ch)) sb.Append(ch);
            else if (sb.Length == 0 || sb[^1] != '_') sb.Append('_');
        }
        string slug = sb.ToString().Trim('_');
        if (slug.Length == 0) return "figure";
        return slug.Length > 48 ? slug[..48] : slug;
    }
}
