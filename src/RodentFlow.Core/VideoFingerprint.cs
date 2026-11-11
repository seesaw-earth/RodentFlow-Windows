using System.Security.Cryptography;
using System.Text;

namespace RodentFlow.Core;

/// <summary>
/// Identifies the video a run folder belongs to, so a folder is never continued with another file.
/// Same recipe as the Mac app's <c>VideoFingerprint</c>: size and last-write time, then the first
/// and last mebibyte of the file.
/// </summary>
/// <remarks>
/// The value is not expected to equal the Mac's for the same file: the Mac mixes in the modification
/// time formatted by Swift, and reproducing that text exactly is not worth the risk of getting it
/// subtly wrong. Nothing needs the two to agree — a Windows run creates and continues its own
/// folder, and the engine only compares a fingerprint with one it wrote itself.
/// </remarks>
public static class VideoFingerprint
{
    private const long Window = 1 << 20;

    public readonly record struct Info(ulong Size, double Modified, string Fingerprint);

    public static Info Make(string path)
    {
        var file = new FileInfo(path);
        if (!file.Exists) throw new FileNotFoundException("No video at " + path, path);
        ulong size = (ulong)Math.Max(0, file.Length);
        double modified = new DateTimeOffset(file.LastWriteTimeUtc).ToUnixTimeMilliseconds() / 1000.0;

        using var sha = SHA256.Create();
        using var stream = File.OpenRead(path);
        var head = Encoding.UTF8.GetBytes($"{size}:{modified:R}");
        sha.TransformBlock(head, 0, head.Length, null, 0);

        long n = Math.Min((long)size, Window);
        var buffer = new byte[Window];
        int read = stream.Read(buffer, 0, (int)n);
        if (read > 0) sha.TransformBlock(buffer, 0, read, null, 0);

        if ((long)size > n)
        {
            stream.Seek((long)size - n, SeekOrigin.Begin);
            read = stream.Read(buffer, 0, (int)n);
            if (read > 0) sha.TransformBlock(buffer, 0, read, null, 0);
        }
        sha.TransformFinalBlock([], 0, 0);
        string hex = Convert.ToHexString(sha.Hash ?? []).ToLowerInvariant();
        return new Info(size, modified, hex);
    }
}
