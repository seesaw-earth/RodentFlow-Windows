using System.Diagnostics;
using System.Globalization;

namespace RodentFlow.Core.Review;

/// <summary>
/// Plays a video for the review: one ffmpeg process decoding from a time onward, scaled down, each frame handed
/// over at its own timestamp (divided by the playback rate). A frame that arrives late is shown at once — the
/// review never skips ahead of what it can decode, so the skeleton always belongs to the picture under it.
/// </summary>
/// <remarks>
/// Frames are paired with <see cref="VideoInfo.FrameTimes"/>: ffmpeg's accurate seek starts at the first frame at
/// or after the requested time, and <c>-fps_mode passthrough</c> passes every frame, so the k-th frame out is the
/// k-th frame time from there — the same pairing the tracking loop uses (FFmpegVideoReader).
/// </remarks>
public sealed class FramePlayer : IDisposable
{
    private readonly VideoInfo _info;
    private readonly FFmpegTools _tools;
    private readonly int _width, _height;
    private CancellationTokenSource? _cancel;
    private Task? _loop;

    public FramePlayer(VideoInfo info, FFmpegTools tools, int maxSide = 960)
    {
        _info = info;
        _tools = tools;
        double scale = Math.Min(1, (double)maxSide / Math.Max(1, Math.Max(info.Width, info.Height)));
        _width = Math.Max(2, (int)Math.Round(info.Width * scale) & ~1);
        _height = Math.Max(2, (int)Math.Round(info.Height * scale) & ~1);
    }

    public bool Playing => _loop is { IsCompleted: false };

    /// <summary>
    /// Starts at <paramref name="from"/> seconds. <paramref name="onFrame"/> is called on a worker thread, in order;
    /// <paramref name="onEnd"/> when the video ends, the player is stopped, or decoding fails (with the reason).
    /// </summary>
    public void Start(double from, double rate, Action<VideoFrameGrabber.Frame> onFrame, Action<string?> onEnd)
    {
        Stop();
        var cancel = new CancellationTokenSource();
        _cancel = cancel;
        _loop = Task.Run(() =>
        {
            string? problem = null;
            try { Run(from, Math.Clamp(rate, 0.05, 16), onFrame, cancel.Token); }
            catch (OperationCanceledException) { }
            catch (Exception e) { problem = e.Message; }
            onEnd(problem);
        });
    }

    public void Stop()
    {
        var cancel = Interlocked.Exchange(ref _cancel, null);
        if (cancel is null) return;
        cancel.Cancel();
        try { _loop?.Wait(TimeSpan.FromSeconds(2)); }
        catch (AggregateException) { }
        cancel.Dispose();
    }

    public void Dispose() => Stop();

    private void Run(double from, double rate, Action<VideoFrameGrabber.Frame> onFrame, CancellationToken cancel)
    {
        var times = _info.FrameTimes;
        int first = 0;
        while (first < times.Count && times[first] < from - 1e-3) first++;
        if (first >= times.Count) return;
        double at = times[first];

        var args = new List<string> { "-v", "error", "-nostdin" };
        if (at > 0.001) args.AddRange(["-ss", at.ToString("0.######", CultureInfo.InvariantCulture)]);
        args.AddRange(["-i", _info.Path, "-map", "0:v:0"]);
        if (_width != _info.Width || _height != _info.Height)
            args.AddRange(["-vf", $"scale={_width}:{_height}:flags=bilinear"]);
        args.AddRange(["-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1"]);

        using var process = FFmpegTools.Start(_tools.FFmpeg, args, binaryOut: true);
        using var stop = cancel.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(); }
            catch (Exception) { /* it ended on its own */ }
        });
        var errors = Task.Run(() => process.StandardError.ReadToEnd(), CancellationToken.None);
        var stream = process.StandardOutput.BaseStream;
        int rowBytes = _width * 4, size = rowBytes * _height;
        var clock = Stopwatch.StartNew();
        for (int k = first; k < times.Count; k++)
        {
            cancel.ThrowIfCancellationRequested();
            var buffer = new byte[size];
            int filled = 0;
            while (filled < size)
            {
                int got = stream.Read(buffer, filled, size - filled);
                if (got <= 0) break;
                filled += got;
            }
            if (filled < size)
            {
                cancel.ThrowIfCancellationRequested();
                process.WaitForExit(2000);
                string wrote = errors.IsCompletedSuccessfully ? errors.Result.Trim() : "";
                if (k == first && wrote.Length > 0) throw new InvalidOperationException("ffmpeg could not play the video: " + wrote);
                return; // the end of the video
            }
            // Pace by the frame's own time (variable frame rate stays right).
            double due = (times[k] - at) / rate;
            double wait = due - clock.Elapsed.TotalSeconds;
            if (wait > 0.002) cancel.WaitHandle.WaitOne(TimeSpan.FromSeconds(Math.Min(wait, 1)));
            cancel.ThrowIfCancellationRequested();
            onFrame(new VideoFrameGrabber.Frame(buffer, _width, _height, rowBytes, times[k]));
        }
    }
}
