using System.Text.Json;
using RodentFlow.Engine;

namespace RodentFlow.Core.Figures;

/// <summary>FigureLayer raw values (Shared/Figures/FigureOptions.swift).</summary>
public static class FigureLayers
{
    public const string ArenaOutline = "arenaOutline";
    public const string ZoneLabels = "zoneLabels";
    public const string InvestigationRings = "investigationRings";
    public const string Trajectory = "trajectory";
    public const string StartEnd = "startEnd";
    public const string Dots = "dots";
    public const string Arrows = "arrows";
    public const string ScaleBar = "scaleBar";
    public const string Legend = "legend";
}

/// <summary>HeatBackdrop raw values: how a heat map meets the original frame.</summary>
public static class HeatBackdrops
{
    public const string None = "none";
    public const string Overlay = "overlay";
    public const string SideBySide = "sideBySide";

    public static readonly string[] All = [None, Overlay, SideBySide];
}

/// <summary>
/// What one arena figure shows (FigureStyle, FigureOptions.swift): layers switched off, zone families
/// switched off, and how a heat map meets the original frame. Only the figure changes, never a measure.
/// </summary>
public sealed class FigureStyle
{
    public HashSet<string> Hidden { get; set; } = [];
    public HashSet<string> HiddenZones { get; set; } = [];
    public string Backdrop { get; set; } = HeatBackdrops.None;
    public double OverlayOpacity { get; set; } = 0.6;

    public bool Shows(string layer) => !Hidden.Contains(layer);

    /// <summary>A zone is drawn when its family is on; dashed rings also need their layer.</summary>
    public bool Shows(ReportZone zone)
    {
        if (zone.OutlineOnly && Hidden.Contains(FigureLayers.InvestigationRings)) return false;
        return !HiddenZones.Contains(zone.Family);
    }

    public bool IsDefault =>
        Hidden.Count == 0 && HiddenZones.Count == 0 && Backdrop == HeatBackdrops.None
        && Math.Abs(OverlayOpacity - 0.6) < 1e-9;

    public FigureStyle Clone() => new()
    {
        Hidden = [.. Hidden],
        HiddenZones = [.. HiddenZones],
        Backdrop = Backdrop,
        OverlayOpacity = OverlayOpacity,
    };

    /// <summary>The Mac's decoding rules: unknown values dropped, the opacity kept within 0.1–1.</summary>
    public FigureStyle Normalized()
    {
        var s = Clone();
        s.Backdrop = Array.IndexOf(HeatBackdrops.All, s.Backdrop) >= 0 ? s.Backdrop : HeatBackdrops.None;
        s.OverlayOpacity = double.IsFinite(s.OverlayOpacity) ? Math.Clamp(s.OverlayOpacity, 0.1, 1) : 0.6;
        return s;
    }
}

/// <summary>
/// Remembered figure styles, per task and figure (FigureStyleStore, FigureOptions.swift), so every animal
/// of a task is drawn and exported the same way. Kept in <c>%LOCALAPPDATA%\RodentFlow\figure-styles.json</c>,
/// one entry per key, each in the Mac's JSON form ({hidden, hiddenZones, backdrop, overlayOpacity}).
/// </summary>
public static class FigureStyleStore
{
    private static readonly object Gate = new();
    private static Dictionary<string, FigureStyle>? _styles;

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private static string _filePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RodentFlow", "figure-styles.json");

    /// <summary>Where the styles are kept; settable so a test can point it elsewhere (the cache is dropped).</summary>
    public static string FilePath
    {
        get => _filePath;
        set
        {
            lock (Gate)
            {
                _filePath = value;
                _styles = null;
            }
        }
    }

    public static FigureStyle Load(string key)
    {
        lock (Gate)
        {
            var all = Read();
            return all.TryGetValue(key, out var s) ? s.Normalized() : new FigureStyle();
        }
    }

    public static void Save(string key, FigureStyle style)
    {
        lock (Gate)
        {
            var all = Read();
            if (style.IsDefault) all.Remove(key);
            else all[key] = style.Normalized();
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(all, Json));
            }
            catch (IOException)
            {
                // A figure style that cannot be remembered still applies for this session.
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static Dictionary<string, FigureStyle> Read()
    {
        if (_styles is not null) return _styles;
        try
        {
            _styles = File.Exists(FilePath)
                ? JsonSerializer.Deserialize<Dictionary<string, FigureStyle>>(File.ReadAllText(FilePath), Json)
                  ?? new Dictionary<string, FigureStyle>()
                : new Dictionary<string, FigureStyle>();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // A damaged file must not stop the results from showing.
            _styles = new Dictionary<string, FigureStyle>();
        }
        return _styles;
    }
}
