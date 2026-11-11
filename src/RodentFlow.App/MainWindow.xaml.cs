using System.ComponentModel;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using RodentFlow.App.Results;
using RodentFlow.Core;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Setup;
using RodentFlow.Core.Text;
using RodentFlow.Core.Workspace;
using RodentFlow.Engine;
using Windows.Foundation;
using Windows.Globalization.NumberFormatting;
using Windows.Storage.Pickers;
using Path = System.IO.Path;

namespace RodentFlow.App;

/// <summary>
/// One window: choose a video and a task, place the arena and the task's markers on a frame, set the
/// task's parameters, analyse, and read the result page — the Mac's session steps Calibrate → Analyse →
/// Results in one window.
/// </summary>
/// <remarks>
/// Nothing here knows which task it is showing. The parameter rows come from <see cref="AssayForms"/>,
/// and the picture shows what the engine returns for the current setup (rf_setup_view): its zones,
/// its handles and the region the model will be given. Dragging a handle sends the drag to the
/// engine (rf_move_handle), which applies the same rules the Mac app does.
/// </remarks>
public sealed partial class MainWindow : Window
{
    private readonly AppSettings _settings = AppSettings.Load();
    private readonly MainViewModel _model;

    /// <summary>
    /// Above zero while the controls are being filled in rather than operated: during XAML load,
    /// while the task's rows are built, and while <see cref="Refresh"/> pushes model values into the
    /// controls. Setting a control's value raises its own changed event, so every handler checks this
    /// to tell the window writing a control from the user turning a knob. It starts at one because
    /// InitializeComponent runs before the window is ready.
    /// </summary>
    private int _quiet = 1;

    /// <summary>The handle being dragged (an engine handle id), or null.</summary>
    private string? _dragging;

    private const double HandleSize = 22;

    /// <summary>One parameter row: its control, and how to show the model's current value in it.</summary>
    private sealed record RowBinding(FormRow Row, FrameworkElement Element, Action Sync);

    /// <summary>A titled group of rows, hidden when none of its rows is shown.</summary>
    private sealed record GroupBinding(FrameworkElement Element, List<RowBinding> Rows);

    private readonly List<RowBinding> _rows = [];
    private readonly List<GroupBinding> _groups = [];
    private string _formTask = "";

    private bool Chinese => _settings.Chinese;

    /// <summary>The result page (the Mac's PoseReportView), drawn into ResultsHost.</summary>
    private readonly ReportPresenter _results;

    /// <summary>The report the page shows now, so it is redrawn only when the report changes.</summary>
    private DisplayReport? _shownReport;

    public MainWindow()
    {
        // Before InitializeComponent: handlers can run during the load, and they reach for the model.
        AppText.Chinese = _settings.Chinese;
        _store = new WorkspaceStore(WorkspaceStore.DefaultFolder);
        _model = new MainViewModel(_settings, _store);
        InitializeComponent();
        _results = new ReportPresenter(ResultsHost);

        TaskBox.ItemsSource = _model.Tasks;
        LanguageBox.SelectedIndex = _settings.Chinese ? 1 : 0;
        DeviceBox.SelectedIndex = _settings.Device switch { "cpu" => 1, "gpu" => 2, _ => 0 };
        ApplyLanguage();
        StepBar.SelectedItem = CalibrateStep;
        ShowStep(Step.Calibrate);
        EngineLabel.Text = _model.EngineLabel;
        // The page is drawn in the window's own light or dark colours; follow a change of theme.
        Root.ActualThemeChanged += (_, _) => ShowResults(force: true);

        _model.PropertyChanged += ModelChanged;
        BuildTaskControls();
        Refresh();
        ShowMissingModels();
        ShowSetupProblems();
        StartWorkspace();
        _quiet = 0;   // the window is built; from here a changed event means the user
    }

    private void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MainViewModel.SelectedTask)) BuildTaskControls();
        if (e.PropertyName == nameof(MainViewModel.Report)) ShowResults(force: false);
        if (e.PropertyName == nameof(MainViewModel.ResultsUpdating)) _results.SetUpdating(_model.ResultsUpdating);
        Refresh();
        if (e.PropertyName is nameof(MainViewModel.PreviewFrame) or nameof(MainViewModel.LivePoses) or nameof(MainViewModel.LiveFrame))
            DrawPicture();
        if (e.PropertyName is nameof(MainViewModel.View) or nameof(MainViewModel.Video))
            DrawOverlay();
    }

    // ---------------------------------------------------------------- binding by hand

    private void Refresh()
    {
        _quiet++;
        try { PushToControls(); }
        finally { _quiet--; }
    }

    private void PushToControls()
    {
        VideoLabel.Text = _model.VideoLabel;
        StatusLabel.Text = _model.Status;
        RunProgress.Value = _model.Progress;
        StartButton.IsEnabled = _model.CanStart;
        StopButton.IsEnabled = _model.CanStop;
        AnimalsBox.IsEnabled = _model.AnimalCountIsEditable;
        AnimalsBox.Value = _model.AnimalCount;
        PlanLabel.Text = _model.PlanLabel;
        OpenResults.IsEnabled = _model.HasResults;
        AnnotateButton.IsEnabled = _model.HasResults && !_model.Busy && _model.VideoPath is not null;
        OpenRunButton.IsEnabled = !_model.Busy && !_model.ResultsUpdating;
        UpdateButton.IsEnabled = _model.CanUpdate && (_model.ResultsStale || _model.Report is null);
        ResultsStateLabel.Text = _model.ResultsState;
        ResultsEmpty.Visibility = _model.Report is null ? Visibility.Visible : Visibility.Collapsed;
        ResultsEmpty.Text = _model.ResultsEmptyText;
        if (SubjectBox.Text != _model.Subject) SubjectBox.Text = _model.Subject;
        if (GroupBox.Text != _model.Group) GroupBox.Text = _model.Group;
        PushSessionInfo();
        foreach (var item in CoatBox.Items.OfType<ComboBoxItem>())
        {
            if (item.Tag is string tag && tag == _model.Coat.ToString() && !ReferenceEquals(CoatBox.SelectedItem, item))
                CoatBox.SelectedItem = item;
        }
        ToBox.Value = _model.ToSeconds;
        StrideBox.Value = _model.Stride;

        var task = _model.SelectedTask;
        if (!ReferenceEquals(TaskBox.SelectedItem, task)) TaskBox.SelectedItem = task;
        // A session belongs to its task (the Mac does not let a session change task either).
        TaskBox.IsEnabled = _model.Current is null;
        TaskTagline.Text = task?.Tagline ?? "";

        // Phase: a list of presets, or the researcher's own label.
        bool presets = task is { Phases.Length: > 0 };
        PhaseBox.Visibility = presets ? Visibility.Visible : Visibility.Collapsed;
        PhaseText.Visibility = presets ? Visibility.Collapsed : Visibility.Visible;
        if (presets)
        {
            var phase = task!.Phases.FirstOrDefault(p => p.Key == _model.Phase);
            if (!ReferenceEquals(PhaseBox.SelectedItem, phase)) PhaseBox.SelectedItem = phase;
        }
        else if (PhaseText.Text != _model.Phase)
        {
            PhaseText.Text = _model.Phase;
        }

        // Arena shape and its two size fields.
        foreach (var item in ArenaBox.Items.OfType<ComboBoxItem>())
        {
            if (item.Tag is ArenaKind kind && kind == _model.Arena && !ReferenceEquals(ArenaBox.SelectedItem, item))
                ArenaBox.SelectedItem = item;
        }
        var (a, b, valueA, valueB) = _model.Dimensions;
        ShowDimension(DimABox, a, valueA);
        ShowDimension(DimBBox, b, valueB);
        FillFrameButton.Visibility = _model.Arena == ArenaKind.Rectangle ? Visibility.Visible : Visibility.Collapsed;

        ArenaHintLabel.Text = _model.ArenaHint;
        MarkerLegendLabel.Text = _model.MarkerLegend;
        MarkerLegendLabel.Visibility = MarkerLegendLabel.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ScaleLabel.Text = _model.ScaleLabel;

        // Parameter rows: value, title (some follow the phase) and whether they are shown.
        var context = _model.FormContext;
        foreach (var r in _rows)
        {
            r.Sync();
            r.Element.Visibility = r.Row.IsVisible(context) ? Visibility.Visible : Visibility.Collapsed;
        }
        foreach (var g in _groups)
        {
            bool any = g.Rows.Any(r => r.Element.Visibility == Visibility.Visible);
            g.Element.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private static void ShowDimension(NumberBox box, string? header, double value)
    {
        box.Visibility = header is null ? Visibility.Collapsed : Visibility.Visible;
        if (header is null) return;
        box.Header = header;
        if (!SameNumber(box.Value, value)) box.Value = value;
    }

    private static bool SameNumber(double a, double b) =>
        (double.IsNaN(a) && double.IsNaN(b)) || Math.Abs(a - b) <= 1e-9 * Math.Max(1, Math.Abs(b));

    private void ShowMissingModels()
    {
        if (_model.MissingModels.Count == 0)
        {
            ModelWarning.IsOpen = false;
            return;
        }
        ModelWarning.IsOpen = true;
        ModelWarning.Message = string.Join(", ", _model.MissingModels) + string.Format(AppText.L(
            " — not in {0}. Export them with RodentFlow_Export_ONNX_All_Models.ipynb and copy the .onnx files there.",
            " —— 不在 {0}。请用 RodentFlow_Export_ONNX_All_Models.ipynb 导出，并把 .onnx 文件复制到那里。"), _settings.ModelsFolder);
    }

    private void ShowSetupProblems()
    {
        SetupCheck.IsOpen = _model.SetupProblems.Count > 0;
        SetupCheck.Message = string.Join("\n", _model.SetupProblems);
    }

    // ---------------------------------------------------------------- the task's own controls

    /// <summary>Phase list, arena shapes and parameter rows of the selected task.</summary>
    private void BuildTaskControls()
    {
        var task = _model.SelectedTask;
        if (task is null || task.Id == _formTask) return;
        _formTask = task.Id;
        _quiet++;
        try
        {
            PhaseBox.ItemsSource = task.Phases;

            ArenaBox.Items.Clear();
            foreach (var kind in task.ArenaKinds)
            {
                string title = _model.Catalogue.ArenaKinds.FirstOrDefault(k => k.Id == kind)?.Title ?? kind.ToString();
                ArenaBox.Items.Add(new ComboBoxItem { Content = title, Tag = kind });
            }
            ArenaBox.IsEnabled = task.ArenaKinds.Length > 1;

            // The coat colours the task's model has (the Mac's coat picker); a group has no choice, only how many mice.
            CoatBox.Items.Clear();
            foreach (var coat in MainViewModel.CoatChoices(task))
                CoatBox.Items.Add(new ComboBoxItem { Content = MainViewModel.CoatTitle(coat, task), Tag = coat.ToString() });
            CoatBox.Visibility = task.IsGroup ? Visibility.Collapsed : Visibility.Visible;
            AnimalsBox.Visibility = task.IsGroup ? Visibility.Visible : Visibility.Collapsed;

            _rows.Clear();
            _groups.Clear();
            TaskFormPanel.Children.Clear();
            CommonFormPanel.Children.Clear();
            foreach (var group in AssayForms.For(task.Id)) AddGroup(TaskFormPanel, group);
            foreach (var group in AssayForms.Common(task.Id)) AddGroup(CommonFormPanel, group);
        }
        finally
        {
            _quiet--;
        }
    }

    private void AddGroup(Panel panel, FormGroup group)
    {
        Panel target = panel;
        FrameworkElement? container = null;
        if (group.En is not null)
        {
            var inner = new StackPanel { Spacing = 10 };
            string title = Chinese ? group.Zh ?? group.En : group.En;
            if (group.Folded)
            {
                container = new Expander
                {
                    Header = title,
                    Content = inner,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                };
            }
            else
            {
                var box = new StackPanel { Spacing = 10 };
                box.Children.Add(new TextBlock
                {
                    Text = title,
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(0, 4, 0, 0),
                });
                box.Children.Add(inner);
                container = box;
            }
            panel.Children.Add(container);
            target = inner;
        }

        var bindings = new List<RowBinding>();
        foreach (var row in group.Rows)
        {
            var binding = MakeRow(row);
            target.Children.Add(binding.Element);
            bindings.Add(binding);
            _rows.Add(binding);
        }
        if (container is not null) _groups.Add(new GroupBinding(container, bindings));
    }

    private string RowTitle(FormRow row)
    {
        string title = row.Title(_model.FormContext, Chinese);
        return row.Unit.Length > 0 ? $"{title} ({row.Unit})" : title;
    }

    private RowBinding MakeRow(FormRow row) => row.Kind switch
    {
        RowKind.Number => NumberRow(row),
        RowKind.Percent => PercentRow(row),
        RowKind.Choice => ChoiceRow(row),
        RowKind.Toggle => ToggleRow(row),
        RowKind.Onsets => OnsetsRow(row),
        _ => NoteRow(row),
    };

    private RowBinding NumberRow(FormRow row)
    {
        var box = new NumberBox
        {
            Header = RowTitle(row),
            Minimum = row.Min,
            Maximum = row.Max,
            SmallChange = row.Step > 0 ? row.Step : (row.Integer || row.Max - row.Min > 5 ? 1 : 0.1),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            NumberFormatter = Formatter(row.Integer),
        };
        string help = row.Help(Chinese);
        if (help.Length > 0) box.Description = help;
        box.ValueChanged += (sender, e) =>
        {
            if (_quiet > 0 || double.IsNaN(e.NewValue)) return;
            _model.EditParams(p => ParamValues.SetNumber(p, row.Key, e.NewValue, row.Integer));
        };
        return new RowBinding(row, box, () =>
        {
            box.Header = RowTitle(row);
            double v = ParamValues.Number(_model.Params, row.Key) ?? row.Fallback ?? double.NaN;
            if (!SameNumber(box.Value, v)) box.Value = v;
        });
    }

    /// <summary>Shows what was typed, to three decimals at most, without a trailing ".000".</summary>
    private static DecimalFormatter Formatter(bool integer) => new()
    {
        IntegerDigits = 1,
        FractionDigits = 0,
        NumberRounder = new IncrementNumberRounder
        {
            Increment = integer ? 1 : 0.001,
            RoundingAlgorithm = RoundingAlgorithm.RoundHalfUp,
        },
    };

    private RowBinding PercentRow(FormRow row)
    {
        var title = new TextBlock { Text = RowTitle(row), TextWrapping = TextWrapping.Wrap };
        var value = new TextBlock { Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Right };
        var slider = new Slider
        {
            Minimum = row.Min,
            Maximum = row.Max,
            StepFrequency = row.Step > 0 ? row.Step : 0.01,
            SmallChange = row.Step > 0 ? row.Step : 0.01,
            IsThumbToolTipEnabled = false,
        };
        slider.ValueChanged += (sender, e) =>
        {
            value.Text = Percent(e.NewValue);
            if (_quiet > 0) return;
            _model.EditParams(p => ParamValues.SetNumber(p, row.Key, Math.Round(e.NewValue, 4), integer: false));
        };

        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(value, 1);
        Grid.SetRow(slider, 1);
        Grid.SetColumnSpan(slider, 2);
        grid.Children.Add(title);
        grid.Children.Add(value);
        grid.Children.Add(slider);

        return new RowBinding(row, grid, () =>
        {
            title.Text = RowTitle(row);
            double v = ParamValues.Number(_model.Params, row.Key) ?? row.Fallback ?? row.Min;
            if (!SameNumber(slider.Value, v)) slider.Value = v;
            value.Text = Percent(v);
        });
    }

    private static string Percent(double v) => $"{Math.Round(v * 100):F0}%";

    private RowBinding ChoiceRow(FormRow row)
    {
        var combo = new ComboBox { Header = RowTitle(row), HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var option in row.Options) combo.Items.Add(Chinese ? option.Zh : option.En);
        combo.SelectionChanged += (sender, e) =>
        {
            if (_quiet > 0 || combo.SelectedIndex < 0) return;
            var option = row.Options[combo.SelectedIndex];
            _model.EditParams(p => ParamValues.SetChoice(p, row.Key, option.Value));
        };
        return new RowBinding(row, combo, () =>
        {
            combo.Header = RowTitle(row);
            int index = Array.FindIndex(row.Options, o => ParamValues.IsChoice(_model.Params, row.Key, o.Value));
            if (combo.SelectedIndex != index) combo.SelectedIndex = index;
        });
    }

    private RowBinding ToggleRow(FormRow row)
    {
        var check = new CheckBox { Content = RowTitle(row) };
        // Click, not Checked/Unchecked: Click is raised only by the user, never by setting IsChecked.
        check.Click += (sender, e) =>
        {
            if (_quiet > 0) return;
            bool on = check.IsChecked == true;
            _model.EditParams(p =>
            {
                if (row.SetToggle is not null) row.SetToggle(p, on);
                else p[row.Key] = on;
            });
        };
        return new RowBinding(row, check, () =>
        {
            bool on = row.GetToggle?.Invoke(_model.Params) ?? ParamValues.Flag(_model.Params, row.Key) == true;
            if (check.IsChecked != on) check.IsChecked = on;
        });
    }

    private RowBinding OnsetsRow(FormRow row)
    {
        var box = new TextBox { Header = RowTitle(row), PlaceholderText = row.Help(Chinese) };
        var error = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(Colors.OrangeRed),
            Visibility = Visibility.Collapsed,
        };
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(box);
        panel.Children.Add(error);

        void Commit()
        {
            if (_quiet > 0) return;
            var (values, bad) = ParamValues.ParseOnsets(box.Text);
            if (values is null)
            {
                error.Text = $"\"{bad}\" is not a time in seconds. Nothing was changed.";
                error.Visibility = Visibility.Visible;
                return;
            }
            error.Visibility = Visibility.Collapsed;
            _model.EditParams(p => ParamValues.SetOnsets(p, row.Key, values));
        }

        box.LostFocus += (sender, e) => Commit();
        box.KeyDown += (sender, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) Commit();
        };
        return new RowBinding(row, panel, () =>
        {
            var onsets = ParamValues.Onsets(_model.Params, row.Key);
            box.Description = onsets.Length == 1 ? "1 time" : $"{onsets.Length} times";
            // Never rewrite the text under the user's cursor.
            if (box.FocusState == FocusState.Unfocused) box.Text = ParamValues.FormatOnsets(onsets);
        });
    }

    private RowBinding NoteRow(FormRow row)
    {
        var text = new TextBlock
        {
            Text = row.Title(_model.FormContext, Chinese),
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
            FontSize = 12,
        };
        return new RowBinding(row, text, () => { });
    }

    // ---------------------------------------------------------------- the picture

    /// <summary>
    /// Sizes the picture to the frame's aspect ratio inside the available area, so that a point on
    /// screen maps straight to normalized frame coordinates with no letterbox arithmetic.
    /// </summary>
    private void FrameAreaSizeChanged(object sender, SizeChangedEventArgs e) => LayoutPicture();

    private void LayoutPicture()
    {
        double availableW = FrameArea.ActualWidth - 8, availableH = FrameArea.ActualHeight - 8;
        if (availableW <= 0 || availableH <= 0) return;
        double aspect = _model.FrameAspect;
        double w = availableW, h = w / aspect;
        if (h > availableH)
        {
            h = availableH;
            w = h * aspect;
        }
        FrameHost.Width = w;
        FrameHost.Height = h;
        DrawOverlay();
    }

    /// <summary>While the model runs: the frame it just analysed and the tracked animals (the Mac's live view).</summary>
    private RodentFlow.App.Figures.ReviewCanvas? _liveCanvas;

    private void DrawLiveOverlay(RodentFlow.Core.Figures.IFigureCanvas c, Func<double, double, RodentFlow.Core.Figures.Pt> map, double scale)
    {
        // The region given to the model (yellow, dashed), as on the Mac.
        if (_model.Plan?.Roi is { IsFullFrame: false } roi && _model.Video is { } v)
        {
            var a = map(roi.X * v.Width, roi.Y * v.Height);
            var b = map((roi.X + roi.W) * v.Width, (roi.Y + roi.H) * v.Height);
            c.Stroke(RodentFlow.Core.Figures.FigurePath.Rect(a.X, a.Y, b.X - a.X, b.Y - a.Y),
                     new RodentFlow.Core.Figures.Rgba(1, 0.84, 0, 0.8), 1.2, new RodentFlow.Core.Figures.StrokeStyle([6, 4]));
        }
        RodentFlow.Core.Review.PoseOverlay.DrawPoses(c, _model.LivePoses, map, scale, 0.3f,
                                                     RodentFlow.Core.Figures.FigureTheme.For(Root.ActualTheme == ElementTheme.Dark));
    }

    private void DrawPicture()
    {
        if (_model.Busy && _model.LiveFrame is { } live && _model.Video is { } video)
        {
            _liveCanvas ??= new RodentFlow.App.Figures.ReviewCanvas(LiveArea) { Overlay = DrawLiveOverlay };
            _liveCanvas.FrameWidth = video.Width;
            _liveCanvas.FrameHeight = video.Height;
            _liveCanvas.Show(new RodentFlow.Core.Figures.FigureImage(live.Pixels, live.Width, live.Height, live.RowBytes));
            LiveArea.Visibility = Visibility.Visible;
            return;
        }
        LiveArea.Visibility = Visibility.Collapsed;
        if (_model.PreviewFrame is not { } frame)
        {
            // A reopened run whose video has moved: no picture rather than the previous video's.
            FrameImage.Source = null;
            return;
        }

        // The calibration frame alone: the tracked animals are drawn on the live layer while the model runs.
        var pixels = (byte[])frame.Pixels.Clone();

        var bitmap = new WriteableBitmap(frame.Width, frame.Height);
        using (var stream = bitmap.PixelBuffer.AsStream())
            stream.Write(pixels, 0, pixels.Length);
        bitmap.Invalidate();
        FrameImage.Source = bitmap;
        LayoutPicture();
    }

    // ---------------------------------------------------------------- zones and handles

    /// <summary>Zone colours by role (the Mac's ZonePalette, CalibrationControls.swift).</summary>
    private static Windows.UI.Color ZoneColor(string role) => role switch
    {
        "center" => Rgb(93, 101, 241),                                 // indigo
        "periphery" or "corner" or "shelter" => Rgb(35, 163, 176),     // teal
        "social" or "interaction" => Rgb(242, 107, 97),                // coral
        "novel" or "choice" or "cue" => Rgb(245, 158, 27),             // amber
        "familiar" => Rgb(0, 114, 178),                                // Okabe–Ito blue
        "open" => Rgb(242, 179, 26),
        "arm" => Rgb(93, 101, 241),
        "light" => Rgb(250, 199, 46),
        "dark" => Rgb(77, 82, 107),
        "target" or "quadrant" => Rgb(0, 158, 115),                    // Okabe–Ito green
        _ => Rgb(142, 142, 147),                                       // gray: arena, chamber, cup, object …
    };

    private static Windows.UI.Color HandleColor(string kind) => kind switch
    {
        "open" or "marker" => Rgb(0, 200, 230),     // cyan
        "divider" => Rgb(175, 82, 222),             // purple
        _ => Rgb(255, 214, 10),                     // yellow: the arena's own points
    };

    private static Windows.UI.Color Rgb(byte r, byte g, byte b) => Windows.UI.Color.FromArgb(255, r, g, b);

    private static Windows.UI.Color WithAlpha(Windows.UI.Color c, byte a) => Windows.UI.Color.FromArgb(a, c.R, c.G, c.B);

    private static SolidColorBrush Brush(Windows.UI.Color c) => new(c);

    /// <summary>Everything drawn over the frame, rebuilt from the engine's view of the setup.</summary>
    private void DrawOverlay()
    {
        Overlay.Children.Clear();
        double w = FrameHost.Width, h = FrameHost.Height;
        if (double.IsNaN(w) || w <= 0 || double.IsNaN(h) || h <= 0) return;
        Overlay.Width = w;
        Overlay.Height = h;
        if (_model.View is not { } view) return;

        Point At(double x, double y) => new(x * w, y * h);

        // The region the model will be given.
        if (view.Region is { } r && !r.IsFullFrame)
        {
            var box = new Rectangle
            {
                Width = r.W * w,
                Height = r.H * h,
                Stroke = Brush(Colors.Orange),
                StrokeThickness = 1.5,
                StrokeDashArray = new DoubleCollection { 5, 4 },
                IsHitTestVisible = false,
            };
            Canvas.SetLeft(box, r.X * w);
            Canvas.SetTop(box, r.Y * h);
            Overlay.Children.Add(box);
            AddLabel(AppText.L("Recognition region", "识别区域"), At(r.X, r.Y), Colors.Orange, centred: false);
        }

        // The task's zones, as the analysis counts them.
        foreach (var zone in view.Zones)
        {
            var polygon = new Polygon
            {
                Stroke = Brush(ZoneColor(zone.Role)),
                StrokeThickness = zone.OutlineOnly ? 1 : 1.5,
                IsHitTestVisible = false,
            };
            foreach (var point in zone.Outline)
            {
                if (point is [double x, double y]) polygon.Points.Add(At(x, y));
            }
            if (polygon.Points.Count < 3) continue;
            if (zone.OutlineOnly) polygon.StrokeDashArray = new DoubleCollection { 4, 3 };
            else if (zone.Role != "hole") polygon.Fill = Brush(WithAlpha(ZoneColor(zone.Role), 46));
            Overlay.Children.Add(polygon);
            if (zone.ShowsLabel && zone.Title.Length > 0 && zone.Center is [double cx, double cy])
                AddLabel(zone.Title, At(cx, cy), Colors.White, centred: true);
        }

        DrawArenaOutline(At);

        // Handles last, so they are on top and receive the pointer first.
        foreach (var handle in view.Handles)
        {
            if (handle.X is not { } hx || handle.Y is not { } hy) continue;
            var element = MakeHandle(handle);
            Canvas.SetLeft(element, hx * w - HandleSize / 2);
            Canvas.SetTop(element, hy * h - HandleSize / 2);
            Overlay.Children.Add(element);
        }
    }

    /// <summary>The calibrated arena itself, dashed yellow (PoseCalibrationCanvas.drawOverlay).</summary>
    private void DrawArenaOutline(Func<double, double, Point> at)
    {
        var yellow = Brush(Rgb(255, 214, 10));
        var dash = new DoubleCollection { 7, 5 };
        var cal = _model.Calibration;
        switch (cal.Kind)
        {
            case ArenaKind.Rectangle:
            {
                var outline = new Polygon { Stroke = yellow, StrokeThickness = 2, StrokeDashArray = dash, IsHitTestVisible = false };
                foreach (var c in cal.Corners) outline.Points.Add(at(c.X, c.Y));
                Overlay.Children.Add(outline);
                break;
            }
            case ArenaKind.Circle:
            {
                var c = at(cal.CircleCenter.X, cal.CircleCenter.Y);
                var e = at(cal.CircleEdge.X, cal.CircleEdge.Y);
                double radius = Math.Sqrt((e.X - c.X) * (e.X - c.X) + (e.Y - c.Y) * (e.Y - c.Y));
                var ring = new Ellipse
                {
                    Width = 2 * radius, Height = 2 * radius,
                    Stroke = yellow, StrokeThickness = 2, StrokeDashArray = dash, IsHitTestVisible = false,
                };
                Canvas.SetLeft(ring, c.X - radius);
                Canvas.SetTop(ring, c.Y - radius);
                Overlay.Children.Add(ring);
                Overlay.Children.Add(new Line
                {
                    X1 = c.X, Y1 = c.Y, X2 = e.X, Y2 = e.Y,
                    Stroke = yellow, StrokeThickness = 1.5, Opacity = 0.7, IsHitTestVisible = false,
                });
                break;
            }
            case ArenaKind.PlusMaze or ArenaKind.YMaze or ArenaKind.TMaze when cal.MazePoints.Length > 1:
            {
                var c = at(cal.MazePoints[0].X, cal.MazePoints[0].Y);
                foreach (var p in cal.MazePoints.Skip(1))
                {
                    var end = at(p.X, p.Y);
                    Overlay.Children.Add(new Line
                    {
                        X1 = c.X, Y1 = c.Y, X2 = end.X, Y2 = end.Y,
                        Stroke = yellow, StrokeThickness = 2, StrokeDashArray = dash, IsHitTestVisible = false,
                    });
                }
                break;
            }
        }
    }

    private void AddLabel(string text, Point at, Windows.UI.Color color, bool centred)
    {
        var label = new Border
        {
            Background = Brush(Windows.UI.Color.FromArgb(150, 0, 0, 0)),
            CornerRadius = new CornerRadius(3),
            Padding = new Thickness(4, 1, 4, 1),
            IsHitTestVisible = false,
            Child = new TextBlock { Text = text, FontSize = 11, Foreground = Brush(color) },
        };
        label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var size = label.DesiredSize;
        Canvas.SetLeft(label, centred ? at.X - size.Width / 2 : at.X + 2);
        Canvas.SetTop(label, centred ? at.Y - size.Height / 2 : at.Y + 2);
        Overlay.Children.Add(label);
    }

    private FrameworkElement MakeHandle(HandleInfo handle)
    {
        var grid = new Grid { Width = HandleSize, Height = HandleSize, Tag = handle.Id };
        grid.Children.Add(new Ellipse
        {
            Fill = Brush(HandleColor(handle.Kind)),
            Stroke = Brush(Windows.UI.Color.FromArgb(220, 0, 0, 0)),
            StrokeThickness = 1.5,
        });
        grid.Children.Add(new TextBlock
        {
            Text = handle.Label,
            FontSize = 11,
            FontWeight = FontWeights.Bold,
            Foreground = Brush(Colors.Black),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
        });
        ToolTipService.SetToolTip(grid, handle.Title.Length > 0 ? $"{handle.Label} — {handle.Title}" : handle.Label);
        grid.PointerPressed += HandlePressed;
        return grid;
    }

    private void HandlePressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id }) return;
        _dragging = id;
        // The overlay holds the capture: it survives the handles being redrawn during the drag.
        Overlay.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OverlayPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging is null || FrameHost.Width <= 0 || FrameHost.Height <= 0) return;
        var p = e.GetCurrentPoint(Overlay).Position;
        _model.MoveHandle(_dragging, p.X / FrameHost.Width, p.Y / FrameHost.Height);
        e.Handled = true;
    }

    private void OverlayPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_dragging is null) return;
        _dragging = null;
        Overlay.ReleasePointerCaptures();
        e.Handled = true;
    }

    // ---------------------------------------------------------------- controls

    /// <summary>The open session's video has moved: point the session at it again (its setup is kept).</summary>
    private async void PickVideo(object sender, RoutedEventArgs e)
    {
        if (_model.Current is null) return;
        var picker = new FileOpenPicker();
        foreach (var extension in VideoExtensions) picker.FileTypeFilter.Add(extension);
        // An unpackaged app has to tell the picker which window it belongs to.
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        StatusLabel.Text = AppText.L("Reading the frame times…", "正在读取逐帧时间…");
        try
        {
            string path = file.Path;
            var tools = _settings.Tools;
            // ffprobe and the frame grab off the window's thread; the model changes back on it.
            var (info, frame) = await Task.Run(() => MainViewModel.LoadVideo(path, tools));
            _videoCache[path] = (info, frame);
            _model.RelinkVideo(info, frame);
            _store.Save();
        }
        catch (Exception ex)
        {
            StatusLabel.Text = ex.Message;
        }
    }

    private static readonly string[] VideoExtensions = [".mp4", ".mov", ".m4v", ".avi", ".mkv"];

    private void TaskChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0) return;
        if (TaskBox.SelectedItem is ParadigmInfo paradigm) _model.SelectedTask = paradigm;
    }

    private void PhaseChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0) return;
        if (PhaseBox.SelectedItem is PhaseOption phase) _model.Phase = phase.Key;
    }

    private void PhaseTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_quiet == 0) _model.Phase = PhaseText.Text;
    }

    private void CoatChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0) return;
        if (CoatBox.SelectedItem is ComboBoxItem { Tag: string tag }
            && Enum.TryParse<CoatColor>(tag, out var coat))
            _model.Coat = coat;
    }

    private void ArenaChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0) return;
        if (ArenaBox.SelectedItem is ComboBoxItem { Tag: ArenaKind kind }) _model.ChangeArena(kind);
    }

    private void DimensionChanged(NumberBox sender, NumberBoxValueChangedEventArgs e)
    {
        if (_quiet > 0 || double.IsNaN(e.NewValue)) return;
        _model.SetDimension(first: sender == DimABox, e.NewValue);
    }

    private void AnimalsChanged(NumberBox sender, NumberBoxValueChangedEventArgs e)
    {
        if (_quiet > 0 || double.IsNaN(e.NewValue)) return;
        _model.AnimalCount = (int)e.NewValue;
    }

    private void RangeChanged(NumberBox sender, NumberBoxValueChangedEventArgs e)
    {
        if (_quiet > 0 || double.IsNaN(e.NewValue)) return;
        if (sender == ToBox) _model.ToSeconds = e.NewValue;
        else _model.Stride = (int)e.NewValue;
    }

    private void SubjectChanged(object sender, TextChangedEventArgs e)
    {
        if (_quiet == 0) _model.Subject = SubjectBox.Text;
    }

    private void GroupChanged(object sender, TextChangedEventArgs e)
    {
        if (_quiet == 0) _model.Group = GroupBox.Text;
    }

    private void FillFrame(object sender, RoutedEventArgs e) => _model.FillFrame();

    private void ResetPositions(object sender, RoutedEventArgs e) => _model.ResetPositions();

    private async void Start(object sender, RoutedEventArgs e)
    {
        await _model.RunAsync(ToUi);
        // As on the Mac, a finished analysis opens its results.
        if (_model.Report is not null && !_model.Busy) ShowStep(Step.Results);
    }

    private void Stop(object sender, RoutedEventArgs e)
    {
        // Stops the session being analysed, and the queue after it.
        _batchStop = true;
        _model.Stop();
    }

    private async void MakeReviewVideo(object sender, RoutedEventArgs e)
    {
        AnnotateButton.IsEnabled = false;
        try
        {
            string output = await _model.WriteAnnotatedVideoAsync(ToUi);
            Reveal(output);
        }
        catch (Exception ex)
        {
            StatusLabel.Text = ex.Message;
        }
        finally
        {
            Refresh();
        }
    }

    private void OpenResultFolder(object sender, RoutedEventArgs e)
    {
        if (_model.ResultFolder is { } folder) Reveal(folder);
    }

    // ---------------------------------------------------------------- results

    /// <summary>The session's steps, as on the Mac: Session info → Calibrate → Results.</summary>
    private enum Step { Info, Calibrate, Results, Review }

    /// <summary>A step was chosen (SelectorBar); every pane stays in the tree, only one is visible.</summary>
    private void StepChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (_quiet > 0) return;
        var step = ReferenceEquals(sender.SelectedItem, ResultsStep) ? Step.Results
                 : ReferenceEquals(sender.SelectedItem, InfoStep) ? Step.Info
                 : ReferenceEquals(sender.SelectedItem, ReviewStep) ? Step.Review
                 : Step.Calibrate;
        ShowStep(step);
        // As on the Mac: coming to the results with a changed setup recomputes them (no new tracking).
        if (step == Step.Results && _model.ResultsStale && _model.CanUpdate) _ = UpdateResultsAsync();
    }

    private void ShowStep(Step step)
    {
        InfoPane.Visibility = step == Step.Info ? Visibility.Visible : Visibility.Collapsed;
        CalibratePane.Visibility = step == Step.Calibrate ? Visibility.Visible : Visibility.Collapsed;
        ResultsPane.Visibility = step == Step.Results ? Visibility.Visible : Visibility.Collapsed;
        ReviewPane.Visibility = step == Step.Review ? Visibility.Visible : Visibility.Collapsed;
        if (step == Step.Review) EnterReview();
        else LeaveReview();
        SelectorBarItem item = step switch
        {
            Step.Info => InfoStep, Step.Results => ResultsStep, Step.Review => ReviewStep, _ => CalibrateStep,
        };
        if (!ReferenceEquals(StepBar.SelectedItem, item))
        {
            _quiet++;
            try { StepBar.SelectedItem = item; }
            finally { _quiet--; }
        }
    }

    /// <summary>Draws the model's report on the result page (again, with <paramref name="force"/>).</summary>
    private void ShowResults(bool force)
    {
        var report = _model.Report;
        if (!force && ReferenceEquals(report, _shownReport)) return;
        _shownReport = report;
        bool dark = Root.ActualTheme == ElementTheme.Dark;
        var theme = FigureTheme.For(dark);
        ResultsScroll.Background = new SolidColorBrush(RodentFlow.App.Figures.Win2DCanvas.ToColor(theme.Background));
        if (report is null)
        {
            _results.Clear();
            return;
        }
        try
        {
            _results.Show(new ReportPresenter.Context
            {
                Report = report,
                Backdrop = _model.Backdrop,
                Dark = dark,
                EnglishReport = _model.EnglishReportAsync,
                WindowHandle = () => WinRT.Interop.WindowNative.GetWindowHandle(this),
                Message = message => StatusLabel.Text = message,
                Notice = _model.RegionOutdated
                    ? AppText.L("The arena calibration now reaches outside the region that was tracked; animals there were not detected. Analyse the video again (calibration and parameters are kept).",
                                "场地标定已超出上次识别的区域，区域外的小鼠没有被识别。请重新分析该视频（标定和参数保留）。")
                    : null,
            });
        }
        catch (Exception e)
        {
            // The window stays usable; the page says what went wrong.
            _results.Clear();
            StatusLabel.Text = AppText.L("The result page could not be drawn: ", "结果页无法显示：") + e.Message;
        }
    }

    private async Task UpdateResultsAsync()
    {
        await _model.UpdateResultsAsync();
        ShowResults(force: true);
    }

    private async void UpdateResults(object sender, RoutedEventArgs e)
    {
        ShowStep(Step.Results);
        await UpdateResultsAsync();
    }

    /// <summary>
    /// A run folder made earlier becomes a session of the workspace (in the selected task when it is the same
    /// paradigm); it opens with its results recomputed from its tracking.
    /// </summary>
    private async void OpenAnalysedFolder(object sender, RoutedEventArgs e)
    {
        if (!CanLeaveSession()) return;
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        try
        {
            var session = _model.ImportRunFolder(folder.Path, _selectedTask);
            _store.Save();
            SelectInSidebar("task:" + session.TaskId.ToString());
            await OpenSessionAsync(session.Id);
        }
        catch (Exception ex)
        {
            StatusLabel.Text = ex.Message;
        }
    }

    /// <summary>
    /// The interface language (the Mac's language menu, here over the results): every text of the window, the parameter
    /// forms, the task list, the reports and figures switch at once.
    /// </summary>
    private async void LanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || sender is not ComboBox { SelectedItem: ComboBoxItem { Tag: string tag } }) return;
        bool chinese = tag == "zh";
        if (chinese == _settings.Chinese) return;
        _settings.Chinese = chinese;
        try { _settings.Save(); }
        catch (Exception) { /* the choice still applies for this session */ }
        AppText.Chinese = chinese;
        Tr.Reset();
        _quiet++;
        try
        {
            // The engine first (task names, phases and tips come from it), then every text of the window.
            _model.ChangeLanguage(chinese);
            LanguageBox.SelectedIndex = chinese ? 1 : 0;
        }
        finally
        {
            _quiet--;
        }
        ApplyLanguage();
        _formTask = "";
        BuildTaskControls();
        ShowMissingModels();
        _sidebarSignature = null;
        _listSignature = null;
        BuildSidebar();
        RebuildSessionList();
        if (TaskPage.Visibility == Visibility.Visible) ShowTaskPage();
        Refresh();
        if (_model.CanUpdate && _model.Report is not null) await UpdateResultsAsync();
        else ShowResults(force: true);
    }

    /// <summary>Where the model runs: automatic (the faster, timed once per model), the processor, or the graphics card.</summary>
    private void DeviceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || DeviceBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        _settings.Device = tag;
        try { _settings.Save(); }
        catch (Exception) { /* applies to this session */ }
        StatusLabel.Text = tag switch
        {
            "cpu" => AppText.L("The next analysis runs on the processor.", "下一次分析使用处理器。"),
            "gpu" => AppText.L("The next analysis runs on the graphics card when it can, otherwise on the processor.",
                               "下一次分析在可用时使用显卡，否则使用处理器。"),
            _ => AppText.L("The next analysis runs on whichever is faster for the model; the first run of each model times both.",
                           "下一次分析使用对该模型更快的设备；每个模型第一次运行时会把两者都测一遍。"),
        };
    }

    /// <summary>The window's own texts in the interface language (the Mac's L("English", "中文")).</summary>
    private void ApplyLanguage()
    {
        string L(string en, string zh) => AppText.L(en, zh);
        NewTaskButton.Content = L("New task…", "新建任务…");
        OpenRunButton.Content = L("Import an analysed folder…", "导入已分析的文件夹…");
        AddVideosButton.Content = L("Add videos…", "添加视频…");
        VideoLabelTitle.Text = L("Video", "视频");
        PickVideoButton.Content = L("Locate the video…", "重新指定视频…");
        TaskLabelTitle.Text = L("Task", "实验范式");
        PhaseBox.Header = L("Phase", "阶段");
        PhaseText.Header = L("Phase or condition label (optional)", "阶段或条件标签（可选）");
        CoatBox.Header = L("Coat colour", "毛色");
        AnimalsBox.Header = L("Animals", "小鼠只数");
        ArenaLabelTitle.Text = L("Arena", "场地");
        FillFrameButton.Content = L("Fill the frame", "铺满画面");
        ResetPositionsButton.Content = L("Reset positions", "恢复默认位置");
        CopySetupButton.Content = L("Use this setup for all sessions of the task…", "把此设置用于本任务全部实验…");
        TaskSettingsTitle.Text = L("Task settings", "范式参数");
        AnalysisWindowTitle.Text = L("Analysis window", "分析时间段");
        RecognitionTitle.Text = L("Recognition", "识别");
        ToBox.Header = L("First N seconds (0 = all)", "只识别前 N 秒（0 = 全部）");
        StrideBox.Header = L("Every Nth frame", "每 N 帧识别一帧");
        RecognitionHelp.Text = L(
            "What the model is run on. A stride above 1 analyses fewer frames, which is quicker but coarser; every measure uses only the frames that were analysed. The analysis window above only chooses which of the recognised frames are counted.",
            "交给模型识别的帧。步长大于 1 时识别的帧更少，更快但更粗；所有指标只用被识别的帧。上面的分析时间段只决定识别出的帧里哪些参与计算。");
        DeviceBox.Header = L("Run the model on", "模型运行在");
        DeviceAutoItem.Content = L("Automatic (the faster, timed once)", "自动（选更快的，只测一次）");
        DeviceCpuItem.Content = L("Processor (CPU)", "处理器（CPU）");
        DeviceGpuItem.Content = L("Graphics card (GPU)", "显卡（GPU）");
        InfoStep.Text = L("Session info", "实验信息");
        CalibrateStep.Text = L("Calibrate", "标定");
        ResultsStep.Text = L("Results", "结果");
        ReviewStep.Text = L("Review", "复核");
        SetupCheck.Title = L("Task forms do not match the engine", "范式表单与引擎不一致");
        ModelWarning.Title = L("Missing models", "缺少模型");
        SubjectBox.Header = L("Animal ID *", "小鼠编号 *");
        GroupBox.Header = L("Group", "分组");
        SexBox.Header = L("Sex", "性别");
        DateBox.Header = L("Recording date *", "实验日期 *");
        SessionNumberBox.Header = L("Session # *", "实验次数 *");
        DayBox.Header = L("Day", "天");
        TrialBox.Header = L("Trial", "试次");
        NotesBox.Header = L("Notes", "备注");
        ReviewBox.Header = L("Tracking check", "追踪核对");
        ReviewUncheckedItem.Content = L("Not checked yet", "尚未核对");
        ReviewOkItem.Content = L("Checked: the tracking is right", "已核对：追踪正确");
        ReviewProblemItem.Content = L("Checked: the tracking has problems", "已核对：追踪有问题");
        ExcludedBox.Content = L("Leave this session out of summaries", "不纳入汇总");
        ExclusionReasonBox.Header = L("Why it is left out", "排除原因");
        RemoveSessionButton.Content = L("Remove this session from the task…", "从任务中移除此实验…");
        PlaceArenaTitle.Text = L("Place the arena", "放置场地");
        ReviewTrailBox.Content = L("Trail", "轨迹");
        ReviewZonesBox.Content = L("Zones", "区域");
        SwapFromHereButton.Content = L("Swap A / B from this frame", "从此帧起交换 A / B");
        SwapRangeButton.Content = L("Swap A / B from the mark to here", "交换从标记到此处的 A / B");
        TrackingOkButton.Content = L("The tracking is right", "追踪正确");
        TrackingProblemButton.Content = L("The tracking has problems", "追踪有问题");
        SetFirstBiteButton.Content = L("Set as first bite", "设为首次进食");
        NoFeedingButton.Content = L("No feeding before the cut-off", "确认截止前未进食");
        ClearFeedingButton.Content = L("Clear", "清除");
        AnnotateButton.Content = L("Make a review video", "生成复核视频");
        OpenResults.Content = L("Open the result folder", "打开结果文件夹");
        StartButton.Content = L("Analyse", "分析");
        StopButton.Content = L("Stop", "停止");
        UpdateButton.Content = L("Update results", "更新结果");
        if (_reviewCanvas is not null) UpdateReviewControls();
    }

    private static void Reveal(string path)
    {
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = Directory.Exists(path) ? path : Path.GetDirectoryName(path) ?? path,
            UseShellExecute = true,
        });
    }

    /// <summary>Runs an action on the window's thread, from wherever the caller is.</summary>
    private void ToUi(Action action)
    {
        if (DispatcherQueue.HasThreadAccess) action();
        else DispatcherQueue.TryEnqueue(() => action());
    }
}
