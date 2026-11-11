using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace RodentFlow.Engine;

// The JSON contract with RodentFlowABI.dll. Names match the Swift types, because the engine's own
// Codable conformances decode these (SessionModels.swift, ArenaROI.swift, PoseStream.swift).
//
// The engine's session decoding is deliberately tolerant — "missing keys fall back to defaults"
// (SessionModels.swift) — so anything left null here simply takes the engine's default.
//
// AnalysisParams (138 fields) is carried as a raw JsonObject instead of being mirrored in C#, but it
// must always be COMPLETE: the object the engine handed out (rf_default_setup / rf_setup_view), edited
// in place. A missing params object gets the task's defaults (AnalysisParams.defaults(for:)), but a
// partial one does not — each missing key falls back to the generic AnalysisParams() value, so an
// elevated plus maze sent as {"openAxis":"EW"} alone would lose its 300 s window without a word.

public static class EngineJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
        // The engine's enums are lowerCamelCase raw values ("dark", "darkWhite", "fullFrame",
        // "plusMaze"), so enum members are written with the same policy as property names.
        // Numbers: the engine writes NaN and infinity as null (they are not JSON); see LenientDoubleConverter.
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase), new LenientDoubleConverter() },
    };

    public static string Write<T>(T value) => JsonSerializer.Serialize(value, Options);

    public static T Read<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Options)
        ?? throw new RodentFlowException("The engine returned empty JSON");
}

/// <summary>
/// Reads a JSON number, or null as NaN. The engine writes every non-finite Double as null
/// (RFJSON.number), so a heat-map cell outside the arena arrives as null in a list of numbers; the
/// default reader would refuse the whole reply. Writes exactly as before: a finite number as a
/// number, NaN and infinity as the named literals ("NaN", "Infinity").
/// </summary>
/// <remarks>
/// For <c>double?</c> properties the serializer wraps this converter and keeps null as null.
/// </remarks>
public sealed class LenientDoubleConverter : JsonConverter<double>
{
    public override bool HandleNull => true;

    public override double Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null:
                return double.NaN;
            case JsonTokenType.Number:
                return reader.GetDouble();
            case JsonTokenType.String:
                string? text = reader.GetString();
                return text switch
                {
                    "NaN" or "nan" => double.NaN,
                    "Infinity" or "inf" => double.PositiveInfinity,
                    "-Infinity" or "-inf" => double.NegativeInfinity,
                    _ => double.TryParse(text, System.Globalization.NumberStyles.Float,
                                         System.Globalization.CultureInfo.InvariantCulture, out double v)
                        ? v
                        : throw new JsonException($"Not a number: {text}"),
                };
            default:
                throw new JsonException($"Expected a number, found {reader.TokenType}");
        }
    }

    public override void Write(Utf8JsonWriter writer, double value, JsonSerializerOptions options)
    {
        if (double.IsFinite(value)) writer.WriteNumberValue(value);
        else if (double.IsNaN(value)) writer.WriteStringValue("NaN");
        else writer.WriteStringValue(value > 0 ? "Infinity" : "-Infinity");
    }
}

public class RodentFlowException : Exception
{
    public RodentFlowException(string message) : base(message) { }
}

/// <summary>Common shape of every engine reply.</summary>
public record EngineReply
{
    public bool Ok { get; init; }
    public string? Error { get; init; }
}

// ---------------------------------------------------------------- library

public record EngineVersion : EngineReply
{
    public string App { get; init; } = "";
    public string Version { get; init; } = "";
    public string Build { get; init; } = "";
    public int Abi { get; init; }
    public string[] Keypoints { get; init; } = [];
    public string[] Models { get; init; } = [];
}

public record PhaseOption(string Key, string Title);

public record ParadigmInfo
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string EnglishName { get; init; } = "";
    public string ShortName { get; init; } = "";
    /// <summary>social · navigation · anxiety · memory · motor · general</summary>
    public string Category { get; init; } = "";
    public string CategoryTitle { get; init; } = "";
    public int AnimalCount { get; init; }
    public bool IsGroup { get; init; }
    /// <summary>Preset phases, the main analysis phase first. Empty = the researcher's own labels.</summary>
    public PhaseOption[] Phases { get; init; } = [];
    /// <summary>Arena shapes the task offers, its default first.</summary>
    public ArenaKind[] ArenaKinds { get; init; } = [];
    public ArenaKind DefaultArena { get; init; } = ArenaKind.Rectangle;
    /// <summary>Every marker the task can have (cups, objects, platform …); which are in use depends on the parameters.</summary>
    public MarkerInfo[] Markers { get; init; } = [];
    /// <summary>cm: width × height; diameter × track width (zero maze); arm length × arm width (mazes).</summary>
    public ArenaSize DefaultArenaSize { get; init; } = new(40, 40);
    public string PrimaryMetric { get; init; } = "";
    /// <summary>Phase → the phase of the same animal its measures are paired with (e.g. Post-test → Pre-test).</summary>
    public Dictionary<string, string> Companions { get; init; } = new();
    public string Tagline { get; init; } = "";
    public string Summary { get; init; } = "";
    public string[] SetupTips { get; init; } = [];

    /// <summary>The phase a new session starts in: the first preset, or none.</summary>
    public string DefaultPhase => Phases.Length > 0 ? Phases[0].Key : "";
}

public record MarkerInfo(string Key, string Label, string Title);

public record ArenaSize(double Width, double Height);

public record ArenaKindInfo
{
    public ArenaKind Id { get; init; }
    public string Title { get; init; } = "";
    /// <summary>Handle labels of a maze, centre first (C N E S W · J A B C · J S L R).</summary>
    public string[] MazeLabels { get; init; } = [];
}

public record Catalogue : EngineReply
{
    public string[] Models { get; init; } = [];
    public string[] Keypoints { get; init; } = [];
    public int MaxGroupAnimals { get; init; }
    public int DefaultGroupAnimals { get; init; }
    public double AnalysisMinScore { get; init; }
    public ParadigmInfo[] Paradigms { get; init; } = [];
    public ArenaKindInfo[] ArenaKinds { get; init; } = [];
}

// ---------------------------------------------------------------- settings

/// <summary>Coat colour, which chooses the pose model (PoseModels.swift).</summary>
public enum CoatColor { Dark, White, DarkWhite }

/// <summary>How much of the frame is tracked (ArenaROI.swift).</summary>
public enum TrackingRegion { Arena, FullFrame }

/// <summary>Arena shape (Paradigms.swift).</summary>
public enum ArenaKind { None, Rectangle, Circle, PlusMaze, YMaze, TMaze }

/// <summary>A rectangle in normalized upright-frame coordinates, origin top-left (NRect).</summary>
public record NRect(double X, double Y, double W, double H)
{
    public static readonly NRect Full = new(0, 0, 1, 1);
    public bool IsFullFrame => X <= 1e-6 && Y <= 1e-6 && X + W >= 1 - 1e-6 && Y + H >= 1 - 1e-6;
}

/// <summary>A point in normalized upright-frame coordinates (NPoint).</summary>
public record NPoint(double X, double Y);

/// <summary>InferenceSettings — what a recognition run does.</summary>
public record InferenceSettings
{
    public int Stride { get; init; } = 1;
    public bool Grayscale { get; init; } = true;
    public int AnimalCount { get; init; } = 1;
    public double StartTime { get; init; }
    /// <summary>0 = until the end of the video.</summary>
    public double EndTime { get; init; }
    public TrackingRegion Region { get; init; } = TrackingRegion.Arena;
    /// <summary>Margin around the arena as a fraction of its longer side (default 0.12).</summary>
    public double ArenaMargin { get; init; } = 0.12;
    /// <summary>Set by the engine when a run starts; leave null.</summary>
    public NRect? Roi { get; init; }
    public CoatColor Coat { get; init; } = CoatColor.Dark;
}

/// <summary>ArenaCalibration — the arena in the picture and its real size.</summary>
public record ArenaCalibration
{
    public ArenaKind Kind { get; init; } = ArenaKind.Rectangle;
    public NPoint[] Corners { get; init; } =
        [new(0.1, 0.1), new(0.9, 0.1), new(0.9, 0.9), new(0.1, 0.9)];
    public double WidthCM { get; init; } = 40;
    public double HeightCM { get; init; } = 40;
    public NPoint CircleCenter { get; init; } = new(0.5, 0.5);
    public NPoint CircleEdge { get; init; } = new(0.85, 0.5);
    public double DiameterCM { get; init; } = 40;
    public NPoint[] MazePoints { get; init; } = [];
    public double ArmWidthCM { get; init; } = 5;
    public double ArmLengthCM { get; init; } = 30;
    public Dictionary<string, NPoint> Markers { get; init; } = new();
    public double RingWidthCM { get; init; }
}

/// <summary>VideoMeta — what the engine records about the file.</summary>
public record VideoMeta
{
    public double Duration { get; init; }
    public double Fps { get; init; } = 30;
    public double Width { get; init; } = 1920;
    public double Height { get; init; } = 1080;
    public long FileSize { get; init; }
}

/// <summary>
/// Session — one analysis. Only the fields the Windows app sets are modelled; everything else takes
/// the engine's default. <see cref="Params"/> is a raw object so the 138 analysis parameters are not
/// duplicated here (see the note at the top of this file).
/// </summary>
public record Session
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    /// <summary>Paradigm id, e.g. "open_field" (see <see cref="Catalogue.Paradigms"/>).</summary>
    public string Paradigm { get; init; } = "open_field";
    public string SubjectID { get; init; } = "";
    public string Group { get; init; } = "";
    /// <summary>"", "M" or "F".</summary>
    public string Sex { get; init; } = "";
    /// <summary>Stored English phase key (see <see cref="ParadigmInfo.Phases"/>).</summary>
    public string Phase { get; init; } = "";
    public int? Day { get; init; }
    public int? Trial { get; init; }
    public string VideoName { get; init; } = "";
    public string? VideoFile { get; init; }
    public VideoMeta Video { get; init; } = new();
    public ArenaCalibration Calibration { get; init; } = new();
    public JsonObject? Params { get; init; }
    public InferenceSettings Inference { get; init; } = new();
    public InferenceSettings? UsedInference { get; init; }
    public string? UsedModel { get; init; }
}

// ---------------------------------------------------------------- setup (ABI/Setup.swift)

/// <summary>A task's default calibration for a frame, and its default parameters.</summary>
public record DefaultSetupRequest
{
    public string Paradigm { get; init; } = "";
    /// <summary>Arena shape; null = the task's default.</summary>
    public ArenaKind? Arena { get; init; }
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
    /// <summary>The current parameters, to reset only the handles; null = the task's defaults.</summary>
    public JsonObject? Params { get; init; }
}

public record SetupDefaults : EngineReply
{
    public ArenaCalibration Calibration { get; init; } = new();
    public JsonObject Params { get; init; } = new();
}

public record SetupViewRequest
{
    public Session Session { get; init; } = new();
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
}

public record MoveHandleRequest : SetupViewRequest
{
    public string Handle { get; init; } = "";
    /// <summary>Normalized frame coordinates.</summary>
    public double X { get; init; }
    public double Y { get; init; }
}

/// <summary>What the calibration picture shows for a setup. Points are normalized frame coordinates.</summary>
public record SetupView : EngineReply
{
    public ZoneInfo[] Zones { get; init; } = [];
    public HandleInfo[] Handles { get; init; } = [];
    /// <summary>The part of the frame the model will be given; null = the whole frame.</summary>
    public NRect? Region { get; init; }
    public bool IsMetric { get; init; }
    public double? PixelsPerCM { get; init; }
    /// <summary>The setup as the engine read it. Keep these rather than what was sent.</summary>
    public ArenaCalibration Calibration { get; init; } = new();
    public JsonObject Params { get; init; } = new();
}

public record ZoneInfo
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    /// <summary>ZoneRole raw value: center, open, closed, cup, object, novel, light, dark, target …</summary>
    public string Role { get; init; } = "";
    /// <summary>[x, y] pairs; an entry is null where the engine had no finite value.</summary>
    public double?[][] Outline { get; init; } = [];
    public double?[] Center { get; init; } = [];
    public bool OutlineOnly { get; init; }
    public bool ShowsLabel { get; init; } = true;
}

public record HandleInfo
{
    public string Id { get; init; } = "";
    public string Label { get; init; } = "";
    public double? X { get; init; }
    public double? Y { get; init; }
    /// <summary>arena (yellow) · open (cyan, an open arm) · divider (purple) · marker (cyan)</summary>
    public string Kind { get; init; } = "";
    public string Title { get; init; } = "";
}

// ---------------------------------------------------------------- run plan

/// <summary>Asks the engine what a run on this video would use (model, region, decode size).</summary>
public record RunPlanRequest
{
    public InferenceSettings Settings { get; init; } = new();
    public ArenaCalibration Calibration { get; init; } = new();
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
}

/// <summary>The region given to the model, in pixels of the upright whole frame.</summary>
public record CropPixels
{
    public int X { get; init; }
    public int Y { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
}

public record RunPlan : EngineReply
{
    public string ModelName { get; init; } = "";
    public int AnimalCount { get; init; }
    public CoatColor Coat { get; init; }
    public bool Grayscale { get; init; }
    public int Stride { get; init; }
    /// <summary>The tracked region, normalized; null = whole frame.</summary>
    public NRect? Roi { get; init; }
    public CropPixels Crop { get; init; } = new();
    /// <summary>Reduced decode size for a large frame, or null for full size.</summary>
    public double? DecodeScale { get; init; }
    public int? DecodeWidth { get; init; }
    public int? DecodeHeight { get; init; }
}

// ---------------------------------------------------------------- tracking run

public record TrackingRunRequest
{
    /// <summary>File name only; stored in the manifest.</summary>
    public string VideoName { get; init; } = "";
    /// <summary>Run folder. Must be empty the first time; continued afterwards.</summary>
    public string Destination { get; init; } = "";
    /// <summary>One of <see cref="Catalogue.Models"/>.</summary>
    public string ModelName { get; init; } = "";
    public InferenceSettings Settings { get; init; } = new();
    /// <summary>The region given to the model, normalized; null = whole frame.</summary>
    public NRect? Roi { get; init; }
    public double Fps { get; init; }
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
    public double VideoDuration { get; init; }
    public ulong SourceSize { get; init; }
    public double SourceModification { get; init; }
    public string SourceFingerprint { get; init; } = "";
    /// <summary>Reduced decode size in use, or null for full size.</summary>
    public double? DecodeScale { get; init; }
    public int ModelInputWidth { get; init; } = 960;
    public int ModelInputHeight { get; init; } = 960;
}

public record RunOpenInfo : EngineReply
{
    public int Handle { get; init; }
    public int AnimalCount { get; init; }
    public int AppearanceDims { get; init; }
    public double ConfidenceThreshold { get; init; }
    public int MaxDetections { get; init; }
    public int Stride { get; init; }
    public double RangeStart { get; init; }
    public double RangeEnd { get; init; }
    public double? ResumeAfter { get; init; }
    public double? DecodeScale { get; init; }
    public NRect? Roi { get; init; }
    public bool Grayscale { get; init; }
    public int ModelInputWidth { get; init; }
    public int ModelInputHeight { get; init; }
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
    public int CompletedSegments { get; init; }
    public int TotalSegments { get; init; }
    public int RecordCount { get; init; }
    public bool AlreadyFinished { get; init; }
    public string ModelName { get; init; } = "";
}

public record RunProgress : EngineReply
{
    public int CompletedSegments { get; init; }
    public int TotalSegments { get; init; }
    public int CurrentSegment { get; init; }
    public int ProcessedInSegment { get; init; }
    public double SourceTime { get; init; }
    public double SourceDuration { get; init; }
    public int AnalysedFrames { get; init; }
}

public record RunFinishResult : EngineReply
{
    public string PoseFile { get; init; } = "";
    public int Frames { get; init; }
    public int FailedFrames { get; init; }
    public int AnimalCount { get; init; }
    public int IdentityUncertain { get; init; }
    public double ProcessedUntil { get; init; }
    public bool AlreadyFinished { get; init; }
}

/// <summary>One animal in one frame, in upright whole-frame pixels.</summary>
public record PoseKeypoints
{
    public bool Detected { get; init; }
    public float Conf { get; init; }
    public float[] X { get; init; } = [];
    public float[] Y { get; init; } = [];
    public float[] Kconf { get; init; } = [];
}

public record FramePoses : EngineReply
{
    public PoseKeypoints[] Poses { get; init; } = [];
}

// ---------------------------------------------------------------- analysis

public record AnalysisRequest
{
    public Session Session { get; init; } = new();
    public string PoseFile { get; init; } = "";
    public string OutDir { get; init; } = "";
    public Dictionary<string, double>? Companion { get; init; }
    public JsonObject? Marbles { get; init; }
    public bool? WriteExports { get; init; }
    /// <summary>Also return the whole report for the result page (<see cref="AnalysisResult.Report"/>).</summary>
    public bool? IncludeReport { get; init; }
    /// <summary>"english" for figures saved to files; null = the interface language.</summary>
    public string? ReportLanguage { get; init; }
}

public record Metric
{
    public string Key { get; init; } = "";
    public string Title { get; init; } = "";
    public string Unit { get; init; } = "";
    public double? Value { get; init; }
    public int Decimals { get; init; }
    public bool Highlight { get; init; }
    /// <summary>Set when the value is a right-censored latency (e.g. "no entry").</summary>
    public string? Censored { get; init; }
    /// <summary>Text shown instead of the number (e.g. "Deep", "5 / 20").</summary>
    public string? ValueText { get; init; }

    /// <summary>
    /// The value as the apps show it: the value text when there is one, "≥ x" for a right-censored
    /// latency, otherwise the number at its own number of decimals. Exports keep the raw number.
    /// </summary>
    public string Display => ValueText
        ?? (Value is { } v && double.IsFinite(v)
            ? (Censored is null ? "" : "≥ ") + v.ToString("F" + Decimals,
                System.Globalization.CultureInfo.CurrentCulture)
            : "—");
}

public record AnalysisResult : EngineReply
{
    public string OutDir { get; init; } = "";
    public string[] Written { get; init; } = [];
    public string Paradigm { get; init; } = "";
    public string Task { get; init; } = "";
    public string Model { get; init; } = "";
    public int AnimalCount { get; init; }
    public int Frames { get; init; }
    public double Fps { get; init; }
    public double WindowStart { get; init; }
    public Metric[] Metrics { get; init; } = [];
    public string[] Warnings { get; init; } = [];
    public string[] Notes { get; init; } = [];
    /// <summary>The whole report for the result page; present when the request set IncludeReport.</summary>
    public DisplayReport? Report { get; init; }
    /// <summary>The session's summary for the group comparison (SessionMetricSummary); kept as it is, sent back to rf_group_analysis.</summary>
    public JsonObject? Summary { get; init; }
}

// ---------------------------------------------------------------- reading a track

public record TrackInfo : EngineReply
{
    public int Frames { get; init; }
    public int AnimalCount { get; init; }
    public double Fps { get; init; }
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
    public int FrameStride { get; init; }
    public bool Complete { get; init; }
    public double ProcessedUntil { get; init; }
    public double MsPerFrame { get; init; }
    public int AppearanceDims { get; init; }
    public double FirstTime { get; init; }
    public double LastTime { get; init; }
    public int IdentityUncertainFrames { get; init; }
}

public record TrackFrame
{
    public int Index { get; init; }
    public int Frame { get; init; }
    public double Time { get; init; }
    public int Flags { get; init; }
    public PoseKeypoints[] Animals { get; init; } = [];
}

public record TrackFrames : EngineReply
{
    public int From { get; init; }
    public TrackFrame[] Frames { get; init; } = [];
}
