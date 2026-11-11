using RodentFlow.Core;
using RodentFlow.Engine;

namespace RodentFlow.SelfCheck;

/// <summary>
/// Checks the frame preparation against the engine's own decoding arithmetic.
///
/// The host app letterboxes each frame into the model's square input, and the engine undoes that
/// letterbox to put keypoints back into frame pixels (PoseDecoding.decode). If the two disagree,
/// every keypoint is wrong by the difference and nothing downstream can notice. So:
///
///   1. the letterbox plan must match a table taken straight from PoseDecoding.swift;
///   2. a pixel placed at a known position in the crop must come back at that position when the
///      engine's inverse is applied to where the pixel landed in the tensor.
///
/// Test 2 uses a transcription of PoseDecoding.decode below as the reference, written from the
/// engine source and independent of FramePreparation.
/// </summary>
internal static class Program
{
    private static int _failures;

    private static int Main()
    {
        Console.WriteLine("RodentFlow Windows — self-check\n");
        LetterboxMatchesEngine();
        PreparationRoundTrips();
        GrayscaleAndPadding();
        SetupChecks.Run(Report);
        FigureChecks.Run(Report);
        WorkspaceChecks.Run(Report);
        ReviewChecks.Run(Report);
        PairingChecks.Run(Report);
        GroupChecks.Run(Report);
        Console.WriteLine(_failures == 0
            ? "\nall checks passed"
            : $"\n{_failures} check(s) failed");
        return _failures == 0 ? 0 : 1;
    }

    // ---------------------------------------------------------------- 1. letterbox plan

    private readonly record struct Expected(
        int InputW, int InputH, double Gain, int ScaledW, int ScaledH, int PadX, int PadY);

    private static void LetterboxMatchesEngine()
    {
        // Computed with the formula in PoseDecoding.swift:
        //   gain = min(mh/ih, mw/iw); padX = ((mw - (iw*gain).rounded())/2 - 0.1).rounded()
        Expected[] table =
        [
            new(1920, 1080, 0.5, 960, 540, 0, 210),
            new(1080, 1920, 0.5, 540, 960, 210, 0),
            new(640, 480, 1.5, 960, 720, 0, 120),
            new(960, 960, 1.0, 960, 960, 0, 0),
            new(1000, 1000, 0.96, 960, 960, 0, 0),
            new(1234, 567, 0.7779578606158833, 960, 441, 0, 259),
            new(33, 999, 0.960960960960961, 32, 960, 464, 0),
            new(3840, 2160, 0.25, 960, 540, 0, 210),
            new(720, 1280, 0.75, 540, 960, 210, 0),
            new(101, 103, 9.320388349514563, 941, 960, 9, 0),
        ];

        Console.WriteLine("1. letterbox plan matches PoseDecoding.swift");
        foreach (var e in table)
        {
            var box = FramePreparation.PlanLetterbox(e.InputW, e.InputH, 960, 960);
            bool ok = Math.Abs(box.Gain - e.Gain) < 1e-12
                      && box.ScaledWidth == e.ScaledW && box.ScaledHeight == e.ScaledH
                      && box.PadX == e.PadX && box.PadY == e.PadY;
            Report(ok, $"   {e.InputW}×{e.InputH} → gain {box.Gain:G17}, "
                       + $"scaled {box.ScaledWidth}×{box.ScaledHeight}, pad {box.PadX},{box.PadY}"
                       + (ok ? "" : $"   expected scaled {e.ScaledW}×{e.ScaledH}, pad {e.PadX},{e.PadY}"));
        }
    }

    // ---------------------------------------------------------------- 2. round trip

    /// <summary>
    /// Transcription of <c>PoseDecoding.decode</c>'s coordinate step (PoseDecoding.swift): a model
    /// keypoint back to a pixel of the image that was given to the model.
    /// </summary>
    private static (double X, double Y) EngineInverse(
        double modelX, double modelY, double inputW, double inputH, int modelW, int modelH)
    {
        double gain = Math.Min(modelH / inputH, modelW / inputW);
        double padX = Math.Round((modelW - Math.Round(inputW * gain, MidpointRounding.AwayFromZero)) / 2 - 0.1,
                                 MidpointRounding.AwayFromZero);
        double padY = Math.Round((modelH - Math.Round(inputH * gain, MidpointRounding.AwayFromZero)) / 2 - 0.1,
                                 MidpointRounding.AwayFromZero);
        double x = Math.Clamp((modelX - padX) / gain, 0, inputW);
        double y = Math.Clamp((modelY - padY) / gain, 0, inputH);
        // decode() then scales by frameSize / inputSize, which the engine calls with both equal to
        // the crop, so that step is the identity.
        return (x, y);
    }

    private static void PreparationRoundTrips()
    {
        Console.WriteLine("\n2. a marked pixel comes back where the engine's inverse expects it");
        (int W, int H, CropPixels Crop)[] cases =
        [
            (1920, 1080, new CropPixels { X = 0, Y = 0, Width = 1920, Height = 1080 }),
            (1920, 1080, new CropPixels { X = 240, Y = 100, Width = 1200, Height = 900 }),
            (1280, 720, new CropPixels { X = 37, Y = 11, Width = 601, Height = 453 }),
            (960, 960, new CropPixels { X = 0, Y = 0, Width = 960, Height = 960 }),
        ];

        const int modelSize = 960;
        var tensor = new float[3 * modelSize * modelSize];

        foreach (var (w, h, crop) in cases)
        {
            double worst = 0;
            // A few spots inside the crop, away from the edges so the mark is not clipped.
            (double fx, double fy)[] spots = [(0.25, 0.25), (0.5, 0.5), (0.75, 0.4), (0.4, 0.8)];
            foreach (var (fx, fy) in spots)
            {
                int markX = crop.X + (int)(crop.Width * fx);
                int markY = crop.Y + (int)(crop.Height * fy);
                var pixels = new byte[w * h * 4];
                // A 3 × 3 white mark on black, so its centre of mass survives the resampling.
                for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++)
                {
                    int px = markX + dx, py = markY + dy;
                    if (px < 0 || py < 0 || px >= w || py >= h) continue;
                    int at = py * w * 4 + px * 4;
                    pixels[at] = pixels[at + 1] = pixels[at + 2] = 255;
                    pixels[at + 3] = 255;
                }

                FramePreparation.Prepare(pixels, w, h, w * 4, crop, w, h,
                                         grayscale: true, modelSize, modelSize, tensor);

                // Centre of mass of the bright pixels in the tensor's first plane, ignoring padding.
                double sx = 0, sy = 0, m = 0;
                float pad = FramePreparation.PadValue / 255f;
                for (int y = 0; y < modelSize; y++)
                for (int x = 0; x < modelSize; x++)
                {
                    float v = tensor[y * modelSize + x];
                    if (v <= pad + 0.02f) continue;
                    double weight = v - pad;
                    sx += (x + 0.5) * weight;
                    sy += (y + 0.5) * weight;
                    m += weight;
                }
                if (m <= 0)
                {
                    Report(false, $"   {w}×{h} crop {crop.Width}×{crop.Height} at ({fx},{fy}): the mark vanished");
                    continue;
                }
                double modelX = sx / m - 0.5, modelY = sy / m - 0.5;

                var (backX, backY) = EngineInverse(modelX, modelY, crop.Width, crop.Height, modelSize, modelSize);
                // The engine then adds the crop origin (ArenaROI.uncrop).
                double frameX = backX + crop.X, frameY = backY + crop.Y;
                worst = Math.Max(worst, Math.Max(Math.Abs(frameX - markX), Math.Abs(frameY - markY)));
            }
            // One source pixel maps to 1/gain output pixels; half a source pixel is the most a
            // centre-of-mass estimate can be expected to resolve.
            double tolerance = Math.Max(1.0, 0.5 * crop.Width / modelSize * 2);
            Report(worst <= tolerance,
                   $"   {w}×{h}, crop {crop.Width}×{crop.Height} at {crop.X},{crop.Y}: "
                   + $"worst error {worst:F2} px (tolerance {tolerance:F2})");
        }
    }

    // ---------------------------------------------------------------- 3. padding and gray

    private static void GrayscaleAndPadding()
    {
        Console.WriteLine("\n3. padding and grayscale");
        const int model = 960;
        var tensor = new float[3 * model * model];
        int w = 1920, h = 1080;
        var pixels = new byte[w * h * 4];
        // A flat colour, so the gray value is easy to predict: B=10, G=150, R=200.
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 10; pixels[i + 1] = 150; pixels[i + 2] = 200; pixels[i + 3] = 255;
        }
        var crop = new CropPixels { X = 0, Y = 0, Width = w, Height = h };

        FramePreparation.Prepare(pixels, w, h, w * 4, crop, w, h, grayscale: true, model, model, tensor);
        var box = FramePreparation.PlanLetterbox(w, h, model, model);
        float expectedGray = (0.299f * 200 + 0.587f * 150 + 0.114f * 10) / 255f;
        float insideR = tensor[(box.PadY + 10) * model + 20];
        float insideG = tensor[model * model + (box.PadY + 10) * model + 20];
        Report(Math.Abs(insideR - expectedGray) < 1e-3 && Math.Abs(insideG - expectedGray) < 1e-3,
               $"   gray inside the image: {insideR:F4} (expected {expectedGray:F4}), "
               + $"all channels equal: {Math.Abs(insideR - insideG) < 1e-6}");

        float expectedPad = FramePreparation.PadValue / 255f;
        float above = tensor[(box.PadY / 2) * model + 20];
        Report(Math.Abs(above - expectedPad) < 1e-6,
               $"   padding above the image: {above:F4} (expected {expectedPad:F4})");

        FramePreparation.Prepare(pixels, w, h, w * 4, crop, w, h, grayscale: false, model, model, tensor);
        float colourR = tensor[(box.PadY + 10) * model + 20];
        float colourB = tensor[2 * model * model + (box.PadY + 10) * model + 20];
        Report(Math.Abs(colourR - 200 / 255f) < 1e-3 && Math.Abs(colourB - 10 / 255f) < 1e-3,
               $"   colour, planes are R,G,B: R={colourR:F4} (expected {200 / 255f:F4}), "
               + $"B={colourB:F4} (expected {10 / 255f:F4})");
    }

    private static void Report(bool ok, string message)
    {
        if (!ok) _failures++;
        Console.WriteLine((ok ? "   ok " : "   FAIL ") + message.TrimStart());
    }
}
