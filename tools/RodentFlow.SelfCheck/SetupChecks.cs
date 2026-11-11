using System.Text.Json.Nodes;
using RodentFlow.Core.Setup;
using RodentFlow.Engine;

namespace RodentFlow.SelfCheck;

/// <summary>
/// Checks of the task setup that need no engine: the JSON the window sends to and reads from
/// ABI/Setup.swift, the parameter values the forms write, and the forms' own structure.
///
/// The engine's decoding is tolerant — a field it cannot read silently becomes its default — so a
/// wrong name or type on this side would not fail anywhere; it would just analyse with a default the
/// user never chose. These checks pin the names and types the Swift side reads.
/// </summary>
internal static class SetupChecks
{
    public static void Run(Action<bool, string> report)
    {
        Console.WriteLine("\n4. requests to the setup calls (names and types the Swift side decodes)");
        Requests(report);
        Console.WriteLine("\n5. replies from the setup calls");
        Replies(report);
        Console.WriteLine("\n6. parameter values written by the forms");
        Values(report);
        Console.WriteLine("\n7. the forms of all tasks");
        Forms(report);
    }

    private static void Requests(Action<bool, string> report)
    {
        var defaults = JsonNode.Parse(EngineJson.Write(new DefaultSetupRequest
        {
            Paradigm = "elevated_plus_maze", Arena = ArenaKind.PlusMaze, FrameWidth = 640, FrameHeight = 480,
        }))!.AsObject();
        report(defaults["paradigm"]?.GetValue<string>() == "elevated_plus_maze"
               && defaults["arena"]?.GetValue<string>() == "plusMaze"
               && defaults["frameWidth"]?.GetValue<double>() == 640
               && !defaults.ContainsKey("params"),
               $"default setup: {defaults.ToJsonString()}");

        string[] kinds = [EngineJson.Write(ArenaKind.YMaze), EngineJson.Write(ArenaKind.TMaze), EngineJson.Write(ArenaKind.None)];
        report(kinds.SequenceEqual(["\"yMaze\"", "\"tMaze\"", "\"none\""]),
               $"arena kinds as the engine spells them: {string.Join(" ", kinds)}");

        var session = new Session
        {
            Paradigm = "three_chamber",
            Phase = "Sociability",
            Calibration = new ArenaCalibration
            {
                Kind = ArenaKind.Rectangle,
                Markers = new() { ["cupL"] = new NPoint(0.2, 0.5) },
            },
            Params = new JsonObject { ["stimSide"] = "R", ["holeCount"] = 20 },
        };
        var move = JsonNode.Parse(EngineJson.Write(new MoveHandleRequest
        {
            Session = session, FrameWidth = 640, FrameHeight = 480, Handle = "dividerL", X = 0.3, Y = 0.4,
        }))!.AsObject();
        var s = move["session"]?.AsObject();
        report(s is not null
               && move["handle"]?.GetValue<string>() == "dividerL"
               && move["x"]?.GetValue<double>() == 0.3
               && s["paradigm"]?.GetValue<string>() == "three_chamber"
               && s["calibration"]?["kind"]?.GetValue<string>() == "rectangle"
               && s["calibration"]?["markers"]?["cupL"]?["x"]?.GetValue<double>() == 0.2
               && s["calibration"]?["widthCM"] is not null
               && s["params"]?["stimSide"]?.GetValue<string>() == "R",
               "move handle: session, calibration (kind, markers by their own key, widthCM), params, handle, x");
    }

    private static void Replies(Action<bool, string> report)
    {
        // Shaped exactly as SetupABI.view writes it (JSONSerialization, sorted keys, null for a
        // non-finite number).
        const string view = """
        {"calibration":{"armLengthCM":30,"armWidthCM":5,"circleCenter":{"x":0.5,"y":0.5},"circleEdge":{"x":0.85,"y":0.5},
          "corners":[{"x":0.1,"y":0.1},{"x":0.9,"y":0.1},{"x":0.9,"y":0.9},{"x":0.1,"y":0.9}],"diameterCM":40,"heightCM":40,
          "kind":"plusMaze","markers":{},"mazePoints":[{"x":0.5,"y":0.5},{"x":0.5,"y":0.06}],"ringWidthCM":0,"widthCM":40},
         "handles":[{"id":"maze1","kind":"open","label":"N","title":"","x":0.5,"y":0.06}],
         "isMetric":true,"ok":true,"params":{"openAxis":"NS","holeCount":20},"pixelsPerCM":null,
         "region":{"h":0.9,"w":0.8,"x":0.1,"y":0.05},
         "zones":[{"center":[0.5,0.3],"id":"arm0","outline":[[0.4,0.1],[0.6,0.1],[null,0.5]],"outlineOnly":false,
                   "role":"open","showsLabel":true,"title":"Open arm"}]}
        """;
        var v = EngineJson.Read<SetupView>(view);
        report(v.Ok && v.Calibration.Kind == ArenaKind.PlusMaze && v.Calibration.MazePoints.Length == 2
               && v.Handles is [{ Id: "maze1", Kind: "open", Label: "N", X: 0.5 }]
               && v.Zones is [{ Role: "open", OutlineOnly: false }] && v.Zones[0].Outline[2][0] is null
               && v.Region is { W: 0.8 } && v.PixelsPerCM is null && v.IsMetric
               && ParamValues.Text(v.Params, "openAxis") == "NS",
               "setup view: calibration, handles, zones (with a null point), region, params");

        const string catalogue = """
        {"ok":true,"models":[],"keypoints":[],"maxGroupAnimals":10,"defaultGroupAnimals":4,"analysisMinScore":0.3,
         "arenaKinds":[{"id":"yMaze","title":"Y maze","mazeLabels":["J","A","B","C"]}],
         "paradigms":[{"id":"place_preference","title":"Place Preference","englishName":"Place Preference (RTPP / CPP)",
           "shortName":"PlacePref","category":"memory","categoryTitle":"Learning, memory & fear","animalCount":1,"isGroup":false,
           "phases":[{"key":"RTPP","title":"RTPP"},{"key":"Pre-test","title":"Pre-test"},{"key":"Post-test","title":"Post-test"}],
           "arenaKinds":["rectangle"],"defaultArena":"rectangle",
           "markers":[{"key":"platform","label":"P","title":"Platform"}],
           "defaultArenaSize":{"width":50,"height":25},"primaryMetric":"paired_pct",
           "companions":{"Post-test":"Pre-test"},"tagline":"t","summary":"s","setupTips":["a","b"]}]}
        """;
        var c = EngineJson.Read<Catalogue>(catalogue);
        var p = c.Paradigms.Single();
        report(p.ArenaKinds is [ArenaKind.Rectangle] && p.DefaultArena == ArenaKind.Rectangle
               && p.Markers is [{ Key: "platform", Label: "P" }] && p.DefaultArenaSize == new ArenaSize(50, 25)
               && p.Companions["Post-test"] == "Pre-test" && p.DefaultPhase == "RTPP" && p.SetupTips.Length == 2
               && c.ArenaKinds is [{ Id: ArenaKind.YMaze, MazeLabels.Length: 4 }],
               "catalogue: arena kinds, markers, default size, companions, default phase = first preset");
    }

    private static void Values(Action<bool, string> report)
    {
        var p = new JsonObject();
        ParamValues.SetNumber(p, "holeCount", 20.4, integer: true);
        ParamValues.SetNumber(p, "cupRadius", 5.5, integer: false);
        report(p["holeCount"]!.ToJsonString() == "20" && p["cupRadius"]!.ToJsonString() == "5.5",
               $"integer fields written as integers: holeCount {p["holeCount"]!.ToJsonString()}, cupRadius {p["cupRadius"]!.ToJsonString()}");

        // As the engine sends it back: a parsed number, compared with the option's double.
        var fromEngine = JsonNode.Parse("""{"timeBin":60,"lightOnLeft":false,"openAxis":"EW"}""")!.AsObject();
        report(ParamValues.IsChoice(fromEngine, "timeBin", 60.0) && !ParamValues.IsChoice(fromEngine, "timeBin", 30.0)
               && ParamValues.IsChoice(fromEngine, "lightOnLeft", false)
               && ParamValues.IsChoice(fromEngine, "openAxis", "EW"),
               "choices recognised in values the engine sent (60 = 60.0, false, \"EW\")");

        var (ok, _) = ParamValues.ParseOnsets("340, 180;260\n 400");
        var (bad, piece) = ParamValues.ParseOnsets("180, 26o");
        report(ok is [180, 260, 340, 400] && bad is null && piece == "26o",
               $"onset times parsed and sorted; a typo is reported (\"{piece}\")");

        var sent = JsonNode.Parse("""{"a":1,"b":"x","c":[1,2],"d":true}""")!.AsObject();
        var read = JsonNode.Parse("""{"a":1.0,"b":"y","c":[1,2],"d":true}""")!.AsObject();
        var diff = ParamValues.Differences(sent, read);
        report(diff is ["b"], $"a value the engine did not take is found: [{string.Join(", ", diff)}]");
    }

    private static void Forms(Action<bool, string> report)
    {
        var problems = new List<string>();
        foreach (var (task, groups) in AssayForms.Tasks)
        {
            foreach (var row in groups.Concat(AssayForms.Common(task)).SelectMany(g => g.Rows))
            {
                string where = $"{task}.{(row.Key.Length > 0 ? row.Key : row.En)}";
                if (row.Kind == RowKind.Choice && row.Options.Length < 2) problems.Add(where + ": fewer than two choices");
                if (row.Kind is RowKind.Number or RowKind.Percent && !(row.Min < row.Max)) problems.Add(where + ": empty range");
                if (row.Kind == RowKind.Percent && (row.Min < 0 || row.Max > 1)) problems.Add(where + ": percent outside 0–1");
                if (row.Kind != RowKind.Note && row.Key.Length == 0 && row.GetToggle is null) problems.Add(where + ": no key");
                if (row.En.Length == 0 || row.Zh.Length == 0) problems.Add(where + ": missing a title");
                if (row.Kind == RowKind.Choice
                    && row.Options.Any(o => o.Value is not (string or bool or double or int)))
                    problems.Add(where + ": a choice value the engine cannot read");
            }
        }
        report(problems.Count == 0, $"{AssayForms.Tasks.Count} tasks: every row well-formed"
                                    + (problems.Count > 0 ? "\n      " + string.Join("\n      ", problems) : ""));

        bool Visible(string task, string key, string phase, JsonObject p) =>
            AssayForms.For(task).SelectMany(g => g.Rows).First(r => r.Key == key).IsVisible(new FormContext(phase, p));

        var empty = new JsonObject();
        report(!Visible("novel_object_recognition", "novelObject", "Training", empty)
               && Visible("novel_object_recognition", "novelObject", "Test", empty)
               && !Visible("morris_water_maze", "mwmCorridor", "Probe", empty)
               && Visible("morris_water_maze", "mwmCorridor", "Acquisition", empty),
               "rows that depend on the phase: novel object hidden in Training, corridor hidden in Probe");

        var speed = new JsonObject { ["loomFreezeRule"] = "speed" };
        var motion = new JsonObject { ["loomFreezeRule"] = "motion" };
        report(Visible("looming_escape", "loomFreezeSpeed", "", speed) && !Visible("looming_escape", "freezeSpeed", "", speed)
               && !Visible("looming_escape", "loomFreezeSpeed", "", motion) && Visible("looming_escape", "freezeSpeed", "", motion),
               "rows that depend on a value: looming freezing by speed or by motion");

        var nsfRows = AssayForms.For("novelty_suppressed_feeding").SelectMany(g => g.Rows).ToArray();
        var hunger = nsfRows.First(r => r.Keys.Contains("nsfHomeCageFood"));
        var nsf = JsonNode.Parse("""{"nsfHomeCageFood":-1,"nsfWeightBefore":-1,"nsfWeightTest":-1}""")!.AsObject();
        bool before = hunger.GetToggle!(nsf);
        hunger.SetToggle!(nsf, true);
        bool on = hunger.GetToggle(nsf) && ParamValues.Number(nsf, "nsfWeightTest") == 0;
        hunger.SetToggle(nsf, false);
        bool off = !hunger.GetToggle(nsf) && ParamValues.Number(nsf, "nsfHomeCageFood") == -1;
        report(!before && on && off, "hunger control switches its three fields between −1 and 0");

        // "No feeding" clears a confirmed bite time: the engine would take the time over the flag.
        var noFeeding = nsfRows.First(r => r.Keys.Contains("nsfNoFeeding"));
        var confirmed = JsonNode.Parse("""{"nsfFeedingTime":42.5,"nsfNoFeeding":false}""")!.AsObject();
        noFeeding.SetToggle!(confirmed, true);
        report(ParamValues.Flag(confirmed, "nsfNoFeeding") == true && ParamValues.Number(confirmed, "nsfFeedingTime") == -1
               && !Visible("novelty_suppressed_feeding", "nsfFeedingTime", "", confirmed),
               "“no feeding” clears the bite time and hides its field");

        var three = AssayForms.For("three_chamber").SelectMany(g => g.Rows).First(r => r.Key == "stimSide");
        report(three.Title(new FormContext("Social novelty", empty), chinese: false) == "Cup with novel stranger"
               && three.Title(new FormContext("Sociability", empty), chinese: false) == "Cup with stranger mouse",
               "three-chamber cup title follows the phase");
    }
}
