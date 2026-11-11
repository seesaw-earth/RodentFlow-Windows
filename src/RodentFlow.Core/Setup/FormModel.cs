using System.Globalization;
using System.Text.Json.Nodes;

namespace RodentFlow.Core.Setup;

// The pieces a task's parameter form is made of. The forms themselves are in AssayForms.cs; the
// window turns each row into a control and never needs to know which task it is showing.
//
// Values live in the task's AnalysisParams object (a JsonObject the engine handed out). Rows read
// and write that object through ParamValues, which keeps the JSON types the engine's decoder expects:
// an Int field written as 20.0 would not decode as Int, and the engine's tolerant decoding would then
// quietly use its default — so integer rows always write integers.

public enum RowKind
{
    /// <summary>A number with a unit (NumberBox).</summary>
    Number,
    /// <summary>A fraction 0–1 shown as a percentage (Slider).</summary>
    Percent,
    /// <summary>One of a few values (segmented choice).</summary>
    Choice,
    /// <summary>On / off.</summary>
    Toggle,
    /// <summary>A list of times in seconds, typed comma-separated.</summary>
    Onsets,
    /// <summary>Explanatory text only.</summary>
    Note,
}

/// <summary>What a row's visibility, title or value can depend on.</summary>
public sealed record FormContext(string Phase, JsonObject Params);

/// <summary>One choice of a <see cref="RowKind.Choice"/> row. Value is a string, double or bool.</summary>
public sealed record ChoiceOption(object Value, string En, string Zh);

public sealed record FormRow
{
    public RowKind Kind { get; init; }
    /// <summary>The AnalysisParams key; empty for notes.</summary>
    public string Key { get; init; } = "";
    public string En { get; init; } = "";
    public string Zh { get; init; } = "";
    public string Unit { get; init; } = "";
    public double Min { get; init; }
    public double Max { get; init; } = double.MaxValue;
    /// <summary>Written as a JSON integer (Int fields: holeCount, mbRows, mbCols).</summary>
    public bool Integer { get; init; }
    /// <summary>Slider step (Percent rows step 0.01, the confidence slider 0.05).</summary>
    public double Step { get; init; }
    public ChoiceOption[] Options { get; init; } = [];
    public string HelpEn { get; init; } = "";
    public string HelpZh { get; init; } = "";
    /// <summary>Shown only when this is true; null = always.</summary>
    public Func<FormContext, bool>? When { get; init; }
    /// <summary>A title that depends on the phase or another value (three-chamber cup, for one).</summary>
    public Func<FormContext, (string En, string Zh)>? TitleFor { get; init; }
    /// <summary>Value when the key is absent or null (cornerFraction is optional in the engine).</summary>
    public double? Fallback { get; init; }
    /// <summary>
    /// A toggle that is not one field but a rule over several (the hunger control of novelty-suppressed
    /// feeding switches three fields between −1 = not recorded and 0 = to be filled in).
    /// </summary>
    public Func<JsonObject, bool>? GetToggle { get; init; }
    public Action<JsonObject, bool>? SetToggle { get; init; }
    /// <summary>Every key the row reads or writes (for checking the form against the engine).</summary>
    public string[] Keys { get; init; } = [];

    public IEnumerable<string> AllKeys() =>
        Key.Length > 0 ? Keys.Prepend(Key).Distinct() : Keys;

    public bool IsVisible(FormContext c) => When?.Invoke(c) ?? true;

    public string Title(FormContext c, bool chinese)
    {
        var (en, zh) = TitleFor?.Invoke(c) ?? (En, Zh);
        return chinese ? zh : en;
    }

    public string Help(bool chinese) => chinese ? HelpZh : HelpEn;
}

/// <summary>Rows shown together, optionally under a title that folds them away.</summary>
public sealed record FormGroup
{
    /// <summary>Null = rows shown directly, not inside an expander.</summary>
    public string? En { get; init; }
    public string? Zh { get; init; }
    public FormRow[] Rows { get; init; } = [];
    /// <summary>Folded away under its title (the Mac's DisclosureGroup); otherwise the title is a heading.</summary>
    public bool Folded { get; init; }
}

/// <summary>Reading and writing AnalysisParams values with the JSON types the engine decodes.</summary>
public static class ParamValues
{
    public static double? Number(JsonObject p, string key)
    {
        if (p[key] is not JsonValue v) return null;
        if (v.TryGetValue(out double d)) return d;
        if (v.TryGetValue(out int i)) return i;
        if (v.TryGetValue(out long l)) return l;
        return null;
    }

    public static string? Text(JsonObject p, string key) =>
        p[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    public static bool? Flag(JsonObject p, string key) =>
        p[key] is JsonValue v && v.TryGetValue(out bool b) ? b : null;

    public static void SetNumber(JsonObject p, string key, double value, bool integer) =>
        p[key] = integer ? JsonValue.Create((int)Math.Round(value)) : JsonValue.Create(value);

    public static void SetChoice(JsonObject p, string key, object value) =>
        p[key] = value switch
        {
            string s => JsonValue.Create(s),
            bool b => JsonValue.Create(b),
            double d => JsonValue.Create(d),
            int i => JsonValue.Create(i),
            _ => throw new ArgumentException($"Choice value of type {value.GetType().Name} for {key}"),
        };

    /// <summary>Whether the stored value is this choice (numbers compared as numbers).</summary>
    public static bool IsChoice(JsonObject p, string key, object value) => value switch
    {
        string s => Text(p, key) == s,
        bool b => Flag(p, key) == b,
        double d => Number(p, key) is { } n && Math.Abs(n - d) < 1e-9,
        int i => Number(p, key) is { } n && Math.Abs(n - i) < 1e-9,
        _ => false,
    };

    public static double[] Onsets(JsonObject p, string key) =>
        p[key] is JsonArray a
            ? a.Select(n => n is JsonValue v && v.TryGetValue(out double d) ? d : double.NaN)
               .Where(double.IsFinite).ToArray()
            : [];

    public static void SetOnsets(JsonObject p, string key, IEnumerable<double> values)
    {
        var a = new JsonArray();
        foreach (var v in values) a.Add(JsonValue.Create(v));
        p[key] = a;
    }

    private static readonly char[] OnsetSeparators = [',', ';', ' ', '\t', '\n', '\r'];

    public static string FormatOnsets(IEnumerable<double> values) =>
        string.Join(", ", values.Select(v => v.ToString("0.###", CultureInfo.InvariantCulture)));

    /// <summary>
    /// "180, 260, 340" → times in seconds, sorted. Accepts commas, semicolons, spaces and new lines as
    /// separators. Returns null and the offending piece when something is not a non-negative number.
    /// </summary>
    public static (double[]? Values, string? Bad) ParseOnsets(string text)
    {
        var values = new List<double>();
        foreach (var piece in text.Split(OnsetSeparators, StringSplitOptions.RemoveEmptyEntries))
        {
            if (!double.TryParse(piece, NumberStyles.Float, CultureInfo.InvariantCulture, out double v)
                || !double.IsFinite(v) || v < 0)
                return (null, piece);
            values.Add(v);
        }
        values.Sort();
        return (values.ToArray(), null);
    }

    /// <summary>
    /// The keys whose value differs between two parameter objects. After every change the engine
    /// returns the parameters as it read them; a key that differs from what was sent is a value the
    /// engine could not read and replaced with its default.
    /// </summary>
    public static List<string> Differences(JsonObject sent, JsonObject read)
    {
        var keys = new List<string>();
        foreach (var (key, value) in sent)
        {
            var other = read[key];
            if (!SameValue(value, other)) keys.Add(key);
        }
        return keys;
    }

    private static bool SameValue(JsonNode? a, JsonNode? b)
    {
        if (a is null || b is null) return a is null && b is null;
        if (a is JsonValue va && b is JsonValue vb
            && va.TryGetValue(out double da) && vb.TryGetValue(out double db))
            return Math.Abs(da - db) <= 1e-9 * Math.Max(1, Math.Abs(da));
        if (a is JsonArray aa && b is JsonArray ab)
            return aa.Count == ab.Count && aa.Zip(ab).All(t => SameValue(t.First, t.Second));
        return a.ToJsonString() == b.ToJsonString();
    }
}
