using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace RodentFlow.Core.Figures;

/// <summary>
/// PNG without a library: writing an 8-bit RGB(A) image (the calibration frame inside SVG files), and
/// setting the resolution of a finished PNG (the 300 / 600 dpi exports — Win2D writes the pixels, this
/// writes the pHYs chunk that tells a journal's system the dpi, as the Mac's export does).
/// </summary>
public static class PngEncoder
{
    private static readonly byte[] Signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    public static byte[] EncodeBgra(byte[] bgra, int width, int height, int rowBytes, bool alpha)
    {
        int channels = alpha ? 4 : 3;
        var raw = new byte[(width * channels + 1) * height];
        int d = 0;
        for (int y = 0; y < height; y++)
        {
            raw[d++] = 0; // filter: none
            int s = y * rowBytes;
            for (int x = 0; x < width; x++, s += 4)
            {
                raw[d++] = bgra[s + 2];
                raw[d++] = bgra[s + 1];
                raw[d++] = bgra[s];
                if (alpha) raw[d++] = bgra[s + 3];
            }
        }
        byte[] compressed;
        using (var ms = new MemoryStream())
        {
            using (var z = new ZLibStream(ms, CompressionLevel.Optimal, leaveOpen: true)) z.Write(raw, 0, raw.Length);
            compressed = ms.ToArray();
        }

        var ihdr = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(0), width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), height);
        ihdr[8] = 8;                          // bit depth
        ihdr[9] = (byte)(alpha ? 6 : 2);      // colour type: RGBA / RGB
        ihdr[10] = ihdr[11] = ihdr[12] = 0;   // deflate, adaptive filtering, no interlace

        using var png = new MemoryStream();
        png.Write(Signature);
        WriteChunk(png, "IHDR", ihdr);
        WriteChunk(png, "IDAT", compressed);
        WriteChunk(png, "IEND", []);
        return png.ToArray();
    }

    /// <summary>The same PNG with its pHYs chunk saying <paramref name="dpi"/> (any earlier pHYs is replaced).</summary>
    public static byte[] SetDpi(byte[] png, double dpi)
    {
        if (png.Length < Signature.Length || !png.AsSpan(0, Signature.Length).SequenceEqual(Signature))
            throw new ArgumentException("Not a PNG file.");
        uint perMetre = (uint)Math.Round(dpi / 0.0254);
        var phys = new byte[9];
        BinaryPrimitives.WriteUInt32BigEndian(phys.AsSpan(0), perMetre);
        BinaryPrimitives.WriteUInt32BigEndian(phys.AsSpan(4), perMetre);
        phys[8] = 1; // unit: metre

        using var output = new MemoryStream();
        output.Write(Signature);
        int at = Signature.Length;
        bool written = false;
        while (at + 12 <= png.Length)
        {
            int length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            string type = Encoding.ASCII.GetString(png, at + 4, 4);
            int total = 12 + length;
            if (length < 0 || at + total > png.Length) throw new ArgumentException("The PNG file is damaged.");
            if (type != "pHYs") output.Write(png, at, total);
            if (type == "IHDR" && !written)
            {
                WriteChunk(output, "pHYs", phys);
                written = true;
            }
            at += total;
            if (type == "IEND") break;
        }
        return output.ToArray();
    }

    /// <summary>Every chunk's CRC is right, the file starts with IHDR and ends with IEND (for the self-check).</summary>
    public static bool Verify(byte[] png, out string problem)
    {
        problem = "";
        if (png.Length < 8 || !png.AsSpan(0, 8).SequenceEqual(Signature)) { problem = "no PNG signature"; return false; }
        int at = 8;
        string first = "", last = "";
        while (at + 12 <= png.Length)
        {
            int length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            if (length < 0 || at + 12 + length > png.Length) { problem = "chunk runs past the end"; return false; }
            string type = Encoding.ASCII.GetString(png, at + 4, 4);
            uint stored = BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(at + 8 + length));
            uint actual = Crc(png.AsSpan(at + 4, 4 + length));
            if (stored != actual) { problem = $"bad CRC in {type}"; return false; }
            if (first.Length == 0) first = type;
            last = type;
            at += 12 + length;
        }
        if (first != "IHDR") { problem = "does not start with IHDR"; return false; }
        if (last != "IEND") { problem = "does not end with IEND"; return false; }
        return true;
    }

    /// <summary>The dpi of a PNG's pHYs chunk, or null.</summary>
    public static double? ReadDpi(byte[] png)
    {
        int at = 8;
        while (at + 12 <= png.Length)
        {
            int length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            if (length < 0 || at + 12 + length > png.Length) return null;
            string type = Encoding.ASCII.GetString(png, at + 4, 4);
            if (type == "pHYs" && length == 9 && png[at + 16] == 1)
                return BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(at + 8)) * 0.0254;
            at += 12 + length;
        }
        return null;
    }

    private static void WriteChunk(Stream s, string type, byte[] data)
    {
        Span<byte> head = stackalloc byte[8];
        BinaryPrimitives.WriteInt32BigEndian(head, data.Length);
        Encoding.ASCII.GetBytes(type, head[4..]);
        s.Write(head);
        s.Write(data);
        var crcInput = new byte[4 + data.Length];
        head[4..].CopyTo(crcInput);
        data.CopyTo(crcInput, 4);
        Span<byte> crc = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(crc, Crc(crcInput));
        s.Write(crc);
    }

    private static readonly uint[] CrcTable = MakeTable();

    private static uint[] MakeTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }

    private static uint Crc(ReadOnlySpan<byte> data)
    {
        uint c = 0xFFFFFFFFu;
        foreach (byte b in data) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
}
