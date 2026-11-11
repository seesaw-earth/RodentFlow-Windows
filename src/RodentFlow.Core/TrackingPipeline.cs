using System.Diagnostics;
using RodentFlow.Engine;

namespace RodentFlow.Core;

/// <summary>What to track, and with what.</summary>
public sealed record TrackingJob
{
    public required string VideoPath { get; init; }
    /// <summary>Run folder. Empty the first time; the same folder continues an interrupted run.</summary>
    public required string Destination { get; init; }
    /// <summary>Stride, grayscale, animal count, time range, region, coat colour.</summary>
    public InferenceSettings Settings { get; init; } = new();
    /// <summary>The arena, which decides the tracked region.</summary>
    public ArenaCalibration Calibration { get; init; } = new();
    /// <summary>Opens the model the run plan asks for.</summary>
    public required Func<string, IPoseModel> OpenModel { get; init; }
    public FFmpegTools Tools { get; init; } = new();
    /// <summary>
    /// With each progress report, a copy of the frame just analysed at most this many pixels on its longest side,
    /// for the window's live picture (0 = none). It is the frame already decoded for the model, so it costs one
    /// small copy every few frames, not another decode.
    /// </summary>
    public int PreviewMaxSide { get; init; }
}

public readonly record struct TrackingProgress(
    double SourceTime,
    double SourceDuration,
    int AnalysedFrames,
    int CompletedSegments,
    int TotalSegments,
    double MsPerFrame,
    PoseKeypoints[] Poses,
    VideoFrameGrabber.Frame? Preview = null);

public sealed record TrackingOutcome(
    RunFinishResult Result,
    RunPlan Plan,
    VideoInfo Video,
    int AnalysedFrames,
    double MsPerFrame);

/// <summary>
/// The recognition loop: decode a frame, ask the engine whether it belongs to the analysis, prepare
/// it, run the model, hand the output back. Everything after the model — decoding the output,
/// keeping the animals apart, writing the rows, resolving A / B and writing pose.mpt — happens in
/// the engine, which is the same code the Mac and the iPhone run.
/// </summary>
public static class TrackingPipeline
{
    /// <summary>A small copy of a BGRA frame (nearest pixel), for showing it while the analysis runs.</summary>
    public static VideoFrameGrabber.Frame Downscale(ReadOnlySpan<byte> bgra, int width, int height, int rowBytes,
                                                   int maxSide, double time)
    {
        double scale = Math.Min(1, (double)maxSide / Math.Max(1, Math.Max(width, height)));
        int w = Math.Max(1, (int)(width * scale)), h = Math.Max(1, (int)(height * scale));
        var pixels = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
        {
            int sy = Math.Min(height - 1, (int)(y / scale));
            int src = sy * rowBytes, dst = y * w * 4;
            for (int x = 0; x < w; x++, dst += 4)
            {
                int s = src + Math.Min(width - 1, (int)(x / scale)) * 4;
                pixels[dst] = bgra[s];
                pixels[dst + 1] = bgra[s + 1];
                pixels[dst + 2] = bgra[s + 2];
                pixels[dst + 3] = 255;
            }
        }
        return new VideoFrameGrabber.Frame(pixels, w, h, w * 4, time);
    }

    /// <summary>How often progress is reported, in frames.</summary>
    private const int ProgressEvery = 15;

    public static TrackingOutcome Run(
        TrackingJob job,
        IProgress<TrackingProgress>? progress = null,
        CancellationToken cancellation = default)
    {
        job.Tools.Check();
        var video = FFprobe.Probe(job.VideoPath, job.Tools);

        var plan = Engine.Engine.PlanRun(new RunPlanRequest
        {
            Settings = job.Settings,
            Calibration = job.Calibration,
            FrameWidth = video.Width,
            FrameHeight = video.Height,
        });

        using var model = job.OpenModel(plan.ModelName);
        var fingerprint = VideoFingerprint.Make(job.VideoPath);

        using var run = Engine.Engine.OpenRun(new TrackingRunRequest
        {
            VideoName = Path.GetFileName(job.VideoPath),
            Destination = job.Destination,
            ModelName = plan.ModelName,
            Settings = job.Settings,
            Roi = plan.Roi,
            Fps = video.Fps,
            FrameWidth = video.Width,
            FrameHeight = video.Height,
            VideoDuration = video.Duration,
            SourceSize = fingerprint.Size,
            SourceModification = fingerprint.Modified,
            SourceFingerprint = fingerprint.Fingerprint,
            DecodeScale = plan.DecodeScale,
            ModelInputWidth = model.InputWidth,
            ModelInputHeight = model.InputHeight,
        });

        if (run.AlreadyFinished)
        {
            var done = run.Finish(0);
            return new TrackingOutcome(done, plan, video, 0, 0);
        }

        using var reader = new FFmpegVideoReader(video, job.Tools,
                                                 plan.DecodeWidth ?? 0, plan.DecodeHeight ?? 0);

        int plane = model.InputWidth * model.InputHeight;
        // Prepared straight into the model's own input when it has one (no copy per frame).
        var direct = model as IPoseModelInput;
        var tensor = direct is { InputBuffer.Length: var n } && n >= 3 * plane ? direct.InputBuffer : new float[3 * plane];
        if (!ReferenceEquals(tensor, direct?.InputBuffer)) direct = null;
        bool wantsColour = run.Info.AppearanceDims > 0;   // two animals: fur colour tells them apart

        var clock = new Stopwatch();
        double modelSeconds = 0;
        int analysed = 0;
        var poses = Array.Empty<PoseKeypoints>();

        foreach (var frame in reader.Frames(cancellation: cancellation))
        {
            cancellation.ThrowIfCancellationRequested();
            var action = run.Filter(frame.Time, out int frameNumber);
            if (action == FrameAction.Stop) break;
            if (action != FrameAction.Analyse) continue;

            var pixels = frame.Pixels.Span;
            FramePreparation.Prepare(
                pixels, frame.Width, frame.Height, frame.RowBytes,
                plan.Crop, video.Width, video.Height,
                run.Info.Grayscale,
                model.InputWidth, model.InputHeight,
                tensor);

            PoseModelOutput output;
            bool failed = false;
            clock.Restart();
            try
            {
                output = direct is not null ? direct.RunBuffer() : model.Run(tensor);
            }
            catch (Exception) when (!cancellation.IsCancellationRequested)
            {
                // The apps write a "no animal" row when the model fails twice on a frame, and give
                // up after five in a row; the engine keeps that rule, so report the failure to it.
                output = default;
                failed = true;
            }
            clock.Stop();
            modelSeconds += clock.Elapsed.TotalSeconds;

            // The frame that is reported is the frame whose poses are reported: the live picture and its marks must be
            // the same moment (they were 14 frames apart before: poses taken before the count went up, the picture after).
            bool report = progress != null && (analysed + 1) % ProgressEvery == 0;
            bool wantPoses = report;
            var result = run.Submit(
                frameNumber, frame.Time,
                failed ? ReadOnlySpan<float>.Empty : output.Values.Span,
                failed ? default : output.Shape,
                new CropRect(plan.Crop.X, plan.Crop.Y, plan.Crop.Width, plan.Crop.Height),
                wantsColour ? pixels : ReadOnlySpan<byte>.Empty,
                frame.Width, frame.Height, frame.RowBytes,
                wantPoses);
            if (wantPoses) poses = result;

            analysed++;
            if (report && progress != null)
            {
                var p = run.Progress();
                progress.Report(new TrackingProgress(
                    p.SourceTime, p.SourceDuration, p.AnalysedFrames,
                    p.CompletedSegments, p.TotalSegments,
                    analysed > 0 ? modelSeconds / analysed * 1000 : 0,
                    poses,
                    job.PreviewMaxSide > 0
                        ? Downscale(frame.Pixels.Span, frame.Width, frame.Height, frame.RowBytes, job.PreviewMaxSide, frame.Time)
                        : null));
            }
        }

        if (reader.LastError is { Length: > 0 } ffmpegError)
            throw new InvalidOperationException(ffmpegError);

        double msPerFrame = analysed > 0 ? modelSeconds / analysed * 1000 : 0;
        var finished = run.Finish(msPerFrame);
        return new TrackingOutcome(finished, plan, video, analysed, msPerFrame);
    }
}
