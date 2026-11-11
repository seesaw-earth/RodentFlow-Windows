using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RodentFlow.Core.Workspace;
using RodentFlow.Engine;
using static RodentFlow.App.AppText;

namespace RodentFlow.App.Workspace;

/// <summary>
/// Adding videos to a task (ImportVideosSheet.swift). Every video is one session of one animal, so the animal
/// ID, the recording date and the session number are required before importing. Group and sex belong to the
/// animal: for an animal that already has sessions in this task they are taken from those.
/// </summary>
internal static class ImportDialog
{
    private sealed class Row
    {
        public required string Path { get; init; }
        public required TextBox Animal { get; init; }
        public required TextBox Group { get; init; }
        public required ComboBox Sex { get; init; }
        public required CalendarDatePicker Date { get; init; }
        public required NumberBox Session { get; init; }
        public ComboBox? Phase { get; init; }
        public required TextBlock Note { get; init; }
        public string DateNote { get; set; } = "";
        public bool SessionEdited { get; set; }
        public string AnimalKey => Animal.Text.Trim();
        public int Number => double.IsNaN(Session.Value) ? 0 : (int)Session.Value;
    }

    /// <summary>Shows the dialog; returns the sessions added to the workspace (none when cancelled).</summary>
    public static async Task<List<WorkspaceSession>> ShowAsync(XamlRoot root, WorkspaceStore store, WorkspaceTask task,
                                                               ParadigmInfo? paradigm, IReadOnlyList<string> paths,
                                                               string? presetGroup)
    {
        var rows = new List<Row>();
        bool quiet = true;
        var table = new Grid { ColumnSpacing = 8, RowSpacing = 4 };
        bool phases = paradigm is { Phases.Length: > 0 };
        double[] widths = phases ? new double[] { 190, 110, 100, 70, 150, 90, 140 } : new double[] { 190, 110, 100, 70, 150, 90 };
        foreach (double w in widths) table.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w) });

        void Cell(UIElement e, int row, int col, int span = 1)
        {
            Grid.SetRow((FrameworkElement)e, row);
            Grid.SetColumn((FrameworkElement)e, col);
            if (span > 1) Grid.SetColumnSpan((FrameworkElement)e, span);
            table.Children.Add(e);
        }

        var heads = new List<string>
        {
            L("Video", "视频"), L("Animal ID *", "小鼠编号 *"), L("Group", "分组"), L("Sex", "性别"), L("Date *", "日期 *"),
            L("Session # *", "实验次数 *"),
        };
        if (phases) heads.Add(L("Phase", "阶段"));
        table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (int c = 0; c < heads.Count; c++)
            Cell(new TextBlock { Text = heads[c], FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Opacity = 0.7 }, 0, c);

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = string.Format(L("Add {0} videos to {1}", "向“{1}”添加 {0} 个视频"), paths.Count, task.Name),
            PrimaryButtonText = L("Add", "添加"),
            CloseButtonText = L("Cancel", "取消"),
            DefaultButton = ContentDialogButton.Primary,
        };
        // A ContentDialog is narrow by default; the table needs room.
        dialog.Resources["ContentDialogMaxWidth"] = 1200.0;

        void Validate()
        {
            bool any = false;
            for (int i = 0; i < rows.Count; i++)
            {
                var r = rows[i];
                var problems = new List<string>();
                if (r.AnimalKey.Length == 0) problems.Add(L("Animal ID is required.", "必须填写小鼠编号。"));
                if (r.Number < 1) problems.Add(L("Session number must be at least 1.", "实验次数至少为 1。"));
                if (r.Date.Date is null) problems.Add(L("The date is required.", "必须填写日期。"));
                if (r.AnimalKey.Length > 0 && r.Number >= 1)
                {
                    if (store.SessionConflict(task.Id, r.AnimalKey, r.Number, null) is { } conflict)
                        problems.Add(string.Format(L("{0} already has session #{1} in this task ({2}).", "{0} 在此任务中已有第 {1} 次实验（{2}）。"),
                                                   r.AnimalKey, r.Number, conflict.FileName));
                    if (rows.Where((o, j) => j != i && o.AnimalKey == r.AnimalKey && o.Number == r.Number).Any())
                        problems.Add(L("The same animal and session number appear twice in this list.", "列表中同一小鼠的实验次数重复。"));
                }
                any |= problems.Count > 0;
                string text = string.Join(" ", problems);
                if (problems.Count == 0 && r.DateNote.Length > 0) text = r.DateNote;
                r.Note.Text = text;
                if (problems.Count > 0) r.Note.Foreground = new SolidColorBrush(Microsoft.UI.Colors.OrangeRed);
                else r.Note.ClearValue(TextBlock.ForegroundProperty);
                r.Note.Opacity = problems.Count > 0 ? 1 : 0.7;
                r.Note.Visibility = text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            }
            dialog.IsPrimaryButtonEnabled = !any && rows.Count > 0;
        }

        // The next free session number of each animal, the list's own rows counted (ImportVideosSheet.renumber).
        void Renumber()
        {
            quiet = true;
            var taken = new Dictionary<string, List<int>>();
            foreach (var r in rows)
            {
                string key = r.AnimalKey;
                if (!taken.TryGetValue(key, out var mine)) taken[key] = mine = [];
                if (!r.SessionEdited) r.Session.Value = store.NextSessionNumber(task.Id, key, mine);
                mine.Add(r.Number);
            }
            quiet = false;
        }

        // An animal that already has sessions brings its group and sex.
        void AnimalAttributes(Row r)
        {
            if (store.AnimalAttributes(task.Id, r.AnimalKey) is { } known)
            {
                r.Group.Text = known.Group;
                r.Sex.SelectedIndex = known.Sex switch { "M" => 1, "F" => 2, _ => 0 };
                r.Group.IsEnabled = r.Sex.IsEnabled = false;
                ToolTipService.SetToolTip(r.Group, L("Taken from this animal's other sessions.", "取自该小鼠的其他实验。"));
            }
            else
            {
                r.Group.IsEnabled = r.Sex.IsEnabled = true;
                ToolTipService.SetToolTip(r.Group, null);
            }
        }

        for (int i = 0; i < paths.Count; i++)
        {
            string path = paths[i];
            string stem = System.IO.Path.GetFileNameWithoutExtension(path);
            DateTime date = DateTime.Today;
            string note = L("Date not found in the file name or file; set it.", "文件名和文件中没有日期，请填写。");
            if (SessionDates.Parse(SessionDates.FromFileName(stem)) is { } fromName)
            {
                date = fromName;
                note = "";
            }
            else if (File.Exists(path))
            {
                date = File.GetCreationTime(path).Date;
                note = L("Date taken from the file's creation date; check it.", "日期取自文件创建日期，请核对。");
            }
            var sex = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (string sx in new[] { "—", "M", "F" }) sex.Items.Add(sx);
            sex.SelectedIndex = 0;
            ComboBox? phase = null;
            if (phases)
            {
                phase = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = "Title" };
                foreach (var ph in paradigm!.Phases) phase.Items.Add(ph);
                phase.SelectedIndex = 0;
            }
            var row = new Row
            {
                Path = path,
                Animal = new TextBox { Text = SessionDates.AnimalGuess(stem), PlaceholderText = L("e.g. M01", "如 M01") },
                Group = new TextBox { Text = presetGroup ?? "" },
                Sex = sex,
                Date = new CalendarDatePicker { Date = new DateTimeOffset(date), HorizontalAlignment = HorizontalAlignment.Stretch },
                Session = new NumberBox { Minimum = 1, Maximum = 9999, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Value = 1 },
                Phase = phase,
                Note = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed },
                DateNote = note,
            };
            rows.Add(row);
            int gridRow = 1 + i * 2;
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var name = new TextBlock
            {
                Text = System.IO.Path.GetFileName(path),
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTipService.SetToolTip(name, path);
            Cell(name, gridRow, 0);
            Cell(row.Animal, gridRow, 1);
            Cell(row.Group, gridRow, 2);
            Cell(row.Sex, gridRow, 3);
            Cell(row.Date, gridRow, 4);
            Cell(row.Session, gridRow, 5);
            if (phase is not null) Cell(phase, gridRow, 6);
            Cell(row.Note, gridRow + 1, 1, widths.Length - 1);

            row.Animal.TextChanged += (_, _) =>
            {
                if (quiet) return;
                AnimalAttributes(row);
                Renumber();
                Validate();
            };
            row.Session.ValueChanged += (_, _) =>
            {
                if (quiet) return;
                row.SessionEdited = true;
                Validate();
            };
            row.Date.DateChanged += (_, _) =>
            {
                if (quiet) return;
                row.DateNote = "";
                Validate();
            };
        }
        foreach (var r in rows) AnimalAttributes(r);
        Renumber();

        // For every row at once: one group; the first row's date.
        var groupForAll = new TextBox { PlaceholderText = L("Group for all new animals", "新小鼠的统一分组"), Width = 220 };
        var applyGroup = new Button { Content = L("Apply", "应用") };
        applyGroup.Click += (_, _) =>
        {
            foreach (var r in rows.Where(r => r.Group.IsEnabled)) r.Group.Text = groupForAll.Text.Trim();
        };
        var sameDate = new Button { Content = L("Use the first date for all", "全部使用第一行的日期") };
        sameDate.Click += (_, _) =>
        {
            if (rows.Count == 0 || rows[0].Date.Date is not { } first) return;
            quiet = true;
            foreach (var r in rows)
            {
                r.Date.Date = first;
                r.DateNote = "";
            }
            quiet = false;
            Validate();
        };
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        tools.Children.Add(groupForAll);
        tools.Children.Add(applyGroup);
        tools.Children.Add(sameDate);

        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = L("Each video is one session of one animal. Animal ID, date and session number are required. Group and sex belong to the animal; for an animal that already has sessions in this task they are taken from those.",
                     "每段视频是一只小鼠的一次实验。小鼠编号、日期和实验次数必须填写。分组和性别属于小鼠；该任务中已有实验的小鼠沿用已有的分组和性别。"),
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.75,
            MaxWidth = 900,
            HorizontalAlignment = HorizontalAlignment.Left,
        });
        content.Children.Add(tools);
        content.Children.Add(new ScrollViewer
        {
            Content = table,
            MaxHeight = 460,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled,
        });
        dialog.Content = content;
        quiet = false;
        Validate();

        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return [];

        var added = new List<WorkspaceSession>();
        foreach (var r in rows)
        {
            string sexTag = r.Sex.SelectedIndex switch { 1 => "M", 2 => "F", _ => "" };
            var s = new WorkspaceSession
            {
                TaskId = task.Id,
                VideoPath = r.Path,
                FileName = System.IO.Path.GetFileName(r.Path),
                FileSize = File.Exists(r.Path) ? new FileInfo(r.Path).Length : 0,
                AnimalId = r.AnimalKey,
                Group = r.Group.Text.Trim(),
                Sex = sexTag,
                SessionDate = r.Date.Date is { } d ? SessionDates.Text(d.Date) : null,
                SessionNumber = r.Number,
                Phase = r.Phase?.SelectedItem is PhaseOption p ? p.Key : paradigm?.DefaultPhase,
            };
            store.Document.Sessions.Add(s);
            added.Add(s);
        }
        store.MarkChanged();
        return added;
    }
}
