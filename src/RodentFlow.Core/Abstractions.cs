using RodentFlow.Engine;

namespace RodentFlow.Core;

/// <summary>
/// What the app knows about a video file before it decodes it. The frame times come from the file,
/// never from frame index ÷ frame rate: every duration, speed and threshold in RodentFlow is built
/// on the file's own timestamps, and a wrong frame rate in the header would scale all of them.
/// </summary>
public sealed record VideoInfo
{
    public required string Path { get; init; }
    /// <summary>Width of the upright frame, after any rotation in the file is applied.</summary>
    public required int Width { get; init; }
    /// <summary>Height of the upright frame.</summary>
    public required int Height { get; init; }
    /// <summary>Average frame rate, used only where the engine asks for a nominal rate.</summary>
    public required double Fps { get; init; }
    public required double Duration { get; init; }
    /// <summary>Rotation the container asks for, in degrees (0, 90, 180, 270).</summary>
    public int Rotation { get; init; }
    public long FileSize { get; init; }
    /// <summary>Last-write time as seconds since 1970, for the run fingerprint.</summary>
    public double Modified { get; init; }
    /// <summary>
    /// Presentation time of every video frame, in order, as the file gives it. Empty when the probe
    /// could not read them, in which case a run cannot start.
    /// </summary>
    public IReadOnlyList<double> FrameTimes { get; init; } = [];
}

/// <summary>
/// One decoded frame. <see cref="Pixels"/> is 32-bit BGRA of the upright frame and is only valid
/// until the next frame is read: the reader fills one buffer over and over.
/// </summary>
public readonly record struct DecodedFrame(
    int Index,
    double Time,
    ReadOnlyMemory<byte> Pixels,
    int Width,
    int Height,
    int RowBytes);

/// <summary>A source of decoded, upright BGRA frames in presentation order.</summary>
public interface IVideoReader : IDisposable
{
    VideoInfo Info { get; }

    /// <summary>
    /// Frames from <paramref name="fromTime"/> on. The decoder may start a little earlier (it has to
    /// begin at a keyframe); the engine's frame filter drops anything before the range, so starting
    /// early is safe and starting late is not.
    /// </summary>
    IEnumerable<DecodedFrame> Frames(double fromTime = 0, CancellationToken cancellation = default);
}

/// <summary>The model's output for one frame.</summary>
public readonly record struct PoseModelOutput(ReadOnlyMemory<float> Values, TensorShape Shape);

/// <summary>
/// A loaded pose model. The Windows app uses ONNX Runtime (RodentFlow.Onnx); the interface exists so
/// the tracking loop does not depend on the runtime, and so a different backend can be dropped in.
/// </summary>
public interface IPoseModel : IDisposable
{
    /// <summary>Model name as the engine knows it, e.g. "MousePose6_960_int8".</summary>
    string Name { get; }
    int InputWidth { get; }
    int InputHeight { get; }

    /// <summary>
    /// Runs the model on one prepared frame.
    /// </summary>
    /// <param name="input">NCHW float32, <c>[1, 3, InputHeight, InputWidth]</c>, RGB, 0–1.</param>
    PoseModelOutput Run(ReadOnlySpan<float> input);
}

/// <summary>
/// A model that owns its input buffer: the frame is prepared straight into <see cref="InputBuffer"/> and run from there,
/// saving one full-size copy per frame (3 × 960 × 960 floats, about 11 MB) and the per-frame allocations.
/// </summary>
public interface IPoseModelInput
{
    /// <summary>NCHW float32, <c>[1, 3, InputHeight, InputWidth]</c>, RGB, 0–1; filled by the caller before each run.</summary>
    float[] InputBuffer { get; }

    /// <summary>Runs the model on what is in <see cref="InputBuffer"/>.</summary>
    PoseModelOutput RunBuffer();
}
