using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using RodentFlow.App.Figures;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Text;
using RodentFlow.Engine;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using static RodentFlow.App.AppText;

namespace RodentFlow.App.Results;

/// <summary>
/// The result page of one session, in the order of the Mac's (PoseReportView, PoseResultFigures.swift):
/// notices, the headline measure with its scale, the detection-quality line, every other measure, the
/// figures, the detection-quality card and the Methods paragraph.
/// </summary>
/// <remarks>
/// Built in code from the engine's report, like the parameter forms: nothing here knows which task it is
/// showing. Each figure card has the Mac's menu — layers, copy, PNG, vector PDF, print PNG, CSV — and files
/// are written in English whatever the interface language, as on the Mac.
/// </remarks>
internal sealed class ReportPresenter
{
    /// <summary>What the page is drawn from, and how it reaches the rest of the window.</summary>
    public sealed class Context
    {
        public required DisplayReport Report { get; init; }
        /// <summary>The calibration frame (for heat maps on / next to the picture); null without a video.</summary>
        public FigureImage? Backdrop { get; init; }
        public required bool Dark { get; init; }
        /// <summary>The same report in English, for files (computed when first needed).</summary>
        public required Func<Task<DisplayReport?>> EnglishReport { get; init; }
        public required Func<IntPtr> WindowHandle { get; init; }
        public required Action<string> Message { get; init; }
        /// <summary>Shown first, as a warning (e.g. the calibration now reaches outside the tracked region).</summary>
        public string? Notice { get; init; }
    }

    private readonly StackPanel _host;
    private readonly List<FigureView> _figures = [];
    private Context? _ctx;
    private FigureTheme _theme = FigureTheme.Light;

    public ReportPresenter(StackPanel host) => _host = host;

    public bool IsShowing => _ctx is not null;

    /// <summary>Takes the page down, releasing every Win2D control on it.</summary>
    public void Clear()
    {
        foreach (var f in _figures) f.Release();
        _figures.Clear();
        _host.Children.Clear();
        _ctx = null;
    }

    /// <summary>Dims the page while new results are computed (the Mac keeps the old ones on screen, dimmed).</summary>
    public void SetUpdating(bool updating) => _host.Opacity = updating ? 0.45 : 1;

    public void Show(Context ctx)
    {
        Clear();
        _ctx = ctx;
        _theme = FigureTheme.For(ctx.Dark);
        Tr.Preload(InterfaceTexts);
        var r = ctx.Report;

        if (ctx.Notice is { Length: > 0 } notice) _host.Children.Add(Banner(notice, Status.Warning));
        if (r.Warnings.Length > 0) _host.Children.Add(NoticeList(r.Warnings));
        if (r.Primary is { } primary) _host.Children.Add(KeyResultCard(primary, r));
        _host.Children.Add(QualityBadge(r.Quality));

        var others = r.Metrics.Where(m => m.Key != r.Primary?.Key).ToList();
        if (others.Count > 0)
        {
            _host.Children.Add(Label(Tr.T("全部指标"), 15, bold: true, margin: new Thickness(0, 4, 0, 0)));
            var grid = new AdaptiveGridPanel();
            foreach (var m in others) grid.Children.Add(MetricTile(m));
            _host.Children.Add(grid);
        }

        foreach (var b in r.Blocks) _host.Children.Add(BlockCard(b));
        _host.Children.Add(QualityCard(r.Quality));
        _host.Children.Add(MethodsCard(r));
    }

    /// <summary>The page's own texts, translated in one engine call.</summary>
    private static readonly string[] InterfaceTexts =
    [
        "全部指标", "主要指标", "识别质量", "检出率良好", "检出率尚可，建议抽查回看", "检出率偏低，请先回看检查",
        "检出率（分析时间段）", "分析帧数", "分析时长", "采样率", "头朝向有效", "比例", "超出标定范围",
        "各关键点有效比例", "检出率 %.1f%%", "方法说明（可用于论文 Methods）", "复制方法说明", "已复制方法说明",
        "图层与原图对照…", "图层（显示 / 移除）…", "复制图像", "复制数据（CSV，英文）", "已复制图像", "已复制数据",
        "%d 条提示", "还有 %d 条", "热图", "原图（标定帧）", "起点", "终点", "距分析起点的时间（m:ss）", "没有数据",
        "平均", "单次（%d）", "平均方向 %.0f°", "平均向量长度 %.2f（0–1）", "参考方向", "停留时间（s）",
        "半径按平方根标度：圈上数字为每格的%@", "少", "多", "停留时间（平方根标度）", "图表操作",
    ];

    // ================================================================ building blocks

    private enum Status { Info, Warning, Success, Error }

    private Rgba StatusColor(Status s) => s switch
    {
        Status.Warning => _theme.Warning,
        Status.Success => _theme.Success,
        Status.Error => _theme.Danger,
        _ => _theme.Accent,
    };

    private static string StatusGlyph(Status s) => s switch
    {
        Status.Warning => "\uE7BA",  // Warning
        Status.Success => "\uE930",  // Completed
        Status.Error => "\uEA39",    // ErrorBadge
        _ => "\uE946",               // Info
    };

    private static SolidColorBrush Brush(Rgba c) => new(Win2DCanvas.ToColor(c));

    private Brush SecondaryInk => Brush(_theme.Secondary);

    private static TextBlock Label(string text, double size = 13, bool bold = false, Brush? color = null,
                                   Thickness? margin = null, bool wrap = true)
    {
        var t = new TextBlock
        {
            Text = text,
            FontSize = size,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
        if (bold) t.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        if (color is not null) t.Foreground = color;
        if (margin is { } m) t.Margin = m;
        return t;
    }

    /// <summary>FigureCard: the Mac's card, on Windows' card colours.</summary>
    private Border Card(UIElement content, double padding = 16) => new()
    {
        Background = Brush(_theme.Card),
        BorderBrush = Brush(_theme.Hairline),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(FigureCards.CardRadius),
        Padding = new Thickness(padding),
        Child = content,
    };

    private static FontIcon Icon(string glyph, Brush color, double size = 14) => new()
    {
        Glyph = glyph,
        FontSize = size,
        Foreground = color,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>FigureCardHeader: symbol, title and caption, and anything on the trailing side.</summary>
    private Grid CardHeader(string glyph, string title, string? caption, UIElement? trailing)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Icon(glyph, SecondaryInk);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 3, 0, 0);
        grid.Children.Add(icon);
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(Label(title, 15, bold: true));
        if (caption is { Length: > 0 }) text.Children.Add(Label(caption, 12, color: SecondaryInk));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (trailing is FrameworkElement t)
        {
            Grid.SetColumn(t, 2);
            t.VerticalAlignment = VerticalAlignment.Top;
            grid.Children.Add(t);
        }
        return grid;
    }

    /// <summary>RPBanner: an inline message; the icon carries the status colour, the text stays in primary ink.</summary>
    private Border Banner(string text, Status status)
    {
        var color = StatusColor(status);
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = Icon(StatusGlyph(status), Brush(color), 16);
        icon.VerticalAlignment = VerticalAlignment.Top;
        row.Children.Add(icon);
        var label = Label(text, 13);
        label.IsTextSelectionEnabled = true;
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        return new Border
        {
            Background = Brush(color.Opacity(0.10)),
            BorderBrush = Brush(color.Opacity(0.25)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12),
            Child = row,
        };
    }

    /// <summary>RPNoticeList: one notice as a banner; several collapse into one card that expands.</summary>
    private FrameworkElement NoticeList(string[] notices)
    {
        if (notices.Length == 1) return Banner(notices[0], Status.Warning);
        var color = StatusColor(Status.Warning);
        var stack = new StackPanel { Spacing = 8 };
        var border = new Border
        {
            Background = Brush(color.Opacity(0.10)),
            BorderBrush = Brush(color.Opacity(0.25)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12),
            Child = stack,
        };
        bool expanded = false;
        void Fill()
        {
            stack.Children.Clear();
            var head = new Grid { ColumnSpacing = 8 };
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.Children.Add(Icon(StatusGlyph(Status.Warning), Brush(color), 16));
            var title = Label(Tr.F("%d 条提示", notices.Length), 13, bold: true);
            Grid.SetColumn(title, 1);
            head.Children.Add(title);
            var chevron = Icon(expanded ? "\uE70E" : "\uE70D", SecondaryInk, 12);
            Grid.SetColumn(chevron, 2);
            head.Children.Add(chevron);
            var toggle = new Button
            {
                Content = head,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0, 2, 0, 2),
            };
            toggle.Click += (_, _) => { expanded = !expanded; Fill(); };
            stack.Children.Add(toggle);
            foreach (string n in expanded ? notices : notices.Take(1))
            {
                var line = new Grid { ColumnSpacing = 8 };
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                line.Children.Add(new Ellipse
                {
                    Width = 5, Height = 5, Fill = Brush(color), VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, 8, 0, 0),
                });
                var text = Label(n, 13);
                text.IsTextSelectionEnabled = true;
                Grid.SetColumn(text, 1);
                line.Children.Add(text);
                stack.Children.Add(line);
            }
            if (!expanded) stack.Children.Add(Label(Tr.F("还有 %d 条", notices.Length - 1), 12, color: SecondaryInk));
        }
        Fill();
        return border;
    }

    /// <summary>RPKeyResultCard: the headline measure, its tag, the task's note, its scale and its description.</summary>
    private Border KeyResultCard(ReportMetric m, DisplayReport r)
    {
        var stack = new StackPanel { Spacing = 10 };
        var top = new Grid { ColumnSpacing = 8 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(Label(m.Title, 14, bold: true, color: SecondaryInk));
        var category = _theme.Category(r.Category);
        var tag = new Border
        {
            Background = Brush(category.Opacity(0.12)),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8, 3, 8, 3),
            VerticalAlignment = VerticalAlignment.Top,
            Child = Label(Tr.T("主要指标"), 12, bold: true, color: Brush(category), wrap: false),
        };
        Grid.SetColumn(tag, 1);
        top.Children.Add(tag);
        stack.Children.Add(top);

        var value = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        value.Children.Add(Label(m.Display, 44, bold: true, wrap: false));
        if (m.DisplayUnit.Length > 0)
            value.Children.Add(Bottom(Label(m.DisplayUnit, 20, color: SecondaryInk, wrap: false)));
        if (m.Censored is { } censored && m.Value is not null)
            value.Children.Add(Bottom(Label("(" + censored + ")", 20, color: SecondaryInk, wrap: false)));
        stack.Children.Add(value);

        if (r.KeyNote is { Length: > 0 } note) stack.Children.Add(Label(note, 15, bold: true));
        if (m.Scale is { } scale && m.Value is { } v && double.IsFinite(v))
        {
            var fill = FigureTheme.CategoryFill(r.Category);
            var theme = _theme;
            var bar = new FigureView((c, w) => ReportFigures.ScaleBar(c, scale, v, fill, 0, 0, w, theme));
            _figures.Add(bar);
            stack.Children.Add(bar);
        }
        if (m.Info is { Length: > 0 } info) stack.Children.Add(Label(info, 12, color: SecondaryInk));
        return Card(stack);
    }

    private static FrameworkElement Bottom(FrameworkElement e)
    {
        e.VerticalAlignment = VerticalAlignment.Bottom;
        e.Margin = new Thickness(0, 0, 0, 8);
        return e;
    }

    private (string Text, Status Status)? QualityLevel(ReportQuality q)
    {
        if (q.FramesInWindow <= 0) return null;
        if (q.DetectionRate >= 0.95) return (Tr.T("检出率良好"), Status.Success);
        if (q.DetectionRate >= 0.8) return (Tr.T("检出率尚可，建议抽查回看"), Status.Warning);
        return (Tr.T("检出率偏低，请先回看检查"), Status.Error);
    }

    /// <summary>RPQualityBadge: one line with the detection rate and its level, under the headline card.</summary>
    private Border QualityBadge(ReportQuality q)
    {
        var level = QualityLevel(q);
        var row = new Grid { ColumnSpacing = 10 };
        for (int i = 0; i < 4; i++)
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = i == 2 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var status = level?.Status ?? Status.Info;
        row.Children.Add(Icon(StatusGlyph(status), Brush(StatusColor(status)), 16));
        var name = Label(Tr.T("识别质量"), 13, bold: true, wrap: false);
        Grid.SetColumn(name, 1);
        row.Children.Add(name);
        if (level is { } l)
        {
            var text = Label(l.Text, 13, color: SecondaryInk, wrap: false);
            Grid.SetColumn(text, 2);
            row.Children.Add(text);
        }
        var rate = Label(Tr.F("检出率 %.1f%%", q.DetectionRate * 100), 13, color: SecondaryInk, wrap: false);
        Grid.SetColumn(rate, 4);
        row.Children.Add(rate);
        return Card(row, 12);
    }

    /// <summary>RPMetricTile: title, value with unit, the reason a latency is censored; the description as a tooltip.</summary>
    private Border MetricTile(ReportMetric m)
    {
        var stack = new StackPanel { Spacing = 4 };
        var title = Label(m.Title, 12, color: SecondaryInk);
        title.MaxLines = 2;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        stack.Children.Add(title);
        var value = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
        value.Children.Add(Label(m.Display, 20, bold: true, wrap: false));
        if (m.DisplayUnit.Length > 0)
        {
            var unit = Label(m.DisplayUnit, 12, color: SecondaryInk, wrap: false);
            unit.VerticalAlignment = VerticalAlignment.Bottom;
            unit.Margin = new Thickness(0, 0, 0, 4);
            value.Children.Add(unit);
        }
        stack.Children.Add(value);
        if (m.Censored is { } censored && m.Value is not null) stack.Children.Add(Label(censored, 12, color: SecondaryInk));
        var tile = new Border
        {
            Background = Brush(_theme.Inset),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12),
            MinHeight = 64,
            Child = stack,
        };
        if (m.Highlight)
        {
            tile.BorderBrush = Brush(_theme.Accent.Opacity(0.45));
            tile.BorderThickness = new Thickness(1);
        }
        if (m.Info is { Length: > 0 } info) ToolTipService.SetToolTip(tile, info);
        return tile;
    }

    // ================================================================ figure cards

    private static string BlockGlyph(string kind) => kind switch
    {
        "arena" => "\uE707",     // MapPin
        "timeline" => "\uE823",  // Recent
        "bars" => "\uE9D2",      // AreaChart
        "line" => "\uE9D2",
        "polar" => "\uE7AD",     // Rotate
        "table" => "\uE8A9",     // ViewAll
        _ => "\uE9D2",
    };

    private Border BlockCard(ReportBlock b)
    {
        var ctx = _ctx!;
        var options = new FigureOptions
        {
            Theme = _theme,
            Style = FigureStyleStore.Load(b.StyleKey),
            Backdrop = ctx.Backdrop,
        };
        FigureView view;
        UIElement content;
        if (b.Kind == "table")
        {
            double natural = ReportFigures.NaturalWidth(new MeasureCanvas(Win2DCanvas.MeasureShared), b) ?? 0;
            view = new FigureView((c, w) => ReportFigures.Paint(c, b, 0, 0, w, options), natural + 2);
            content = new ScrollViewer
            {
                Content = view,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalScrollMode = ScrollMode.Enabled,
                VerticalScrollMode = ScrollMode.Disabled,
            };
        }
        else
        {
            view = new FigureView((c, w) => ReportFigures.Paint(c, b, 0, 0, w, options));
            content = view;
        }
        _figures.Add(view);

        if (b.Kind == "line")
        {
            // chartXSelection: the values under the pointer.
            view.PointerAt = p =>
            {
                double? x = null;
                if (p is { } pt && options.Plot is { } plot && pt.X >= plot.Left && pt.X <= plot.Left + plot.Width
                    && pt.Y >= plot.Top && pt.Y <= plot.Top + plot.Height)
                    x = plot.XAt(pt.X);
                if (x == options.HoverX) return;
                options.HoverX = x;
                view.Redraw();
            };
        }

        var more = new Button
        {
            Content = Icon("\uE712", SecondaryInk, 14),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6),
            Flyout = Menu(b, options, view),
        };
        ToolTipService.SetToolTip(more, Tr.T("图表操作"));
        var stack = new StackPanel { Spacing = 12 };
        stack.Children.Add(CardHeader(BlockGlyph(b.Kind), b.Title, b.Caption, more));
        stack.Children.Add(content);
        var card = Card(stack);
        card.ContextFlyout = Menu(b, options, view);
        return card;
    }

    private MenuFlyout Menu(ReportBlock b, FigureOptions options, FigureView view)
    {
        var menu = new MenuFlyout();
        void Add(string text, string glyph, Func<Task> action)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += async (_, _) =>
            {
                try { await action(); }
                catch (Exception e) { _ctx?.Message(e.Message); }
            };
            menu.Items.Add(item);
        }

        if (b.Arena is { } arena)
        {
            Add(Tr.T(arena.Heat is not null ? "图层与原图对照…" : "图层（显示 / 移除）…"), "\uE81E", () => ShowLayersAsync(b, options, view));
            menu.Items.Add(new MenuFlyoutSeparator());
        }
        Add(Tr.T("复制图像"), "\uE8C8", () => CopyImageAsync(b, options));
        Add(L("Save image…", "保存图像…"), "\uE74E", () => SaveAsync(b, options, Export.Png));
        Add(L("Save as vector PDF…", "存为矢量 PDF…"), "\uEA90", () => SaveAsync(b, options, Export.Pdf));
        Add(L("Save as SVG…", "存为 SVG…"), "\uE771", () => SaveAsync(b, options, Export.Svg));
        Add(L("Save as PNG, 300 dpi…", "存为 PNG（300 dpi）…"), "\uE749", () => SaveAsync(b, options, Export.Print300));
        Add(L("Save as PNG, 600 dpi…", "存为 PNG（600 dpi）…"), "\uE749", () => SaveAsync(b, options, Export.Print600));
        if (b.Csv is { Length: > 0 } csv)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            Add(Tr.T("复制数据（CSV，英文）"), "\uE8C8", () =>
            {
                var data = new DataPackage();
                data.SetText(csv);
                Clipboard.SetContent(data);
                _ctx?.Message(Tr.T("已复制数据"));
                return Task.CompletedTask;
            });
        }
        return menu;
    }

    private async Task ShowLayersAsync(ReportBlock b, FigureOptions options, FigureView view)
    {
        if (_ctx is not { } ctx || _host.XamlRoot is not { } root) return;
        await LayersDialog.ShowAsync(root, b, ctx.Report, options.Style, ctx.Backdrop is not null, style =>
        {
            FigureStyleStore.Save(b.StyleKey, style);
            view.Relayout();
        });
    }

    // ================================================================ exports

    private enum Export { Png, Pdf, Svg, Print300, Print600 }

    /// <summary>The block and options a file is drawn with: English (when asked), light, the layers on screen.</summary>
    private async Task<(ReportBlock Block, FigureOptions Options)> ForFile(ReportBlock b, FigureOptions screen, bool english)
    {
        var block = b;
        if (english && _ctx is { } ctx)
        {
            var en = await ctx.EnglishReport();
            var match = en?.Blocks.FirstOrDefault(x => x.Index == b.Index && x.Kind == b.Kind);
            if (match is not null) block = match;
        }
        return (block, new FigureOptions
        {
            Theme = FigureTheme.Light,
            English = english,
            Style = screen.Style,
            Backdrop = screen.Backdrop,
        });
    }

    /// <summary>The card as a PNG: 3× on the page colour ("Save image", copy), or a print resolution on white.</summary>
    private static async Task<byte[]> CardPng(ReportBlock block, FigureOptions o, double pixelsPerUnit, Rgba page, double? dpi)
    {
        double contentWidth = FigureCards.ContentWidth(Win2DCanvas.MeasureShared, block, o);
        var (w, h) = FigureCards.PageSize(Win2DCanvas.MeasureShared, block, o, contentWidth);
        return await FigureRaster.PngAsync(w, h, pixelsPerUnit, c => FigureCards.Draw(c, block, o, contentWidth, h, page), dpi);
    }

    private async Task CopyImageAsync(ReportBlock b, FigureOptions screen)
    {
        // The clipboard gets the interface language, as on the Mac; files get English.
        var (block, o) = await ForFile(b, screen, english: false);
        byte[] png = await CardPng(block, o, 3, FigureTheme.Light.Background, null);
        var data = new DataPackage();
        data.SetBitmap(await FigureRaster.ClipboardImageAsync(png));
        Clipboard.SetContent(data);
        try { Clipboard.Flush(); }
        catch (Exception) { /* the copy is there for as long as the app runs */ }
        _ctx?.Message(Tr.T("已复制图像"));
    }

    private async Task SaveAsync(ReportBlock b, FigureOptions screen, Export kind)
    {
        var (block, o) = await ForFile(b, screen, english: true);
        string name = "rodentpose_" + FigureCards.Slug(block.Title);
        switch (kind)
        {
            case Export.Png:
            {
                byte[] png = await CardPng(block, o, 3, FigureTheme.Light.Background, null);
                await SaveFileAsync(name, "PNG", ".png", png);
                break;
            }
            case Export.Print300:
            case Export.Print600:
            {
                int dpi = kind == Export.Print300 ? 300 : 600;
                byte[] png = await CardPng(block, o, dpi / 72.0, Rgba.White, dpi);
                await SaveFileAsync(name + "_" + dpi.ToString(CultureInfo.InvariantCulture) + "dpi", "PNG", ".png", png);
                break;
            }
            case Export.Pdf:
            {
                double cw = FigureCards.ContentWidth(HelveticaMetrics.Measure, block, o);
                var (w, h) = FigureCards.PageSize(HelveticaMetrics.Measure, block, o, cw);
                var pdf = new PdfCanvas(w, h, block.Title);
                FigureCards.Draw(pdf, block, o, cw, h, Rgba.White);
                await SaveFileAsync(name, "PDF", ".pdf", pdf.Document());
                break;
            }
            case Export.Svg:
            {
                double cw = FigureCards.ContentWidth(HelveticaMetrics.Measure, block, o);
                var (w, h) = FigureCards.PageSize(HelveticaMetrics.Measure, block, o, cw);
                var svg = new SvgCanvas(w, h, block.Title);
                FigureCards.Draw(svg, block, o, cw, h, Rgba.White);
                await SaveFileAsync(name, "SVG", ".svg", System.Text.Encoding.UTF8.GetBytes(svg.Document()));
                break;
            }
        }
    }

    private async Task SaveFileAsync(string suggestedName, string typeName, string extension, byte[] data)
    {
        if (_ctx is not { } ctx) return;
        var picker = new FileSavePicker
        {
            SuggestedFileName = suggestedName,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeChoices.Add(typeName, new List<string> { extension });
        // An unpackaged app has to tell the picker which window it belongs to.
        WinRT.Interop.InitializeWithWindow.Initialize(picker, ctx.WindowHandle());
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        await FileIO.WriteBytesAsync(file, data);
        ctx.Message(L("Saved ", "已保存 ") + file.Path);
    }

    // ================================================================ quality and methods

    /// <summary>RPQualityCard: detection rate, frames, duration, sampling, head direction, scale, outside the arena, keypoints.</summary>
    private Border QualityCard(ReportQuality q)
    {
        var stack = new StackPanel { Spacing = 8 };
        UIElement? levelLabel = null;
        if (QualityLevel(q) is { } level)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            row.Children.Add(Icon(StatusGlyph(level.Status), Brush(StatusColor(level.Status)), 12));
            row.Children.Add(Label(level.Text, 12, bold: true, color: Brush(StatusColor(level.Status)), wrap: false));
            levelLabel = row;
        }
        stack.Children.Add(CardHeader("\uE73E", Tr.T("识别质量"), null, levelLabel));

        void Row(string key, string value)
        {
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(Label(key, 13, color: SecondaryInk));
            var v = Label(value, 13, wrap: false);
            v.IsTextSelectionEnabled = true;
            v.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(v, 1);
            grid.Children.Add(v);
            stack.Children.Add(grid);
        }
        string Pct(double v) => Printf.Format("%.1f%%", v * 100);
        Row(Tr.T("检出率（分析时间段）"), Pct(q.DetectionRate));
        Row(Tr.T("分析帧数"), $"{q.FramesInWindow} / {q.Frames}");
        Row(Tr.T("分析时长"), Fmt.Clock(q.WindowSeconds));
        Row(Tr.T("采样率"), Printf.Format("%.1f Hz", q.SampleRate));
        Row(Tr.T("头朝向有效"), Pct(q.HeadDirectionRate));
        if (q.Unit == "cm") Row(Tr.T("比例"), Printf.Format("%.1f px/cm", q.PxPerUnit));
        if (q.OutsideArenaFraction.Length > 0)
        {
            var shares = q.OutsideArenaFraction.Select(Pct).ToList();
            string text = shares.Count > 1
                ? string.Join(" · ", shares.Select((s, i) => (i < q.AnimalLetters.Length ? q.AnimalLetters[i] : "") + " " + s))
                : shares[0];
            Row(Tr.T("超出标定范围"), text);
        }

        if (q.KeypointRates.Length > 0)
        {
            stack.Children.Add(Label(Tr.T("各关键点有效比例"), 12, bold: true, color: SecondaryInk, margin: new Thickness(0, 4, 0, 0)));
            var grid = new Grid { ColumnSpacing = 8, RowSpacing = 6 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            for (int k = 0; k < q.KeypointRates.Length; k++)
            {
                double rate = Math.Clamp(double.IsFinite(q.KeypointRates[k]) ? q.KeypointRates[k] : 0, 0, 1);
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                name.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = Brush(_theme.Keypoint(k)), VerticalAlignment = VerticalAlignment.Center });
                name.Children.Add(Label(k < q.Keypoints.Length ? q.Keypoints[k].Title : $"#{k}", 12, wrap: false));
                Grid.SetRow(name, k);
                grid.Children.Add(name);

                var track = new Grid { Height = 7, VerticalAlignment = VerticalAlignment.Center, CornerRadius = new CornerRadius(3.5), Background = Brush(_theme.Inset) };
                track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(rate, 1e-4), GridUnitType.Star) });
                track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(1 - rate, 1e-4), GridUnitType.Star) });
                track.Children.Add(new Border { CornerRadius = new CornerRadius(3.5), Background = Brush(_theme.Accent.Opacity(0.75)) });
                Grid.SetRow(track, k);
                Grid.SetColumn(track, 1);
                grid.Children.Add(track);

                var pct = Label(Printf.Format("%.0f%%", rate * 100), 12, color: SecondaryInk, wrap: false);
                pct.HorizontalAlignment = HorizontalAlignment.Right;
                Grid.SetRow(pct, k);
                Grid.SetColumn(pct, 2);
                grid.Children.Add(pct);
            }
            stack.Children.Add(grid);
        }
        return Card(stack);
    }

    /// <summary>The Methods paragraph, folded, with a copy button.</summary>
    private FrameworkElement MethodsCard(DisplayReport r)
    {
        var body = new StackPanel { Spacing = 10 };
        var text = Label(r.MethodsText, 12);
        text.IsTextSelectionEnabled = true;
        body.Children.Add(text);
        var copy = new Button
        {
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { new FontIcon { Glyph = "\uE8C8", FontSize = 14 }, new TextBlock { Text = Tr.T("复制方法说明") } },
            },
        };
        copy.Click += (_, _) =>
        {
            var data = new DataPackage();
            data.SetText(r.MethodsText);
            Clipboard.SetContent(data);
            _ctx?.Message(Tr.T("已复制方法说明"));
        };
        body.Children.Add(copy);
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        header.Children.Add(Icon("\uE8FD", SecondaryInk));
        header.Children.Add(Label(Tr.T("方法说明（可用于论文 Methods）"), 15, bold: true, wrap: false));
        return new Expander
        {
            Header = header,
            Content = body,
            IsExpanded = false,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
    }
}
