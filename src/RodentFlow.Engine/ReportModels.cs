namespace RodentFlow.Engine;

// The report a result page draws: rf_analyze's "report" (engine/Sources/RodentFlowABI/ABI/ReportView.swift).
// Property names are the Swift dictionary keys in camelCase; check/check_report_contract.py compares
// the two files key by key, so a key renamed on one side shows up before it silently reads as a default.
//
// Point lists are flat: [x0, y0, x1, y1, …]. A non-finite number arrives as NaN (LenientDoubleConverter).
// Colours are ColorKey names ("accent", "center", "animalA" …) and zone roles ZoneRole names; the
// palette that turns them into colours is RodentFlow.Core.Figures.Palette (a port of ReportPalette.swift).

/// <summary>Everything the result page shows for one session.</summary>
public record DisplayReport
{
    /// <summary>"zh" or "en": the language the texts are in.</summary>
    public string Language { get; init; } = "en";
    /// <summary>ParadigmCategory: social · navigation · anxiety · memory · motor · general.</summary>
    public string Category { get; init; } = "general";
    public string PrimaryKey { get; init; } = "";
    /// <summary>One line under the headline value (e.g. "First choice: deep side").</summary>
    public string? KeyNote { get; init; }
    public ReportMetric[] Metrics { get; init; } = [];
    /// <summary>Tracking and data problems first, the task's standing notes last.</summary>
    public string[] Warnings { get; init; } = [];
    /// <summary>One sentence per method decision.</summary>
    public string[] Methods { get; init; } = [];
    /// <summary>The Methods sentences joined as the Mac shows them (spaced in English).</summary>
    public string MethodsText { get; init; } = "";
    public ReportQuality Quality { get; init; } = new();
    public ReportBlock[] Blocks { get; init; } = [];
    /// <summary>Two animals, one dark and one white: index of the dark one.</summary>
    public int? DarkAnimal { get; init; }
    /// <summary>FigureLayer raw value → its title in the report's language.</summary>
    public Dictionary<string, string> LayerTitles { get; init; } = new();
    /// <summary>HeatBackdrop raw value (none · overlay · sideBySide) → its title.</summary>
    public Dictionary<string, string> BackdropTitles { get; init; } = new();
    /// <summary>What the review player shows under the video.</summary>
    public ReportReview Review { get; init; } = new();

    /// <summary>The headline measure: the primary key's, else the first (AnalysisReport.primary).</summary>
    public ReportMetric? Primary => Metrics.FirstOrDefault(m => m.Key == PrimaryKey) ?? Metrics.FirstOrDefault();
}

public record ReportMetric
{
    public string Key { get; init; } = "";
    public string Title { get; init; } = "";
    public string Unit { get; init; } = "";
    public double? Value { get; init; }
    public int Decimals { get; init; }
    public bool Highlight { get; init; }
    /// <summary>The value as cards show it ("≥ 300.0" for a censored latency, the value text when there is one, "—").</summary>
    public string Display { get; init; } = "—";
    /// <summary>The unit shown next to <see cref="Display"/> (empty with a value text or no value).</summary>
    public string DisplayUnit { get; init; } = "";
    public string? Info { get; init; }
    /// <summary>Why a latency is the cut-off (e.g. "no entry").</summary>
    public string? Censored { get; init; }
    public string? ValueText { get; init; }
    public double? Reference { get; init; }
    public string? ReferenceLabel { get; init; }
    /// <summary>The scale bar under the headline value (MetricScale); null when the measure has none.</summary>
    public ReportMetricScale? Scale { get; init; }
}

public record ReportMetricScale
{
    public double Low { get; init; }
    public double High { get; init; }
    public string LowLabel { get; init; } = "";
    public string HighLabel { get; init; } = "";
    public double? Reference { get; init; }
    public string? ReferenceLabel { get; init; }
}

public record ReportQuality
{
    public int Frames { get; init; }
    public int FramesInWindow { get; init; }
    public double WindowSeconds { get; init; }
    public double DetectionRate { get; init; }
    /// <summary>Fraction of frames with each keypoint above the confidence threshold (keypoint order).</summary>
    public double[] KeypointRates { get; init; } = [];
    public double HeadDirectionRate { get; init; }
    public double SampleRate { get; init; }
    public double PxPerUnit { get; init; }
    public string Unit { get; init; } = "cm";
    /// <summary>Per animal: share of the window's frames tracked outside the calibrated arena.</summary>
    public double[] OutsideArenaFraction { get; init; } = [];
    /// <summary>The animals' letters, as on the video (A / B, or 1, 2, 3 … in a group).</summary>
    public string[] AnimalLetters { get; init; } = [];
    public KeypointLabel[] Keypoints { get; init; } = [];
}

public record KeypointLabel
{
    public string Title { get; init; } = "";
    public string Short { get; init; } = "";
}

/// <summary>One figure of the report. Exactly one of the kind-named payloads is set.</summary>
public record ReportBlock
{
    public int Index { get; init; }
    public string Title { get; init; } = "";
    public string? Caption { get; init; }
    /// <summary>arena · timeline · bars · line · polar · table</summary>
    public string Kind { get; init; } = "";
    /// <summary>Task + English title: where the figure's layer choice is remembered.</summary>
    public string StyleKey { get; init; } = "";
    /// <summary>The data behind the figure, in English (BlockCSV); null for arena figures.</summary>
    public string? Csv { get; init; }
    public ReportArena? Arena { get; init; }
    public ReportTimeline? Timeline { get; init; }
    public ReportBars? Bars { get; init; }
    public ReportLine? Line { get; init; }
    public ReportPolar? Polar { get; init; }
    public ReportTable? Table { get; init; }
}

// ---------------------------------------------------------------- arena figures

public record ReportArena
{
    /// <summary>[width, height] of the plotting frame in arena units (cm, or px uncalibrated).</summary>
    public double[] Extent { get; init; } = [1, 1];
    public string Unit { get; init; } = "cm";
    public ReportZone? Arena { get; init; }
    public ReportZone[] Zones { get; init; } = [];
    public ReportPath[] Paths { get; init; } = [];
    public ReportDot[] Dots { get; init; } = [];
    public ReportArrow[] Arrows { get; init; } = [];
    public ReportHeat? Heat { get; init; }
    public int? HeatKeypoint { get; init; }
    /// <summary>The figure on the video frame; null when the figure has no video behind it.</summary>
    public ReportFrame? Frame { get; init; }
    /// <summary>FigureLayer raw values this figure offers, in the order of the layer list.</summary>
    public string[] Layers { get; init; } = [];
    public ZoneFamilyInfo[] ZoneFamilies { get; init; } = [];

    public double Width => Extent.Length > 0 ? Extent[0] : 1;
    public double Height => Extent.Length > 1 ? Extent[1] : 1;
}

public record ReportZone
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    /// <summary>ZoneRole raw value.</summary>
    public string Role { get; init; } = "";
    /// <summary>ZoneFamily.key: zones shown or hidden together.</summary>
    public string Family { get; init; } = "";
    public bool ShowsLabel { get; init; } = true;
    public bool OutlineOnly { get; init; }
    /// <summary>Closed outline in arena units, flat.</summary>
    public double[] Outline { get; init; } = [];
    public double[] Center { get; init; } = [];
    /// <summary>The same outline in upright-frame pixels; null without a calibrated mapping.</summary>
    public double[]? Image { get; init; }
    public double[]? ImageCenter { get; init; }
}

public record ReportPath
{
    public string Color { get; init; } = "accent";
    public double Width { get; init; } = 1.2;
    public double Opacity { get; init; } = 0.8;
    /// <summary>Polylines (flat); a new one starts after missing samples.</summary>
    public double[][] Segments { get; init; } = [];
}

public record ReportDot
{
    public double X { get; init; }
    public double Y { get; init; }
    public string Color { get; init; } = "accent";
    public double Radius { get; init; } = 1.6;
}

public record ReportArrow
{
    public double[] From { get; init; } = [];
    public double[] To { get; init; } = [];
    public string Color { get; init; } = "accent";
}

public record ReportHeat
{
    public int Columns { get; init; }
    public int Rows { get; init; }
    /// <summary>Cell size in arena units.</summary>
    public double Cell { get; init; }
    /// <summary>Row-major seconds per cell; NaN = outside the arena.</summary>
    public double[] Values { get; init; } = [];
}

public record ReportFrame
{
    public bool IsMetric { get; init; }
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
    /// <summary>The part of the frame that shows the arena, with a margin (FigureGeometry.frameCrop).</summary>
    public ReportBox? Crop { get; init; }
    /// <summary>9 numbers per drawn heat cell: its index in <see cref="ReportHeat.Values"/>, then four corners in pixels.</summary>
    public double[] HeatCells { get; init; } = [];
}

public record ReportBox
{
    public double X { get; init; }
    public double Y { get; init; }
    public double W { get; init; }
    public double H { get; init; }
}

public record ZoneFamilyInfo
{
    public string Key { get; init; } = "";
    public string Title { get; init; } = "";
}

// ---------------------------------------------------------------- charts

public record ReportTimeline
{
    public double Start { get; init; }
    public double End { get; init; }
    public ReportTrack[] Tracks { get; init; } = [];
    public ReportEpoch[] Epochs { get; init; } = [];
}

public record ReportTrack
{
    public string Name { get; init; } = "";
    public string Color { get; init; } = "neutral";
    /// <summary>"behavior" (solid bars) or "flag" (a moment to check: hatched outline).</summary>
    public string Style { get; init; } = "behavior";
    /// <summary>[start0, end0, start1, end1, …] in video seconds.</summary>
    public double[] Bouts { get; init; } = [];
    /// <summary>Sub-bouts drawn as a darker band inside the bars (e.g. clinch inside attacks).</summary>
    public double[] Inner { get; init; } = [];
    public string InnerColor { get; init; } = "neutral";
    public string? InnerName { get; init; }

    public bool IsFlag => Style == "flag";
}

public record ReportEpoch
{
    public string Name { get; init; } = "";
    public double Start { get; init; }
    public double End { get; init; }
    public string Color { get; init; } = "warning";
}

public record ReportBars
{
    public ReportBar[] Items { get; init; } = [];
    public string Unit { get; init; } = "";
    public int Decimals { get; init; } = 1;
    public double? ReferenceLine { get; init; }
    public bool Horizontal { get; init; }
    public string? ReferenceLabel { get; init; }
}

public record ReportBar
{
    public string Label { get; init; } = "";
    public double Value { get; init; }
    public string Color { get; init; } = "accent";
    public string? Group { get; init; }
}

public record ReportLine
{
    public ReportSeries[] Series { get; init; } = [];
    public string XLabel { get; init; } = "";
    public string YLabel { get; init; } = "";
    /// <summary>[low, high], or null for an automatic axis.</summary>
    public double[]? YRange { get; init; }
    public double? ReferenceY { get; init; }
    public double? ReferenceX { get; init; }
    public string? ReferenceYLabel { get; init; }
    public string? ReferenceXLabel { get; init; }
    public ReportEpoch[] Epochs { get; init; } = [];
}

public record ReportSeries
{
    public string Name { get; init; } = "";
    public string Color { get; init; } = "series1";
    /// <summary>[x0, y0, x1, y1, …].</summary>
    public double[] Points { get; init; } = [];
    public bool Dashed { get; init; }
}

public record ReportPolar
{
    /// <summary>Value per angular bin; bin 0 starts at 0°, counter-clockwise.</summary>
    public double[] Values { get; init; } = [];
    public string Unit { get; init; } = "s";
    public string Color { get; init; } = "accent";
    public double? MeanAngle { get; init; }
    public double? ResultantLength { get; init; }
    public double? ReferenceAngle { get; init; }
}

public record ReportTable
{
    public string[] Columns { get; init; } = [];
    public string[][] Rows { get; init; } = [];
    /// <summary>Optional colour per row (ColorKey name), null for none.</summary>
    public string?[] RowColors { get; init; } = [];
}

public record ReportReview
{
    public ReportTrack[] Tracks { get; init; } = [];
    public ReportEpoch[] Epochs { get; init; } = [];
    /// <summary>Novelty-suppressed feeding: candidate feeding bouts to confirm, flat [start, end, …].</summary>
    public double[] FeedingCandidates { get; init; } = [];
    /// <summary>Moments to check in the tracking (ABI/ReviewABI.swift qcEvents), in track order.</summary>
    public ReviewEvent[] Qc { get; init; } = [];
}

/// <summary>A run of consecutive frames with the same tracking-quality note. Only points frames out for review.</summary>
public record ReviewEvent
{
    /// <summary>noDetection · animalMissing · lowConfidence · outsideArena · identitySuspect · identityUncertain · overlapping</summary>
    public string Kind { get; init; } = "";
    /// <summary>The kind in the report's language.</summary>
    public string Title { get; init; } = "";
    /// <summary>Track indices (positions in pose.mpt), first and last.</summary>
    public int FirstIndex { get; init; }
    public int LastIndex { get; init; }
    public int Frames { get; init; }
    /// <summary>Video seconds.</summary>
    public double Start { get; init; }
    public double End { get; init; }
    public double? ToleranceCM { get; init; }
}

// ---------------------------------------------------------------- identity corrections (ABI/ReviewABI.swift)

public record SwapRequest(string PoseFile, int? At, int? From, int? To);

public record SwapResult : EngineReply
{
    /// <summary>False when there was nothing to swap.</summary>
    public bool Swapped { get; init; }
    /// <summary>[first, last] track indices whose A / B order changed; null when none.</summary>
    public int[]? Changed { get; init; }
}

public record IdentitySegmentsReply : EngineReply
{
    /// <summary>[first, last] track indices of each identity segment.</summary>
    public int[][] Segments { get; init; } = [];
}

// ---------------------------------------------------------------- interface texts

public record TranslateRequest(string[] Texts, bool English);

public record TranslateReply : EngineReply
{
    public string[] Texts { get; init; } = [];
}

// ---------------------------------------------------------------- marble burying (ABI/MarbleABI.swift)

/// <summary>Where to read the marbles of a session: centres (upright pixels), radius, interval, cache key.</summary>
public record MarblePlan : EngineReply
{
    /// <summary>False when the session is not marble burying or its marble grid is not placed.</summary>
    public bool Needed { get; init; }
    /// <summary>MarbleGrid.sampleKey: readings saved under another key are read again.</summary>
    public string Key { get; init; } = "";
    /// <summary>[x, y] per marble, row by row from the top-left.</summary>
    public double[][] Centers { get; init; } = [];
    public double Radius { get; init; }
    /// <summary>Seconds between readings (AnalysisParams.mbSampleInterval, at least 0.1).</summary>
    public double Interval { get; init; } = 0.5;
    public double FrameWidth { get; init; }
    public double FrameHeight { get; init; }
}

