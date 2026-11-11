using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RodentFlow.App.Figures;
using RodentFlow.Core;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Workspace;
using RodentFlow.Engine;
using Windows.Storage.Pickers;
using static RodentFlow.App.AppText;

namespace RodentFlow.App;

/// <summary>
/// The workspace half of the window, as the Mac's AnalysisWorkflowView: the sidebar (tasks → groups, and the
/// cross-task lists), the list of a task's animals and sessions, the task's overview page, adding videos, the
/// analysis queue, and the Session info step of a session.
/// </summary>
public sealed partial class MainWindow
{
    private readonly WorkspaceStore _store;

    /// <summary>Probed videos and their calibration frames, so revisiting a session does not run ffprobe again.</summary>
    private readonly Dictionary<string, (VideoInfo Info, VideoFrameGrabber.Frame Frame)> _videoCache = new();

    private DispatcherQueueTimer? _saveTimer;
    private bool _listsDirty;

    /// <summary>What the sidebar points at: a task (and maybe one of its groups), or a list.</summary>
    private Guid? _selectedTask;
    private string? _selectedGroup;
    private SmartList? _selectedList;

    private string? _sidebarSignature;
    private string? _listSignature;
    private int _openGeneration;

    private bool _batchStop;
    private string? _batchText;

    /// <summary>The group comparison on the task page (kept between redraws of the page).</summary>
    private Results.GroupPanel? _groupPanel;

    // ================================================================ start-up and saving

    private void StartWorkspace()
    {
        _store.Changed += () => _listsDirty = true;
        // Changes are many and small (a dragged handle); they are written and redrawn at most once a second.
        _saveTimer = DispatcherQueue.CreateTimer();
        _saveTimer.Interval = TimeSpan.FromSeconds(1);
        _saveTimer.Tick += (_, _) => FlushWorkspace();
        _saveTimer.Start();
        Closed += (_, _) => _store.Save();

        BuildSidebar();
        if (_store.Document.Tasks.FirstOrDefault() is { } first) SelectInSidebar("task:" + first.Id);
        else ShowTaskPage();
        if (_store.Notice is { } notice) StatusLabel.Text = notice;
    }

    private void FlushWorkspace()
    {
        if (_listsDirty)
        {
            _listsDirty = false;
            BuildSidebar();
            RebuildSessionList();
            if (TaskPage.Visibility == Visibility.Visible) ShowTaskPage();
        }
        if (_store.Dirty && !_store.Save())
            StatusLabel.Text = L("The workspace could not be written to ", "工作区无法写入 ") + _store.FilePath;
    }

    // ================================================================ sidebar

    private static string StageTitle(SessionStage stage) => stage switch
    {
        SessionStage.NeedsSetup => L("Needs calibration", "需要标定"),
        SessionStage.Ready => L("Ready to analyse", "可以分析"),
        SessionStage.Running => L("Analysing…", "正在分析…"),
        SessionStage.Paused => L("Paused — can resume", "已暂停，可继续"),
        SessionStage.Failed => L("Analysis failed", "分析失败"),
        _ => L("Analysed", "已分析"),
    };

    private static string StageGlyph(SessionStage stage) => stage switch
    {
        SessionStage.NeedsSetup => "\uE7A8",  // Crop
        SessionStage.Ready => "\uE768",       // Play
        SessionStage.Running => "\uE895",     // Sync
        SessionStage.Paused => "\uE769",      // Pause
        SessionStage.Failed => "\uE7BA",      // Warning
        _ => "\uE930",                        // Completed
    };

    private Rgba StageColor(SessionStage stage)
    {
        var theme = FigureTheme.For(Root.ActualTheme == ElementTheme.Dark);
        return stage switch
        {
            SessionStage.NeedsSetup => theme.Secondary,
            SessionStage.Ready or SessionStage.Running => theme.Accent,
            SessionStage.Paused => theme.Warning,
            SessionStage.Failed => theme.Danger,
            _ => theme.Success,
        };
    }

    private static string ListTitleOf(SmartList list) => list switch
    {
        SmartList.ToAnalyse => L("To analyse", "待分析"),
        SmartList.ToReview => L("To review", "待复核"),
        SmartList.MissingInfo => L("Missing info", "缺信息"),
        SmartList.Excluded => L("Excluded", "已排除"),
        _ => L("All sessions", "全部实验"),
    };

    private static string ListExplanation(SmartList list) => list switch
    {
        SmartList.ToAnalyse => L("Sessions of every task that have not been analysed yet.", "所有任务中尚未分析的实验。"),
        SmartList.ToReview => L("Analysed sessions whose tracking has not been checked yet.", "已分析、但追踪尚未复核的实验。"),
        SmartList.MissingInfo => L("Sessions without animal ID, date or session number. They are left out of summaries until completed.",
                                   "缺少小鼠编号、日期或实验次数的实验，补全前不进入汇总。"),
        SmartList.Excluded => L("Sessions left out of group summaries, with the reason.", "已排除出组间汇总的实验（附原因）。"),
        _ => "",
    };

    private static string ListGlyph(SmartList list) => list switch
    {
        SmartList.ToAnalyse => "\uE768",
        SmartList.ToReview => "\uE73E",
        SmartList.MissingInfo => "\uE783",
        SmartList.Excluded => "\uE738",
        _ => "\uE8FD",
    };

    private string TaskGlyph(WorkspaceTask t) =>
        _model.Tasks.FirstOrDefault(p => p.Id == t.Paradigm)?.Category switch
        {
            "social" => "\uE716",      // People
            "navigation" => "\uE707",  // MapPin
            "anxiety" => "\uE7BA",     // Warning
            "memory" => "\uE82D",      // Library
            "motor" => "\uE805",       // Walk
            _ => "\uE80A",             // grid
        };

    /// <summary>The sidebar's items, rebuilt only when tasks, groups or counts change; the selection is kept.</summary>
    private void BuildSidebar()
    {
        var lists = new[] { SmartList.ToAnalyse, SmartList.ToReview, SmartList.MissingInfo, SmartList.Excluded, SmartList.All };
        string signature = string.Join("|", _store.Document.Tasks.Select(t =>
                               t.Id + ":" + t.Name + ":" + string.Join(",", _store.GroupsOf(t.Id)) + ":" + _store.SessionsOf(t.Id).Count()))
                           + "#" + string.Join(",", lists.Select(l => _store.ListSessions(l).Count()));
        if (signature == _sidebarSignature) return;
        _sidebarSignature = signature;

        string? selected = (Sidebar.SelectedItem as NavigationViewItem)?.Tag as string;
        _quiet++;
        try
        {
            Sidebar.MenuItems.Clear();
            Sidebar.MenuItems.Add(new NavigationViewItemHeader { Content = L("Tasks", "任务") });
            foreach (var t in _store.Document.Tasks)
            {
                var item = new NavigationViewItem
                {
                    Content = t.Name,
                    Tag = "task:" + t.Id,
                    Icon = new FontIcon { Glyph = TaskGlyph(t) },
                };
                int count = _store.SessionsOf(t.Id).Count();
                if (count > 0) item.InfoBadge = new InfoBadge { Value = count };
                var groups = _store.GroupsOf(t.Id);
                if (groups.Any(g => g.Length > 0))
                {
                    foreach (string g in groups)
                    {
                        item.MenuItems.Add(new NavigationViewItem
                        {
                            Content = g.Length > 0 ? g : L("No group", "未分组"),
                            Tag = "group:" + t.Id + ":" + g,
                            Icon = new FontIcon { Glyph = "\uE902" },
                        });
                    }
                }
                Sidebar.MenuItems.Add(item);
            }
            Sidebar.MenuItems.Add(new NavigationViewItemSeparator());
            Sidebar.MenuItems.Add(new NavigationViewItemHeader { Content = L("Lists", "列表") });
            foreach (var list in lists)
            {
                var item = new NavigationViewItem
                {
                    Content = ListTitleOf(list),
                    Tag = "list:" + list,
                    Icon = new FontIcon { Glyph = ListGlyph(list) },
                };
                int count = _store.ListSessions(list).Count();
                if (count > 0 && list != SmartList.All) item.InfoBadge = new InfoBadge { Value = count };
                Sidebar.MenuItems.Add(item);
            }
            if (selected is not null && FindSidebarItem(selected) is { } again) Sidebar.SelectedItem = again;
        }
        finally
        {
            _quiet--;
        }
    }

    private NavigationViewItem? FindSidebarItem(string tag)
    {
        foreach (var top in Sidebar.MenuItems.OfType<NavigationViewItem>())
        {
            if (top.Tag as string == tag) return top;
            foreach (var child in top.MenuItems.OfType<NavigationViewItem>())
            {
                if (child.Tag as string == tag)
                {
                    top.IsExpanded = true;
                    return child;
                }
            }
        }
        return null;
    }

    /// <summary>Selects a sidebar item by its tag and shows what it points at.</summary>
    private void SelectInSidebar(string tag)
    {
        BuildSidebar();
        if (FindSidebarItem(tag) is { } item)
        {
            _quiet++;
            try { Sidebar.SelectedItem = item; }
            finally { _quiet--; }
        }
        ApplySidebarTag(tag);
    }

    private void SidebarSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_quiet > 0) return;
        if (args.SelectedItem is NavigationViewItem { Tag: string tag }) ApplySidebarTag(tag);
    }

    private void ApplySidebarTag(string tag)
    {
        // A session still being opened (its video read) is not shown any more: the page follows the sidebar at once.
        _openGeneration++;
        _selectedTask = null;
        _selectedGroup = null;
        _selectedList = null;
        string[] parts = tag.Split(':', 3);
        if (parts[0] == "task" && parts.Length > 1 && Guid.TryParse(parts[1], out var task)) _selectedTask = task;
        else if (parts[0] == "group" && parts.Length > 2 && Guid.TryParse(parts[1], out var owner))
        {
            _selectedTask = owner;
            _selectedGroup = parts[2];
        }
        else if (parts[0] == "list" && parts.Length > 1 && Enum.TryParse<SmartList>(parts[1], out var list)) _selectedList = list;
        _listSignature = null;
        RebuildSessionList();
        ShowTaskPage();
    }

    // ================================================================ the session list

    /// <summary>The sessions the sidebar's selection stands for, in tree order (task, group, animal, session).</summary>
    private List<WorkspaceSession> ListedSessions()
    {
        if (_selectedTask is { } task) return _store.OrderedSessions(task, _selectedGroup);
        if (_selectedList is { } list)
        {
            var wanted = _store.ListSessions(list).Select(s => s.Id).ToHashSet();
            return _store.Document.Tasks.SelectMany(t => _store.OrderedSessions(t.Id)).Where(s => wanted.Contains(s.Id)).ToList();
        }
        return [];
    }

    private static string SessionTitle(WorkspaceSession s)
    {
        string date = SessionDates.IsValid(s.SessionDate) ? s.SessionDate! : L("No date", "无日期");
        string number = (s.SessionNumber ?? 0) >= 1 ? "#" + s.SessionNumber : L("#?", "第?次");
        return date + " · " + number;
    }

    private void RebuildSessionList()
    {
        var sessions = ListedSessions();
        string signature = $"{_selectedTask}|{_selectedGroup}|{_selectedList}|" + string.Join("|", sessions.Select(s =>
            $"{s.Id}:{s.Stage}:{s.AnimalKey}:{s.GroupKey}:{s.SessionDate}:{s.SessionNumber}:{s.PrimaryLine}:{s.Excluded}:{s.Phase}"));
        if (signature == _listSignature) return;
        _listSignature = signature;

        var task = _selectedTask is { } id ? _store.FindTask(id) : null;
        ListTitle.Text = task?.Name ?? (_selectedList is { } l ? ListTitleOf(l) : L("No task yet", "还没有任务"));
        if (_selectedGroup is { } g) ListTitle.Text += " · " + (g.Length > 0 ? g : L("No group", "未分组"));
        int animals = sessions.Select(s => s.TaskId + "/" + s.AnimalKey).Distinct().Count();
        ListSubtitle.Text = string.Format(L("{0} animals · {1} sessions", "{0} 只小鼠 · {1} 次实验"), animals, sessions.Count);
        AddVideosButton.Visibility = task is not null ? Visibility.Visible : Visibility.Collapsed;
        int ready = BatchQueue().Count;
        AnalyseAllButton.Content = ready > 0
            ? string.Format(L("Analyse all ready ({0})", "分析全部可分析的（{0}）"), ready)
            : L("Analyse all ready", "分析全部可分析的");
        AnalyseAllButton.IsEnabled = ready > 0 && !_model.Busy;

        _quiet++;
        try
        {
            SessionList.Items.Clear();
            bool grouped = task is not null && _selectedGroup is null && _store.GroupsOf(task.Id).Any(x => x.Length > 0);
            string? lastGroup = null, lastAnimal = null;
            Guid? lastTask = null;
            foreach (var s in sessions)
            {
                if (_selectedList is not null && s.TaskId != lastTask)
                {
                    SessionList.Items.Add(Header(_store.FindTask(s.TaskId)?.Name ?? "", big: true));
                    lastTask = s.TaskId;
                    lastAnimal = null;
                }
                if (grouped && s.GroupKey != lastGroup)
                {
                    SessionList.Items.Add(Header(s.GroupKey.Length > 0 ? s.GroupKey : L("No group", "未分组"), big: true));
                    lastGroup = s.GroupKey;
                    lastAnimal = null;
                }
                if (s.AnimalKey != lastAnimal)
                {
                    string animal = s.AnimalId.Trim().Length > 0 ? s.AnimalKey : L("No animal ID", "无小鼠编号");
                    SessionList.Items.Add(Header(animal, big: false));
                    lastAnimal = s.AnimalKey;
                }
                SessionList.Items.Add(SessionRow(s));
            }
            if (_model.Current is { } current)
            {
                foreach (var item in SessionList.Items.OfType<ListViewItem>())
                {
                    if (item.Tag is Guid tagId && tagId == current.Id)
                    {
                        SessionList.SelectedItem = item;
                        break;
                    }
                }
            }
        }
        finally
        {
            _quiet--;
        }
    }

    private static ListViewItem Header(string text, bool big) => new()
    {
        Content = new TextBlock
        {
            Text = text,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = big ? 14 : 13,
            Opacity = big ? 1 : 0.75,
            TextTrimming = TextTrimming.CharacterEllipsis,
        },
        IsHitTestVisible = false,
        IsTabStop = false,
        MinHeight = 28,
        Padding = new Thickness(big ? 8 : 12, big ? 8 : 4, 8, 0),
    };

    private ListViewItem SessionRow(WorkspaceSession s)
    {
        var stage = s.Stage;
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(14, 4, 4, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon
        {
            Glyph = StageGlyph(stage),
            FontSize = 14,
            Foreground = new SolidColorBrush(Win2DCanvas.ToColor(StageColor(stage))),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = SessionTitle(s), TextTrimming = TextTrimming.CharacterEllipsis });
        string detail = s.PrimaryLine.Length > 0 ? s.PrimaryLine : StageTitle(stage);
        if (s.Phase is { Length: > 0 } phase) detail = phase + " · " + detail;
        if (s.Excluded) detail = L("Excluded", "已排除") + " · " + detail;
        text.Children.Add(new TextBlock { Text = detail, FontSize = 12, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (s.Excluded) grid.Opacity = 0.6;
        var item = new ListViewItem { Content = grid, Tag = s.Id };
        ToolTipService.SetToolTip(item, s.FileName + " — " + StageTitle(stage) + (s.RunMessage is { Length: > 0 } m ? "\n" + m : ""));
        return item;
    }

    private async void SessionSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || SessionList.SelectedItem is not ListViewItem { Tag: Guid id }) return;
        await OpenSessionAsync(id);
    }

    // ================================================================ opening a session

    /// <summary>Nothing may switch the open session while it is being analysed.</summary>
    private bool CanLeaveSession()
    {
        if (!_model.Busy) return true;
        StatusLabel.Text = L("An analysis is running. Stop it, or wait until it finishes.", "正在分析。请先停止，或等它完成。");
        return false;
    }

    private void ShowSessionPage()
    {
        TaskPage.Visibility = Visibility.Collapsed;
        SessionPage.Visibility = Visibility.Visible;
    }

    private async Task OpenSessionAsync(Guid id)
    {
        if (_store.FindSession(id) is not { } s) return;
        if (!ReferenceEquals(_model.Current, s) && !CanLeaveSession())
        {
            _listSignature = null;
            RebuildSessionList();
            return;
        }
        int generation = ++_openGeneration;
        _store.Save();
        if (!ReferenceEquals(_model.Current, s))
        {
            // Nothing of the previous session stays on the page while this one's video is read.
            FrameImage.Source = null;
            _results.Clear();
            _shownReport = null;
            InfoTitle.Text = (_store.FindTask(s.TaskId)?.Name ?? "") + " · " + (s.AnimalId.Trim().Length > 0 ? s.AnimalKey : "");
        }
        VideoInfo? info = null;
        VideoFrameGrabber.Frame? frame = null;
        if (_videoCache.TryGetValue(s.VideoPath, out var cached))
        {
            (info, frame) = cached;
        }
        else if (File.Exists(s.VideoPath))
        {
            ShowSessionPage();
            StatusLabel.Text = L("Opening the video…", "正在打开视频…");
            try
            {
                var tools = _settings.Tools;
                string path = s.VideoPath;
                var loaded = await Task.Run(() => MainViewModel.LoadVideo(path, tools));
                if (_videoCache.Count > 24) _videoCache.Clear();
                _videoCache[path] = loaded;
                (info, frame) = loaded;
            }
            catch (Exception e)
            {
                StatusLabel.Text = e.Message;
            }
        }
        // Another session was chosen while this video was read, or an analysis has started meanwhile.
        if (generation != _openGeneration || (_model.Busy && !ReferenceEquals(_model.Current, s))) return;
        try
        {
            _model.OpenSession(s, info, frame);
        }
        catch (Exception e)
        {
            StatusLabel.Text = e.Message;
            return;
        }
        ShowSessionPage();
        _listSignature = null;
        RebuildSessionList();
        var step = s.Stage == SessionStage.Analysed ? Step.Results : !s.HasSessionInfo ? Step.Info : Step.Calibrate;
        ShowStep(step);
        if (s.Stage == SessionStage.Analysed) await UpdateResultsAsync();
    }

    // ================================================================ the task page

    private void ShowTaskPage()
    {
        SessionPage.Visibility = Visibility.Collapsed;
        TaskPage.Visibility = Visibility.Visible;
        TaskHost.Children.Clear();
        var theme = FigureTheme.For(Root.ActualTheme == ElementTheme.Dark);

        TextBlock Text(string text, double size = 14, bool bold = false, double opacity = 1) => new()
        {
            Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Opacity = opacity,
            FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        };

        if (_model.Busy && _model.Current is { } running)
        {
            var show = new Button { Content = L("Show the analysis", "查看正在进行的分析") };
            show.Click += (_, _) => { ShowSessionPage(); ShowStep(Step.Calibrate); };
            var bar = new InfoBar
            {
                IsOpen = true,
                IsClosable = false,
                Severity = InfoBarSeverity.Informational,
                Title = L("Analysing", "正在分析"),
                Message = (_store.FindTask(running.TaskId)?.Name ?? "") + " · " + running.AnimalKey + " · " + SessionTitle(running)
                          + (_batchText is { } b ? " · " + b : ""),
                ActionButton = show,
            };
            TaskHost.Children.Add(bar);
        }

        if (_store.Document.Tasks.Count == 0)
        {
            TaskHost.Children.Add(Text(L("Start with a task", "从一个任务开始"), 28, bold: true));
            TaskHost.Children.Add(Text(L("A task is one behavioural test, e.g. an open field with one cohort. Add its videos — each video is one session of one animal — place the arena once, and analyse them all.",
                                          "任务是一项行为学实验，例如一批小鼠的旷场。添加它的视频（每段视频是一只小鼠的一次实验），标定一次场地，然后全部分析。"),
                                        opacity: 0.8));
            var create = new Button { Content = L("New task…", "新建任务…"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            create.Click += NewTask;
            TaskHost.Children.Add(create);
            return;
        }

        var sessions = ListedSessions();
        if (_selectedTask is { } taskId && _store.FindTask(taskId) is { } task)
        {
            var paradigm = _model.Tasks.FirstOrDefault(p => p.Id == task.Paradigm);
            TaskHost.Children.Add(Text(task.Name + (_selectedGroup is { } g ? " · " + (g.Length > 0 ? g : L("No group", "未分组")) : ""), 28, bold: true));
            if (paradigm is not null)
                TaskHost.Children.Add(Text((Chinese ? paradigm.Title : paradigm.EnglishName) + " · " + paradigm.CategoryTitle
                                           + (paradigm.Tagline.Length > 0 ? " — " + paradigm.Tagline : ""), 13, opacity: 0.7));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var add = new Button { Content = L("Add videos…", "添加视频…"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            add.Click += AddVideos;
            actions.Children.Add(add);
            int ready = BatchQueue().Count;
            var all = new Button
            {
                Content = string.Format(L("Analyse all ready ({0})", "分析全部可分析的（{0}）"), ready),
                IsEnabled = ready > 0 && !_model.Busy,
            };
            all.Click += AnalyseAll;
            actions.Children.Add(all);
            var rename = new Button { Content = L("Rename…", "重命名…") };
            rename.Click += async (_, _) => await RenameTaskAsync(task);
            actions.Children.Add(rename);
            var remove = new Button { Content = L("Remove task…", "移除任务…") };
            remove.Click += async (_, _) => await RemoveTaskAsync(task);
            actions.Children.Add(remove);
            TaskHost.Children.Add(actions);
        }
        else if (_selectedList is { } list)
        {
            TaskHost.Children.Add(Text(ListTitleOf(list), 28, bold: true));
            if (ListExplanation(list) is { Length: > 0 } why) TaskHost.Children.Add(Text(why, 13, opacity: 0.7));
        }

        // Where every session stands.
        var counts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var group in sessions.GroupBy(s => s.Stage).OrderBy(gr => gr.Key))
        {
            var color = StageColor(group.Key);
            counts.Children.Add(new Border
            {
                Background = new SolidColorBrush(Win2DCanvas.ToColor(color.Opacity(0.12))),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(10, 4, 10, 4),
                Child = new TextBlock
                {
                    Text = StageTitle(group.Key) + "  " + group.Count(),
                    FontSize = 12,
                    Foreground = new SolidColorBrush(Win2DCanvas.ToColor(color)),
                },
            });
        }
        if (counts.Children.Count > 0) TaskHost.Children.Add(counts);

        if (sessions.Count == 0)
        {
            TaskHost.Children.Add(Text(_selectedTask is not null
                ? L("No videos yet. Add videos: each video is one session of one animal.", "还没有视频。添加视频：每段视频是一只小鼠的一次实验。")
                : L("Nothing here.", "这里没有实验。"), 14, opacity: 0.7));
            return;
        }

        // Every session: group, animal, date and number, stage, headline measure. A row opens the session.
        var table = new Grid { ColumnSpacing = 14, RowSpacing = 2 };
        bool showTask = _selectedList is not null;
        var columns = new List<string>();
        if (showTask) columns.Add(L("Task", "任务"));
        columns.AddRange([L("Group", "分组"), L("Animal", "小鼠"), L("Session", "实验"), L("Stage", "状态"), L("Headline measure", "主要指标")]);
        for (int c = 0; c < columns.Count; c++) table.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        table.ColumnDefinitions[^1].Width = new GridLength(1, GridUnitType.Star);
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (int c = 0; c < columns.Count; c++)
        {
            var head = Text(columns[c], 12, bold: true, opacity: 0.7);
            Grid.SetColumn(head, c);
            table.Children.Add(head);
        }
        int row = 1;
        foreach (var s in sessions)
        {
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var cells = new List<string>();
            if (showTask) cells.Add(_store.FindTask(s.TaskId)?.Name ?? "");
            cells.AddRange([s.GroupKey, s.AnimalId.Trim().Length > 0 ? s.AnimalKey : "—", SessionTitle(s), StageTitle(s.Stage),
                            s.PrimaryDisplay is { Length: > 0 } d ? d + (s.PrimaryUnit is { Length: > 0 } u ? " " + u : "") : ""]);
            for (int c = 0; c < cells.Count; c++)
            {
                FrameworkElement cell;
                if (c == (showTask ? 2 : 1))
                {
                    var link = new HyperlinkButton { Content = cells[c], Padding = new Thickness(0) };
                    Guid id = s.Id;
                    link.Click += async (_, _) => await OpenSessionAsync(id);
                    cell = link;
                }
                else
                {
                    var t = Text(cells[c], 13, opacity: s.Excluded ? 0.5 : 1);
                    if (columns[c] == L("Stage", "状态")) t.Foreground = new SolidColorBrush(Win2DCanvas.ToColor(StageColor(s.Stage)));
                    t.VerticalAlignment = VerticalAlignment.Center;
                    cell = t;
                }
                Grid.SetRow(cell, row);
                Grid.SetColumn(cell, c);
                table.Children.Add(cell);
            }
            row++;
        }
        TaskHost.Children.Add(new Border
        {
            Background = new SolidColorBrush(Win2DCanvas.ToColor(theme.Card)),
            BorderBrush = new SolidColorBrush(Win2DCanvas.ToColor(theme.Hairline)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16),
            Child = new ScrollViewer { Content = table, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled },
        });

        // The group comparison of the task (the Mac's task page): once sessions have results.
        if (_selectedTask is { } groupTask && _store.FindTask(groupTask) is { } owner)
        {
            _groupPanel ??= new Results.GroupPanel(_store, () => WinRT.Interop.WindowNative.GetWindowHandle(this),
                                                   message => StatusLabel.Text = message,
                                                   () => Root.ActualTheme == ElementTheme.Dark);
            _groupPanel.Attach(TaskHost, owner);
        }
    }

    // ================================================================ tasks

    private static readonly string[] CategoryOrder = ["social", "navigation", "anxiety", "memory", "motor", "general"];

    private async void NewTask(object sender, RoutedEventArgs e)
    {
        var paradigms = _model.Tasks
            .OrderBy(p => Array.IndexOf(CategoryOrder, p.Category) is var i && i >= 0 ? i : 99)
            .ThenBy(p => p.EnglishName, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        var combo = new ComboBox { Header = L("Test", "实验范式"), HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var p in paradigms)
            combo.Items.Add(new ComboBoxItem { Content = (Chinese ? p.Title : p.EnglishName) + "  ·  " + p.CategoryTitle, Tag = p.Id });
        var tagline = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.7, FontSize = 12 };
        var name = new TextBox { Header = L("Name", "名称"), PlaceholderText = L("e.g. Open field, cohort 1", "如 旷场 第一批") };
        bool named = false;
        name.TextChanged += (_, _) => named = name.FocusState != FocusState.Unfocused || named;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedIndex < 0) return;
            var p = paradigms[combo.SelectedIndex];
            tagline.Text = p.Tagline;
            if (!named) name.Text = Chinese ? p.Title : p.EnglishName;
        };
        var panel = new StackPanel { Spacing = 12, MinWidth = 420 };
        panel.Children.Add(combo);
        panel.Children.Add(tagline);
        panel.Children.Add(name);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = L("New task", "新建任务"),
            Content = panel,
            PrimaryButtonText = L("Create", "创建"),
            CloseButtonText = L("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Primary,
        };
        combo.SelectedIndex = Math.Max(0, paradigms.FindIndex(p => p.Id == "open_field"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || combo.SelectedIndex < 0) return;
        var chosen = paradigms[combo.SelectedIndex];
        var task = _store.AddTask(chosen.Id, name.Text.Trim().Length > 0 ? name.Text.Trim() : chosen.EnglishName);
        _store.Save();
        SelectInSidebar("task:" + task.Id);
    }

    private async Task RenameTaskAsync(WorkspaceTask task)
    {
        var box = new TextBox { Text = task.Name, MinWidth = 360 };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = L("Rename task", "重命名任务"),
            Content = box,
            PrimaryButtonText = L("Rename", "重命名"),
            CloseButtonText = L("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || box.Text.Trim().Length == 0) return;
        task.Name = box.Text.Trim();
        _store.MarkChanged();
        _store.Save();
        SelectInSidebar("task:" + task.Id);
    }

    private async Task RemoveTaskAsync(WorkspaceTask task)
    {
        if (_model.Busy && _model.Current?.TaskId == task.Id)
        {
            StatusLabel.Text = L("A session of this task is being analysed. Stop it first.", "此任务的一个实验正在分析，请先停止。");
            return;
        }
        int n = _store.SessionsOf(task.Id).Count();
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = L("Remove the task?", "移除该任务？"),
            Content = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Text = string.Format(L("\"{0}\" and its {1} sessions are taken out of the workspace. The videos and the analysis folders stay on disk.",
                                       "“{0}”及其 {1} 次实验将从工作区移除。视频和分析文件夹仍保留在磁盘上。"), task.Name, n),
            },
            PrimaryButtonText = L("Remove", "移除"),
            CloseButtonText = L("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        _store.RemoveTask(task.Id);
        _store.Save();
        if (_store.Document.Tasks.FirstOrDefault() is { } first) SelectInSidebar("task:" + first.Id);
        else
        {
            BuildSidebar();
            ApplySidebarTag("none");
        }
    }

    // ================================================================ videos

    private async void AddVideos(object sender, RoutedEventArgs e)
    {
        if (_selectedTask is not { } taskId || _store.FindTask(taskId) is not { } task) return;
        var picker = new FileOpenPicker();
        foreach (var extension in VideoExtensions) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is null || files.Count == 0) return;
        var paths = files.Select(f => f.Path).Where(p => p.Length > 0).ToList();
        var already = _store.SessionsOf(task.Id).Select(s => s.VideoPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
        int skipped = paths.RemoveAll(p => already.Contains(p));
        if (paths.Count == 0)
        {
            StatusLabel.Text = L("These videos are already in the task.", "这些视频已在任务中。");
            return;
        }
        var paradigm = _model.Tasks.FirstOrDefault(p => p.Id == task.Paradigm);
        var added = await Workspace.ImportDialog.ShowAsync(Root.XamlRoot, _store, task, paradigm, paths, _selectedGroup);
        if (added.Count == 0) return;
        _store.Save();
        StatusLabel.Text = string.Format(L("Added {0} sessions.", "已添加 {0} 次实验。"), added.Count)
                           + (skipped > 0 ? " " + string.Format(L("{0} were already in the task.", "{0} 个已在任务中。"), skipped) : "");
        _listSignature = null;
        _sidebarSignature = null;
        BuildSidebar();
        RebuildSessionList();
        await OpenSessionAsync(added[0].Id);
    }

    // ================================================================ the queue

    /// <summary>
    /// What "Analyse all ready" will run: listed sessions with their arena placed (or a paused / failed run to
    /// continue), their session info complete, not excluded, and their video where it was.
    /// </summary>
    private List<WorkspaceSession> BatchQueue() => ListedSessions()
        .Where(s => s.Stage is SessionStage.Ready or SessionStage.Paused or SessionStage.Failed
                    && s.HasSessionInfo && !s.Excluded && File.Exists(s.VideoPath))
        .ToList();

    private async void AnalyseAll(object sender, RoutedEventArgs e)
    {
        if (_model.Busy) return;
        var queue = BatchQueue();
        if (queue.Count == 0)
        {
            StatusLabel.Text = L("Nothing is ready: place the arena on a session (or use one session's setup for all), and complete the session info.",
                                 "没有可分析的实验：请先在实验上标定场地（或把一个实验的设置用于全部），并补全实验信息。");
            return;
        }
        _batchStop = false;
        int done = 0;
        try
        {
            for (int i = 0; i < queue.Count && !_batchStop; i++)
            {
                var s = queue[i];
                _batchText = string.Format(L("session {0} of {1}", "第 {0} / {1} 次"), i + 1, queue.Count);
                await OpenSessionAsync(s.Id);
                if (!ReferenceEquals(_model.Current, s) || !_model.CanStart) continue;
                ShowStep(Step.Calibrate);
                await _model.RunAsync(ToUi);
                if (s.Stage == SessionStage.Analysed) done++;
            }
        }
        finally
        {
            _batchText = null;
        }
        StatusLabel.Text = string.Format(L("Analysed {0} of {1} sessions.", "已分析 {0} / {1} 次实验。"), done, queue.Count)
                           + (_batchStop ? " " + L("Stopped.", "已停止。") : "");
        _listSignature = null;
        RebuildSessionList();
        if (_model.Report is not null) ShowStep(Step.Results);
    }

    // ================================================================ session info

    private void PushSessionInfo()
    {
        var s = _model.Current;
        bool open = s is not null;
        InfoStep.IsEnabled = open;
        ReviewStep.IsEnabled = open && _model.PoseFile is not null;
        CopySetupButton.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        CopySetupButton.IsEnabled = open && !_model.Busy;
        PickVideoButton.Visibility = open && _model.VideoPath is null ? Visibility.Visible : Visibility.Collapsed;
        RemoveSessionButton.IsEnabled = open && !_model.Busy;
        if (StatusLabel.Text == _model.Status && _batchText is { } batch) StatusLabel.Text = batch + " · " + _model.Status;
        if (s is null) return;

        InfoTitle.Text = (_store.FindTask(s.TaskId)?.Name ?? "") + " · " + (s.AnimalId.Trim().Length > 0 ? s.AnimalKey : L("New animal", "新小鼠"));
        string size = s.FileSize > 0 ? $" · {s.FileSize / 1048576.0:F0} MB" : "";
        InfoVideoLabel.Text = s.VideoPath + size + (s.Setup?.CopiedFrom is { } from ? "\n" + L("Setup copied from ", "设置复制自 ") + from : "");
        int sex = (s.Sex ?? "") switch { "M" => 1, "F" => 2, _ => 0 };
        if (SexBox.SelectedIndex != sex) SexBox.SelectedIndex = sex;
        var date = SessionDates.Parse(s.SessionDate);
        if (DateBox.Date?.Date != date) DateBox.Date = date is { } d ? new DateTimeOffset(d) : null;
        SetNumber(SessionNumberBox, s.SessionNumber);
        SetNumber(DayBox, s.Day);
        SetNumber(TrialBox, s.Trial);
        if (NotesBox.Text != (s.Notes ?? "")) NotesBox.Text = s.Notes ?? "";
        int review = (int)s.Review;
        if (ReviewBox.SelectedIndex != review) ReviewBox.SelectedIndex = review;
        if (ExcludedBox.IsChecked != s.Excluded) ExcludedBox.IsChecked = s.Excluded;
        ExclusionReasonBox.Visibility = s.Excluded ? Visibility.Visible : Visibility.Collapsed;
        if (ExclusionReasonBox.Text != (s.ExclusionReason ?? "")) ExclusionReasonBox.Text = s.ExclusionReason ?? "";
        string problems = _model.InfoProblems;
        InfoProblemsLabel.Text = problems;
        InfoProblemsLabel.Visibility = problems.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static void SetNumber(NumberBox box, int? value)
    {
        double v = value ?? double.NaN;
        if (!(double.IsNaN(v) && double.IsNaN(box.Value)) && box.Value != v) box.Value = v;
    }

    private void SexChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || _model.Current is not { } s || SexBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        // Sex belongs to the animal: every session of it in the task.
        _store.SetAnimalAttributes(s.TaskId, s.AnimalKey, null, tag);
        _model.SessionInfoChanged();
    }

    private void DateChanged(CalendarDatePicker sender, CalendarDatePickerDateChangedEventArgs args)
    {
        if (_quiet > 0 || _model.Current is not { } s) return;
        s.SessionDate = sender.Date is { } d ? SessionDates.Text(d.Date) : null;
        _model.SessionInfoChanged();
    }

    private void SessionNumberChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_quiet > 0 || _model.Current is not { } s) return;
        s.SessionNumber = double.IsNaN(args.NewValue) ? null : (int)Math.Round(args.NewValue);
        _model.SessionInfoChanged();
    }

    private void DayTrialChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_quiet > 0 || _model.Current is not { } s) return;
        int? v = double.IsNaN(args.NewValue) ? null : (int)Math.Round(args.NewValue);
        if (sender == DayBox) s.Day = v;
        else s.Trial = v;
        _model.SessionInfoChanged();
    }

    private void NotesChanged(object sender, TextChangedEventArgs e)
    {
        if (_quiet > 0 || _model.Current is not { } s) return;
        s.Notes = NotesBox.Text;
        _model.SessionInfoChanged();
    }

    private void ReviewChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || _model.Current is not { } s || ReviewBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        if (Enum.TryParse<ReviewVerdict>(tag, out var verdict)) s.Review = verdict;
        _model.SessionInfoChanged();
    }

    private void ExcludedChanged(object sender, RoutedEventArgs e)
    {
        if (_quiet > 0 || _model.Current is not { } s) return;
        s.Excluded = ExcludedBox.IsChecked == true;
        _model.SessionInfoChanged();
        Refresh();
    }

    private void ExclusionReasonChanged(object sender, TextChangedEventArgs e)
    {
        if (_quiet > 0 || _model.Current is not { } s) return;
        s.ExclusionReason = ExclusionReasonBox.Text;
        _model.SessionInfoChanged();
    }

    private async void CopySetupToTask(object sender, RoutedEventArgs e)
    {
        if (_model.Current is not { } s) return;
        int others = _store.SessionsOf(s.TaskId).Count(o => o.Id != s.Id);
        if (others == 0)
        {
            StatusLabel.Text = L("This is the only session of the task.", "这是该任务唯一的实验。");
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = L("Use this setup for all sessions?", "把此设置用于全部实验？"),
            Content = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Text = string.Format(L("The arena, the markers and the parameters of this session are copied to the other {0} sessions of the task (each keeps its own phase). Use it when the camera did not move. Analysed sessions keep their results until they are analysed again or their results are updated.",
                                       "此实验的场地、标记和参数将复制到该任务的其他 {0} 次实验（阶段各自保留）。适用于相机没有移动的情况。已分析的实验在重新分析或更新结果之前保留原结果。"), others),
            },
            PrimaryButtonText = L("Copy", "复制"),
            CloseButtonText = L("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        int n = _model.CopySetupToTask();
        _store.Save();
        StatusLabel.Text = string.Format(L("The setup is now used by {0} more sessions.", "已有另外 {0} 次实验使用此设置。"), n);
    }

    private async void RemoveSession(object sender, RoutedEventArgs e)
    {
        if (_model.Current is not { } s || _model.Busy) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = L("Remove this session?", "移除此实验？"),
            Content = new TextBlock
            {
                TextWrapping = TextWrapping.Wrap,
                Text = L("The session is taken out of the task. The video and its analysis folders stay on disk.",
                         "此实验将从任务中移除。视频和分析文件夹仍保留在磁盘上。"),
            },
            PrimaryButtonText = L("Remove", "移除"),
            CloseButtonText = L("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        _store.RemoveSession(s.Id);
        _store.Save();
        _listSignature = null;
        RebuildSessionList();
        ShowTaskPage();
    }
}
