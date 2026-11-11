namespace RodentFlow.Core.Figures;

/// <summary>
/// Light or dark, and the surfaces and inks that depend on it. Mark colours do not change with the
/// theme (they are the Mac's fixed Okabe–Ito and zone tints); only the surfaces and text do.
/// </summary>
/// <remarks>
/// Surfaces follow Windows' own text and card colours (WinUI TextFillColorPrimary / Secondary,
/// cards), the way the Mac's follow macOS's system colours; figures saved to files always use
/// <see cref="Light"/>, as the Mac's do.
/// </remarks>
public sealed class FigureTheme
{
    private FigureTheme(bool dark) => Dark = dark;

    public static readonly FigureTheme Light = new(false);
    public static readonly FigureTheme DarkTheme = new(true);

    public static FigureTheme For(bool dark) => dark ? DarkTheme : Light;

    public bool Dark { get; }

    /// <summary>Text and strong marks (SwiftUI .primary).</summary>
    public Rgba Primary => Dark ? Rgba.White : Rgba.Black.Opacity(0.894);

    /// <summary>Secondary text, axes, outlines (SwiftUI .secondary).</summary>
    public Rgba Secondary => Dark ? Rgba.White.Opacity(0.773) : Rgba.Black.Opacity(0.62);

    /// <summary>Cards (FigureSurface.card).</summary>
    public Rgba Card => Dark ? Rgba.Hex(0x2B2B2B) : Rgba.White;

    /// <summary>Insets inside cards and empty plot areas (FigureSurface.inset: primary at 5.5 %).</summary>
    public Rgba Inset => Dark ? Rgba.White.Opacity(0.075) : Rgba.Black.Opacity(0.055);

    public Rgba Hairline => Dark ? Rgba.White.Opacity(0.12) : Rgba.Black.Opacity(0.1);

    /// <summary>The page behind cards (FigureSurface.canvas).</summary>
    public Rgba Background => Dark ? Rgba.Hex(0x202020) : Rgba.Hex(0xF3F3F3);

    /// <summary>The Mac's default accent (system blue), used for the trajectory and the mean line.</summary>
    public Rgba Accent => Dark ? Rgba.Hex(0x0A84FF) : Rgba.Hex(0x007AFF);

    public Rgba SystemGray => Dark ? Rgba.Hex(0x98989D) : Rgba.Hex(0x8E8E93);

    // RodentPose DesignSystem status colours (RPPalette.success / warning / danger).
    public Rgba Success => Dark ? Rgba.Hex(0x3DD27F) : Rgba.Hex(0x0A7A44);
    public Rgba Warning => Dark ? Rgba.Hex(0xFFB547) : Rgba.Hex(0xA65700);
    public Rgba Danger => Dark ? Rgba.Hex(0xFF6E6E) : Rgba.Hex(0xD12E2E);

    // SwiftUI system colours used by the keypoint swatches and the nose / body / tail marks.
    public Rgba SystemRed => Dark ? Rgba.Hex(0xFF453A) : Rgba.Hex(0xFF3B30);
    public Rgba SystemOrange => Dark ? Rgba.Hex(0xFF9F0A) : Rgba.Hex(0xFF9500);
    public Rgba SystemYellow => Dark ? Rgba.Hex(0xFFD60A) : Rgba.Hex(0xFFCC00);
    public Rgba SystemGreen => Dark ? Rgba.Hex(0x32D74B) : Rgba.Hex(0x28CD41);
    public Rgba SystemCyan => Dark ? Rgba.Hex(0x64D2FF) : Rgba.Hex(0x32ADE6);
    public Rgba SystemPurple => Dark ? Rgba.Hex(0xBF5AF2) : Rgba.Hex(0xAF52DE);

    /// <summary>Keypoint swatches of the quality card (RPPalette.keypoints: red, orange, yellow, green, cyan, purple).</summary>
    public Rgba Keypoint(int k) => (((k % 6) + 6) % 6) switch
    {
        0 => SystemRed,
        1 => SystemOrange,
        2 => SystemYellow,
        3 => SystemGreen,
        4 => SystemCyan,
        _ => SystemPurple,
    };

    /// <summary>Category tint of a task (RPPalette.category), for the "primary measure" tag.</summary>
    public Rgba Category(string category) => category switch
    {
        "social" => Dark ? Rgba.Hex(0xFF7B6E) : Rgba.Hex(0xBE3A32),
        "navigation" => Dark ? Rgba.Hex(0x8C88FF) : Rgba.Hex(0x4F46E5),
        "anxiety" => Dark ? Rgba.Hex(0x3CC3CD) : Rgba.Hex(0x0B7480),
        "memory" => Dark ? Rgba.Hex(0xB593FF) : Rgba.Hex(0x7C4DDB),
        "motor" => Dark ? Rgba.Hex(0xF2A04E) : Rgba.Hex(0xAB4F08),
        _ => Dark ? Rgba.Hex(0xA3ABB8) : Rgba.Hex(0x5B6474),
    };

    /// <summary>Fill of the headline scale bar (RPPalette.categoryFill: the same in both themes).</summary>
    public static Rgba CategoryFill(string category) => category switch
    {
        "social" => Rgba.Hex(0xBE3A32),
        "navigation" => Rgba.Hex(0x4F46E5),
        "anxiety" => Rgba.Hex(0x0B7480),
        "memory" => Rgba.Hex(0x7C4DDB),
        "motor" => Rgba.Hex(0xAB4F08),
        _ => Rgba.Hex(0x5B6474),
    };
}

/// <summary>
/// The figure colours of ReportPalette.swift (Shared/PoseUI), identical to the Mac and the phone:
/// mark colours by ColorKey, zone tints by ZoneRole, and the heat ramp.
/// </summary>
public static class Palette
{
    // Okabe–Ito (Wong 2011, Nature Methods) — colour-vision-deficiency-safe series colours.
    public static readonly Rgba OkabeBlue = new(0.000, 0.447, 0.698);
    public static readonly Rgba OkabeVermillion = new(0.835, 0.369, 0.000);
    public static readonly Rgba OkabeGreen = new(0.000, 0.620, 0.451);
    public static readonly Rgba OkabePurple = new(0.800, 0.475, 0.655);

    // Zone and mark tints.
    public static readonly Rgba Coral = new(0.949, 0.420, 0.380);
    public static readonly Rgba Amber = new(0.961, 0.620, 0.106);
    public static readonly Rgba Indigo = new(0.365, 0.396, 0.945);
    public static readonly Rgba Teal = new(0.137, 0.639, 0.690);
    public static readonly Rgba Violet = new(0.616, 0.388, 0.898);
    public static readonly Rgba Slate = new(0.443, 0.494, 0.573);

    // AnimalColors (AnimalGlyph.swift): A blue, B red, then the group colours.
    private static readonly Rgba[] Animals =
    [
        new(0.118, 0.533, 0.898), new(0.898, 0.224, 0.208), new(0.00, 0.62, 0.45), new(0.90, 0.62, 0.00),
        new(0.80, 0.47, 0.65), new(0.34, 0.71, 0.91), new(0.55, 0.38, 0.12), new(0.94, 0.84, 0.26),
        new(0.45, 0.45, 0.48), new(0.91, 0.30, 0.56),
    ];

    public static Rgba Animal(int i) => Animals[Math.Abs(i) % Animals.Length];

    /// <summary>ReportPalette.color(_:) — a ColorKey name to its colour.</summary>
    public static Rgba Color(string key, FigureTheme theme) => key switch
    {
        "accent" => theme.Accent,
        "neutral" => theme.SystemGray,
        "warning" => Amber,
        "social" => Coral,
        "object" => theme.SystemGray,
        "novel" => Amber,
        "familiar" => OkabeBlue,
        "center" => Indigo,
        "periphery" => Teal,
        "open" => new Rgba(0.95, 0.70, 0.10),
        "closed" => theme.SystemGray,
        "light" => new Rgba(0.98, 0.78, 0.18),
        "dark" => new Rgba(0.30, 0.32, 0.42),
        "freezing" => Indigo,
        "sniff" => new Rgba(0.91, 0.30, 0.56),
        "headDip" => new Rgba(0.92, 0.26, 0.24),
        "sap" => Violet,
        "poke" => new Rgba(0.91, 0.30, 0.56),
        "target" => OkabeGreen,
        "error" => new Rgba(0.92, 0.26, 0.24),
        "shelter" => Teal,
        "escape" => OkabeGreen,
        "cw" => OkabeVermillion,
        "ccw" => OkabeBlue,
        "animalA" => Animal(0),
        "animalB" => Animal(1),
        "animalC" => Animal(2),
        "animalD" => Animal(3),
        "animalE" => Animal(4),
        "animalF" => Animal(5),
        "animalG" => Animal(6),
        "animalH" => Animal(7),
        "animalI" => Animal(8),
        "animalJ" => Animal(9),
        "nose" => theme.SystemRed,
        "body" => theme.SystemCyan,
        "tail" => theme.SystemPurple,
        "series1" => OkabeBlue,
        "series2" => OkabeGreen,
        "series3" => OkabeVermillion,
        "series4" => OkabePurple,
        // Resident–intruder ethogram.
        "attack" => new Rgba(0.84, 0.18, 0.13),
        "clinch" => new Rgba(0.42, 0.05, 0.04),
        "chase" => new Rgba(0.90, 0.62, 0.00),
        "keepDown" => new Rgba(0.56, 0.27, 0.68),
        "threat" => new Rgba(0.94, 0.84, 0.26),
        "upright" => new Rgba(0.55, 0.38, 0.12),
        "mount" => new Rgba(0.00, 0.45, 0.70),
        "investigate" => new Rgba(0.34, 0.71, 0.91),
        "follow" => new Rgba(0.00, 0.62, 0.45),
        _ => theme.SystemGray,
    };

    /// <summary>ReportPalette.zone(_:) — a ZoneRole name to its tint.</summary>
    public static Rgba Zone(string role, FigureTheme theme) => role switch
    {
        "center" => Indigo,
        "periphery" or "corner" => Teal,
        "social" or "interaction" => Coral,
        "novel" => Amber,
        "familiar" => OkabeBlue,
        "open" => Color("open", theme),
        "arm" => Indigo,
        "choice" => Amber,
        "light" => Color("light", theme),
        "dark" => Color("dark", theme),
        "shelter" => Teal,
        "target" or "quadrant" => OkabeGreen,
        "cue" => Amber,
        // arena, chamber, cup, enclosure, mazeCenter, hole, object, closed
        _ => theme.SystemGray,
    };

    /// <summary>Sequential occupancy scale (dark blue → teal → yellow), ReportPalette.heatStops.</summary>
    private static readonly (double R, double G, double B)[] HeatStops =
        [(0.12, 0.10, 0.36), (0.16, 0.38, 0.62), (0.13, 0.62, 0.60), (0.48, 0.80, 0.38), (0.99, 0.88, 0.22)];

    public static Rgba Heat(double t)
    {
        double x = Math.Clamp(double.IsFinite(t) ? t : 0, 0, 1) * (HeatStops.Length - 1);
        int i = Math.Min((int)x, HeatStops.Length - 2);
        double f = x - i;
        var a = HeatStops[i];
        var b = HeatStops[i + 1];
        return new Rgba(a.R + (b.R - a.R) * f, a.G + (b.G - a.G) * f, a.B + (b.B - a.B) * f);
    }

    /// <summary>
    /// Heat maps are drawn in this many colour steps (indistinguishable from a continuous scale), so
    /// all cells of one step are filled at once (HeatSteps, ReportFigures.swift).
    /// </summary>
    public const int HeatStepCount = 64;

    public static int HeatStep(double t) =>
        (int)Math.Round(Math.Clamp(t, 0, 1) * HeatStepCount, MidpointRounding.AwayFromZero);

    public static double HeatStepValue(int k) => (double)k / HeatStepCount;
}
