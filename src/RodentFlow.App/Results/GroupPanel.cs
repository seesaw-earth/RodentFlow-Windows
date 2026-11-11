using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RodentFlow.App.Figures;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Workspace;
using RodentFlow.Engine;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using static RodentFlow.App.AppText;

namespace RodentFlow.App.Results;

/// <summary>
/// The group comparison of a task, as on the Mac's task page (GroupsUI): design, measure, phase, session, test and
/// groups; the publication figure (the same PubGroupFigure the Mac shows and exports); the result in a paragraph and
/// line by line; descriptives per group; the statistics and long-format tables. Everything is computed by the
/// engine (rf_group_analysis); this panel only offers what the engine lists and shows what it returns.
/// </summary>
/// <remarks>
/// The chosen request and plot style are remembered with the task. The card is kept between redraws of the task
/// page and computed again only when the task's analysed sessions or the language change.
/// </remarks>
internal sealed class GroupPanel
{
    private readonly WorkspaceStore _store;
    private readonly Func<IntPtr> _window;
    private readonly Action<string> _message;
    private readonly Func<bool> _dark;

    private readonly Border _card;
    private readonly StackPanel _body = new() { Spacing = 12 };
    private FigureView? _figure;
    private WorkspaceTask? _task;
    private GroupReply? _reply;
    private string? _signature;
    private int _generation;

    public GroupPanel(WorkspaceStore store, Func<IntPtr> window, Action<string> message, Func<bool> dark)
    {
        _store = store;
        _window = window;
        _message = message;
        _dark = dark;
        _card = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(FigureCards.CardRadius),
            Padding = new Thickness(16),
            Child = _body,
        };
    }

    private FigureTheme Theme => FigureTheme.For(_dark());

    private static SolidColorBrush Brush(Rgba c) => new(Win2DCanvas.ToColor(c));

    /// <summary>The analysed sessions of the task the comparison reads (with a summary and complete session info).</summary>
    private List<WorkspaceSession> Sessions(WorkspaceTask task) => _store.OrderedSessions(task.Id)
        .Where(s => s.Summary is not null && s.RunState == RunState.Complete && s.HasSessionInfo)
        .ToList();

    /// <summary>Puts the card on the task page; computes it again when what it depends on changed.</summary>
    public void Attach(StackPanel host, WorkspaceTask task)
    {
        var sessions = Sessions(task);
        if (sessions.Count == 0) return;
        if (_card.Parent is Panel old) old.Children.Remove(_card);
        host.Children.Add(_card);
        _card.Background = Brush(Theme.Card);
        _card.BorderBrush = Brush(Theme.Hairline);
        string signature = task.Id + "|" + Chinese + "|" + string.Join(";", sessions.Select(s =>
            $"{s.Id}:{s.RunFinishedAt:O}:{s.Excluded}:{s.GroupKey}:{s.Phase}:{s.Review}:{s.Sex}:{s.SessionNumber}"));
        if (!ReferenceEquals(task, _task) || signature != _signature)
        {
            if (!ReferenceEquals(task, _task))
            {
                // Another task: the previous task's comparison goes at once, not when the new one is ready.
                _figure?.Release();
                _figure = null;
                _reply = null;
                _body.Children.Clear();
                _body.Children.Add(Text(L("Group comparison", "组间比较"), 18, bold: true));
                _body.Children.Add(new ProgressRing { IsActive = true, Width = 28, Height = 28, HorizontalAlignment = HorizontalAlignment.Left });
            }
            _task = task;
            _signature = signature;
            _ = RunAsync();
        }
    }

    private GroupAnalysisCall Call(WorkspaceTask task, bool english) => new()
    {
        Paradigm = task.Paradigm,
        TaskName = task.Name,
        Sessions = Sessions(task).Select(s => new GroupSessionInput(
            s.Id, s.AnimalId.Trim(), s.AnimalKey, s.GroupKey, s.Phase ?? "", s.Day, s.Trial, s.SessionNumber, s.SessionDate,
            s.Excluded, s.ExclusionReason, s.Sex, s.Review == ReviewVerdict.Flagged, s.Summary!)).ToArray(),
        Request = task.GroupRequest,
        Style = task.GroupStyle,
        English = english,
    };

    private async Task RunAsync()
    {
        if (_task is not { } task) return;
        int generation = ++_generation;
        _card.Opacity = 0.55;
        try
        {
            var call = Call(task, english: !Chinese);
            var reply = await Task.Run(() => Engine.Engine.GroupAnalysis(call));
            if (generation != _generation) return;
            _reply = reply;
            // Remembered with the task (the engine may have filled in or corrected the request).
            task.GroupRequest = (JsonObject)reply.Request.DeepClone();
            task.GroupStyle = (JsonObject)reply.Style.DeepClone();
            _store.MarkChanged();
            Build();
        }
        catch (Exception e)
        {
            if (generation != _generation) return;
            _body.Children.Clear();
            _body.Children.Add(Text(L("Group comparison", "组间比较"), 18, bold: true));
            _body.Children.Add(Text(e.Message, 13, color: Brush(Theme.Danger)));
        }
        finally
        {
            if (generation == _generation) _card.Opacity = 1;
        }
    }

    // ================================================================ changing the request

    private static string Str(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue(out string? s) ? s ?? "" : "";

    private static bool Bool(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue(out bool b) && b;

    private void Change(bool style, Action<JsonObject> edit)
    {
        if (_task is not { } task || _reply is null) return;
        var target = (JsonObject)(style ? _reply.Style : _reply.Request).DeepClone();
        edit(target);
        if (style) task.GroupStyle = target;
        else task.GroupRequest = target;
        _ = RunAsync();
    }

    // ================================================================ the card

    private static TextBlock Text(string text, double size = 13, bool bold = false, Brush? color = null, bool select = false)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = select };
        if (bold) t.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        if (color is not null) t.Foreground = color;
        return t;
    }

    private ComboBox Combo(string header, IEnumerable<GroupOption> options, string selected, Action<string> chosen)
    {
        var box = new ComboBox { Header = header, HorizontalAlignment = HorizontalAlignment.Stretch };
        int index = 0, i = 0;
        foreach (var o in options)
        {
            box.Items.Add(new ComboBoxItem { Content = o.Unit is { Length: > 0 } u ? $"{o.Title} ({u})" : o.Title, Tag = o.Key });
            if (o.Key == selected) index = i;
            i++;
        }
        if (box.Items.Count > 0) box.SelectedIndex = index;
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is ComboBoxItem { Tag: string key } && key != selected) chosen(key);
        };
        return box;
    }

    private static CheckBox Check(string text, bool on, Action<bool> changed)
    {
        var box = new CheckBox { Content = text, IsChecked = on, VerticalAlignment = VerticalAlignment.Bottom };
        box.Click += (_, _) => changed(box.IsChecked == true);
        return box;
    }

    private void Build()
    {
        if (_reply is not { } reply) return;
        _figure?.Release();
        _figure = null;
        _body.Children.Clear();
        var theme = Theme;
        var req = reply.Request;
        var style = reply.Style;
        var o = reply.Options;
        var r = reply.Result;
        string design = Str(req, "design");

        _body.Children.Add(Text(L("Group comparison", "组间比较"), 18, bold: true));
        _body.Children.Add(Text(string.Format(L("{0} animals in the comparison", "参与比较的小鼠：{0} 只"), r.AnimalCount), 12,
                                color: Brush(theme.Secondary)));

        // What is compared.
        var controls = new AdaptiveGridPanel { MinItemWidth = 200, Spacing = 10 };
        controls.Children.Add(Combo(L("Design", "设计"), o.Designs, design, k => Change(false, q => q["design"] = k)));
        if (design is "between_groups" or "by_session" or "by_day" or "phase_change")
            controls.Children.Add(Combo(L("Measure", "指标"), o.Metrics, Str(req, "metricKey"), k => Change(false, q => q["metricKey"] = k)));
        if (design == "within_session" && o.Series.Length > 0)
            controls.Children.Add(Combo(L("Time course of", "时间进程"), o.Series, Str(req, "seriesKey"), k => Change(false, q => q["seriesKey"] = k)));
        if (design == "paired_measures" && o.Pairs.Length > 0)
            controls.Children.Add(Combo(L("Pair", "配对"), o.Pairs, Str(req, "pairKey"), k => Change(false, q => q["pairKey"] = k)));
        if (design == "phase_change" && o.Phases.Length > 1)
        {
            controls.Children.Add(Combo(L("From phase", "起始阶段"), o.Phases, Str(req, "phaseA"), k => Change(false, q => q["phaseA"] = k)));
            controls.Children.Add(Combo(L("To phase", "目标阶段"), o.Phases, Str(req, "phaseB"), k => Change(false, q => q["phaseB"] = k)));
        }
        else if (o.Phases.Length > 0)
        {
            var phases = new List<GroupOption> { new() { Key = "", Title = L("All phases", "全部阶段") } };
            phases.AddRange(o.Phases);
            controls.Children.Add(Combo(L("Phase", "阶段"), phases, Str(req, "phaseFilter"), k => Change(false, q =>
            {
                if (k.Length == 0) q.Remove("phaseFilter");
                else q["phaseFilter"] = k;
            })));
        }
        if (design == "between_groups" && o.Sessions.Length > 1)
        {
            var sessions = new List<GroupOption> { new() { Key = "", Title = L("All sessions (mean per animal)", "全部实验（每只小鼠取均值）") } };
            sessions.AddRange(o.Sessions.Select(n => new GroupOption { Key = n.ToString(CultureInfo.InvariantCulture), Title = "#" + n }));
            string current = req["sessionFilter"] is JsonValue sv && sv.TryGetValue(out int sf) ? sf.ToString(CultureInfo.InvariantCulture) : "";
            controls.Children.Add(Combo(L("Session", "实验次数"), sessions, current, k => Change(false, q =>
            {
                if (k.Length == 0) q.Remove("sessionFilter");
                else q["sessionFilter"] = int.Parse(k, CultureInfo.InvariantCulture);
            })));
        }
        controls.Children.Add(Combo(L("Test", "检验"), o.Modes, Str(req, "mode"), k => Change(false, q => q["mode"] = k)));
        controls.Children.Add(Combo(L("Comparisons", "比较方式"), o.Comparisons, Str(req, "comparison"), k => Change(false, q => q["comparison"] = k)));
        if (design == "between_groups" && o.Factors.Length > 1)
            controls.Children.Add(Combo(L("Second factor", "第二因素"), o.Factors, Str(req, "factorB"), k => Change(false, q => q["factorB"] = k)));
        if (design == "between_groups" && o.Metrics.Length > 1)
        {
            // ANCOVA: another measure of the same animal as the covariate ("" = none).
            var covariates = new List<GroupOption> { new() { Key = "", Title = L("No covariate", "无协变量") } };
            covariates.AddRange(o.Metrics.Where(m => m.Key != Str(req, "metricKey")));
            controls.Children.Add(Combo(L("Covariate (ANCOVA)", "协变量（ANCOVA）"), covariates, Str(req, "covariateKey"),
                                        k => Change(false, q => q["covariateKey"] = k)));
        }
        controls.Children.Add(Check(L("Test against the reference value", "与参考值比较"), Bool(req, "testAgainstChance"),
                                    on => Change(false, q => q["testAgainstChance"] = on)));
        controls.Children.Add(Check(L("Include excluded sessions", "包含已排除的实验"), Bool(req, "includeExcluded"),
                                    on => Change(false, q => q["includeExcluded"] = on)));
        _body.Children.Add(controls);

        // Which groups, in which order (the first is the control).
        if (o.Groups.Length > 1)
        {
            var included = req["groups"] is JsonArray a
                ? a.Select(n => n?.GetValue<string>() ?? "").ToList()
                : o.Groups.Select(g => g.Key).ToList();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            row.Children.Add(Text(L("Groups:", "分组："), 13, bold: true));
            foreach (var g in o.Groups)
            {
                string key = g.Key;
                row.Children.Add(Check(g.Title, included.Contains(key), on => Change(false, q =>
                {
                    var now = included.Where(x => x != key).ToList();
                    if (on) now.Add(key);
                    // Keep the options' order, so the first group stays the control.
                    var ordered = o.Groups.Select(x => x.Key).Where(now.Contains).ToList();
                    q["groups"] = new JsonArray(ordered.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
                })));
            }
            _body.Children.Add(new ScrollViewer
            {
                Content = row,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalScrollMode = ScrollMode.Enabled,
                VerticalScrollMode = ScrollMode.Disabled,
            });
        }

        // How it is drawn.
        var looks = new AdaptiveGridPanel { MinItemWidth = 170, Spacing = 10 };
        looks.Children.Add(Combo(L("Plot", "图形"), o.Plots, Str(style, "kind"), k => Change(true, q => q["kind"] = k)));
        looks.Children.Add(Combo(L("Error bars", "误差线"), o.Errors, Str(style, "error"), k => Change(true, q => q["error"] = k)));
        looks.Children.Add(Combo(L("Significance as", "显著性标注"), o.Significance, Str(style, "significance"),
                                 k => Change(true, q => q["significance"] = k)));
        looks.Children.Add(Check(L("Every animal", "每只小鼠"), Bool(style, "showPoints"), on => Change(true, q => q["showPoints"] = on)));
        looks.Children.Add(Check(L("Significance brackets", "显著性括号"), Bool(style, "showSignificance"),
                                 on => Change(true, q => q["showSignificance"] = on)));
        looks.Children.Add(Check(L("Grayscale", "灰度"), Bool(style, "grayscale"), on => Change(true, q => q["grayscale"] = on)));
        // A fixed Y range (the same axis for figures that go side by side); off = automatic.
        double? yMin = style["yMin"] is JsonValue lo && lo.TryGetValue(out double l) ? l : null;
        double? yMax = style["yMax"] is JsonValue hi && hi.TryGetValue(out double h) ? h : null;
        bool fixedRange = yMin is not null && yMax is not null;
        looks.Children.Add(Check(L("Fixed Y range", "固定 Y 轴范围"), fixedRange, on => Change(true, q =>
        {
            if (on)
            {
                // Seeded from the data shown: 0 (or the lowest value) to a little above the highest.
                double top = r.Descriptives.Length > 0 ? r.Descriptives.Max(d => double.IsFinite(d.Max) ? d.Max : 0) : 1;
                double bottom = r.Descriptives.Length > 0 ? Math.Min(0, r.Descriptives.Min(d => double.IsFinite(d.Min) ? d.Min : 0)) : 0;
                q["yMin"] = bottom;
                q["yMax"] = top > bottom ? top * 1.1 : bottom + 1;
            }
            else
            {
                q.Remove("yMin");
                q.Remove("yMax");
            }
        })));
        if (fixedRange)
        {
            NumberBox Bound(string header, double value, string key) 
            {
                var box = new NumberBox { Header = header, Value = value, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
                box.ValueChanged += (_, e) =>
                {
                    if (double.IsFinite(e.NewValue) && e.NewValue != value) Change(true, q => q[key] = e.NewValue);
                };
                return box;
            }
            looks.Children.Add(Bound(L("Y from", "Y 起点"), yMin!.Value, "yMin"));
            looks.Children.Add(Bound(L("Y to", "Y 终点"), yMax!.Value, "yMax"));
        }
        _body.Children.Add(looks);

        // The figure, as large as the card allows (at most 2.5 × its print size).
        if (!r.IsEmpty && reply.Figure.Width > 0)
        {
            var figure = reply.Figure;
            _figure = new FigureView((c, w) =>
            {
                double scale = Math.Clamp(w / Math.Max(1, figure.Width), 0.5, 2.5);
                double x = Math.Max(0, (w - figure.Width * scale) / 2);
                PubFigurePainter.Paint(c, figure, scale, x, 0);
                return figure.Height * scale;
            }, fontFamily: "Arial");
            _body.Children.Add(_figure);
        }

        var notes = r.Notes.ToList();
        if (r.MainNote.Length > 0) notes.Add(r.MainNote);
        foreach (string note in notes)
            _body.Children.Add(Text("⚠ " + note, 12, color: Brush(theme.Warning), select: true));
        if (r.Summary.Length > 0) _body.Children.Add(Text(r.Summary, 13, select: true));
        if (r.Details.Length > 0)
        {
            var details = Text(string.Join("\n", r.Details), 12, select: true);
            details.FontFamily = new FontFamily("Consolas");
            _body.Children.Add(new Expander
            {
                Header = L("The tests in detail", "检验详情"),
                Content = details,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            });
        }
        if (r.Descriptives.Length > 0) _body.Children.Add(DescriptivesTable(r));

        // Copy and save (files in English, as on the Mac).
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var copy = new Button { Content = L("Copy the result", "复制结果") };
        copy.Click += (_, _) =>
        {
            var data = new DataPackage();
            data.SetText(r.Summary + (r.Details.Length > 0 ? "\n\n" + string.Join("\n", r.Details) : ""));
            Clipboard.SetContent(data);
            _message(L("Copied the result.", "已复制结果。"));
        };
        actions.Children.Add(copy);
        var save = new DropDownButton { Content = L("Save…", "保存…") };
        var menu = new MenuFlyout();
        void Item(string text, Func<Task> act)
        {
            var it = new MenuFlyoutItem { Text = text };
            it.Click += async (_, _) =>
            {
                try { await act(); }
                catch (Exception e) { _message(e.Message); }
            };
            menu.Items.Add(it);
        }
        Item(L("Figure as vector PDF…", "图：矢量 PDF…"), () => SaveFigureAsync("pdf", 0));
        Item(L("Figure as SVG…", "图：SVG…"), () => SaveFigureAsync("svg", 0));
        Item(L("Figure as PNG, 300 dpi…", "图：PNG（300 dpi）…"), () => SaveFigureAsync("png", 300));
        Item(L("Figure as PNG, 600 dpi…", "图：PNG（600 dpi）…"), () => SaveFigureAsync("png", 600));
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(L("Statistics table (CSV)…", "统计表（CSV）…"), () => SaveTableAsync(longFormat: false));
        Item(L("Data, one row per animal (CSV, for Prism / R)…", "数据：每只小鼠一行（CSV，用于 Prism / R）…"), () => SaveTableAsync(longFormat: true));
        save.Flyout = menu;
        actions.Children.Add(save);
        _body.Children.Add(actions);
    }

    private UIElement DescriptivesTable(GroupResultInfo r)
    {
        var grid = new Grid { ColumnSpacing = 14, RowSpacing = 4 };
        string[] heads = [L("Group", "组"), "n", L("Mean", "均值"), "SD", "SEM", L("Median", "中位数"), "Q1", "Q3", L("Min", "最小"), L("Max", "最大")];
        for (int c = 0; c < heads.Length; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (int c = 0; c < heads.Length; c++)
        {
            var h = Text(heads[c], 12, bold: true, color: Brush(Theme.Secondary));
            Grid.SetColumn(h, c);
            grid.Children.Add(h);
        }
        static string F(double v) => double.IsFinite(v) ? v.ToString("0.###", CultureInfo.InvariantCulture) : "—";
        for (int i = 0; i < r.Descriptives.Length; i++)
        {
            var d = r.Descriptives[i];
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            string[] cells = [d.Group, d.N.ToString(CultureInfo.InvariantCulture), F(d.Mean), F(d.Sd), F(d.Sem), F(d.Median), F(d.Q1), F(d.Q3), F(d.Min), F(d.Max)];
            for (int c = 0; c < cells.Length; c++)
            {
                var t = Text(cells[c], 12, select: true);
                Grid.SetRow(t, i + 1);
                Grid.SetColumn(t, c);
                grid.Children.Add(t);
            }
        }
        return new ScrollViewer
        {
            Content = grid,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollMode = ScrollMode.Disabled,
        };
    }

    // ================================================================ files

    /// <summary>The same comparison in English, for files.</summary>
    private async Task<GroupReply?> EnglishAsync()
    {
        if (_task is not { } task) return null;
        if (!Chinese && _reply is not null) return _reply;
        var call = Call(task, english: true);
        return await Task.Run(() => Engine.Engine.GroupAnalysis(call));
    }

    private string FileStem(GroupReply reply) =>
        "rodentflow_" + FigureCards.Slug((_task?.Name ?? "task") + " " + reply.Result.MetricName);

    private async Task SaveFigureAsync(string kind, int dpi)
    {
        if (await EnglishAsync() is not { } reply || reply.Result.IsEmpty) return;
        var figure = reply.Figure;
        string stem = FileStem(reply);
        switch (kind)
        {
            case "svg":
                await SaveAsync(stem, "SVG", ".svg", Encoding.UTF8.GetBytes(reply.Svg));
                break;
            case "pdf":
            {
                var pdf = new PdfCanvas(figure.Width, figure.Height, reply.Result.MetricName);
                PubFigurePainter.Paint(pdf, figure);
                await SaveAsync(stem, "PDF", ".pdf", pdf.Document());
                break;
            }
            default:
            {
                byte[] png = await FigureRaster.PngAsync(figure.Width, figure.Height, dpi / 72.0,
                                                         c => PubFigurePainter.Paint(c, figure), dpi, fontFamily: "Arial");
                await SaveAsync(stem + "_" + dpi.ToString(CultureInfo.InvariantCulture) + "dpi", "PNG", ".png", png);
                break;
            }
        }
    }

    private async Task SaveTableAsync(bool longFormat)
    {
        if (await EnglishAsync() is not { } reply) return;
        string text = longFormat ? reply.Result.LongCsv : reply.Result.StatsCsv;
        // With a byte-order mark, so Excel opens the UTF-8 file with the right characters.
        byte[] bytes = Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(text)).ToArray();
        await SaveAsync(FileStem(reply) + (longFormat ? "_data" : "_statistics"), "CSV", ".csv", bytes);
    }

    private async Task SaveAsync(string suggestedName, string typeName, string extension, byte[] data)
    {
        var picker = new FileSavePicker
        {
            SuggestedFileName = suggestedName,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeChoices.Add(typeName, new List<string> { extension });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, _window());
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        await FileIO.WriteBytesAsync(file, data);
        _message(L("Saved ", "已保存 ") + file.Path);
    }
}
