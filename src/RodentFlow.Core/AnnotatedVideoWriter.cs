using System.Diagnostics;
using System.Globalization;
using RodentFlow.Engine;

namespace RodentFlow.Core;

/// <summary>
/// Writes a review video: the frames the engine analysed, with its keypoints drawn on them.
/// </summary>
/// <remarks>
/// The keypoints come out of the pose.mpt the run wrote, read through the engine, so this shows what
/// the analysis actually used — not a second inference pass that might disagree with it.
///
/// Only analysed frames are written. With a frame stride the run skipped frames, and holding the
/// last skeleton over them would make the tracking look steadier than it is.
/// </remarks>
public static class AnnotatedVideoWriter
{
    public sealed record Request
    {
        /// <summary>Folder a run wrote (holds pose.mpt).</summary>
        public required string RunFolder { get; init; }
        /// <summary>The video that was analysed.</summary>
        public required string VideoPath { get; init; }
        /// <summary>Output file. The extension decides the format: .mp4, or frames_%04d.png.</summary>
        public required string Output { get; init; }
        /// <summary>Seconds of video to cover; 0 = from the start / to the end.</summary>
        public double From { get; init; }
        public double To { get; init; }
        /// <summary>Write every Nth analysed frame (1 = all of them).</summary>
        public int Every { get; init; } = 1;
        /// <summary>Playback rate. 0 = real time, i.e. the rate the analysed frames came at.</summary>
        public double Fps { get; init; }
        /// <summary>Drawn so you can see what the model was given; from the engine's run plan.</summary>
        public CropPixels? Crop { get; init; }
        /// <summary>Drawn so you can see whether the calibrated arena matches the real one.</summary>
        public NPoint[]? ArenaCorners { get; init; }
        public FFmpegTools Tools { get; init; } = new();
        /// <summary>
        /// Draws the marks onto one frame in place (pixels, width, height, row bytes, animals, context); null = the
        /// built-in drawing (<see cref="Annotation.Draw"/>). The window passes one that draws as the Mac's review video
        /// does: one animal as its skeleton, two or more as coloured head glyphs with A / B (or numbered) badges.
        /// </summary>
        public Action<byte[], int, int, int, IReadOnlyList<PoseKeypoints>, Annotation.Context>? Draw { get; init; }
    }

    public sealed record Result(string Output, int FramesWritten, int FramesWithoutDetection, double Fps);

    public static Result Write(Request request, IProgress<int>? progress = null,
                               CancellationToken cancellation = default)
    {
        request.Tools.Check();
        string poseFile = Path.Combine(request.RunFolder, "pose.mpt");
        if (!File.Exists(poseFile))
            throw new FileNotFoundException($"No pose.mpt in {request.RunFolder}. Track the video first.", poseFile);

        var info = Engine.Engine.TrackInfo(poseFile);
        if (info.Frames == 0) throw new InvalidOperationException("The pose file has no frames.");

        // Read the whole track once. 6 keypoints × a few thousand frames is small, and scrubbing
        // back and forth over a file would be slower than holding it.
        var records = Engine.Engine.TrackFrames(poseFile, 0, info.Frames).Frames;

        // The saved probe when the video is unchanged (listing every frame time again takes seconds).
        var video = VideoProbeCache.Probe(request.VideoPath, request.Tools);
        if (Math.Abs(video.Width - info.FrameWidth) > 1 || Math.Abs(video.Height - info.FrameHeight) > 1)
            throw new InvalidOperationException(
                $"{Path.GetFileName(request.VideoPath)} is {video.Width}×{video.Height}, but the run was made on "
                + $"{info.FrameWidth:F0}×{info.FrameHeight:F0}. This is not the video that was analysed.");

        double from = request.From, to = request.To > 0 ? request.To : double.MaxValue;
        int every = Math.Max(1, request.Every);

        // Real time by default: the analysed frames came every `frameStride` source frames.
        double fps = request.Fps > 0
            ? request.Fps
            : Math.Max(0.1, info.Fps / Math.Max(1, info.FrameStride) / every);

        var context = new Annotation.Context
        {
            Crop = request.Crop,
            ArenaCorners = request.ArenaCorners,
            FrameWidth = info.FrameWidth,
            FrameHeight = info.FrameHeight,
        };

        using var reader = new FFmpegVideoReader(video, request.Tools);
        int width = reader.DecodeWidth, height = reader.DecodeHeight;
        using var writer = new Encoder(request.Tools, request.Output, width, height, fps);

        // Both sides carry the file's own timestamps, so matching on time needs only a tolerance
        // for the text round trip, not a search window.
        const double tolerance = 1e-4;
        int at = 0, written = 0, blank = 0, analysed = 0;

        // Decoding and drawing here, encoding on its own thread: the two overlap instead of taking turns. Frame buffers
        // go round between the two (a few in flight), so a long video makes no garbage per frame.
        using var queue = new System.Collections.Concurrent.BlockingCollection<byte[]>(boundedCapacity: 4);
        var spare = new System.Collections.Concurrent.ConcurrentBag<byte[]>();
        Exception? encodeError = null;
        var encoding = Task.Run(() =>
        {
            try
            {
                foreach (var buffer in queue.GetConsumingEnumerable())
                {
                    writer.Write(buffer);
                    spare.Add(buffer);
                }
            }
            catch (Exception e)
            {
                encodeError = e;
                queue.CompleteAdding();
            }
        });
        try
        {
            foreach (var frame in reader.Frames(cancellation: cancellation))
            {
                cancellation.ThrowIfCancellationRequested();
                if (encodeError is not null) break;
                while (at < records.Length && records[at].Time < frame.Time - tolerance) at++;
                if (at >= records.Length) break;
                if (Math.Abs(records[at].Time - frame.Time) > tolerance) continue;   // not analysed

                var record = records[at];
                at++;
                if (record.Time < from - tolerance) continue;
                if (record.Time > to + tolerance) break;
                if (analysed++ % every != 0) continue;

                // The reader reuses its buffer; drawing needs its own.
                int size = frame.Pixels.Length;
                if (!spare.TryTake(out var buffer) || buffer.Length != size) buffer = new byte[size];
                frame.Pixels.Span.CopyTo(buffer);
                if (request.Draw is { } draw) draw(buffer, frame.Width, frame.Height, frame.RowBytes, record.Animals, context);
                else Annotation.Draw(buffer, frame.Width, frame.Height, frame.RowBytes, record.Animals, context);
                try
                {
                    if (!queue.TryAdd(buffer, Timeout.Infinite, cancellation)) break;
                }
                catch (InvalidOperationException) when (encodeError is not null)
                {
                    break;   // the encoder stopped; its own error is reported below
                }
                written++;
                if (!record.Animals.Any(a => a.Detected)) blank++;
                if (written % 25 == 0) progress?.Report(written);
            }
        }
        finally
        {
            if (!queue.IsAddingCompleted) queue.CompleteAdding();
            encoding.Wait(CancellationToken.None);
        }
        if (encodeError is not null) throw new InvalidOperationException("Writing the review video failed: " + encodeError.Message, encodeError);

        writer.Finish();
        if (written == 0)
            throw new InvalidOperationException(
                "No frames were written. Check that the time range overlaps the part of the video that was analysed.");
        return new Result(request.Output, written, blank, fps);
    }

    /// <summary>Pipes finished frames into ffmpeg, which writes the file.</summary>
    private sealed class Encoder : IDisposable
    {
        private readonly Process _process;
        private readonly Task<string> _errors;
        private readonly Stream _input;
        private readonly string _output;

        public Encoder(FFmpegTools tools, string output, int width, int height, double fps)
        {
            _output = output;
            string? folder = Path.GetDirectoryName(Path.GetFullPath(output));
            if (!string.IsNullOrEmpty(folder)) Directory.CreateDirectory(folder);

            var args = new List<string>
            {
                "-v", "error", "-y", "-nostdin",
                "-f", "rawvideo", "-pix_fmt", "bgra",
                "-video_size", $"{width}x{height}",
                "-framerate", fps.ToString("0.####", CultureInfo.InvariantCulture),
                "-i", "pipe:0",
            };
            if (output.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
            {
                args.AddRange(["-f", "image2"]);
            }
            else
            {
                // yuv420p so the file plays in anything, including PowerPoint and QuickTime.
                args.AddRange(["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "veryfast"]);
            }
            args.Add(output);

            var start = new ProcessStartInfo(tools.FFmpeg)
            {
                RedirectStandardInput = true,
                RedirectStandardError = true,
                RedirectStandardOutput = false,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var a in args) start.ArgumentList.Add(a);
            _process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start " + tools.FFmpeg);
            // Drained on a worker so a chatty encoder cannot fill the pipe and deadlock the writer.
            _errors = Task.Run(() => _process.StandardError.ReadToEnd(), CancellationToken.None);
            _input = _process.StandardInput.BaseStream;
        }

        public void Write(byte[] frame)
        {
            try
            {
                _input.Write(frame, 0, frame.Length);
            }
            catch (IOException)
            {
                // The encoder stopped; its own message is the useful one.
                throw new InvalidOperationException(Message());
            }
        }

        public void Finish()
        {
            try
            {
                _input.Flush();
                _input.Close();
            }
            catch (IOException) { /* already gone; the exit code tells the story */ }
            _process.WaitForExit();
            if (_process.ExitCode != 0) throw new InvalidOperationException(Message());
        }

        private string Message()
        {
            string wrote = _errors.IsCompletedSuccessfully ? _errors.Result.Trim() : "";
            return $"ffmpeg could not write {Path.GetFileName(_output)}."
                   + (wrote.Length > 0 ? " It reported: " + wrote : "");
        }

        public void Dispose()
        {
            if (!_process.HasExited)
            {
                try { _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            }
            _process.Dispose();
        }
    }
}
