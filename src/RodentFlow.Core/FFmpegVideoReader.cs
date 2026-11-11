using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace RodentFlow.Core;

/// <summary>Where the ffmpeg and ffprobe executables are.</summary>
/// <remarks>
/// RodentFlow reads video through ffmpeg rather than Media Foundation for one reason: it reports each
/// frame's presentation time as the file stores it. Every duration, speed and threshold in the engine
/// is built on those timestamps, so an approximation (frame index ÷ frame rate) is not acceptable.
/// </remarks>
public sealed record FFmpegTools(string FFmpeg = "ffmpeg", string FFprobe = "ffprobe")
{
    /// <summary>ffmpeg.exe and ffprobe.exe inside <paramref name="folder"/>.</summary>
    public static FFmpegTools In(string folder) => new(
        Path.Combine(folder, OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg"),
        Path.Combine(folder, OperatingSystem.IsWindows() ? "ffprobe.exe" : "ffprobe"));

    /// <summary>Runs ffprobe once to check both tools can start; throws with the reason if not.</summary>
    public void Check()
    {
        try
        {
            using var p = Start(FFprobe, ["-version"]);
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0) throw new InvalidOperationException($"{FFprobe} -version exited with {p.ExitCode}");
        }
        catch (Exception e)
        {
            throw new InvalidOperationException(
                $"Cannot run {FFprobe}. Put ffmpeg.exe and ffprobe.exe next to the app, or point " +
                $"FFmpegTools at the folder that holds them. ({e.Message})", e);
        }
    }

    internal static Process Start(string exe, IEnumerable<string> args, bool binaryOut = false)
    {
        var info = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        if (!binaryOut) info.StandardOutputEncoding = System.Text.Encoding.UTF8;
        return Process.Start(info) ?? throw new InvalidOperationException("Cannot start " + exe);
    }
}

/// <summary>Reads a video's shape and the presentation time of every frame, with ffprobe.</summary>
public static class FFprobe
{
    public static VideoInfo Probe(string path, FFmpegTools tools)
    {
        var (width, height, fps, duration, rotation) = ProbeStream(path, tools);
        int uprightW = (rotation == 90 || rotation == 270) ? height : width;
        int uprightH = (rotation == 90 || rotation == 270) ? width : height;
        var fingerprint = VideoFingerprint.Make(path);
        return new VideoInfo
        {
            Path = path,
            Width = uprightW,
            Height = uprightH,
            Fps = fps,
            Duration = duration,
            Rotation = rotation,
            FileSize = (long)fingerprint.Size,
            Modified = fingerprint.Modified,
            FrameTimes = ProbeFrameTimes(path, tools),
        };
    }

    private static (int Width, int Height, double Fps, double Duration, int Rotation) ProbeStream(
        string path, FFmpegTools tools)
    {
        using var p = FFmpegTools.Start(tools.FFprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate,duration,nb_frames",
            "-show_entries", "stream_tags=rotate",
            "-show_entries", "stream_side_data=rotation",
            "-show_entries", "format=duration",
            "-of", "json", path,
        ]);
        string json = p.StandardOutput.ReadToEnd();
        string err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0 || json.Length == 0)
            throw new InvalidOperationException($"ffprobe could not read {Path.GetFileName(path)}: {err.Trim()}");

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (!root.TryGetProperty("streams", out var streams) || streams.GetArrayLength() == 0)
            throw new InvalidOperationException($"{Path.GetFileName(path)} has no video stream");
        var s = streams[0];

        int width = s.TryGetProperty("width", out var w) ? w.GetInt32() : 0;
        int height = s.TryGetProperty("height", out var h) ? h.GetInt32() : 0;
        if (width <= 0 || height <= 0)
            throw new InvalidOperationException($"{Path.GetFileName(path)} has no frame size");

        double fps = Fraction(s, "avg_frame_rate");
        if (!(fps > 0)) fps = Fraction(s, "r_frame_rate");
        if (!(fps > 0)) fps = 30;

        double duration = Number(s, "duration");
        if (!(duration > 0) && root.TryGetProperty("format", out var f)) duration = Number(f, "duration");

        int rotation = 0;
        // Newer ffprobe: side_data_list[].rotation, negative for a clockwise display rotation.
        if (s.TryGetProperty("side_data_list", out var sides) && sides.ValueKind == JsonValueKind.Array)
        {
            foreach (var side in sides.EnumerateArray())
            {
                if (!side.TryGetProperty("rotation", out var rot)) continue;
                double value = rot.ValueKind == JsonValueKind.Number ? rot.GetDouble()
                    : double.TryParse(rot.GetString(), CultureInfo.InvariantCulture, out var parsed) ? parsed : 0;
                rotation = Normalize((int)Math.Round(-value));
                break;
            }
        }
        // Older files: the rotate tag, already clockwise.
        if (rotation == 0 && s.TryGetProperty("tags", out var tags)
            && tags.TryGetProperty("rotate", out var tag)
            && int.TryParse(tag.GetString(), out var tagged))
        {
            rotation = Normalize(tagged);
        }
        return (width, height, fps, duration, rotation);

        static int Normalize(int degrees) => ((degrees % 360) + 360) % 360;
    }

    /// <summary>
    /// The presentation time of every video frame, in order. This is a full pass over the file, which
    /// is the price of exact timestamps; it runs once per video.
    /// </summary>
    private static List<double> ProbeFrameTimes(string path, FFmpegTools tools)
    {
        using var p = FFmpegTools.Start(tools.FFprobe, [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "frame=best_effort_timestamp_time,pts_time",
            "-of", "csv=p=0", path,
        ]);
        var times = new List<double>();
        var errors = Task.Run(() => p.StandardError.ReadToEnd());
        while (p.StandardOutput.ReadLine() is { } line)
        {
            if (line.Length == 0) continue;
            double? value = null;
            foreach (var field in line.Split(','))
            {
                var text = field.Trim();
                if (text.Length == 0 || text == "N/A") continue;
                if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var t))
                {
                    value = t;
                    break;
                }
            }
            if (value is { } ok && double.IsFinite(ok)) times.Add(ok);
        }
        p.WaitForExit();
        if (p.ExitCode != 0)
            throw new InvalidOperationException($"ffprobe could not list the frame times: {errors.Result.Trim()}");
        return times;
    }

    private static double Number(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v)
        && double.TryParse(v.ValueKind == JsonValueKind.String ? v.GetString() : v.ToString(),
                           NumberStyles.Float, CultureInfo.InvariantCulture, out var d)
            ? d : 0;

    private static double Fraction(JsonElement e, string name)
    {
        if (!e.TryGetProperty(name, out var v)) return 0;
        var text = v.GetString();
        if (string.IsNullOrEmpty(text)) return 0;
        var parts = text.Split('/');
        if (parts.Length == 2
            && double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
            && double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var b)
            && b != 0)
            return a / b;
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var single) ? single : 0;
    }
}

/// <summary>
/// Decodes a video to upright 32-bit BGRA frames by piping ffmpeg's raw output.
/// </summary>
/// <remarks>
/// ffmpeg applies the container's rotation by default, so the frames arrive upright. Frames are
/// paired with the times <see cref="FFprobe"/> listed, by position: the decoder is asked for every
/// frame (<c>-vsync 0</c>) and never seeks, so position n in the pipe is position n in that list.
/// Not seeking means continuing an interrupted run re-decodes from the start of the file; the engine
/// still skips the frames it already has, so the result is right, only slower (docs/STATUS_CN.md).
/// </remarks>
public sealed class FFmpegVideoReader : IVideoReader
{
    private readonly FFmpegTools _tools;
    private readonly int _decodeWidth;
    private readonly int _decodeHeight;

    /// <param name="decodeWidth">Decode at this width instead of full size (the engine's run plan
    /// asks for this on very large frames); 0 = full size.</param>
    public FFmpegVideoReader(VideoInfo info, FFmpegTools tools, int decodeWidth = 0, int decodeHeight = 0)
    {
        Info = info;
        _tools = tools;
        _decodeWidth = decodeWidth > 0 ? decodeWidth : info.Width;
        _decodeHeight = decodeHeight > 0 ? decodeHeight : info.Height;
        if (info.FrameTimes.Count == 0)
            throw new InvalidOperationException(
                $"{Path.GetFileName(info.Path)}: ffprobe reported no frame times, so the analysis has no time base.");
    }

    public VideoInfo Info { get; }

    /// <summary>Width of the buffers this reader fills.</summary>
    public int DecodeWidth => _decodeWidth;
    /// <summary>Height of the buffers this reader fills.</summary>
    public int DecodeHeight => _decodeHeight;

    public IEnumerable<DecodedFrame> Frames(double fromTime = 0, CancellationToken cancellation = default)
    {
        // -fps_mode passthrough: hand every frame over with its own timestamp, no rate conversion.
        // This replaced -vsync 0, which recent ffmpeg (9.x) rejects outright. Needs ffmpeg >= 5.0.
        var args = new List<string>
        {
            "-v", "error", "-nostdin", "-i", Info.Path, "-map", "0:v:0", "-fps_mode", "passthrough",
        };
        if (_decodeWidth != Info.Width || _decodeHeight != Info.Height)
            args.AddRange(["-vf", $"scale={_decodeWidth}:{_decodeHeight}:flags=bilinear"]);
        args.AddRange(["-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1"]);

        using var process = FFmpegTools.Start(_tools.FFmpeg, args, binaryOut: true);
        var errors = Task.Run(() => process.StandardError.ReadToEnd(), CancellationToken.None);
        int rowBytes = _decodeWidth * 4;
        int frameBytes = rowBytes * _decodeHeight;
        var buffer = new byte[frameBytes];
        var stream = process.StandardOutput.BaseStream;

        int delivered = 0;
        bool streamEnded = false;
        try
        {
            for (int index = 0; index < Info.FrameTimes.Count; index++)
            {
                cancellation.ThrowIfCancellationRequested();
                int filled = 0;
                while (filled < frameBytes)
                {
                    int got = stream.Read(buffer, filled, frameBytes - filled);
                    if (got <= 0) break;
                    filled += got;
                }
                if (filled < frameBytes)
                {
                    streamEnded = true;
                    break;
                }
                delivered++;
                yield return new DecodedFrame(index, Info.FrameTimes[index], buffer,
                                              _decodeWidth, _decodeHeight, rowBytes);
            }
        }
        finally
        {
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            }
            process.WaitForExit();
            FramesDelivered = delivered;
            string wrote = errors.IsCompletedSuccessfully ? errors.Result.Trim() : "";
            string name = Path.GetFileName(Info.Path);
            if (cancellation.IsCancellationRequested)
            {
                // Stopped on purpose.
            }
            else if (delivered == 0)
            {
                // ffmpeg never produced a frame: it refused the file or the arguments.
                LastError = $"ffmpeg could not decode {name}."
                            + (wrote.Length > 0 ? " It reported: " + wrote : "")
                            + " RodentFlow needs ffmpeg 5.0 or newer.";
            }
            else if (streamEnded && delivered < Info.FrameTimes.Count && process.ExitCode != 0)
            {
                // It started and then gave up: a damaged file, usually.
                LastError = $"ffmpeg stopped after {delivered} of {Info.FrameTimes.Count} frames of {name}."
                            + (wrote.Length > 0 ? " It reported: " + wrote : "");
            }
            // Otherwise the caller stopped reading early (a time range, or the user stopping the
            // run), which kills ffmpeg on purpose and is not a failure.
        }
    }

    /// <summary>Frames handed over by the last call to <see cref="Frames"/>.</summary>
    public int FramesDelivered { get; private set; }

    /// <summary>Why decoding failed, when it did. Null when the caller simply stopped early.</summary>
    public string? LastError { get; private set; }

    public void Dispose() { }
}
