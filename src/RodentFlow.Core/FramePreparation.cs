using RodentFlow.Engine;

namespace RodentFlow.Core;

/// <summary>
/// Turns a decoded upright BGRA frame into the tensor the pose models expect:
///
///   crop to the tracked region → optional grayscale → letterbox into 960 × 960 → NCHW float, 0–1
///
/// The letterbox arithmetic here is the inverse of the engine's <c>PoseDecoding.decode</c>
/// (Shared/PoseEngine/PoseDecoding.swift), which undoes it to put keypoints back into frame pixels.
/// Both sides must agree exactly, so the gain and padding are computed with the same formula and the
/// same rounding (Swift's <c>rounded()</c> is half-away-from-zero, which is
/// <see cref="MidpointRounding.AwayFromZero"/> here, not .NET's default half-to-even).
/// </summary>
/// <remarks>
/// Two choices differ from what the Mac does through Core Image and Vision, deliberately, because
/// they follow how the models were trained rather than how Apple's frameworks happen to behave.
/// Both are listed in docs/STATUS_CN.md as things to measure against a Mac run:
///
///   • padding is <see cref="PadValue"/> (114), the value Ultralytics letterboxes with and the one
///     the training pipeline used, where Vision's <c>.scaleFit</c> pads with black;
///   • grayscale is Rec. 601 luma in sRGB space, as the training pipeline did it, where Core Image's
///     <c>CIColorControls</c> desaturates in a linear working space.
/// </remarks>
public static class FramePreparation
{
    /// <summary>Letterbox padding. 114/255 is what the models were trained with.</summary>
    public const byte PadValue = 114;

    /// <summary>Where the scaled crop sits inside the model's square input.</summary>
    public readonly record struct Letterbox(double Gain, int ScaledWidth, int ScaledHeight, int PadX, int PadY);

    /// <summary>
    /// The same letterbox the engine assumes: <c>gain = min(mh/ih, mw/iw)</c>, the scaled size
    /// rounded, and the padding centred with the engine's <c>- 0.1</c> bias.
    /// </summary>
    public static Letterbox PlanLetterbox(double inputWidth, double inputHeight, int modelWidth, int modelHeight)
    {
        double gain = Math.Min(modelHeight / inputHeight, modelWidth / inputWidth);
        double scaledW = Round(inputWidth * gain);
        double scaledH = Round(inputHeight * gain);
        int padX = (int)Round((modelWidth - scaledW) / 2 - 0.1);
        int padY = (int)Round((modelHeight - scaledH) / 2 - 0.1);
        return new Letterbox(gain, (int)scaledW, (int)scaledH, padX, padY);
    }

    /// <summary>Swift's <c>Double.rounded()</c>: half away from zero.</summary>
    private static double Round(double v) => Math.Round(v, MidpointRounding.AwayFromZero);

    /// <summary>
    /// Fills <paramref name="tensor"/> with one frame, ready for the model.
    /// </summary>
    /// <param name="pixels">The decoded upright frame, 32-bit BGRA.</param>
    /// <param name="pixelWidth">Width of that buffer. May be smaller than the frame when the video
    /// is decoded at a reduced size; the crop is scaled to match.</param>
    /// <param name="crop">The tracked region, in pixels of the upright whole frame (from the engine's
    /// run plan).</param>
    /// <param name="frameWidth">Width of the upright whole frame, which the crop is expressed in.</param>
    /// <param name="grayscale">Convert to gray before the model, as the run settings ask.</param>
    /// <param name="tensor">Receives <c>[1, 3, modelHeight, modelWidth]</c> floats, RGB, 0–1.</param>
    public static void Prepare(
        ReadOnlySpan<byte> pixels, int pixelWidth, int pixelHeight, int rowBytes,
        CropPixels crop, int frameWidth, int frameHeight,
        bool grayscale,
        int modelWidth, int modelHeight,
        Span<float> tensor)
    {
        int plane = modelWidth * modelHeight;
        if (tensor.Length < 3 * plane)
            throw new ArgumentException($"The tensor needs {3 * plane} floats", nameof(tensor));
        if (pixelWidth <= 0 || pixelHeight <= 0 || frameWidth <= 0 || frameHeight <= 0)
            throw new ArgumentException("Empty frame");
        if (rowBytes < pixelWidth * 4)
            throw new ArgumentException("rowBytes is smaller than the row", nameof(rowBytes));

        // A reduced decode gives a smaller buffer; the crop is in whole-frame pixels either way.
        double bufferScaleX = (double)pixelWidth / frameWidth;
        double bufferScaleY = (double)pixelHeight / frameHeight;
        double srcX = crop.X * bufferScaleX;
        double srcY = crop.Y * bufferScaleY;
        double srcW = crop.Width * bufferScaleX;
        double srcH = crop.Height * bufferScaleY;

        // The letterbox is planned on the crop in whole-frame pixels, because that is the size the
        // engine hands to PoseDecoding as `inputSize`.
        var box = PlanLetterbox(crop.Width, crop.Height, modelWidth, modelHeight);

        const float padNorm = PadValue / 255f;
        tensor[..(3 * plane)].Fill(padNorm);
        if (box.ScaledWidth <= 0 || box.ScaledHeight <= 0) return;

        // Bilinear, mapping destination centres back to source centres — the convention OpenCV's
        // INTER_LINEAR uses, which is what the training pipeline resized with.
        double stepX = srcW / box.ScaledWidth;
        double stepY = srcH / box.ScaledHeight;

        for (int dy = 0; dy < box.ScaledHeight; dy++)
        {
            int ty = box.PadY + dy;
            if (ty < 0 || ty >= modelHeight) continue;
            double fy = srcY + (dy + 0.5) * stepY - 0.5;
            int y0 = (int)Math.Floor(fy);
            double wy = fy - y0;
            int y0c = Math.Clamp(y0, 0, pixelHeight - 1);
            int y1c = Math.Clamp(y0 + 1, 0, pixelHeight - 1);
            int row0 = y0c * rowBytes;
            int row1 = y1c * rowBytes;
            int rowOut = ty * modelWidth;

            for (int dx = 0; dx < box.ScaledWidth; dx++)
            {
                int tx = box.PadX + dx;
                if (tx < 0 || tx >= modelWidth) continue;
                double fx = srcX + (dx + 0.5) * stepX - 0.5;
                int x0 = (int)Math.Floor(fx);
                double wx = fx - x0;
                int x0c = Math.Clamp(x0, 0, pixelWidth - 1) * 4;
                int x1c = Math.Clamp(x0 + 1, 0, pixelWidth - 1) * 4;

                // BGRA
                float b = Lerp2(pixels[row0 + x0c + 0], pixels[row0 + x1c + 0],
                                pixels[row1 + x0c + 0], pixels[row1 + x1c + 0], wx, wy);
                float g = Lerp2(pixels[row0 + x0c + 1], pixels[row0 + x1c + 1],
                                pixels[row1 + x0c + 1], pixels[row1 + x1c + 1], wx, wy);
                float r = Lerp2(pixels[row0 + x0c + 2], pixels[row0 + x1c + 2],
                                pixels[row1 + x0c + 2], pixels[row1 + x1c + 2], wx, wy);

                if (grayscale)
                {
                    // Rec. 601 luma, the same weights the engine's AppearanceSampler uses.
                    float y = 0.299f * r + 0.587f * g + 0.114f * b;
                    r = g = b = y;
                }

                int at = rowOut + tx;
                tensor[at] = r / 255f;                  // R plane
                tensor[plane + at] = g / 255f;          // G plane
                tensor[2 * plane + at] = b / 255f;      // B plane
            }
        }
    }

    private static float Lerp2(byte p00, byte p10, byte p01, byte p11, double wx, double wy)
    {
        double top = p00 + (p10 - p00) * wx;
        double bottom = p01 + (p11 - p01) * wx;
        return (float)(top + (bottom - top) * wy);
    }
}
