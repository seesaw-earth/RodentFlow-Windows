using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RodentFlow.Core;

/// <summary>
/// ffprobe's answer for a video (size, rate, every frame's time), kept on disk so that opening a session again does not
/// list every frame again — that takes seconds for a long recording and made the window look stuck on the previous
/// page. Kept in <c>%LOCALAPPDATA%\RodentFlow\probe</c>, one file per video, and used only while the video's size and
/// last-write time are unchanged.
/// </summary>
public static class VideoProbeCache
{
    private static readonly string Folder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RodentFlow", "probe");

    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private static string FileFor(string path)
    {
        byte[] hash = SHA1.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(path).ToLowerInvariant()));
        return Path.Combine(Folder, Convert.ToHexString(hash) + ".json");
    }

    /// <summary>The probe of <paramref name="path"/>: saved when the file is unchanged, otherwise ffprobe (and saved).</summary>
    public static VideoInfo Probe(string path, FFmpegTools tools)
    {
        string cache = FileFor(path);
        try
        {
            // The same size and last-write time FFprobe.Probe records (VideoFingerprint).
            var now = VideoFingerprint.Make(path);
            if (File.Exists(cache) && JsonSerializer.Deserialize<VideoInfo>(File.ReadAllText(cache), Json) is { } saved
                && saved.FileSize == (long)now.Size && Math.Abs(saved.Modified - now.Modified) < 1e-6
                && saved.FrameTimes.Count > 0)
                return saved with { Path = path };
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or NotSupportedException)
        {
            // A damaged cache entry is probed again below.
        }
        var info = FFprobe.Probe(path, tools);
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(cache, JsonSerializer.Serialize(info, Json));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Probing again next time is all that is lost.
        }
        return info;
    }
}
