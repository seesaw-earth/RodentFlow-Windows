using System.Runtime.InteropServices;

namespace RodentFlow.Engine;

/// <summary>
/// The RodentFlow shared engine, as the Windows app uses it. Every method here is a thin, typed
/// call into RodentFlowABI.dll; the science is on the other side of that boundary and is the same
/// code the Mac and the iPhone run.
/// </summary>
public static class Engine
{
    /// <summary>Engine version, keypoint names and the pose models it knows.</summary>
    public static EngineVersion Version() =>
        Checked(EngineJson.Read<EngineVersion>(NativeString.Take(RodentFlowNative.rf_version())));

    /// <summary>
    /// Report language. Set it once before analysing; the engine writes metric titles, warnings and
    /// the Methods paragraph in this language.
    /// </summary>
    public static void SetLanguage(bool chinese) => RodentFlowNative.rf_set_language(chinese ? 1 : 0);

    /// <summary>Every task the engine can analyse, for the app's task list.</summary>
    public static Catalogue Catalogue() =>
        Checked(EngineJson.Read<Catalogue>(NativeString.Take(RodentFlowNative.rf_catalogue())));

    /// <summary>
    /// Which model a run would load, which part of the frame it would give it, and at what size the
    /// video should be decoded. Ask this before opening a run: these are engine decisions, so the
    /// app does not carry its own copy of them.
    /// </summary>
    public static RunPlan PlanRun(RunPlanRequest request) =>
        Checked(EngineJson.Read<RunPlan>(
            NativeString.Take(RodentFlowNative.rf_plan_run(EngineJson.Write(request)))));

    /// <summary>
    /// A task's default calibration, laid out for a frame of this size, and its default parameters.
    /// With <see cref="DefaultSetupRequest.Params"/> set, only the handles are reset and those
    /// parameters are kept (apart from what the handles themselves set).
    /// </summary>
    public static SetupDefaults DefaultSetup(DefaultSetupRequest request) =>
        Checked(EngineJson.Read<SetupDefaults>(
            NativeString.Take(RodentFlowNative.rf_default_setup(EngineJson.Write(request)))));

    /// <summary>Zones, handles and tracked region of a setup, and the setup as the engine reads it.</summary>
    public static SetupView SetupView(SetupViewRequest request) =>
        Checked(EngineJson.Read<SetupView>(
            NativeString.Take(RodentFlowNative.rf_setup_view(EngineJson.Write(request)))));

    /// <summary>One handle dragged to a point; the view of the setup after the move.</summary>
    public static SetupView MoveHandle(MoveHandleRequest request) =>
        Checked(EngineJson.Read<SetupView>(
            NativeString.Take(RodentFlowNative.rf_move_handle(EngineJson.Write(request)))));

    /// <summary>Opens, or continues, a recognition run over one video.</summary>
    public static TrackingRun OpenRun(TrackingRunRequest request)
    {
        var reply = EngineJson.Read<RunOpenInfo>(
            NativeString.Take(RodentFlowNative.rf_run_open(EngineJson.Write(request))));
        Checked(reply);
        return new TrackingRun(reply);
    }

    /// <summary>pose.mpt + a session → the task's metrics and the export files.</summary>
    public static AnalysisResult Analyze(AnalysisRequest request) =>
        Checked(EngineJson.Read<AnalysisResult>(
            NativeString.Take(RodentFlowNative.rf_analyze(EngineJson.Write(request)))));

    /// <summary>
    /// Interface texts through the engine's own catalogue (L10n.tr), so the result page uses the
    /// words the Mac uses: Chinese source texts in, the interface language out (or English with
    /// <paramref name="english"/>). Format templates such as "%d 条提示" come back as templates.
    /// </summary>
    public static string[] Translate(IReadOnlyList<string> texts, bool english = false)
    {
        if (texts.Count == 0) return [];
        var reply = Checked(EngineJson.Read<TranslateReply>(NativeString.Take(
            RodentFlowNative.rf_translate(EngineJson.Write(new TranslateRequest(texts.ToArray(), english))))));
        return reply.Texts.Length == texts.Count
            ? reply.Texts
            : throw new RodentFlowException($"rf_translate returned {reply.Texts.Length} texts for {texts.Count}");
    }

    /// <summary>
    /// "Swap A / B from here" on a two-animal pose.mpt (IdentityResolver.correct, as on the Mac): the identity
    /// segment at track index <paramref name="at"/> is reversed and the rest of the video re-solved. pose.mpt is
    /// rewritten; recompute the results afterwards.
    /// </summary>
    public static SwapResult SwapIdentity(string poseFile, int at) =>
        Checked(EngineJson.Read<SwapResult>(NativeString.Take(
            RodentFlowNative.rf_swap_identity(EngineJson.Write(new SwapRequest(poseFile, at, null, null))))));

    /// <summary>"Swap A / B in a range": the segments track indices <paramref name="from"/>…<paramref name="to"/> cover.</summary>
    public static SwapResult SwapIdentity(string poseFile, int from, int to) =>
        Checked(EngineJson.Read<SwapResult>(NativeString.Take(
            RodentFlowNative.rf_swap_identity(EngineJson.Write(new SwapRequest(poseFile, null, from, to))))));

    /// <summary>Identity segments of a two-animal pose.mpt (what a range swap covers).</summary>
    public static IdentitySegmentsReply IdentitySegments(string poseFile) =>
        Checked(EngineJson.Read<IdentitySegmentsReply>(NativeString.Take(RodentFlowNative.rf_identity_segments(poseFile))));

    /// <summary>The marbles to read for a marble-burying session (MarbleGrid); Needed = false otherwise.</summary>
    public static MarblePlan MarblePlan(Session session) =>
        Checked(EngineJson.Read<MarblePlan>(NativeString.Take(RodentFlowNative.rf_marble_plan(EngineJson.Write(session)))));

    /// <summary>
    /// The group comparison of a task (GroupAnalysisEngine, PubGroupFigure): options, texts, tables and the figure,
    /// as the Mac's task page shows them.
    /// </summary>
    public static GroupReply GroupAnalysis(GroupAnalysisCall call) =>
        Checked(EngineJson.Read<GroupReply>(NativeString.Take(RodentFlowNative.rf_group_analysis(EngineJson.Write(call)))));

    /// <summary>Header of a pose.mpt.</summary>
    public static TrackInfo TrackInfo(string poseFile) =>
        Checked(EngineJson.Read<TrackInfo>(NativeString.Take(RodentFlowNative.rf_track_info(poseFile))));

    /// <summary>Frames of a pose.mpt, for drawing the skeleton while scrubbing.</summary>
    public static TrackFrames TrackFrames(string poseFile, int from, int count) =>
        Checked(EngineJson.Read<TrackFrames>(
            NativeString.Take(RodentFlowNative.rf_track_frames(poseFile, from, count))));

    internal static T Checked<T>(T reply) where T : EngineReply =>
        reply.Ok ? reply : throw new RodentFlowException(reply.Error ?? "The engine reported a failure");
}

/// <summary>What <see cref="TrackingRun.Filter"/> says to do with a decoded frame.</summary>
public enum FrameAction
{
    /// <summary>Run the model on this frame, then call <see cref="TrackingRun.Submit"/>.</summary>
    Analyse,
    /// <summary>Skipped by the frame stride.</summary>
    Skip,
    /// <summary>Before the analysed range: keep decoding.</summary>
    BeforeRange,
    /// <summary>Past the analysed range: stop decoding.</summary>
    Stop,
}

/// <summary>
/// One recognition run. The host owns the loop: decode a frame, ask <see cref="Filter"/> what to do
/// with it, run the model, hand the output to <see cref="Submit"/>; at the end call
/// <see cref="Finish"/>, which writes pose.mpt.
/// </summary>
/// <remarks>
/// Drive one run from one thread. Disposing without <see cref="Finish"/> keeps the rows written so
/// far, so the folder can be continued later — that is how "stop" works in the apps.
/// </remarks>
public sealed class TrackingRun : IDisposable
{
    private int _handle;

    internal TrackingRun(RunOpenInfo info)
    {
        Info = info;
        _handle = info.Handle;
    }

    public RunOpenInfo Info { get; }

    /// <summary>The run folder already holds a finished pose.mpt; there is nothing to do.</summary>
    public bool AlreadyFinished => Info.AlreadyFinished;

    /// <summary>
    /// Call for every decoded frame, in presentation order, before running the model. The engine
    /// applies the same guards the Mac read loop applies (resume point, time range, frame stride),
    /// so a Windows run analyses exactly the same frames.
    /// </summary>
    public unsafe FrameAction Filter(double time, out int frameNumber)
    {
        int frame = 0;
        int status = RodentFlowNative.rf_run_filter(_handle, time, &frame);
        frameNumber = frame;
        return status switch
        {
            RodentFlowNative.Analyze => FrameAction.Analyse,
            RodentFlowNative.Skip => FrameAction.Skip,
            RodentFlowNative.BeforeRange => FrameAction.BeforeRange,
            RodentFlowNative.PastRange => FrameAction.Stop,
            _ => throw new RodentFlowException($"rf_run_filter failed with status {status}"),
        };
    }

    /// <summary>
    /// Hands one frame's model output to the engine, which decodes it, assigns identities and writes
    /// the row.
    /// </summary>
    /// <param name="frameNumber">From <see cref="Filter"/>.</param>
    /// <param name="time">The frame's presentation time, as the file gives it.</param>
    /// <param name="tensor">
    /// The model's end-to-end output, <c>[1, detections, fields]</c> of float32. Pass an empty span
    /// when the model failed on this frame: the row is then written as "no animal", as the apps do.
    /// </param>
    /// <param name="shape">Shape and element strides of that output.</param>
    /// <param name="crop">The region given to the model, in upright whole-frame pixels.</param>
    /// <param name="bgra">
    /// The decoded upright frame as 32-bit BGRA. Needed only with two animals, where the engine reads
    /// fur colour off each animal's back to tell them apart; pass an empty span otherwise.
    /// </param>
    /// <param name="wantPoses">Also return the poses, for a live preview.</param>
    public unsafe PoseKeypoints[] Submit(
        int frameNumber, double time,
        ReadOnlySpan<float> tensor, TensorShape shape,
        CropRect crop,
        ReadOnlySpan<byte> bgra, int bgraWidth, int bgraHeight, int bgraRowBytes,
        bool wantPoses = false)
    {
        // The JSON out-parameter is always passed: besides the poses, it is how the engine returns
        // an error message (for instance "too many model failures near 12.3 s").
        IntPtr json = IntPtr.Zero;
        int status;
        fixed (float* t = tensor)
        fixed (byte* b = bgra)
        {
            status = RodentFlowNative.rf_run_frame(
                _handle, frameNumber, time,
                tensor.IsEmpty ? null : t, tensor.Length,
                shape.Detections, shape.Fields, shape.DetectionStride, shape.FieldStride,
                crop.X, crop.Y, crop.Width, crop.Height,
                bgra.IsEmpty ? null : b, bgraWidth, bgraHeight, bgraRowBytes,
                &json);
        }

        string text = NativeString.Take(json);
        if (status != 0)
        {
            string detail = text.Length > 0 ? EngineJson.Read<EngineReply>(text).Error ?? text : "";
            throw new RodentFlowException(
                status == RodentFlowNative.TooManyFailures
                    ? detail
                    : $"rf_run_frame failed with status {status}. {detail}".TrimEnd());
        }
        if (!wantPoses || text.Length == 0) return [];
        return EngineJson.Read<FramePoses>(text).Poses;
    }

    /// <summary>How far the run has got, for a progress bar.</summary>
    public RunProgress Progress() =>
        Engine.Checked(EngineJson.Read<RunProgress>(
            NativeString.Take(RodentFlowNative.rf_run_progress(_handle))));

    /// <summary>
    /// Every frame of the range is in: writes pose.mpt. With two animals this is where A / B are
    /// resolved over the whole video (IdentityResolver).
    /// </summary>
    /// <param name="msPerFrame">Measured model time per frame; recorded in the track.</param>
    public RunFinishResult Finish(double msPerFrame) =>
        Engine.Checked(EngineJson.Read<RunFinishResult>(
            NativeString.Take(RodentFlowNative.rf_run_finish(_handle, msPerFrame))));

    public void Dispose()
    {
        int handle = Interlocked.Exchange(ref _handle, 0);
        if (handle != 0) RodentFlowNative.rf_run_close(handle);
    }
}

/// <summary>Shape and element strides of the model's output tensor.</summary>
/// <remarks>For the usual contiguous <c>[1, 300, 24]</c>: 300, 24, 24, 1.</remarks>
public readonly record struct TensorShape(int Detections, int Fields, int DetectionStride, int FieldStride)
{
    /// <summary>A contiguous <c>[1, detections, fields]</c> tensor.</summary>
    public static TensorShape Contiguous(int detections, int fields) => new(detections, fields, fields, 1);
}

/// <summary>The region given to the model, in pixels of the upright whole frame.</summary>
public readonly record struct CropRect(double X, double Y, double Width, double Height);
