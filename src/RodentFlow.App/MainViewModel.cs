using System.Globalization;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using RodentFlow.Core;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Marbles;
using RodentFlow.Core.Setup;
using RodentFlow.Core.Workspace;
using RodentFlow.Engine;
using RodentFlow.Onnx;

namespace RodentFlow.App;

/// <summary>
/// Everything the window does, kept out of the XAML: pick a video, choose a task and its phase,
/// place the arena and the task's markers, set the task's parameters, run the model, analyse, and keep
/// the report the result page shows.
/// </summary>
/// <remarks>
/// The setup — <see cref="Calibration"/> and <see cref="Params"/> — always comes from the engine:
/// a task's defaults from rf_default_setup, every later change sent back through rf_setup_view or
/// rf_move_handle, and what the engine returns is kept. So the zones drawn, the handles and the
/// numbers the analysis uses are the engine's, and a value the engine could not read is visible at
/// once instead of being silently replaced by a default in the analysis.
/// </remarks>
public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly AppSettings _settings;
    private CancellationTokenSource? _cancel;

    /// <summary>Every task and session (the Mac's WorkspaceStore).</summary>
    public WorkspaceStore Store { get; }

    public MainViewModel(AppSettings settings, WorkspaceStore store)
    {
        _settings = settings;
        Store = store;
        Engine.Engine.SetLanguage(settings.Chinese);
        Catalogue = Engine.Engine.Catalogue();
        foreach (var p in Catalogue.Paradigms) Tasks.Add(p);
        MaxGroupAnimals = Catalogue.MaxGroupAnimals;
        var version = Engine.Engine.Version();
        EngineLabel = $"{version.App} · ABI {version.Abi}";
        ReviewModels();
        CheckForms();
        SelectedTask = Tasks.FirstOrDefault(t => t.Id == "open_field") ?? Tasks.FirstOrDefault();
    }

    public Catalogue Catalogue { get; private set; }

    /// <summary>
    /// The interface language changed (the Mac's language menu): the engine answers in it from now on, and the task
    /// list — names, phases, tips, marker titles, which come from the engine's catalogue — is read again in it. The
    /// selected task stays selected; nothing about the open session changes.
    /// </summary>
    public void ChangeLanguage(bool chinese)
    {
        Engine.Engine.SetLanguage(chinese);
        Catalogue = Engine.Engine.Catalogue();
        string selected = TaskId;
        Tasks.Clear();
        foreach (var t in Catalogue.Paradigms) Tasks.Add(t);
        _selectedTask = Tasks.FirstOrDefault(t => t.Id == selected) ?? _selectedTask;
        Notify(nameof(SelectedTask));
        RefreshView();
        Notify(nameof(Dimensions));
        Notify(nameof(InfoProblems));
        Notify(nameof(ResultsState));
    }
    public ObservableCollection<ParadigmInfo> Tasks { get; } = [];
    public ObservableCollection<string> MissingModels { get; } = [];

    /// <summary>Form keys the engine does not know (a form typo or an engine change), task by task.</summary>
    public List<string> SetupProblems { get; } = [];

    public int MaxGroupAnimals { get; }
    public string EngineLabel { get; } = "";

    // ---------------------------------------------------------------- the video

    private string? _videoPath;
    public string? VideoPath
    {
        get => _videoPath;
        private set { Set(ref _videoPath, value); Notify(nameof(CanStart)); }
    }

    private VideoInfo? _video;
    public VideoInfo? Video
    {
        get => _video;
        private set { Set(ref _video, value); Notify(nameof(VideoLabel)); Notify(nameof(FrameAspect)); }
    }

    public string VideoLabel => Video is null
        ? AppText.L("No video chosen", "未选择视频")
        : $"{Path.GetFileName(Video.Path)}\n{Video.Width} × {Video.Height} · {Video.Duration:F1} s · "
          + Video.FrameTimes.Count + AppText.L(" frames", " 帧");

    /// <summary>Width ÷ height of the upright frame, for sizing the calibration view.</summary>
    public double FrameAspect => Video is { Width: > 0, Height: > 0 } v ? (double)v.Width / v.Height : 4.0 / 3.0;

    /// <summary>The frame size the setup is laid out for: the video's, or a placeholder before one is open.</summary>
    private (double W, double H) FrameSize => Video is { Width: > 0, Height: > 0 } v ? (v.Width, v.Height) : (1280, 960);

    private VideoFrameGrabber.Frame? _previewFrame;
    public VideoFrameGrabber.Frame? PreviewFrame
    {
        get => _previewFrame;
        private set { _previewFrame = value; _backdrop = null; Notify(nameof(PreviewFrame)); }
    }

    private FigureImage? _backdrop;

    /// <summary>
    /// The calibration frame behind arena figures (heat map on / next to the original picture), as the
    /// Mac uses the session's calibration frame. Null without a video.
    /// </summary>
    public FigureImage? Backdrop
    {
        get
        {
            if (_backdrop is null && PreviewFrame is { } f)
            {
                try { _backdrop = new FigureImage(f.Pixels, f.Width, f.Height, f.RowBytes); }
                catch (ArgumentException) { _backdrop = null; }
            }
            return _backdrop;
        }
    }

    // ---------------------------------------------------------------- the task

    private ParadigmInfo? _selectedTask;
    public ParadigmInfo? SelectedTask
    {
        get => _selectedTask;
        set
        {
            if (value is null || !Set(ref _selectedTask, value)) return;
            // A new task starts from its own defaults: phase, arena shape, size, markers, parameters.
            _phase = value.DefaultPhase;
            _coat = ValidCoat(_coat, value);
            Notify(nameof(Coat));
            ApplyDefaults(value.DefaultArena, keepParams: false);
            Notify(nameof(Phase));
            Notify(nameof(AnimalCountIsEditable));
            Notify(nameof(AnimalCount));
            Notify(nameof(CanStart));
        }
    }

    public string TaskId => SelectedTask?.Id ?? "";

    private string _phase = "";
    /// <summary>The phase key (English, as the engine stores it), or the researcher's own label.</summary>
    public string Phase
    {
        get => _phase;
        set
        {
            if (!Set(ref _phase, value?.Trim() ?? "")) return;
            RefreshView();   // zones and rows can depend on the phase
            Touch();
        }
    }

    /// <summary>Only a group task lets the user choose; every other task fixes the number.</summary>
    public bool AnimalCountIsEditable => SelectedTask?.IsGroup == true;

    private int _groupAnimals = 4;
    public int AnimalCount
    {
        get => SelectedTask?.IsGroup == true ? _groupAnimals : SelectedTask?.AnimalCount ?? 1;
        set
        {
            if (SelectedTask?.IsGroup == true && Set(ref _groupAnimals, Math.Clamp(value, 3, MaxGroupAnimals)))
            {
                RefreshPlan();
                Touch();
            }
        }
    }

    private CoatColor _coat = CoatColor.Dark;
    public CoatColor Coat
    {
        get => _coat;
        set { if (Set(ref _coat, value)) { RefreshPlan(); Touch(); } }
    }

    private string _subject = "", _group = "";
    /// <summary>The animal ID; in the workspace it is the session's (group and sex follow the animal).</summary>
    public string Subject
    {
        get => _subject;
        set
        {
            if (!Set(ref _subject, value ?? "")) return;
            if (_current is not { } s) return;
            s.AnimalId = _subject.Trim();
            // An animal that already has sessions in this task brings its group and sex (ImportVideosSheet).
            if (Store.AnimalAttributes(s.TaskId, s.AnimalKey, s.Id) is { } known)
            {
                s.Group = known.Group;
                s.Sex = known.Sex;
                _group = known.Group;
                Notify(nameof(Group));
            }
            Store.MarkChanged();
            Notify(nameof(InfoProblems));
        }
    }

    /// <summary>The group; it belongs to the animal, so every session of the animal in the task changes with it.</summary>
    public string Group
    {
        get => _group;
        set
        {
            if (!Set(ref _group, value ?? "")) return;
            if (_current is { } s) Store.SetAnimalAttributes(s.TaskId, s.AnimalKey, _group, null);
        }
    }

    private int _stride = 1;
    public int Stride
    {
        get => _stride;
        set { if (Set(ref _stride, Math.Max(1, value))) { RefreshPlan(); Touch(); } }
    }

    private double _toSeconds;
    /// <summary>Recognise only the first N seconds; 0 = the whole video.</summary>
    public double ToSeconds
    {
        get => _toSeconds;
        set { if (Set(ref _toSeconds, Math.Max(0, value))) { RefreshPlan(); Touch(); } }
    }

    // ---------------------------------------------------------------- the setup

    /// <summary>The arena in the picture and the task's markers, as the engine last returned it.</summary>
    public ArenaCalibration Calibration { get; private set; } = new();

    /// <summary>The task's complete AnalysisParams, as the engine last returned them. Never partial.</summary>
    public JsonObject Params { get; private set; } = new();

    /// <summary>Zones, handles and tracked region for the current setup; null before a video is open.</summary>
    private SetupView? _view;
    public SetupView? View
    {
        get => _view;
        private set { _view = value; Notify(nameof(View)); Notify(nameof(ScaleLabel)); }
    }

    public ArenaKind Arena => Calibration.Kind;

    public FormContext FormContext => new(Phase, Params);

    /// <summary>A different arena shape: the task's default layout for it, keeping the parameters.</summary>
    public void ChangeArena(ArenaKind kind)
    {
        if (kind == Calibration.Kind) return;
        ApplyDefaults(kind, keepParams: true);
        Touch();
    }

    /// <summary>The handles back to the task's default places (PoseCalibrationEditor.resetCalibration).</summary>
    public void ResetPositions()
    {
        ApplyDefaults(Calibration.Kind, keepParams: true);
        Touch();
    }

    /// <summary>Rectangle corners on the frame corners — when the arena fills the picture.</summary>
    public void FillFrame()
    {
        if (Calibration.Kind != ArenaKind.Rectangle) return;
        Calibration = Calibration with { Corners = [new(0, 0), new(1, 0), new(1, 1), new(0, 1)] };
        RefreshView();
        Touch();
    }

    /// <summary>
    /// The two size fields of the current arena shape: their titles (null = not shown) and values.
    /// Copied from the Mac's dimensionsCard: a zero maze is a circle with a track width; the mazes
    /// are sized by arm length and width.
    /// </summary>
    public (string? A, string? B, double ValueA, double ValueB) Dimensions => Calibration.Kind switch
    {
        ArenaKind.Rectangle => (AppText.L("Width (1 → 2), cm", "宽（1 → 2），cm"), AppText.L("Height (2 → 3), cm", "高（2 → 3），cm"),
                                Calibration.WidthCM, Calibration.HeightCM),
        ArenaKind.Circle when TaskId == "elevated_zero_maze" =>
            (AppText.L("Outer diameter, cm", "外径，cm"), AppText.L("Track width, cm", "跑道宽，cm"), Calibration.DiameterCM, Calibration.RingWidthCM),
        ArenaKind.Circle => (AppText.L("Diameter, cm", "直径，cm"), null, Calibration.DiameterCM, 0),
        ArenaKind.PlusMaze or ArenaKind.YMaze or ArenaKind.TMaze =>
            (AppText.L("Arm length (excluding center), cm", "臂长（不含中央区），cm"), AppText.L("Arm width, cm", "臂宽，cm"),
             Calibration.ArmLengthCM, Calibration.ArmWidthCM),
        _ => (null, null, 0, 0),
    };

    public void SetDimension(bool first, double value)
    {
        if (!double.IsFinite(value) || value <= 0) return;
        Calibration = (Calibration.Kind, first) switch
        {
            (ArenaKind.Rectangle, true) => Calibration with { WidthCM = value },
            (ArenaKind.Rectangle, false) => Calibration with { HeightCM = value },
            (ArenaKind.Circle, true) => Calibration with { DiameterCM = value },
            (ArenaKind.Circle, false) => Calibration with { RingWidthCM = value },
            (_, true) => Calibration with { ArmLengthCM = value },
            (_, false) => Calibration with { ArmWidthCM = value },
        };
        RefreshView();
        Touch();
    }

    /// <summary>One handle dragged to a normalized point. The engine applies the drag rules.</summary>
    public void MoveHandle(string handle, double x, double y)
    {
        if (Video is null) return;
        try
        {
            var (w, h) = FrameSize;
            Adopt(Engine.Engine.MoveHandle(new MoveHandleRequest
            {
                Session = SetupSession(), FrameWidth = w, FrameHeight = h, Handle = handle, X = x, Y = y,
            }), sent: null);
            RefreshPlan();   // the tracked region follows the arena
            Touch();
        }
        catch (Exception e)
        {
            Status = e.Message;
        }
    }

    /// <summary>Changes parameters (a form row), then asks the engine to read them back.</summary>
    public void EditParams(Action<JsonObject> edit)
    {
        edit(Params);
        RefreshView();
        Touch();
    }

    /// <summary>Scale the calibration implies, so a wrong arena shows up as an implausible scale.</summary>
    public string ScaleLabel => View switch
    {
        null => "",
        { IsMetric: false } => AppText.L("Not calibrated: distances and speeds will be in pixels.", "未标定：距离和速度将以像素为单位。"),
        { PixelsPerCM: { } ppcm } when ppcm > 0 => string.Format(AppText.L("Scale ≈ {0:F1} pixels per cm ({1:F2} mm per pixel)",
                                                                             "比例 ≈ 每厘米 {0:F1} 像素（每像素 {1:F2} mm）"), ppcm, 10 / ppcm),
        _ => AppText.L("The handles do not describe an arena yet.", "手柄还没有构成一个场地。"),
    };

    /// <summary>What the handles are for, by arena shape (PoseCalibrationEditor.hint).</summary>
    public string ArenaHint => Calibration.Kind switch
    {
        // The Mac's own wording in both languages (PoseCalibrationEditor.hint).
        ArenaKind.None => AppText.L("Without calibration, coordinates, distance and speed are measured in pixels.",
                                    "不标定时，坐标、距离和速度以像素为单位。"),
        ArenaKind.Rectangle when TaskId == "three_chamber" => AppText.L(
            "Align yellow handles 1–4 to the arena corners. Drag purple L/R handles to set the center-chamber dividers independently; cyan L/R move the cups.",
            "黄色 1–4 对齐场地内壁四角；紫色 L/R 分别拖动中箱左右分隔线；青色 L/R 移动杯子。"),
        ArenaKind.Rectangle => AppText.L("Drag yellow handles 1–4 to the arena's inside corners (top-left, top-right, bottom-right, bottom-left).",
                                         "拖动黄色手柄 1–4 对齐场地内壁四角（左上、右上、右下、左下）。"),
        ArenaKind.Circle => AppText.L("Place C at the circle center (drag to move together) and R on the arena's inner edge.",
                                      "C 对准圆心（拖动整体移动），R 拖到场地内缘。"),
        ArenaKind.PlusMaze => AppText.L("Place C at the center and N / E / S / W at the arm tips; cyan denotes open arms.",
                                        "C 对准中央，N / E / S / W 拖到四个臂的末端；青色为开放臂。"),
        ArenaKind.YMaze => AppText.L("Place J at the three-arm junction and A / B / C at the arm tips.",
                                     "J 对准三臂交汇中心，A / B / C 拖到三个臂的末端。"),
        ArenaKind.TMaze => AppText.L("Place J at the choice point, S at the start arm, and L / R at left and right arm tips.",
                                     "J 对准选择点，S 为起始臂末端，L / R 为左右臂末端。"),
        _ => "",
    };

    /// <summary>Cyan marker handles in use and what each is (handleLegend).</summary>
    public string MarkerLegend => View is null
        ? ""
        : string.Join("   ", View.Handles.Where(h => h.Kind == "marker").Select(h => $"{h.Label} = {h.Title}"));

    private void ApplyDefaults(ArenaKind kind, bool keepParams)
    {
        if (SelectedTask is null) return;
        try
        {
            var (w, h) = FrameSize;
            var d = Engine.Engine.DefaultSetup(new DefaultSetupRequest
            {
                Paradigm = SelectedTask.Id,
                Arena = kind,
                FrameWidth = w,
                FrameHeight = h,
                Params = keepParams ? (JsonObject)Params.DeepClone() : null,
            });
            Calibration = d.Calibration;
            Params = d.Params;
        }
        catch (Exception e)
        {
            Status = e.Message;
        }
        RefreshView();
    }

    /// <summary>Sends the setup to the engine and keeps what it read back.</summary>
    private void RefreshView()
    {
        Notify(nameof(Calibration));
        Notify(nameof(Params));
        if (Video is null || SelectedTask is null)
        {
            View = null;
            RefreshPlan();
            return;
        }
        try
        {
            var sent = (JsonObject)Params.DeepClone();
            var (w, h) = FrameSize;
            Adopt(Engine.Engine.SetupView(new SetupViewRequest
            {
                Session = SetupSession(), FrameWidth = w, FrameHeight = h,
            }), sent);
        }
        catch (Exception e)
        {
            View = null;
            Status = e.Message;
        }
        RefreshPlan();
    }

    private void Adopt(SetupView view, JsonObject? sent)
    {
        Calibration = view.Calibration;
        Params = view.Params;
        View = view;
        Notify(nameof(Calibration));
        Notify(nameof(Params));
        Notify(nameof(MarkerLegend));
        if (sent is not null)
        {
            var refused = ParamValues.Differences(sent, view.Params);
            if (refused.Count > 0)
                Status = string.Format(AppText.L("The engine did not accept {0}; the value it will use is shown instead.",
                                                 "引擎没有接受 {0}；显示的是它实际使用的值。"), string.Join(", ", refused));
        }
    }

    /// <summary>The parts of a session the setup calls look at.</summary>
    private Session SetupSession() => new()
    {
        Paradigm = TaskId,
        Phase = Phase,
        Calibration = Calibration,
        Params = (JsonObject)Params.DeepClone(),
        Inference = BuildSettings(),
    };

    // ---------------------------------------------------------------- running

    private bool _busy;
    public bool Busy
    {
        get => _busy;
        private set { Set(ref _busy, value); Notify(nameof(CanStart)); Notify(nameof(CanStop)); Notify(nameof(CanUpdate)); }
    }

    public bool CanStart => !Busy && !ResultsUpdating && VideoPath is not null && SelectedTask is not null;
    public bool CanStop => Busy;

    private double _progress;
    public double Progress { get => _progress; private set => Set(ref _progress, value); }

    private string _status = AppText.L("Create a task and add its videos to start.", "新建任务并添加视频即可开始。");
    public string Status { get => _status; private set => Set(ref _status, value); }

    private string? _runFolder;
    public string? RunFolder { get => _runFolder; private set => Set(ref _runFolder, value); }

    private string? _resultFolder;
    public string? ResultFolder
    {
        get => _resultFolder;
        private set { Set(ref _resultFolder, value); Notify(nameof(HasResults)); }
    }
    public bool HasResults => ResultFolder is not null;

    /// <summary>The engine's run plan for the current settings: model, region, decode size.</summary>
    private RunPlan? _plan;
    public RunPlan? Plan
    {
        get => _plan;
        private set { Set(ref _plan, value); Notify(nameof(PlanLabel)); }
    }

    public string PlanLabel => Plan is null
        ? ""
        : $"{Plan.ModelName} · region {Plan.Crop.Width} × {Plan.Crop.Height} px"
          + (Plan.DecodeScale is null ? "" : $" · decoding at {Plan.DecodeWidth} × {Plan.DecodeHeight}");

    // ---------------------------------------------------------------- actions

    /// <summary>
    /// The slow half of opening a video: every frame time from ffprobe, and one decoded frame to
    /// place the arena on. Static and touching no state, so it is safe off the window's thread.
    /// </summary>
    public static (VideoInfo Info, VideoFrameGrabber.Frame Frame) LoadVideo(string path, FFmpegTools tools)
    {
        // Saved probes are used while the file is unchanged: listing every frame time again takes seconds.
        var info = VideoProbeCache.Probe(path, tools);
        return (info, VideoFrameGrabber.GrabForCalibration(info, tools));
    }

    /// <summary>
    /// The quick half: makes a loaded video the current one. Every property set here raises
    /// PropertyChanged, which the window answers by touching its controls — and WinUI controls
    /// may only be touched from the window's own thread. So this must run there, never inside
    /// Task.Run. (It used to: the first property set threw RPC_E_WRONG_THREAD, and the video
    /// looked as if it had never been chosen.)
    /// </summary>
    public void ShowVideo(string path, VideoInfo info, VideoFrameGrabber.Frame frame)
    {
        Video = info;
        VideoPath = path;
        PreviewFrame = frame;
        ForgetRun();
        Progress = 0;
        Status = info.FrameTimes.Count > 0
            ? AppText.L("Place the arena and the markers on the picture, then analyse.", "在画面上放好场地和标记后再分析。")
            : AppText.L("This file reports no frame times, so it cannot be analysed.", "这个文件没有逐帧时间，无法分析。");
        // The default handles are laid out for the frame's size; the parameters stay as set.
        ApplyDefaults(Calibration.Kind, keepParams: true);
    }

    /// <summary>Asks the engine what the current settings would use. Cheap; call after any change.</summary>
    public void RefreshPlan()
    {
        if (Video is null) { Plan = null; return; }
        try
        {
            Plan = Engine.Engine.PlanRun(new RunPlanRequest
            {
                Settings = BuildSettings(),
                Calibration = Calibration,
                FrameWidth = Video.Width,
                FrameHeight = Video.Height,
            });
        }
        catch (Exception e)
        {
            Plan = null;
            Status = e.Message;
        }
        UpdateRegionOutdated();
    }

    /// <summary>Which pose models are missing, so the window can say so before a run starts.</summary>
    public void ReviewModels()
    {
        MissingModels.Clear();
        var library = new OnnxModelLibrary(_settings.ModelsFolder);
        foreach (var (name, file) in library.Survey(Engine.Engine.Version().Models))
            if (file is null) MissingModels.Add(name);
    }

    /// <summary>Every form key must be a parameter the engine has for that task.</summary>
    private void CheckForms()
    {
        foreach (var task in Tasks)
        {
            try
            {
                var d = Engine.Engine.DefaultSetup(new DefaultSetupRequest
                {
                    Paradigm = task.Id, FrameWidth = 1280, FrameHeight = 960,
                });
                foreach (var key in AssayForms.UnknownKeys(task.Id, d.Params))
                    SetupProblems.Add($"{task.EnglishName}: the engine has no parameter \"{key}\"");
            }
            catch (Exception e)
            {
                SetupProblems.Add($"{task.EnglishName}: {e.Message}");
            }
        }
    }

    /// <summary>
    /// Tracks the video and analyses the result. Runs on a worker thread; <paramref name="toUi"/>
    /// marshals the progress callbacks onto the window's thread.
    /// </summary>
    /// <remarks>
    /// In the workspace a session's runs live in its own folder (run1, run2 …). A paused or failed run is
    /// continued where it stopped, as on the Mac; if its settings no longer match (another model or region),
    /// the engine refuses it and the run starts afresh in a new folder — the old one is kept.
    /// </remarks>
    public async Task RunAsync(Action<Action> toUi)
    {
        if (VideoPath is null || SelectedTask is null || Video is null) return;
        _cancel = new CancellationTokenSource();
        Busy = true;
        var current = _current;
        ForgetRun();
        Progress = 0;
        Status = AppText.L("Starting", "正在开始");
        using var awake = KeepAwake.Begin();

        // Built here, on the window's thread: the worker gets its own copy of the setup.
        var session = BuildSession();
        string key = SetupKey();
        if (current is not null)
        {
            // Analysing a session confirms its setup.
            _touched = true;
            PersistSetup(force: true);
        }
        string folder = current is not null
            ? Store.RunFolderForAnalysis(current, _settings.WorkFolder)
            : Path.Combine(_settings.WorkFolder, $"{Path.GetFileNameWithoutExtension(VideoPath)}_{DateTime.Now:yyyyMMdd_HHmmss}");

        try
        {
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    await RunInto(folder, session, key, current, toUi);
                    break;
                }
                catch (RodentFlowException e) when (attempt == 0 && current is not null
                                                    && e.Message.Contains("belongs to another video, model or tracking setting"))
                {
                    folder = Store.RunFolderForAnalysis(current, _settings.WorkFolder, continueIfPossible: false);
                    toUi(() => Status = AppText.L("The paused run was made with other settings; starting a new run (the old one is kept).",
                                                  "暂停的那次运行用的是另一套设置，重新开始一次新的运行（旧的保留）。"));
                }
            }
        }
        catch (OperationCanceledException)
        {
            if (current is not null) current.RunState = Core.Workspace.RunState.Partial;
            toUi(() => Status = AppText.L("Stopped. The frames analysed so far are kept — start again to continue.",
                                          "已停止。已分析的帧都保留，再次开始即从这里继续。"));
        }
        catch (Exception e)
        {
            if (current is not null)
            {
                current.RunState = Core.Workspace.RunState.Failed;
                current.RunMessage = e.Message;
            }
            toUi(() => Status = e.Message);
        }
        finally
        {
            Busy = false;
            _cancel?.Dispose();
            _cancel = null;
            if (current is not null)
            {
                Store.MarkChanged();
                Store.Save();
            }
        }
    }

    /// <summary>One tracking run into <paramref name="folder"/>, then the analysis of what it wrote.</summary>
    private async Task RunInto(string folder, Session session, string key, WorkspaceSession? current, Action<Action> toUi)
    {
        Directory.CreateDirectory(folder);
        RunFolder = folder;
        if (current is not null)
        {
            current.RunFolder = folder;
            current.RunState = Core.Workspace.RunState.Running;
            current.RunMessage = null;
            Store.MarkChanged();
            Store.Save();
        }
        var library = new OnnxModelLibrary(_settings.ModelsFolder, _settings.ModelOptions());
        _device = null;
        var job = new TrackingJob
        {
            VideoPath = VideoPath!,
            Destination = folder,
            Settings = session.Inference,
            Calibration = session.Calibration,
            // Which device the model runs on (graphics card or processor), for the status line.
            OpenModel = name =>
            {
                var model = library.Open(name);
                if (model is OnnxPoseModel onnx) _device = (onnx.ProviderInUse, onnx.ProviderNote ?? DeviceTiming(onnx.Timing));
                return model;
            },
            Tools = _settings.Tools,
            // The frame just analysed, small, with each progress report: the picture moves while it runs.
            PreviewMaxSide = 640,
        };

        // Remaining time from the pace of this run so far (a resumed run starts its clock where it resumes).
        var clock = System.Diagnostics.Stopwatch.StartNew();
        double? firstSource = null;
        var progress = new Progress<TrackingProgress>(p => toUi(() =>
        {
            Progress = p.SourceDuration > 0 ? p.SourceTime / p.SourceDuration * 100 : 0;
            firstSource ??= p.SourceTime;
            double done = p.SourceTime - firstSource.Value, elapsed = clock.Elapsed.TotalSeconds;
            string remaining = "";
            if (done > 0.5 && elapsed > 2 && p.SourceDuration > p.SourceTime)
                remaining = " · " + AppText.L("about ", "剩余约 ") + Duration((p.SourceDuration - p.SourceTime) * elapsed / done)
                            + AppText.L(" left", "");
            string device = _device is { } d ? " · " + DeviceTitle(d.Provider) : "";
            Status = string.Format(AppText.L("{0:F0} / {1:F0} s · {2} frames · {3:F0} ms per frame", "{0:F0} / {1:F0} 秒 · {2} 帧 · 每帧 {3:F0} ms"),
                                   p.SourceTime, p.SourceDuration, p.AnalysedFrames, p.MsPerFrame) + device + remaining;
            if (p.Poses.Length > 0) LivePoses = p.Poses;
            if (p.Preview is { } preview) LiveFrame = preview;
        }));

        var token = _cancel!.Token;
        TrackingOutcome outcome;
        try
        {
            outcome = await Task.Run(() => TrackingPipeline.Run(job, progress, token), token);
        }
        finally
        {
            // Back to the calibration frame once the model is done.
            LiveFrame = null;
            LivePoses = [];
        }

        toUi(() => Status = _device is { Note: { Length: > 0 } note } ? note : AppText.L("Analysing", "正在分析"));
        string outDir = Path.Combine(folder, "results");
        var analysed = session with { UsedModel = outcome.Plan.ModelName };
        var companion = CompanionFor(current, analysed.Phase);
        var marbles = await MarblesFor(analysed, folder, toUi, token);
        var result = await Task.Run(() => Engine.Engine.Analyze(new AnalysisRequest
        {
            Session = analysed,
            PoseFile = outcome.Result.PoseFile,
            OutDir = outDir,
            Companion = companion,
            Marbles = marbles,
            IncludeReport = true,
        }), CancellationToken.None);
        _reportCompanion = companion;
        _reportMarbles = marbles;

        var record = new RunRecord
        {
            VideoPath = VideoPath ?? "",
            ModelName = outcome.Plan.ModelName,
            Roi = outcome.Plan.Roi,
            AnalysedAt = DateTime.Now,
            App = EngineLabel,
        };
        SaveRunFolder(folder, analysed, record);

        toUi(() =>
        {
            _poseFile = outcome.Result.PoseFile;
            _usedModel = outcome.Plan.ModelName;
            _runRoi = outcome.Plan.Roi;
            _runRoiKnown = true;
            if (current is not null)
            {
                current.RunState = Core.Workspace.RunState.Complete;
                current.RunModel = outcome.Plan.ModelName;
                current.RunFrames = result.Frames;
                current.RunFinishedAt = DateTime.Now;
                // A new analysis has not been checked yet.
                current.Review = ReviewVerdict.Unreviewed;
            }
            AdoptReport(result, analysed, key);
            Progress = 100;
            // AdoptReport says so when the engine library is too old to return a report; keep that.
            if (result.Report is not null)
                Status = string.Format(AppText.L("{0} · {1} frames · {2:F0} ms per frame", "{0} · {1} 帧 · 每帧 {2:F0} ms"),
                                       result.Task, result.Frames, outcome.MsPerFrame)
                         + (_device is { } d ? " · " + DeviceTitle(d.Provider) + (d.Note is { Length: > 0 } n ? " — " + n : "") : "");
        });
    }

    public void Stop() => _cancel?.Cancel();

    /// <summary>Latest poses from the run, drawn over the preview frame.</summary>
    private PoseKeypoints[] _livePoses = [];
    public PoseKeypoints[] LivePoses
    {
        get => _livePoses;
        private set { _livePoses = value; Notify(nameof(LivePoses)); }
    }

    /// <summary>
    /// Writes a review video of the finished run, with the engine's keypoints drawn on it. This is
    /// the check that confidence cannot give you: that the keypoints sit on the animal and move
    /// with it.
    /// </summary>
    public async Task<string> WriteAnnotatedVideoAsync(Action<Action> toUi)
    {
        if (RunFolder is null || VideoPath is null) throw new InvalidOperationException("Nothing has been analysed yet.");
        string output = Path.Combine(RunFolder, "annotated.mp4");
        var corners = Calibration.Kind == ArenaKind.Rectangle ? Calibration.Corners.ToArray() : null;
        var crop = Plan?.Crop;
        var tools = _settings.Tools;
        string run = RunFolder, video = VideoPath;

        toUi(() => Status = AppText.L("Drawing the keypoints onto the video", "正在把关键点画到视频上"));
        var result = await Task.Run(() => AnnotatedVideoWriter.Write(new AnnotatedVideoWriter.Request
        {
            RunFolder = run,
            VideoPath = video,
            Output = output,
            Crop = crop,
            ArenaCorners = corners,
            Tools = tools,
            // As the Mac's review video: one animal as its skeleton, two or more as coloured head glyphs with badges.
            Draw = Figures.Win2DAnnotation.Draw,
        }, new Progress<int>(n => toUi(() => Status = string.Format(AppText.L("Drawing: {0} frames", "正在绘制：{0} 帧"), n)))));

        toUi(() => Status = result.FramesWithoutDetection > 0
            ? string.Format(AppText.L("Review video written. {0} of {1} frames have no detection (red border).",
                                      "复核视频已生成。{1} 帧中有 {0} 帧未检出（红框）。"), result.FramesWithoutDetection, result.FramesWritten)
            : string.Format(AppText.L("Review video written: {0} frames, all with a detection.", "复核视频已生成：共 {0} 帧，每帧都有检出。"),
                            result.FramesWritten));
        return result.Output;
    }

    // ---------------------------------------------------------------- building the session

    private InferenceSettings BuildSettings() => new()
    {
        Stride = Stride,
        Grayscale = true,
        AnimalCount = AnimalCount,
        EndTime = ToSeconds,
        Coat = Coat,
    };

    private Session BuildSession()
    {
        var video = Video;
        var stored = _storedSession;
        return new Session
        {
            Paradigm = SelectedTask!.Id,
            Phase = Phase,
            SubjectID = Subject,
            Group = Group,
            Sex = _current?.Sex ?? "",
            Day = _current?.Day,
            Trial = _current?.Trial,
            // A reopened run whose video has moved keeps what was recorded about it; the engine takes the
            // frame rate and size from pose.mpt anyway.
            VideoName = video is not null ? Path.GetFileName(video.Path) : _current?.FileName ?? stored?.VideoName ?? "",
            VideoFile = video?.Path ?? _current?.VideoPath ?? stored?.VideoFile,
            Video = video is not null
                ? new VideoMeta
                {
                    Fps = video.Fps, Width = video.Width, Height = video.Height,
                    Duration = video.Duration, FileSize = video.FileSize,
                }
                : stored?.Video ?? new VideoMeta(),
            Calibration = Calibration,
            // A copy: the window may keep editing its own while the run uses this one.
            Params = (JsonObject)Params.DeepClone(),
            Inference = BuildSettings(),
        };
    }

    // ---------------------------------------------------------------- the result page

    /// <summary>The run's setup, next to pose.mpt, so the folder can be opened and recomputed later.</summary>
    public const string SessionFileName = "rodentflow_session.json";

    /// <summary>Which video, model and region the run used.</summary>
    public const string RunFileName = "rodentflow_run.json";

    private DisplayReport? _report;
    /// <summary>The report the result page shows (rf_analyze with includeReport); null before an analysis.</summary>
    public DisplayReport? Report
    {
        get => _report;
        private set { _report = value; Notify(nameof(Report)); Notify(nameof(ResultsStale)); }
    }

    private bool _resultsUpdating;
    /// <summary>The results are being recomputed from the saved tracking.</summary>
    public bool ResultsUpdating
    {
        get => _resultsUpdating;
        private set
        {
            if (!Set(ref _resultsUpdating, value)) return;
            Notify(nameof(CanUpdate));
            Notify(nameof(CanStart));
        }
    }

    private bool _regionOutdated;
    /// <summary>The calibration now reaches outside the region the saved tracking covered.</summary>
    public bool RegionOutdated
    {
        get => _regionOutdated;
        private set => Set(ref _regionOutdated, value);
    }

    /// <summary>The session the shown report was computed from, and the setup it reflects.</summary>
    private Session? _reportSession;
    private string? _reportKey;
    private DisplayReport? _englishReport;

    /// <summary>The tracking the results are computed from (pose.mpt), and what made it.</summary>
    private string? _poseFile;
    private string? _usedModel;
    private NRect? _runRoi;
    private bool _runRoiKnown;

    /// <summary>The setup read from a reopened run folder (for its video facts when the video has moved).</summary>
    private Session? _storedSession;

    /// <summary>Saved tracking is there and nothing is running: the results can be recomputed.</summary>
    public bool CanUpdate => !Busy && !ResultsUpdating && _poseFile is not null && SelectedTask is not null;

    /// <summary>The setup changed since the shown results were computed (Mac: they are recomputed).</summary>
    public bool ResultsStale => Report is not null && _reportKey != SetupKey();

    /// <summary>One line over the result page.</summary>
    public string ResultsState => Report is null
        ? ""
        : ResultsUpdating
            ? AppText.L("Updating the results…", "正在更新结果…")
            : ResultsStale
                ? AppText.L("The setup has changed since these results. Update results recomputes them from the saved tracking.",
                            "设置已改动。“Update results”用已保存的识别结果重新计算，不需要重新识别。")
                : AppText.L("Figures and tables are saved in English, as on the Mac.", "图和表格导出为英文，与 Mac 相同。");

    /// <summary>What the empty result page says.</summary>
    public string ResultsEmptyText => _poseFile is not null
        ? AppText.L("Update results to compute them from the saved tracking.", "点击“Update results”，用已保存的识别结果计算。")
        : AppText.L("No results yet. Choose a video, place the arena and analyse — or open a folder analysed earlier.",
                    "还没有结果。选择视频、标定场地后分析，或打开以前分析过的文件夹。");

    /// <summary>Everything the results depend on that the window can change (the Mac's session-metrics key).</summary>
    private string SetupKey() =>
        EngineJson.Write(new SetupKeyParts(TaskId, Phase, Calibration, Params, Subject, Group, Coat));

    private sealed record SetupKeyParts(string Task, string Phase, ArenaCalibration Calibration, JsonObject Params,
                                        string Subject, string Group, CoatColor Coat);

    /// <summary>A new video or a new run: the previous run's results no longer apply.</summary>
    private void ForgetRun()
    {
        _poseFile = null;
        _usedModel = null;
        _runRoi = null;
        _runRoiKnown = false;
        _reportSession = null;
        _reportKey = null;
        _englishReport = null;
        _storedSession = null;
        ResultFolder = null;
        RegionOutdated = false;
        Report = null;
        Notify(nameof(CanUpdate));
    }

    private void AdoptReport(AnalysisResult result, Session session, string key)
    {
        _reportSession = session;
        _reportKey = key;
        _englishReport = null;
        ResultFolder = result.OutDir;
        if (result.Report is null)
        {
            Status = AppText.L(
                "The engine library is older than this window and returned no report. Rebuild the engine (swift build) and copy the new RodentFlowABI.dll next to RodentFlow.exe.",
                "引擎库比窗口程序旧，没有返回结果页数据。请重新编译引擎（swift build），把新的 RodentFlowABI.dll 放到 RodentFlow.exe 旁边。");
        }
        Report = result.Report;
        if (_current is { } s && result.Report?.Primary is { } primary)
        {
            s.PrimaryTitle = primary.Title;
            s.PrimaryDisplay = primary.Display;
            s.PrimaryUnit = primary.DisplayUnit;
            Store.MarkChanged();
        }
        if (_current is { } owner)
        {
            // Every finite measure, for the other phase of this animal (pairing).
            owner.Values = result.Metrics.Where(m => m.Value is { } v && double.IsFinite(v))
                                         .GroupBy(m => m.Key).ToDictionary(g => g.Key, g => g.First().Value!.Value);
            // The summary the task's group comparison reads (as the Mac saves one per session).
            if (result.Summary is { } summary) owner.Summary = (JsonObject)summary.DeepClone();
            Store.MarkChanged();
        }
        UpdateRegionOutdated();
        Notify(nameof(CanUpdate));
    }

    /// <summary>
    /// Recomputes the results from the saved tracking with the current setup — calibration, zones,
    /// parameters, phase — without running the model again, as the Mac's results tab does.
    /// </summary>
    public async Task UpdateResultsAsync()
    {
        if (!CanUpdate || _poseFile is not { } pose || SelectedTask is null) return;
        string? folder = RunFolder;
        string outDir = ResultFolder ?? Path.Combine(folder ?? Path.GetDirectoryName(pose) ?? ".", "results");
        Session session;
        string key;
        try
        {
            session = BuildSession() with { UsedModel = _usedModel };
            key = SetupKey();
        }
        catch (Exception e)
        {
            Status = e.Message;
            return;
        }
        ResultsUpdating = true;
        Notify(nameof(ResultsState));
        try
        {
            var companion = CompanionFor(_current, session.Phase);
            string runFolder = folder ?? Path.GetDirectoryName(pose) ?? ".";
            var marbles = await MarblesFor(session, runFolder, a => a(), CancellationToken.None);
            var result = await Task.Run(() => Engine.Engine.Analyze(new AnalysisRequest
            {
                Session = session,
                PoseFile = pose,
                OutDir = outDir,
                Companion = companion,
                Marbles = marbles,
                IncludeReport = true,
            }));
            _reportCompanion = companion;
            _reportMarbles = marbles;
            if (folder is not null) SaveRunFolder(folder, session, null);
            AdoptReport(result, session, key);
            if (result.Report is not null)
                Status = AppText.L($"Results updated from the saved tracking · {result.Task} · {result.Frames} frames",
                                   $"已用已保存的识别结果更新 · {result.Task} · {result.Frames} 帧");
        }
        catch (Exception e)
        {
            Status = e.Message;
        }
        finally
        {
            ResultsUpdating = false;
            Notify(nameof(ResultsState));
        }
    }

    /// <summary>
    /// The shown report in English, for figures saved to files (the Mac writes every export in English).
    /// Computed once per report, from the same session and tracking as the report on screen.
    /// </summary>
    public async Task<DisplayReport?> EnglishReportAsync()
    {
        if (Report is null) return null;
        if (Report.Language == "en") return Report;
        if (_englishReport is not null) return _englishReport;
        if (_reportSession is not { } session || _poseFile is not { } pose) return null;
        string outDir = ResultFolder ?? Path.GetTempPath();
        var result = await Task.Run(() => Engine.Engine.Analyze(new AnalysisRequest
        {
            Session = session,
            PoseFile = pose,
            OutDir = outDir,
            WriteExports = false,
            Companion = _reportCompanion,
            Marbles = _reportMarbles,
            IncludeReport = true,
            ReportLanguage = "english",
        }));
        return _englishReport = result.Report;
    }

    /// <summary>The companion and marble readings the shown report was computed with (the English copy uses the same).</summary>
    private Dictionary<string, double>? _reportCompanion;
    private JsonObject? _reportMarbles;

    /// <summary>The other phase's values for a session (Store.Companion), or null when there are none.</summary>
    private Dictionary<string, double>? CompanionFor(WorkspaceSession? s, string phase)
    {
        if (s is null || SelectedTask is not { } task) return null;
        var values = Store.Companion(s, task.Companions, task.Id, phase);
        return values.Count > 0 ? values : null;
    }

    /// <summary>
    /// Marble burying: the readings of the marbles (MarbleSampler.samples) — saved ones when they were read with the
    /// same marbles, size and interval, otherwise read from the whole video and saved next to the pose data. Without
    /// readings the analysis has no main measure, so a missing video is an error here, as on the Mac.
    /// </summary>
    private async Task<JsonObject?> MarblesFor(Session session, string runFolder, Action<Action> toUi, CancellationToken cancel)
    {
        if (session.Paradigm != "marble_burying") return null;
        var plan = await Task.Run(() => Engine.Engine.MarblePlan(session), cancel);
        if (!plan.Needed) return null;
        if (MarbleSamples.Load(runFolder, plan.Key) is { } saved) return saved.ToJsonObject();
        if (Video is not { } info)
            throw new RodentFlowException(AppText.L(
                "Marble burying reads the marbles from the video, and the video of this session was not found. Locate the video.",
                "埋珠实验需要从视频读取珠子，但找不到这次实验的视频。请重新指定视频。"));
        var tools = _settings.Tools;
        var progress = new Progress<double>(f => toUi(() => Status = string.Format(
            AppText.L("Reading the marbles… {0:F0} %", "正在读取珠子… {0:F0}%"), f * 100)));
        var samples = await Task.Run(() => MarbleSampling.Sample(info, tools, plan, progress, cancel), cancel);
        try { samples.Save(runFolder); }
        catch (IOException) { /* read again next time */ }
        return samples.ToJsonObject();
    }

    /// <summary>The run's setup and what made it, written next to pose.mpt.</summary>
    private static void SaveRunFolder(string folder, Session session, RunRecord? run)
    {
        try
        {
            File.WriteAllText(Path.Combine(folder, SessionFileName), EngineJson.Write(session));
            if (run is not null) File.WriteAllText(Path.Combine(folder, RunFileName), EngineJson.Write(run));
        }
        catch (IOException)
        {
            // The results are still shown; only reopening the folder later needs these files.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Reads a run folder made by this app: its setup, and (when present) the run record.</summary>
    public static (Session Session, RunRecord? Run) ReadRunFolder(string folder)
    {
        if (!File.Exists(Path.Combine(folder, "pose.mpt")))
            throw new FileNotFoundException(AppText.L(
                "This folder has no pose.mpt, so it is not a RodentFlow run folder.",
                "此文件夹中没有 pose.mpt，不是 RodentFlow 的分析文件夹。"));
        string sessionFile = Path.Combine(folder, SessionFileName);
        if (!File.Exists(sessionFile))
            throw new FileNotFoundException(AppText.L(
                "This run was made before the Windows app saved its setup (rodentflow_session.json), so its calibration and parameters are not known. Analyse the video again.",
                "此分析由更早的 Windows 版本生成，没有保存设置（rodentflow_session.json），标定和参数无从得知。请重新分析该视频。"));
        var session = EngineJson.Read<Session>(File.ReadAllText(sessionFile));
        string runFile = Path.Combine(folder, RunFileName);
        RunRecord? run = File.Exists(runFile) ? EngineJson.Read<RunRecord>(File.ReadAllText(runFile)) : null;
        return (session, run);
    }

    // ---------------------------------------------------------------- the workspace session

    private WorkspaceSession? _current;

    /// <summary>The session open in the page; null when none is.</summary>
    public WorkspaceSession? Current => _current;

    private VideoFrameGrabber.Frame? _liveFrame;
    /// <summary>While the model runs: the frame it just analysed (small), shown instead of the calibration frame.</summary>
    public VideoFrameGrabber.Frame? LiveFrame
    {
        get => _liveFrame;
        private set { _liveFrame = value; Notify(nameof(LiveFrame)); }
    }

    /// <summary>The device the last run's model used, and why it is not the graphics card when it could not be.</summary>
    private (string Provider, string? Note)? _device;

    private static string DeviceTitle(string provider) => provider.StartsWith("DirectML", StringComparison.Ordinal)
        ? AppText.L("graphics card ", "显卡 ") + provider
        : AppText.L("processor (CPU)", "处理器（CPU）");

    /// <summary>What "Automatic" measured (shown once at the start of the run).</summary>
    private static string? DeviceTiming(string? timing) => timing is { Length: > 0 }
        ? AppText.L("Fastest device chosen (timed once per model): ", "已自动选择最快的设备（每个模型只测一次）：") + timing
        : null;

    /// <summary>"4 min 10 s" / "4 分 10 秒".</summary>
    private static string Duration(double seconds)
    {
        long s = Math.Max(0, (long)Math.Round(seconds));
        if (s < 60) return AppText.L($"{s} s", $"{s} 秒");
        if (s < 3600) return AppText.L($"{s / 60} min {s % 60} s", $"{s / 60} 分 {s % 60} 秒");
        return AppText.L($"{s / 3600} h {s / 60 % 60} min", $"{s / 3600} 小时 {s / 60 % 60} 分");
    }

    /// <summary>The tracking the results come from (pose.mpt), for the review; null before an analysis.</summary>
    public string? PoseFile => _poseFile;

    /// <summary>Keypoints below this confidence are missing for the analysis (AnalysisParams.kpConf).</summary>
    public float KeypointConfidence => (float)(ParamValues.Number(Params, "kpConf") ?? 0.5);

    /// <summary>
    /// "Swap A / B from here" (at) or "in a range" (from–to) on the run's pose.mpt, then the results recomputed from
    /// the corrected tracking. Returns the engine's answer (null when there is no tracking to correct).
    /// </summary>
    public async Task<SwapResult?> SwapIdentityAsync(int from, int? to = null)
    {
        if (_poseFile is not { } pose || Busy) return null;
        var result = await Task.Run(() => to is { } end
            ? Engine.Engine.SwapIdentity(pose, from, end)
            : Engine.Engine.SwapIdentity(pose, from));
        if (result.Swapped)
        {
            if (_current is { } s)
            {
                // A corrected identity has to be looked at again.
                s.Review = ReviewVerdict.Unreviewed;
                Store.MarkChanged();
            }
            await UpdateResultsAsync();
        }
        return result;
    }

    /// <summary>The user changed the setup of the open session (it is saved with the session from then on).</summary>
    private bool _touched;
    private string? _persistedKey;

    /// <summary>
    /// Opens a session of the workspace: its task, phase, setup, video and — when it was analysed — its tracking,
    /// so its results can be recomputed at once. Without its video the results still show; nothing can be placed.
    /// </summary>
    public void OpenSession(WorkspaceSession s, VideoInfo? info, VideoFrameGrabber.Frame? frame)
    {
        var owner = Store.FindTask(s.TaskId)
                    ?? throw new RodentFlowException(AppText.L("This session's task is no longer in the workspace.", "此实验所属的任务已不在工作区中。"));
        var task = Tasks.FirstOrDefault(t => t.Id == owner.Paradigm)
                   ?? throw new RodentFlowException(AppText.L("This engine does not know the task ", "引擎不认识任务 ") + owner.Paradigm);
        ForgetRun();
        _current = s;
        _touched = false;
        _selectedTask = task;
        _phase = s.Phase is { Length: > 0 } phase ? phase : task.DefaultPhase;
        _subject = s.AnimalId;
        _group = s.Group ?? "";
        var setup = s.Setup;
        _coat = ValidCoat(setup?.Coat ?? DefaultCoat(s.TaskId), task);
        _stride = Math.Max(1, setup?.Stride ?? 1);
        _toSeconds = Math.Max(0, setup?.EndTime ?? 0);
        if (task.IsGroup)
            _groupAnimals = Math.Clamp(setup?.AnimalCount ?? Catalogue.DefaultGroupAnimals, 3, Math.Max(3, MaxGroupAnimals));

        Video = info;
        VideoPath = info?.Path;
        PreviewFrame = frame;
        if (info is not null)
        {
            s.VideoPath = info.Path;
            s.FileName = Path.GetFileName(info.Path);
            s.FileSize = info.FileSize;
        }
        if (setup is not null)
        {
            Calibration = setup.Calibration;
            Params = setup.Params is { } saved ? (JsonObject)saved.DeepClone() : DefaultParams(task);
            RefreshView();
        }
        else
        {
            // Never placed: the task's default layout for this frame, not yet saved with the session.
            Params = DefaultParams(task);
            ApplyDefaults(task.DefaultArena, keepParams: false);
        }

        RunFolder = s.RunFolder;
        ResultFolder = s.RunFolder is { } folder ? Path.Combine(folder, "results") : null;
        if (s.RunState == Core.Workspace.RunState.Complete && s.RunFolder is { } runFolder
            && File.Exists(Path.Combine(runFolder, "pose.mpt")))
        {
            _poseFile = Path.Combine(runFolder, "pose.mpt");
            _usedModel = s.RunModel;
            var run = ReadRunRecord(runFolder);
            _runRoi = run?.Roi;
            _runRoiKnown = run is not null;
        }
        Progress = s.RunState == Core.Workspace.RunState.Complete ? 100 : 0;
        _persistedKey = SetupKey();
        foreach (string name in new[]
                 {
                     nameof(SelectedTask), nameof(Phase), nameof(AnimalCountIsEditable), nameof(AnimalCount), nameof(Coat),
                     nameof(Subject), nameof(Group), nameof(Stride), nameof(ToSeconds), nameof(CanStart), nameof(CanUpdate),
                     nameof(InfoProblems), nameof(Current),
                 })
            Notify(name);
        RefreshPlan();
        Status = info is not null
            ? s.FileName
            : AppText.L("The video of this session was not found. Results and figures still show; use \"Locate the video…\" to place the arena or analyse.",
                        "找不到这次实验的视频。结果和图照常显示；要标定或分析，请点“Locate the video…”重新指定视频。");
    }

    /// <summary>The session's video has moved: the same session, its setup kept, with the video at its new place.</summary>
    public void RelinkVideo(VideoInfo info, VideoFrameGrabber.Frame frame)
    {
        if (_current is not { } s) return;
        s.VideoPath = info.Path;
        s.FileName = Path.GetFileName(info.Path);
        s.FileSize = info.FileSize;
        Video = info;
        VideoPath = info.Path;
        PreviewFrame = frame;
        if (s.Setup is null && SelectedTask is { } task) ApplyDefaults(task.DefaultArena, keepParams: true);
        else RefreshView();
        Store.MarkChanged();
        Notify(nameof(CanStart));
    }

    /// <summary>
    /// Coat colours a task offers, as the Mac's CoatColor.choices: they choose the pose model, so a task only offers its
    /// model's colours — one mouse: dark or white; two: both dark, or one dark and one white; a group: dark only (and no
    /// choice is shown). Copied from Shared/PoseEngine/PoseModels.swift; keep in step.
    /// </summary>
    public static CoatColor[] CoatChoices(ParadigmInfo task) =>
        task.IsGroup || task.AnimalCount > 2 ? [CoatColor.Dark]
        : task.AnimalCount > 1 ? [CoatColor.Dark, CoatColor.DarkWhite]
        : [CoatColor.Dark, CoatColor.White];

    /// <summary>CoatColor.title(animalCount:), through the engine's catalogue.</summary>
    public static string CoatTitle(CoatColor coat, ParadigmInfo task) => coat switch
    {
        CoatColor.White => Core.Text.Tr.T("白色"),
        CoatColor.DarkWhite => Core.Text.Tr.T("一黑一白"),
        _ => Core.Text.Tr.T(task.IsGroup || task.AnimalCount > 2 ? "全部深色" : task.AnimalCount > 1 ? "两只都是深色" : "深色"),
    };

    /// <summary>The colour if the task's model has it, otherwise dark (CoatColor.valid(for:)).</summary>
    private static CoatColor ValidCoat(CoatColor coat, ParadigmInfo task) => CoatChoices(task).Contains(coat) ? coat : CoatColor.Dark;

    /// <summary>The coat of a session never set up: the task's latest (PoseTaskSetup default, Mac defaultCoat).</summary>
    private CoatColor DefaultCoat(Guid taskId) =>
        Store.SessionsOf(taskId).Where(x => x.Setup is not null).OrderByDescending(x => x.ImportedAt)
             .Select(x => x.Setup!.Coat).FirstOrDefault(CoatColor.Dark);

    private void Touch()
    {
        _touched = true;
        PersistSetup();
    }

    /// <summary>The open session's setup into the workspace, once the user has changed it.</summary>
    private void PersistSetup(bool force = false)
    {
        if (_current is not { } s || !_touched) return;
        string key = SetupKey();
        if (!force && key == _persistedKey && s.Setup is { Confirmed: true }) return;
        s.Setup = new SessionSetup
        {
            Calibration = Calibration,
            Params = (JsonObject)Params.DeepClone(),
            Coat = Coat,
            Stride = Stride,
            EndTime = ToSeconds,
            AnimalCount = AnimalCount,
            Confirmed = true,
        };
        s.Phase = Phase;
        _persistedKey = key;
        Store.MarkChanged();
    }

    /// <summary>Info of the open session was edited in the window (date, number, sex, notes …).</summary>
    public void SessionInfoChanged()
    {
        Store.MarkChanged();
        Notify(nameof(InfoProblems));
    }

    /// <summary>What is missing or clashing in the open session's information (ImportVideosSheet.problems).</summary>
    public string InfoProblems
    {
        get
        {
            if (_current is not { } s) return "";
            var list = new List<string>();
            if (s.AnimalId.Trim().Length == 0) list.Add(AppText.L("Animal ID is required.", "必须填写小鼠编号。"));
            if (!SessionDates.IsValid(s.SessionDate)) list.Add(AppText.L("The recording date is required.", "必须填写实验日期。"));
            if ((s.SessionNumber ?? 0) < 1) list.Add(AppText.L("Session number must be at least 1.", "实验次数至少为 1。"));
            else if (s.AnimalId.Trim().Length > 0
                     && Store.SessionConflict(s.TaskId, s.AnimalKey, s.SessionNumber!.Value, s.Id) is { } other)
                list.Add(string.Format(AppText.L("{0} already has session #{1} in this task ({2}).", "{0} 在此任务中已有第 {1} 次实验（{2}）。"),
                                       s.AnimalKey, s.SessionNumber, other.FileName));
            return string.Join("\n", list);
        }
    }

    /// <summary>
    /// The open session's arena and parameters for every other session of its task ("use for all videos of this
    /// task"); returns how many were set. The phase stays each session's own; running sessions are left alone.
    /// </summary>
    public int CopySetupToTask()
    {
        if (_current is not { } s) return 0;
        _touched = true;
        PersistSetup(force: true);
        var setup = s.Setup!;
        string from = s.AnimalKey + " · " + (s.SessionDate ?? "") + " #" + (s.SessionNumber?.ToString(CultureInfo.InvariantCulture) ?? "?");
        int n = 0;
        foreach (var other in Store.SessionsOf(s.TaskId).Where(o => o.Id != s.Id && o.RunState != Core.Workspace.RunState.Running))
        {
            var copy = setup.Clone();
            copy.CopiedFrom = from;
            copy.Confirmed = true;
            other.Setup = copy;
            n++;
        }
        Store.MarkChanged();
        return n;
    }

    /// <summary>
    /// A run folder made by this app becomes a session of the workspace (in the given task when it is the same
    /// paradigm, else in the first task of that paradigm, which is made when there is none).
    /// </summary>
    public WorkspaceSession ImportRunFolder(string folder, Guid? taskId)
    {
        var (session, run) = ReadRunFolder(folder);
        var task = taskId is { } id ? Store.FindTask(id) : null;
        if (task is null || task.Paradigm != session.Paradigm)
        {
            task = Store.Document.Tasks.FirstOrDefault(t => t.Paradigm == session.Paradigm)
                   ?? Store.AddTask(session.Paradigm, Tasks.FirstOrDefault(t => t.Id == session.Paradigm)?.EnglishName ?? session.Paradigm);
        }
        string video = run?.VideoPath is { Length: > 0 } v ? v : session.VideoFile ?? "";
        string? date = SessionDates.FromFileName(Path.GetFileNameWithoutExtension(video))
                       ?? (File.Exists(video) ? SessionDates.Text(File.GetCreationTime(video)) : null)
                       ?? (run is not null ? SessionDates.Text(run.AnalysedAt) : null);
        var s = new WorkspaceSession
        {
            TaskId = task.Id,
            VideoPath = video,
            FileName = Path.GetFileName(video),
            AnimalId = session.SubjectID.Trim(),
            Group = session.Group,
            Sex = session.Sex,
            Phase = session.Phase,
            Day = session.Day,
            Trial = session.Trial,
            SessionDate = date,
            Setup = new SessionSetup
            {
                Calibration = session.Calibration,
                Params = session.Params?.DeepClone() as JsonObject,
                Coat = session.Inference.Coat,
                Stride = Math.Max(1, session.Inference.Stride),
                EndTime = session.Inference.EndTime,
                AnimalCount = session.Inference.AnimalCount,
                Confirmed = true,
            },
            RunFolder = folder,
            RunState = Core.Workspace.RunState.Complete,
            RunModel = session.UsedModel ?? run?.ModelName,
            RunFinishedAt = run?.AnalysedAt,
        };
        s.SessionNumber = Store.NextSessionNumber(task.Id, s.AnimalKey);
        Store.Document.Sessions.Add(s);
        Store.MarkChanged();
        return s;
    }

    private static RunRecord? ReadRunRecord(string folder)
    {
        string file = Path.Combine(folder, RunFileName);
        try
        {
            return File.Exists(file) ? EngineJson.Read<RunRecord>(File.ReadAllText(file)) : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private JsonObject DefaultParams(ParadigmInfo task)
    {
        try
        {
            return Engine.Engine.DefaultSetup(new DefaultSetupRequest
            {
                Paradigm = task.Id, FrameWidth = 1280, FrameHeight = 960,
            }).Params;
        }
        catch (Exception)
        {
            return new JsonObject();
        }
    }

    /// <summary>The Mac's check (TaskResultsView.outsideTrackedRegion): does the region now needed still fit the tracked one?</summary>
    private void UpdateRegionOutdated()
    {
        RegionOutdated = Report is not null && _runRoiKnown && Plan is not null && !Inside(Plan.Roi, _runRoi);
        Notify(nameof(ResultsState));
    }

    /// <summary><paramref name="inner"/> lies within <paramref name="outer"/>; null means the whole frame.</summary>
    private static bool Inside(NRect? inner, NRect? outer)
    {
        const double e = 1e-4;
        if (outer is null || outer.IsFullFrame) return true;
        if (inner is null) return false;
        return inner.X >= outer.X - e && inner.Y >= outer.Y - e
               && inner.X + inner.W <= outer.X + outer.W + e && inner.Y + inner.H <= outer.Y + outer.H + e;
    }

    // ---------------------------------------------------------------- INotifyPropertyChanged

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Notify(name);
        return true;
    }

    private void Notify(string? name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name ?? ""));
}

/// <summary>What a run used, written next to pose.mpt (rodentflow_run.json).</summary>
public sealed record RunRecord
{
    public string VideoPath { get; init; } = "";
    public string ModelName { get; init; } = "";
    /// <summary>The region given to the model, normalized; null = the whole frame.</summary>
    public NRect? Roi { get; init; }
    public DateTime AnalysedAt { get; init; }
    public string App { get; init; } = "";
}
