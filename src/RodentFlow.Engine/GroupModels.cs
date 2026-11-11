using System.Text.Json;
using System.Text.Json.Nodes;

namespace RodentFlow.Engine;

// The group comparison of a task (rf_group_analysis, engine/Sources/RodentFlowABI/ABI/GroupABI.swift).
// The request and the plot style travel as the engine wrote them (GroupAnalysisRequest, GroupPlotStyle): the window
// changes single keys and sends them back. check/check_report_contract.py compares the keys of both files.

/// <summary>One analysed session of the task, with the summary rf_analyze returned for it (kept unchanged).</summary>
public record GroupSessionInput(Guid Id, string SubjectID, string SubjectKey, string Group, string Phase, int? Day,
                                int? Trial, int? Session, string? Date, bool Excluded, string? ExclusionReason,
                                string? Sex, bool? TrackingProblem, JsonObject Summary);

public record GroupAnalysisCall
{
    public string Paradigm { get; init; } = "";
    public string? TaskName { get; init; }
    public GroupSessionInput[] Sessions { get; init; } = [];
    /// <summary>GroupAnalysisRequest as the engine last returned it; null = the task's default.</summary>
    public JsonObject? Request { get; init; }
    /// <summary>GroupPlotStyle; null = the default (dots + mean ± SEM, brackets with stars).</summary>
    public JsonObject? Style { get; init; }
    /// <summary>Texts and figure in English (files); else the interface language.</summary>
    public bool? English { get; init; }
    public bool? ShowAnimals { get; init; }
}

public record GroupReply : EngineReply
{
    public JsonObject Request { get; init; } = new();
    public JsonObject Style { get; init; } = new();
    public GroupOptions Options { get; init; } = new();
    public GroupResultInfo Result { get; init; } = new();
    public PubFigureData Figure { get; init; } = new();
    /// <summary>The figure as the Mac's SVG (PubSVG.render), for files.</summary>
    public string Svg { get; init; } = "";
}

public record GroupOption
{
    public string Key { get; init; } = "";
    public string Title { get; init; } = "";
    public string? Unit { get; init; }
}

public record GroupOptions
{
    public GroupOption[] Designs { get; init; } = [];
    public GroupOption[] Metrics { get; init; } = [];
    public GroupOption[] Series { get; init; } = [];
    public GroupOption[] Pairs { get; init; } = [];
    public GroupOption[] Phases { get; init; } = [];
    public int[] Sessions { get; init; } = [];
    public int[] Days { get; init; } = [];
    public GroupOption[] Groups { get; init; } = [];
    public GroupOption[] Factors { get; init; } = [];
    public GroupOption[] Modes { get; init; } = [];
    public GroupOption[] Comparisons { get; init; } = [];
    public GroupOption[] Plots { get; init; } = [];
    public GroupOption[] Errors { get; init; } = [];
    public GroupOption[] Significance { get; init; } = [];
}

public record GroupResultInfo
{
    public string MetricName { get; init; } = "";
    public string Unit { get; init; } = "";
    public string AxisTitle { get; init; } = "";
    public int AnimalCount { get; init; }
    public bool IsEmpty { get; init; } = true;
    /// <summary>MainAnalysis: standard · proportion · survival · survival_unavailable · two_way · ancova · descriptive.</summary>
    public string Main { get; init; } = "standard";
    public string MainNote { get; init; } = "";
    public string[] Notes { get; init; } = [];
    public string[] CrossoverSubjects { get; init; } = [];
    /// <summary>The result in one paragraph (GroupAnalysisEngine.summaryText).</summary>
    public string Summary { get; init; } = "";
    /// <summary>The tests line by line (GroupReportText.detailLines).</summary>
    public string[] Details { get; init; } = [];
    public string StatsCsv { get; init; } = "";
    public string LongCsv { get; init; } = "";
    public GroupDescriptives[] Descriptives { get; init; } = [];
}

public record GroupDescriptives
{
    public string Group { get; init; } = "";
    public int N { get; init; }
    public double Mean { get; init; }
    public double Sd { get; init; }
    public double Sem { get; init; }
    public double Median { get; init; }
    public double Q1 { get; init; }
    public double Q3 { get; init; }
    public double Min { get; init; }
    public double Max { get; init; }
}

/// <summary>A publication figure (PubFigure) as drawing items, in points; y grows downwards.</summary>
public record PubFigureData
{
    public double Width { get; init; }
    public double Height { get; init; }
    /// <summary>[r, g, b, a] 0–1, or null for none.</summary>
    public double[]? Background { get; init; }
    public PubItemData[] Items { get; init; } = [];
}

/// <summary>"shape" (path ops, fill, stroke) or "text".</summary>
public record PubItemData
{
    public string Kind { get; init; } = "";
    /// <summary>Path operations: ["M", x, y], ["L", x, y], ["C", x1, y1, x2, y2, x, y], ["Z"].</summary>
    public JsonElement[]? Ops { get; init; }
    public double[]? Fill { get; init; }
    public PubStrokeData? Stroke { get; init; }
    public string Text { get; init; } = "";
    public double X { get; init; }
    public double Y { get; init; }
    public double Size { get; init; } = 7;
    public bool Bold { get; init; }
    public double[]? Color { get; init; }
    /// <summary>start · middle · end</summary>
    public string Anchor { get; init; } = "start";
    /// <summary>alphabetic · middle · hanging</summary>
    public string Baseline { get; init; } = "alphabetic";
    /// <summary>Degrees, clockwise, about (x, y).</summary>
    public double Rotation { get; init; }
}

public record PubStrokeData
{
    public double[] Color { get; init; } = [0, 0, 0, 1];
    public double Width { get; init; } = 1;
    public double[] Dash { get; init; } = [];
}
