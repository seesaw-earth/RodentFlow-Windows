using System.Globalization;

namespace RodentFlow.Core;

/// <summary>
/// One frame of a video as 32-bit BGRA, for the calibration picture and the preview.
/// </summary>
/// <remarks>
/// A seek is accurate enough here: the picture is for placing the arena and watching the skeleton,
/// not for measurement. Anything that is measured goes through <see cref="FFmpegVideoReader"/>,
/// which reads every frame in order with the file's own timestamps.
/// </remarks>
public static class VideoFrameGrabber
{
    public sealed record Frame(byte[] Pixels, int Width, int Height, int RowBytes, double Time);

    /// <summary>
    /// The frame at <paramref name="time"/> seconds, upright. Falls back to the first frame when the
    /// seek lands past the end.
    /// </summary>
    /// <param name="maxSide">
    /// Longest side of the returned picture. The calibration view does not need full resolution, and
    /// a smaller buffer keeps the window responsive; 0 keeps the original size.
    /// </param>
    public static Frame Grab(VideoInfo info, FFmpegTools tools, double time = 0, int maxSide = 0)
    {
        double scale = 1;
        if (maxSide > 0)
        {
            int longest = Math.Max(info.Width, info.Height);
            if (longest > maxSide) scale = (double)maxSide / longest;
        }
        // Even sizes: some decoders and filters insist on them.
        int width = Math.Max(2, (int)Math.Round(info.Width * scale) & ~1);
        int height = Math.Max(2, (int)Math.Round(info.Height * scale) & ~1);

        double at = Math.Max(0, time);
        if (info.Duration > 0 && at > info.Duration - 0.05) at = Math.Max(0, info.Duration - 0.05);

        var args = new List<string> { "-v", "error", "-nostdin" };
        if (at > 0.001) args.AddRange(["-ss", at.ToString("0.###", CultureInfo.InvariantCulture)]);
        args.AddRange(["-i", info.Path, "-map", "0:v:0", "-frames:v", "1"]);
        if (width != info.Width || height != info.Height)
            args.AddRange(["-vf", $"scale={width}:{height}:flags=bilinear"]);
        args.AddRange(["-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1"]);

        using var process = FFmpegTools.Start(tools.FFmpeg, args, binaryOut: true);
        var errors = Task.Run(() => process.StandardError.ReadToEnd(), CancellationToken.None);
        int rowBytes = width * 4;
        var buffer = new byte[rowBytes * height];
        int filled = 0;
        var stream = process.StandardOutput.BaseStream;
        while (filled < buffer.Length)
        {
            int got = stream.Read(buffer, filled, buffer.Length - filled);
            if (got <= 0) break;
            filled += got;
        }
        process.WaitForExit();

        if (filled < buffer.Length)
        {
            string wrote = errors.IsCompletedSuccessfully ? errors.Result.Trim() : "";
            throw new InvalidOperationException(
                $"Could not read a frame of {Path.GetFileName(info.Path)} at {at:F2} s."
                + (wrote.Length > 0 ? " ffmpeg reported: " + wrote : ""));
        }
        return new Frame(buffer, width, height, rowBytes, at);
    }

    /// <summary>
    /// A frame worth calibrating on: a little way in, so it is past any lead-in where the animal is
    /// still being placed and the lid may be off.
    /// </summary>
    public static Frame GrabForCalibration(VideoInfo info, FFmpegTools tools, int maxSide = 720) =>
        Grab(info, tools, info.Duration > 20 ? info.Duration * 0.1 : 0, maxSide);
}
