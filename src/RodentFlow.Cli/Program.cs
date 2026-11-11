using System.Text.Json;
using System.Text.Json.Nodes;
using RodentFlow.Core;
using RodentFlow.Engine;
using RodentFlow.Onnx;

namespace RodentFlow.Cli;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help" or "help")
        {
            Usage();
            return args.Length == 0 ? 2 : 0;
        }
        try
        {
            var options = Options.Parse(args.Skip(1));
            if (options.Chinese) Engine.Engine.SetLanguage(true);
            return args[0] switch
            {
                "version" => Version(),
                "catalogue" or "tasks" => Catalogue(),
                "models" => Models(options),
                "info" => Info(options),
                "plan" => Plan(options),
                "track" => Track(options),
                "analyze" or "analyse" => Analyze(options),
                "run" => Run(options),
                "track-info" => TrackInfo(options),
                "annotate" => Annotate(options),
                _ => Unknown(args[0]),
            };
        }
        catch (RodentFlowException e)
        {
            Console.Error.WriteLine("engine: " + e.Message);
            return 1;
        }
        catch (DllNotFoundException e)
        {
            Console.Error.WriteLine(
                "Cannot load RodentFlowABI.dll. Build the engine (build\\build_engine.ps1) and put the "
                + "library next to this program.\n" + e.Message);
            return 1;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e.Message);
            return 1;
        }
    }

    private static void Usage() => Console.WriteLine(
        """
        rodentflow — RodentFlow for Windows, without a window

          rodentflow version
          rodentflow catalogue                       the tasks the engine can analyse
          rodentflow models      --models DIR        which pose models are present
          rodentflow info        VIDEO               size, frame rate, frame times
          rodentflow plan        VIDEO [task options]   model, tracked region, decode size
          rodentflow track       VIDEO RUNDIR  [options]  run the model, write pose.mpt
          rodentflow analyze     RUNDIR OUTDIR [options]  metrics and the export files
          rodentflow run         VIDEO RUNDIR  [options]  track, then analyze into RUNDIR/results
          rodentflow track-info  RUNDIR               what is in a finished pose.mpt
          rodentflow annotate    RUNDIR OUTPUT --video V   draw the keypoints onto the video

        Annotate options
          --video V            the video that was analysed (required)
          --from S --to S      only this part, in seconds
          --every N            every Nth analysed frame
          --fps F              playback rate (default: real time)
          --corners ...        draw the arena outline you calibrated with

        Task options
          --task ID            paradigm id, e.g. open_field (default), three_chamber, dyadic_social
          --phase KEY          phase of a multi-phase task (default: the task's main phase, listed first)
          --subject NAME       animal id written into the exports
          --group NAME         group written into the exports
          --animals N          animals per frame (the task usually fixes this; 3–10 for group_behavior)
          --coat dark|white|darkWhite
          --stride N           analyse every Nth frame (default 1)
          --from S --to S      analyse only this part of the video, in seconds
          --no-gray            give the model colour frames (default is gray, as in the apps)
          --region full        track the whole frame instead of the calibrated arena
          --margin F           margin around the arena, 0.05 / 0.12 / 0.25 (default 0.12)

        Arena (everything starts from the task's own default: shape, size, handles, markers)
          --arena none|rect|circle|plus|y|t   none = no calibration, results in pixels
          --cm W H                      real width and height of a rectangular arena
          --diameter D                  real diameter of a round arena
          --corners x1,y1,...,x4,y4     corners in the picture, 0–1, from the top left
          --center x,y --edge x,y       centre and a point on the rim of a round arena
          --session FILE.json           a full session, instead of the options above
          --param KEY=VALUE             one analysis parameter, e.g. openAxis=EW, csOnsets=180,260,340

        Where things are
          --models DIR         folder with the .onnx files (default: models next to this program)
          --ffmpeg DIR         folder with ffmpeg.exe and ffprobe.exe (default: on PATH)
          --provider CPU|DML   ONNX Runtime execution provider (default CPU)
          --threads N          intra-op threads
          --zh                 report text in Chinese
        """);

    private static int Unknown(string command)
    {
        Console.Error.WriteLine($"Unknown command '{command}'. Try: rodentflow --help");
        return 2;
    }

    // ---------------------------------------------------------------- commands

    private static int Version()
    {
        var v = Engine.Engine.Version();
        Console.WriteLine($"{v.App}  (ABI {v.Abi})");
        Console.WriteLine("keypoints: " + string.Join(", ", v.Keypoints));
        Console.WriteLine("models:    " + string.Join("\n           ", v.Models));
        return 0;
    }

    private static int Catalogue()
    {
        var c = Engine.Engine.Catalogue();
        Console.WriteLine($"{c.Paradigms.Length} tasks, {c.Keypoints.Length} keypoints, "
                          + $"up to {c.MaxGroupAnimals} animals in a group\n");
        Console.WriteLine($"{"id",-28}{"animals",8}  task");
        foreach (var p in c.Paradigms)
        {
            Console.WriteLine($"{p.Id,-28}{(p.IsGroup ? "3–10" : p.AnimalCount.ToString()),8}  {p.EnglishName}");
            if (p.Phases.Length > 0)
                Console.WriteLine($"{"",-28}{"",8}  phases: " + string.Join(", ", p.Phases.Select(x => x.Key)));
        }
        return 0;
    }

    private static int Models(Options o)
    {
        var library = new OnnxModelLibrary(o.ModelsDir);
        var known = Engine.Engine.Version().Models;
        Console.WriteLine($"models in {o.ModelsDir}\n");
        int missing = 0;
        foreach (var (name, file) in library.Survey(known))
        {
            if (file is null) missing++;
            Console.WriteLine($"  {(file is null ? "missing" : "ok     ")}  {name,-28} {(file is null ? "" : Path.GetFileName(file))}");
        }
        if (missing > 0)
            Console.WriteLine($"\n{missing} missing. Export them with RodentFlow_Export_ONNX_All_Models.ipynb.");
        return 0;
    }

    private static int Info(Options o)
    {
        var video = FFprobe.Probe(o.Need(0, "VIDEO"), o.Tools);
        Console.WriteLine($"{Path.GetFileName(video.Path)}");
        Console.WriteLine($"  upright size   {video.Width} × {video.Height}" +
                          (video.Rotation != 0 ? $"  (rotated {video.Rotation}° in the file)" : ""));
        Console.WriteLine($"  duration       {video.Duration:F3} s");
        Console.WriteLine($"  frame rate     {video.Fps:F4} (nominal)");
        Console.WriteLine($"  frames         {video.FrameTimes.Count} with a timestamp");
        if (video.FrameTimes.Count > 1)
        {
            var gaps = new List<double>();
            for (int i = 1; i < video.FrameTimes.Count; i++) gaps.Add(video.FrameTimes[i] - video.FrameTimes[i - 1]);
            gaps.Sort();
            double median = gaps[gaps.Count / 2];
            Console.WriteLine($"  frame gap      median {median * 1000:F2} ms "
                              + $"({(median > 0 ? 1 / median : 0):F3} fps), "
                              + $"min {gaps[0] * 1000:F2}, max {gaps[^1] * 1000:F2}");
            Console.WriteLine($"  first / last   {video.FrameTimes[0]:F3} s / {video.FrameTimes[^1]:F3} s");
            if (Math.Abs(1 / median - video.Fps) > 0.05)
                Console.WriteLine("  note           the header's frame rate and the real frame gaps disagree; "
                                  + "the analysis uses the timestamps, which is the right thing.");
        }
        return 0;
    }

    private static int Plan(Options o)
    {
        var video = FFprobe.Probe(o.Need(0, "VIDEO"), o.Tools);
        var session = o.BuildSession(video);
        var plan = Engine.Engine.PlanRun(new RunPlanRequest
        {
            Settings = session.Inference,
            Calibration = session.Calibration,
            FrameWidth = video.Width,
            FrameHeight = video.Height,
        });
        Console.WriteLine($"model          {plan.ModelName}  ({plan.AnimalCount} animal(s), {plan.Coat})");
        Console.WriteLine($"grayscale      {plan.Grayscale}");
        Console.WriteLine($"frame stride   {plan.Stride}");
        Console.WriteLine($"tracked region {(plan.Roi is null ? "whole frame" : $"{plan.Roi.X:F4},{plan.Roi.Y:F4} {plan.Roi.W:F4}×{plan.Roi.H:F4}")}");
        Console.WriteLine($"crop (pixels)  {plan.Crop.Width} × {plan.Crop.Height} at {plan.Crop.X},{plan.Crop.Y}");
        Console.WriteLine($"decode at      {(plan.DecodeScale is null ? "full size" : $"{plan.DecodeWidth} × {plan.DecodeHeight}  (scale {plan.DecodeScale:F4})")}");
        var file = new OnnxModelLibrary(o.ModelsDir).FindFile(plan.ModelName);
        Console.WriteLine($"model file     {file ?? "MISSING in " + o.ModelsDir}");
        return file is null ? 1 : 0;
    }

    private static int Track(Options o)
    {
        string video = o.Need(0, "VIDEO");
        string runDir = o.Need(1, "RUNDIR");
        var outcome = RunTracking(o, video, runDir);
        Console.WriteLine();
        Console.WriteLine($"pose file      {outcome.Result.PoseFile}");
        Console.WriteLine($"frames         {outcome.Result.Frames}"
                          + (outcome.Result.FailedFrames > 0 ? $"  ({outcome.Result.FailedFrames} with no detection)" : ""));
        if (outcome.Result.AnimalCount > 1)
            Console.WriteLine($"identity       {outcome.Result.IdentityUncertain} frame(s) marked for review");
        Console.WriteLine($"model time     {outcome.MsPerFrame:F1} ms/frame");
        return 0;
    }

    private static TrackingOutcome RunTracking(Options o, string video, string runDir)
    {
        var library = new OnnxModelLibrary(o.ModelsDir, new PoseModelOptions(o.Provider, IntraOpThreads: o.Threads));
        var probe = FFprobe.Probe(video, o.Tools);
        var session = o.BuildSession(probe);

        var job = new TrackingJob
        {
            VideoPath = video,
            Destination = runDir,
            Settings = session.Inference,
            Calibration = session.Calibration,
            OpenModel = library.Open,
            Tools = o.Tools,
        };

        var last = DateTime.MinValue;
        var progress = new Progress<TrackingProgress>(p =>
        {
            if ((DateTime.UtcNow - last).TotalMilliseconds < 400) return;
            last = DateTime.UtcNow;
            double percent = p.SourceDuration > 0 ? p.SourceTime / p.SourceDuration * 100 : 0;
            Console.Write($"\r  {percent,5:F1}%   {p.SourceTime,8:F1} / {p.SourceDuration:F1} s   "
                          + $"{p.AnalysedFrames} frames   {p.MsPerFrame:F0} ms/frame        ");
        });

        using var cancel = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            Console.WriteLine("\nstopping; the frames analysed so far are kept — run the same command to continue");
            cancel.Cancel();
        };
        return TrackingPipeline.Run(job, progress, cancel.Token);
    }

    private static int Analyze(Options o)
    {
        string runDir = o.Need(0, "RUNDIR");
        string outDir = o.Need(1, "OUTDIR");
        string poseFile = Path.Combine(runDir, "pose.mpt");
        if (!File.Exists(poseFile))
            throw new FileNotFoundException($"No pose.mpt in {runDir}. Track the video first.", poseFile);

        var info = Engine.Engine.TrackInfo(poseFile);
        var session = o.BuildSession(new VideoInfo
        {
            Path = o.String("video") ?? "",
            Width = (int)info.FrameWidth,
            Height = (int)info.FrameHeight,
            Fps = info.Fps,
            Duration = info.ProcessedUntil,
        });
        var result = Engine.Engine.Analyze(new AnalysisRequest
        {
            Session = session,
            PoseFile = poseFile,
            OutDir = outDir,
        });

        Console.WriteLine($"{result.Task}  —  {result.Model}, {result.AnimalCount} animal(s), "
                          + $"{result.Frames} frames at {result.Fps:F3} fps\n");
        foreach (var m in result.Metrics)
        {
            string value = m.ValueText
                           ?? (m.Value is { } v && double.IsFinite(v)
                               ? (m.Censored is null ? "" : "≥ ") + v.ToString("F" + m.Decimals)
                               : "—");
            Console.WriteLine($"  {(m.Highlight ? "*" : " ")} {m.Title,-44} {value,12} {m.Unit}"
                              + (m.Censored is null ? "" : $"  ({m.Censored})"));
        }
        foreach (var w in result.Warnings) Console.WriteLine("\n  warning: " + w);
        foreach (var n in result.Notes) Console.WriteLine("  note: " + n);
        Console.WriteLine("\nwritten to " + result.OutDir);
        foreach (var f in result.Written) Console.WriteLine("  " + f);
        return 0;
    }

    private static int Run(Options o)
    {
        string video = o.Need(0, "VIDEO");
        string runDir = o.Need(1, "RUNDIR");
        var outcome = RunTracking(o, video, runDir);
        Console.WriteLine();
        string outDir = Path.Combine(runDir, "results");
        var session = o.BuildSession(outcome.Video) with { UsedModel = outcome.Plan.ModelName };
        var result = Engine.Engine.Analyze(new AnalysisRequest
        {
            Session = session,
            PoseFile = outcome.Result.PoseFile,
            OutDir = outDir,
        });
        Console.WriteLine($"{result.Task}\n");
        foreach (var m in result.Metrics.Where(m => m.Highlight))
            Console.WriteLine($"  {m.Title,-44} {(m.Value is { } v ? v.ToString("F" + m.Decimals) : "—"),12} {m.Unit}");
        foreach (var w in result.Warnings) Console.WriteLine("\n  warning: " + w);
        foreach (var n in result.Notes) Console.WriteLine("  note: " + n);
        Console.WriteLine("\nwritten to " + result.OutDir);
        Console.WriteLine($"\nTo see the tracking on the video:\n"
                          + $"  rodentflow annotate \"{runDir}\" \"{Path.Combine(runDir, "annotated.mp4")}\" "
                          + $"--video \"{video}\"");
        return 0;
    }

    private static int Annotate(Options o)
    {
        string runDir = o.Need(0, "RUNDIR");
        string output = o.Need(1, "OUTPUT");
        string video = o.String("video")
            ?? throw new ArgumentException("annotate needs --video: the file that was analysed");

        var corners = o.Corners();
        var result = AnnotatedVideoWriter.Write(new AnnotatedVideoWriter.Request
        {
            RunFolder = runDir,
            VideoPath = video,
            Output = output,
            From = o.Number("from") ?? 0,
            To = o.Number("to") ?? 0,
            Every = o.Integer("every") ?? 1,
            Fps = o.Number("fps") ?? 0,
            Crop = o.Has("no-crop") ? null : PlanCrop(o, video),
            ArenaCorners = corners.Length >= 3 ? corners : null,
            Tools = o.Tools,
        }, new Progress<int>(n => Console.Write($"\r  {n} frames          ")));

        Console.WriteLine();
        Console.WriteLine($"wrote {result.Output}");
        Console.WriteLine($"  {result.FramesWritten} frames at {result.Fps:F2} fps"
                          + (result.FramesWithoutDetection > 0
                              ? $", {result.FramesWithoutDetection} with no detection (red border)"
                              : ", every frame has a detection"));
        Console.WriteLine();
        Console.WriteLine("  filled dot   keypoint the analysis used");
        Console.WriteLine("  hollow dot   confidence below 0.5, so the analysis treats it as missing");
        Console.WriteLine("  grey box     the region given to the model");
        Console.WriteLine("  amber box    the arena you calibrated (only with --corners)");
        Console.WriteLine("  red border   the model found nothing in that frame");
        return 0;
    }

    /// <summary>The crop the engine would use, so the overlay shows what the model was given.</summary>
    private static CropPixels? PlanCrop(Options o, string video)
    {
        try
        {
            var probe = FFprobe.Probe(video, o.Tools);
            var session = o.BuildSession(probe);
            return Engine.Engine.PlanRun(new RunPlanRequest
            {
                Settings = session.Inference,
                Calibration = session.Calibration,
                FrameWidth = probe.Width,
                FrameHeight = probe.Height,
            }).Crop;
        }
        catch (Exception)
        {
            return null;   // the overlay is still useful without it
        }
    }

    private static int TrackInfo(Options o)
    {
        string runDir = o.Need(0, "RUNDIR");
        string poseFile = File.Exists(runDir) ? runDir : Path.Combine(runDir, "pose.mpt");
        var info = Engine.Engine.TrackInfo(poseFile);
        string sampling = info.FrameStride == 1 ? "every frame" : $"every {info.FrameStride}th frame";
        Console.WriteLine($"frames         {info.Frames} ({sampling})");
        Console.WriteLine($"animals        {info.AnimalCount}");
        Console.WriteLine($"frame rate     {info.Fps:F4}");
        Console.WriteLine($"frame size     {info.FrameWidth:F0} × {info.FrameHeight:F0}");
        Console.WriteLine($"time covered   {info.FirstTime:F3} – {info.LastTime:F3} s (processed to {info.ProcessedUntil:F3})");
        Console.WriteLine($"complete       {info.Complete}");
        Console.WriteLine($"model time     {info.MsPerFrame:F2} ms/frame");
        if (info.AnimalCount > 1)
            Console.WriteLine($"identity       {info.IdentityUncertainFrames} frame(s) marked for review");
        return 0;
    }
}

/// <summary>A small argument reader, so the tool needs no NuGet package.</summary>
internal sealed class Options
{
    private readonly List<string> _positional = [];
    private readonly Dictionary<string, List<string>> _flags = new(StringComparer.OrdinalIgnoreCase);

    public static Options Parse(IEnumerable<string> args)
    {
        var o = new Options();
        string? flag = null;
        foreach (var a in args)
        {
            if (a.StartsWith("--", StringComparison.Ordinal))
            {
                flag = a[2..];
                o._flags.TryAdd(flag, []);
            }
            else if (flag is not null)
            {
                o._flags[flag].Add(a);
                if (flag is not ("cm" or "corners" or "center" or "edge")) flag = null;
            }
            else
            {
                o._positional.Add(a);
            }
        }
        return o;
    }

    public string Need(int index, string name) =>
        index < _positional.Count ? _positional[index]
            : throw new ArgumentException($"Missing {name}. Try: rodentflow --help");

    public bool Has(string flag) => _flags.ContainsKey(flag);
    public string? String(string flag) => _flags.TryGetValue(flag, out var v) && v.Count > 0 ? v[0] : null;
    public string[] Strings(string flag) => _flags.TryGetValue(flag, out var v) ? v.ToArray() : [];
    public double? Number(string flag) =>
        double.TryParse(String(flag), System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : null;
    public int? Integer(string flag) => int.TryParse(String(flag), out var i) ? i : null;

    public bool Chinese => Has("zh");
    public string? Provider => String("provider");
    public int Threads => Integer("threads") ?? 0;

    public string ModelsDir => String("models")
        ?? Path.Combine(AppContext.BaseDirectory, "models");

    public FFmpegTools Tools => String("ffmpeg") is { } dir ? FFmpegTools.In(dir) : new FFmpegTools();

    /// <summary>
    /// The session the engine analyses: a file when one is given, otherwise built from the options.
    /// The engine fills in everything that is missing with its own defaults.
    /// </summary>
    public Session BuildSession(VideoInfo video)
    {
        if (String("session") is { } path)
        {
            var text = File.ReadAllText(path);
            var loaded = JsonSerializer.Deserialize<Session>(text, EngineJson.Options)
                         ?? throw new ArgumentException($"{path} is not a session");
            return loaded with
            {
                VideoName = loaded.VideoName.Length > 0 ? loaded.VideoName : Path.GetFileName(video.Path),
                Video = loaded.Video with
                {
                    Fps = video.Fps, Width = video.Width, Height = video.Height,
                    Duration = video.Duration, FileSize = video.FileSize,
                },
            };
        }

        string task = String("task") ?? "open_field";
        var animals = Integer("animals");
        var coat = String("coat") switch
        {
            "white" => CoatColor.White,
            "darkWhite" or "darkwhite" or "bw" => CoatColor.DarkWhite,
            _ => CoatColor.Dark,
        };

        // The task fixes the animal count, except for group behaviour; ask the engine rather than
        // keeping a second copy of that rule here.
        var catalogue = Engine.Engine.Catalogue();
        var paradigm = catalogue.Paradigms.FirstOrDefault(p => p.Id == task)
            ?? throw new ArgumentException(
                $"Unknown task '{task}'. Run `rodentflow catalogue` for the list.");
        int count = paradigm.IsGroup
            ? Math.Clamp(animals ?? catalogue.DefaultGroupAnimals, 3, catalogue.MaxGroupAnimals)
            : paradigm.AnimalCount;

        var settings = new InferenceSettings
        {
            Stride = Math.Max(1, Integer("stride") ?? 1),
            Grayscale = !Has("no-gray"),
            AnimalCount = count,
            StartTime = Number("from") ?? 0,
            EndTime = Number("to") ?? 0,
            Region = String("region") is "full" or "fullFrame" ? TrackingRegion.FullFrame : TrackingRegion.Arena,
            ArenaMargin = Number("margin") ?? 0.12,
            Coat = coat,
        };

        // The task's own default setup — arena shape and size, handle layout for this frame, markers,
        // parameters — from the engine; the command line only overrides parts of it. (Starting from
        // a bare ArenaCalibration gave every task a 40 × 40 cm rectangle, and sending only the
        // overridden parameters dropped the task's own defaults, e.g. the 300 s window of the
        // elevated plus maze.)
        var defaults = Engine.Engine.DefaultSetup(new DefaultSetupRequest
        {
            Paradigm = task,
            Arena = RequestedArena(),
            FrameWidth = video.Width > 0 ? video.Width : 1280,
            FrameHeight = video.Height > 0 ? video.Height : 960,
        });

        return new Session
        {
            Paradigm = task,
            // The first preset is the task's main analysis phase (Paradigm.phases); not the last.
            Phase = String("phase") ?? paradigm.DefaultPhase,
            SubjectID = String("subject") ?? "",
            Group = String("group") ?? "",
            VideoName = Path.GetFileName(video.Path),
            VideoFile = video.Path.Length > 0 ? video.Path : null,
            Video = new VideoMeta
            {
                Fps = video.Fps, Width = video.Width, Height = video.Height,
                Duration = video.Duration, FileSize = video.FileSize,
            },
            Calibration = BuildCalibration(defaults.Calibration),
            Inference = settings,
            Params = ParamOverrides(defaults.Params),
        };
    }

    /// <summary>The arena shape asked for with --arena; null = the task's default shape.</summary>
    private ArenaKind? RequestedArena() => String("arena") switch
    {
        null => null,
        "none" => ArenaKind.None,
        "rectangle" or "rect" => ArenaKind.Rectangle,
        "circle" => ArenaKind.Circle,
        "plus" or "plusMaze" => ArenaKind.PlusMaze,
        "y" or "yMaze" => ArenaKind.YMaze,
        "t" or "tMaze" => ArenaKind.TMaze,
        var other => throw new ArgumentException($"Unknown --arena '{other}': none, rectangle, circle, plus, y, t"),
    };

    /// <summary>The task's default calibration with what the command line sets on top.</summary>
    private ArenaCalibration BuildCalibration(ArenaCalibration calibration)
    {

        var cm = Strings("cm");
        if (cm.Length >= 2
            && double.TryParse(cm[0], System.Globalization.CultureInfo.InvariantCulture, out var cw)
            && double.TryParse(cm[1], System.Globalization.CultureInfo.InvariantCulture, out var ch))
            calibration = calibration with { WidthCM = cw, HeightCM = ch };
        if (Number("diameter") is { } d) calibration = calibration with { DiameterCM = d };

        var corners = ParsePoints(Strings("corners"));
        if (corners.Length == 4) calibration = calibration with { Corners = corners };
        else if (corners.Length != 0)
            throw new ArgumentException("--corners needs four points: x1,y1,x2,y2,x3,y3,x4,y4");

        var center = ParsePoints(Strings("center"));
        if (center.Length == 1) calibration = calibration with { CircleCenter = center[0] };
        var edge = ParsePoints(Strings("edge"));
        if (edge.Length == 1) calibration = calibration with { CircleEdge = edge[0] };
        return calibration;
    }

    /// <summary>The arena corners given on the command line, if any.</summary>
    public NPoint[] Corners() => ParsePoints(Strings("corners"));

    private static NPoint[] ParsePoints(string[] parts)
    {
        var numbers = parts
            .SelectMany(p => p.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Select(s => double.Parse(s, System.Globalization.CultureInfo.InvariantCulture))
            .ToArray();
        if (numbers.Length % 2 != 0) throw new ArgumentException("Points need an even number of values");
        return Enumerable.Range(0, numbers.Length / 2)
            .Select(i => new NPoint(numbers[2 * i], numbers[2 * i + 1]))
            .ToArray();
    }

    /// <summary>
    /// The task's default parameters with <c>--param key=value</c> on top. Always the complete set:
    /// the engine fills a missing key with the generic default, not the task's (see Models.cs).
    /// A key the task's parameters do not have is refused rather than sent and silently ignored.
    /// </summary>
    private JsonObject ParamOverrides(JsonObject defaults)
    {
        var node = (JsonObject)defaults.DeepClone();
        foreach (var pair in Strings("param"))
        {
            int at = pair.IndexOf('=');
            if (at <= 0) throw new ArgumentException($"--param needs key=value, got '{pair}'");
            string key = pair[..at], value = pair[(at + 1)..];
            if (!node.ContainsKey(key) && key != "cornerFraction")
                throw new ArgumentException($"--param {key}: this task has no parameter called '{key}'");
            node[key] = ParamValue(key, value, node[key]);
        }
        return node;
    }

    /// <summary>
    /// A --param value in the JSON type the engine decodes for that key, judged by the type of the
    /// task's default: a list stays a list ("180,260,340"), a flag a flag, a number a number (written
    /// as an integer when it is one, so Int fields such as holeCount decode).
    /// </summary>
    private static JsonNode ParamValue(string key, string value, JsonNode? current)
    {
        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        if (current is JsonArray)
        {
            var (values, bad) = RodentFlow.Core.Setup.ParamValues.ParseOnsets(value);
            if (values is null) throw new ArgumentException($"--param {key}: '{bad}' is not a number of seconds");
            var list = new JsonArray();
            foreach (var seconds in values) list.Add(JsonValue.Create(seconds));
            return list;
        }
        if (bool.TryParse(value, out var flag)) return JsonValue.Create(flag);
        if (double.TryParse(value, System.Globalization.NumberStyles.Float, invariant, out var number))
            return Math.Abs(number) < 1e15 && number == Math.Floor(number)
                ? JsonValue.Create((long)number)
                : JsonValue.Create(number);
        if (current is JsonValue existing && existing.TryGetValue(out double _))
            throw new ArgumentException($"--param {key}: '{value}' is not a number");
        return JsonValue.Create(value);
    }
}
