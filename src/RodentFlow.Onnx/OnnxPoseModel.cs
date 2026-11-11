using System.Diagnostics;
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using RodentFlow.Core;
using RodentFlow.Engine;

namespace RodentFlow.Onnx;

/// <summary>How to run the models.</summary>
/// <param name="Provider">
/// "Auto" (the app's default): the faster of the processor and each graphics card, timed once per model file on this
/// machine and remembered (<see cref="DeviceChoices"/>). "DML" / "DirectML": the graphics card <paramref name="DeviceId"/>.
/// null or "CPU": the processor, which always works. Another name is passed to ONNX Runtime's string-based
/// <c>AppendExecutionProvider</c> (QNN, SNPE, XNNPACK); one that is not available falls back to the processor.
/// </param>
/// <param name="Configure">Called with the session options before the session is created (anything not covered above).</param>
/// <param name="IntraOpThreads">0 = let ONNX Runtime decide.</param>
/// <param name="DeviceId">DirectML: the graphics adapter (0 = the default one; on a laptop with two, often the integrated one).</param>
public sealed record PoseModelOptions(
    string? Provider = null,
    Action<SessionOptions>? Configure = null,
    int IntraOpThreads = 0,
    int DeviceId = 0);

/// <summary>
/// One RodentFlow pose model as an ONNX file. The file is the same network the Core ML package in
/// the Mac and iOS apps holds — exported from the same checkpoint — so the engine decodes its output
/// with the same code.
/// </summary>
/// <remarks>
/// <para>The export notebook writes <c>rodentflow.model</c> into the ONNX metadata, which is checked here
/// against the model the run plan asked for: loading the wrong file would otherwise go unnoticed and
/// produce plausible, wrong keypoints.</para>
/// <para>The input lives in one array for the model's lifetime, wrapped once as an <see cref="OrtValue"/>; the tracking
/// loop prepares each frame straight into it (<see cref="IPoseModelInput"/>), so no frame-sized copy or tensor object is
/// made per frame.</para>
/// </remarks>
public sealed class OnnxPoseModel : IPoseModel, IPoseModelInput
{
    private readonly InferenceSession _session;
    private readonly RunOptions _run = new();
    private readonly string[] _inputNames;
    private readonly string[] _outputNames;
    private readonly float[] _input;
    private readonly OrtValue _inputValue;
    private readonly OrtValue[] _inputValues;
    /// <summary>Reused between frames; <see cref="Run"/> returns a window onto it.</summary>
    private float[] _output = [];

    public string Name { get; }
    public int InputWidth { get; }
    public int InputHeight { get; }
    /// <summary>"CPU", or "DirectML" with the adapter ("DirectML 1"): what the model runs on.</summary>
    public string ProviderInUse { get; }
    /// <summary>Why the asked-for provider was not used, when it was not.</summary>
    public string? ProviderNote { get; }
    /// <summary>With "Auto": how long one frame took on each device when they were timed (e.g. "CPU 24 ms · DirectML 0 27 ms").</summary>
    public string? Timing { get; }
    /// <summary><c>rodentflow.*</c> and Ultralytics metadata stored in the file.</summary>
    public IReadOnlyDictionary<string, string> Metadata { get; }

    public float[] InputBuffer => _input;

    public OnnxPoseModel(string path, string expectedName, PoseModelOptions? options = null)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("No model file at " + path, path);
        options ??= new PoseModelOptions();

        var opened = OpenSession(path, options);
        _session = opened.Session;
        ProviderInUse = opened.Provider;
        ProviderNote = opened.Note;
        Timing = opened.Timing;
        Metadata = _session.ModelMetadata.CustomMetadataMap;

        if (_session.InputMetadata.Count != 1)
            throw new InvalidDataException($"{Path.GetFileName(path)} has {_session.InputMetadata.Count} inputs; one was expected");
        if (_session.OutputMetadata.Count != 1)
            throw new InvalidDataException($"{Path.GetFileName(path)} has {_session.OutputMetadata.Count} outputs; the end-to-end pose head has one");

        var input = _session.InputMetadata.First();
        int[] inputShape = input.Value.Dimensions;
        if (inputShape.Length != 4 || inputShape[1] != 3)
            throw new InvalidDataException(
                $"{Path.GetFileName(path)} takes {string.Join("×", inputShape)}; [1, 3, H, W] was expected");
        InputHeight = inputShape[2];
        InputWidth = inputShape[3];
        if (InputWidth <= 0 || InputHeight <= 0)
            throw new InvalidDataException(
                $"{Path.GetFileName(path)} has a dynamic input size; export it with a fixed imgsz (960).");

        _inputNames = [input.Key];
        _outputNames = [_session.OutputMetadata.First().Key];
        _input = new float[3 * InputHeight * InputWidth];
        _inputValue = OrtValue.CreateTensorValueFromMemory(_input, [1L, 3L, InputHeight, InputWidth]);
        _inputValues = [_inputValue];

        // The file says which RodentFlow model it is; refuse a mismatch rather than analyse with it.
        Name = Metadata.TryGetValue("rodentflow.model", out var stamped) && stamped.Length > 0
            ? stamped
            : Path.GetFileNameWithoutExtension(path);
        if (!Matches(Name, expectedName))
            throw new InvalidDataException(
                $"{Path.GetFileName(path)} is {Name}, but this run needs {expectedName}.");
    }

    // ---------------------------------------------------------------- choosing the device

    private sealed record Opened(InferenceSession Session, string Provider, string? Note, string? Timing);

    private static SessionOptions BaseOptions(PoseModelOptions options)
    {
        var o = new SessionOptions();
        if (options.IntraOpThreads > 0) o.IntraOpNumThreads = options.IntraOpThreads;
        return o;
    }

    private static InferenceSession? TryDirectML(string path, PoseModelOptions options, int device, out string? error)
    {
        error = null;
        try
        {
            var gpu = BaseOptions(options);
            // Required by the DirectML provider (ONNX Runtime documentation): no memory-pattern planning, one operator
            // at a time.
            gpu.EnableMemoryPattern = false;
            gpu.ExecutionMode = ExecutionMode.ORT_SEQUENTIAL;
            gpu.AppendExecutionProvider_DML(device);
            return new InferenceSession(path, gpu);
        }
        catch (Exception e)
        {
            error = e.Message.Trim();
            return null;
        }
    }

    private static InferenceSession Cpu(string path, PoseModelOptions options) => new(path, BaseOptions(options));

    private static bool Is(string? provider, params string[] names) =>
        provider is { } p && names.Any(n => p.Equals(n, StringComparison.OrdinalIgnoreCase));

    private static Opened OpenSession(string path, PoseModelOptions options)
    {
        if (Is(options.Provider, "Auto")) return Fastest(path, options);
        if (Is(options.Provider, "DML", "DirectML"))
        {
            var gpu = TryDirectML(path, options, options.DeviceId, out string? error);
            return gpu is not null
                ? new Opened(gpu, $"DirectML {options.DeviceId}", null, null)
                : new Opened(Cpu(path, options), "CPU",
                             $"The graphics card could not be used ({error}); using the processor.", null);
        }
        var sessionOptions = BaseOptions(options);
        string provider = "CPU";
        string? note = null;
        if (!string.IsNullOrWhiteSpace(options.Provider) && !Is(options.Provider, "CPU"))
        {
            try
            {
                sessionOptions.AppendExecutionProvider(options.Provider);
                provider = options.Provider;
            }
            catch (Exception e)
            {
                note = $"{options.Provider} is not available ({e.Message.Trim()}); using the processor.";
            }
        }
        if (options.Configure is { } configure)
        {
            try
            {
                configure(sessionOptions);
                provider = "custom";
            }
            catch (Exception e)
            {
                note = $"The execution provider could not be set up ({e.Message.Trim()}); using the processor.";
            }
        }
        return new Opened(new InferenceSession(path, sessionOptions), provider, note, null);
    }

    /// <summary>
    /// The processor and each graphics card DirectML can open (adapters 0 and 1), each timed over a few frames of the real
    /// input size; the fastest is kept and remembered for this model file, so the timing happens once. A graphics card is
    /// not always faster: with one frame at a time, the 11 MB input crosses to the card and back every frame, and an
    /// integrated card can lose to a fast processor (ONNX Runtime performance notes).
    /// </summary>
    private static Opened Fastest(string path, PoseModelOptions options)
    {
        string key = DeviceChoices.Key(path);
        if (DeviceChoices.Get(key) is { } remembered)
        {
            if (remembered.Device >= 0 && TryDirectML(path, options, remembered.Device, out _) is { } gpu)
                return new Opened(gpu, $"DirectML {remembered.Device}", null, remembered.Timing);
            if (remembered.Device < 0) return new Opened(Cpu(path, options), "CPU", null, remembered.Timing);
        }

        var candidates = new List<(int Device, InferenceSession Session, double Ms)>();
        var cpu = Cpu(path, options);
        candidates.Add((-1, cpu, Time(cpu)));
        for (int device = 0; device <= 1; device++)
        {
            if (TryDirectML(path, options, device, out _) is not { } gpu) break;
            double ms;
            try { ms = Time(gpu); }
            catch (Exception) { ms = double.PositiveInfinity; }
            candidates.Add((device, gpu, ms));
        }
        var best = candidates.OrderBy(c => c.Ms).First();
        foreach (var c in candidates.Where(c => !ReferenceEquals(c.Session, best.Session))) c.Session.Dispose();
        string timing = string.Join(" · ", candidates.Select(c =>
            (c.Device < 0 ? "CPU" : $"DirectML {c.Device}") + " " + (double.IsFinite(c.Ms) ? $"{c.Ms:F0} ms" : "failed")));
        DeviceChoices.Set(key, new DeviceChoice(best.Device, timing));
        return new Opened(best.Session, best.Device < 0 ? "CPU" : $"DirectML {best.Device}", null, timing);
    }

    /// <summary>Median milliseconds per frame over 7 runs of a blank frame of the model's own size, after 3 warm-up runs.</summary>
    private static double Time(InferenceSession session)
    {
        var meta = session.InputMetadata.First();
        int[] dims = meta.Value.Dimensions;
        long[] shape = dims.Select(d => (long)Math.Max(1, d)).ToArray();
        var data = new float[shape.Aggregate(1L, (a, b) => a * b)];
        using var value = OrtValue.CreateTensorValueFromMemory(data, shape);
        using var run = new RunOptions();
        string[] inputs = [meta.Key];
        string[] outputs = [session.OutputMetadata.First().Key];
        OrtValue[] values = [value];
        var times = new List<double>();
        var clock = new Stopwatch();
        for (int i = 0; i < 10; i++)
        {
            clock.Restart();
            using (session.Run(run, inputs, values, outputs)) { }
            clock.Stop();
            if (i >= 3) times.Add(clock.Elapsed.TotalMilliseconds);
        }
        times.Sort();
        return times[times.Count / 2];
    }

    /// <summary>
    /// The engine's model names carry the Core ML precision ("MousePose6_960_int8"); the ONNX export
    /// is the same checkpoint at another precision, so compare the part before the size.
    /// </summary>
    private static bool Matches(string stamped, string expected)
    {
        static string Head(string s) => s.Split('_')[0];
        return Head(stamped).Equals(Head(expected), StringComparison.OrdinalIgnoreCase);
    }

    // ---------------------------------------------------------------- running

    public PoseModelOutput Run(ReadOnlySpan<float> input)
    {
        int need = _input.Length;
        if (input.Length < need)
            throw new ArgumentException($"The model needs {need} floats, got {input.Length}", nameof(input));
        input[..need].CopyTo(_input);
        return RunBuffer();
    }

    public PoseModelOutput RunBuffer()
    {
        int detections, fields;
        using (var results = _session.Run(_run, _inputNames, _inputValues, _outputNames))
        {
            var value = results.First();
            long[] shape = value.GetTensorTypeAndShape().Shape;
            if (shape.Length != 3)
                throw new InvalidDataException(
                    $"{Name} returned a {shape.Length}-dimensional output; the end-to-end pose head gives [1, detections, fields]");
            detections = (int)shape[1];
            fields = (int)shape[2];
            // Copied out before the result is disposed: the output is native memory that disposal releases.
            int length = detections * fields;
            if (_output.Length < length) _output = new float[length];
            value.GetTensorDataAsSpan<float>()[..length].CopyTo(_output);
        }
        // Contiguous row-major, so the strides follow from the shape.
        return new PoseModelOutput(_output.AsMemory(0, detections * fields), TensorShape.Contiguous(detections, fields));
    }

    public void Dispose()
    {
        _inputValue.Dispose();
        _run.Dispose();
        _session.Dispose();
    }
}

/// <summary>Which device "Auto" chose for a model file: -1 = the processor, otherwise the DirectML adapter.</summary>
public sealed record DeviceChoice(int Device, string Timing);

/// <summary>
/// The devices "Auto" chose, per model file (name, size and date, so a new export is timed again), kept in
/// <c>%LOCALAPPDATA%\RodentFlow\device-choice.json</c>. Delete the file to time again (e.g. after a new graphics card).
/// </summary>
public static class DeviceChoices
{
    private static readonly object Gate = new();

    public static string FilePath { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RodentFlow", "device-choice.json");

    public static string Key(string modelPath)
    {
        var f = new FileInfo(modelPath);
        return $"{f.Name}|{f.Length}|{f.LastWriteTimeUtc.Ticks}";
    }

    private static Dictionary<string, DeviceChoice> Read()
    {
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<Dictionary<string, DeviceChoice>>(File.ReadAllText(FilePath)) ?? new Dictionary<string, DeviceChoice>()
                : new Dictionary<string, DeviceChoice>();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return new Dictionary<string, DeviceChoice>();
        }
    }

    public static DeviceChoice? Get(string key)
    {
        lock (Gate) return Read().TryGetValue(key, out var c) ? c : null;
    }

    public static void Set(string key, DeviceChoice choice)
    {
        lock (Gate)
        {
            var all = Read();
            all[key] = choice;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(all));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Timed again next time.
            }
        }
    }

    /// <summary>Forget every choice (the next run times the devices again).</summary>
    public static void Clear()
    {
        lock (Gate)
        {
            try { if (File.Exists(FilePath)) File.Delete(FilePath); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }
}

/// <summary>Finds the model files, so the app can say plainly which one is missing.</summary>
public sealed class OnnxModelLibrary
{
    private readonly string _folder;
    private readonly PoseModelOptions _options;

    /// <param name="folder">Folder holding the exported .onnx files.</param>
    public OnnxModelLibrary(string folder, PoseModelOptions? options = null)
    {
        _folder = folder;
        _options = options ?? new PoseModelOptions();
    }

    /// <summary>
    /// The file for a model the engine named, e.g. "MousePose6_960_int8" →
    /// <c>MousePose6_960_fp32.onnx</c> or any other file whose name starts with "MousePose6".
    /// </summary>
    public string? FindFile(string modelName)
    {
        if (!Directory.Exists(_folder)) return null;
        string head = modelName.Split('_')[0];
        return Directory.EnumerateFiles(_folder, "*.onnx")
            .Where(f => Path.GetFileName(f).StartsWith(head, StringComparison.OrdinalIgnoreCase))
            .OrderBy(f => Path.GetFileName(f).Length)
            .FirstOrDefault();
    }

    /// <summary>Which of the engine's models are present, for a settings page.</summary>
    public IReadOnlyDictionary<string, string?> Survey(IEnumerable<string> modelNames) =>
        modelNames.ToDictionary(n => n, FindFile);

    /// <summary>Opens the model, or says what is missing. Pass this to <see cref="TrackingJob"/>.</summary>
    public IPoseModel Open(string modelName)
    {
        string? file = FindFile(modelName);
        if (file is null)
            throw new FileNotFoundException(
                $"No file for {modelName} in {_folder}. Export it with the notebook "
                + "RodentFlow_Export_ONNX_All_Models.ipynb and copy the .onnx file here.");
        return new OnnxPoseModel(file, modelName, _options);
    }
}
