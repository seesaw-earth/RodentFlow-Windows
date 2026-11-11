using RodentFlow.Core.Marbles;
using RodentFlow.Core.Workspace;

namespace RodentFlow.SelfCheck;

/// <summary>
/// Stage B: which session pairs with which (SessionResultsEngine.companion), and the marble readings
/// (MarbleSampler: the points read, the luminance, the saved file in the Mac's form).
/// </summary>
internal static class PairingChecks
{
    public static void Run(Action<bool, string> report)
    {
        Console.WriteLine("\n17. pairing of phases, marble readings");
        Pairing(report);
        Marbles(report);
    }

    private static void Pairing(Action<bool, string> report)
    {
        string folder = Path.Combine(Path.GetTempPath(), "rf-pair-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new WorkspaceStore(folder);
            var task = store.AddTask("place_preference", "CPP");
            WorkspaceSession Add(string animal, string phase, double paired, int minutesAgo)
            {
                var s = new WorkspaceSession
                {
                    TaskId = task.Id, AnimalId = animal, Phase = phase, RunState = RunState.Complete,
                    RunFinishedAt = DateTime.Now.AddMinutes(-minutesAgo),
                    Values = new Dictionary<string, double> { ["paired_time"] = paired, ["paired_pct"] = paired / 9 },
                };
                store.Document.Sessions.Add(s);
                return s;
            }
            var oldPre = Add("M1", "Pre-test", 100, 60);
            var pre = Add("M1", "Pre-test", 120, 10);
            var post = Add("M1", "Post-test", 300, 5);
            Add("M2", "Pre-test", 999, 1);
            var cpp = new Dictionary<string, string> { ["Post-test"] = "Pre-test" };
            var forPost = store.Companion(post, cpp, "place_preference", "Post-test");
            var forPre = store.Companion(pre, cpp, "place_preference", "Pre-test");
            report(forPost.TryGetValue("paired_time", out double v) && v == 120 && forPre.Count == 0,
                   "   place preference: a post-test gets its animal's latest pre-test; a pre-test gets nothing");
            oldPre.Values = null;

            var si = store.AddTask("social_interaction", "SI");
            var a = new WorkspaceSession { TaskId = si.Id, AnimalId = "R1", Phase = "No target", RunState = RunState.Complete, Values = new() { ["iz_time"] = 20 } };
            var b = new WorkspaceSession { TaskId = si.Id, AnimalId = "R1", Phase = "Target", RunState = RunState.Complete, Values = new() { ["iz_time"] = 60 } };
            var c = new WorkspaceSession { TaskId = si.Id, AnimalId = "R1", Phase = "Target", RunState = RunState.Partial, Values = new() { ["iz_time"] = 5 } };
            store.Document.Sessions.AddRange([a, b, c]);
            var none = new Dictionary<string, string>();
            report(store.Companion(a, none, "social_interaction", "No target")["iz_time"] == 60
                   && store.Companion(b, none, "social_interaction", "Target")["iz_time"] == 20,
                   "   social interaction: each phase gets the other phase of the same animal (analysed ones only)");
            var unnamed = new WorkspaceSession { TaskId = si.Id, AnimalId = " ", Phase = "Target", RunState = RunState.Complete };
            report(store.Companion(unnamed, none, "social_interaction", "Target").Count == 0, "   no animal ID: no pairing");
        }
        catch (Exception e)
        {
            report(false, "   pairing check failed: " + e);
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
        }
    }

    private static void Marbles(Action<bool, string> report)
    {
        var inner = MarbleSampling.Offsets(0, 8);
        var ring = MarbleSampling.Offsets(13, 20);
        bool symmetric = inner.All(o => inner.Contains((-o.Dx, -o.Dy)));
        report(inner.Count is > 150 and <= 320 && ring.Count is > 150 and <= 400 && symmetric
               && inner.All(o => Math.Sqrt(o.Dx * o.Dx + o.Dy * o.Dy) <= 8)
               && ring.All(o => Math.Sqrt(o.Dx * o.Dx + o.Dy * o.Dy) is >= 13 and <= 20),
               $"   points read: {inner.Count} inside the marble, {ring.Count} in the bedding ring (about 300 each)");

        // A frame of B 40, G 120, R 200: luminance 0.114·40 + 0.587·120 + 0.299·200 = 134.8.
        int w = 64, h = 48;
        var px = new byte[w * h * 4];
        for (int i = 0; i < w * h; i++) { px[4 * i] = 40; px[4 * i + 1] = 120; px[4 * i + 2] = 200; px[4 * i + 3] = 255; }
        float mean = MarbleSampling.Mean(px, w, h, w * 4, 32, 24, MarbleSampling.Offsets(0, 5));
        float edge = MarbleSampling.Mean(px, w, h, w * 4, -50, -50, MarbleSampling.Offsets(0, 5));
        report(Math.Abs(mean - 134.8f) < 0.01f && float.IsNaN(edge), $"   luminance as the Mac's (134.8 → {mean:F2}); a marble outside the frame reads NaN");

        string folder = Path.Combine(Path.GetTempPath(), "rf-mb-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(folder);
            var samples = new MarbleSamples
            {
                Key = "mb1|v.mp4|1280x960|r12.0|i0.500|t0.00-0.00|10.0,10.0",
                Times = [0, 0.5, 1.0],
                Inner = [[200f, float.NaN, 60.5f]],
                Ring = [[90f, 91f, 92f]],
            };
            samples.Save(folder);
            string text = File.ReadAllText(Path.Combine(folder, MarbleSamples.FileName));
            var back = MarbleSamples.Load(folder, samples.Key);
            report(text.Contains("\"nan\"") && back is not null && float.IsNaN(back.Inner[0][1]) && back.Inner[0][2] == 60.5f
                   && back.Times.Length == 3 && MarbleSamples.Load(folder, "another key") is null
                   && samples.ToJsonObject()["inner"]?[0]?[1]?.GetValue<string>() == "nan",
                   "   saved in the Mac's form (NaN as \"nan\"); read back only under the same key");
        }
        catch (Exception e)
        {
            report(false, "   marble file check failed: " + e.Message);
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
        }
    }
}
