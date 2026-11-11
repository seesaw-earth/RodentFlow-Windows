using System.Text.Json;
using RodentFlow.Core;
using RodentFlow.Onnx;

namespace RodentFlow.App;

/// <summary>
/// Where the app finds the models and ffmpeg, and how it runs them. Kept next to the user's data so
/// a lab machine holds its own setup.
/// </summary>
public sealed class AppSettings
{
    private static string Folder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RodentFlow");

    private static string File => Path.Combine(Folder, "settings.json");

    /// <summary>Folder with the exported .onnx files.</summary>
    public string ModelsFolder { get; set; } = Path.Combine(AppContext.BaseDirectory, "models");

    /// <summary>Folder with ffmpeg.exe and ffprobe.exe; empty = look on PATH.</summary>
    public string FFmpegFolder { get; set; } = "";

    /// <summary>
    /// ONNX Runtime execution provider to try. "CPU" always works. A hardware provider needs its own
    /// NuGet package: for DirectML, add Microsoft.ML.OnnxRuntime.DirectML to RodentFlow.Onnx and pass
    /// <c>Configure: o =&gt; o.AppendExecutionProvider_DML(0)</c> below. See docs/STATUS_CN.md.
    /// </summary>
    public string Provider { get; set; } = "CPU";

    /// <summary>
    /// Where the model runs: "auto" (default) times the processor and each graphics card once per model and keeps the
    /// fastest — a graphics card is not always faster; "cpu" the processor; "gpu" the graphics card (DirectML).
    /// </summary>
    public string Device { get; set; } = "auto";

    /// <summary>0 = let ONNX Runtime decide.</summary>
    public int Threads { get; set; }

    /// <summary>The interface, the reports and the forms in Chinese (switched in the window, as on the Mac).</summary>
    public bool Chinese { get; set; }

    /// <summary>Where new run folders are created.</summary>
    public string WorkFolder { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "RodentFlow");

    public FFmpegTools Tools => FFmpegFolder.Length > 0 ? FFmpegTools.In(FFmpegFolder) : new FFmpegTools();

    public PoseModelOptions ModelOptions() => new(
        Provider: Device switch { "cpu" => Provider, "gpu" => "DML", _ => "Auto" }, IntraOpThreads: Threads);

    public static AppSettings Load()
    {
        try
        {
            if (System.IO.File.Exists(File))
                return JsonSerializer.Deserialize<AppSettings>(System.IO.File.ReadAllText(File)) ?? new AppSettings();
        }
        catch (Exception)
        {
            // A damaged settings file should not stop the app from opening.
        }
        return new AppSettings();
    }

    public void Save()
    {
        Directory.CreateDirectory(Folder);
        System.IO.File.WriteAllText(File,
            JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
