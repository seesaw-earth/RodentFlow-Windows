using System.Text.Json.Nodes;
using RodentFlow.Core.Workspace;
using RodentFlow.Engine;

namespace RodentFlow.SelfCheck;

/// <summary>
/// The workspace rules, checked against the Mac's (SessionModel.swift, ImportVideosSheet.swift, SessionDate.swift):
/// dates in file names, the animal ID guessed from a file name, natural order, group order, the next free
/// session number, stages and lists, where runs go, and that a workspace survives a save, a reload and a crash.
/// </summary>
internal static class WorkspaceChecks
{
    public static void Run(Action<bool, string> report)
    {
        Console.WriteLine("\n14. workspace: names, dates and order");
        Names(report);
        Console.WriteLine("\n15. workspace: sessions, stages, lists, run folders, saving");
        Store(report);
    }

    private static void Names(Action<bool, string> report)
    {
        (string Name, string? Date, string Animal)[] files =
        [
            ("M01_2026-10-17", "2026-10-17", "M01"),
            ("2026_10_17 cage3", "2026-10-17", "cage3"),
            ("KO-4.20261017", "2026-10-17", "KO-4"),
            ("rat7", null, "rat7"),
            ("M2_2026-13-40", null, "M2_2026-13-40"),
            ("20260229", null, "20260229"),
            ("20240229_F3", "2024-02-29", "F3"),
        ];
        foreach (var f in files)
        {
            string? date = SessionDates.FromFileName(f.Name);
            string animal = SessionDates.AnimalGuess(f.Name);
            bool ok = date == f.Date && animal == f.Animal;
            report(ok, $"   \"{f.Name}\" → date {date ?? "none"}, animal \"{animal}\""
                       + (ok ? "" : $"   expected {f.Date ?? "none"}, \"{f.Animal}\""));
        }
        var ids = new List<string> { "M10", "m2", "M1", "M02", "F3", "M2b" };
        ids.Sort(NaturalComparer.Instance);
        report(string.Join(" ", ids) == "F3 M1 M02 m2 M2b M10" || string.Join(" ", ids) == "F3 M1 m2 M02 M2b M10",
               "   natural order (M2 before M10): " + string.Join(" ", ids));
        report(WorkspaceStore.IsLikelyControl("WT") && WorkspaceStore.IsLikelyControl("Veh-saline")
               && WorkspaceStore.IsLikelyControl("control group") && !WorkspaceStore.IsLikelyControl("KO")
               && !WorkspaceStore.IsLikelyControl("contrast"),
               "   likely control groups (WT, Veh-…, control …; not KO, not \"contrast\")");
    }

    private static void Store(Action<bool, string> report)
    {
        string folder = Path.Combine(Path.GetTempPath(), "rf-ws-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new WorkspaceStore(folder);
            var task = store.AddTask("open_field", "Open field, cohort 1");
            WorkspaceSession Add(string animal, string? group, int? number, string? date = "2026-10-17")
            {
                var s = new WorkspaceSession
                {
                    TaskId = task.Id, AnimalId = animal, Group = group, SessionNumber = number, SessionDate = date,
                    VideoPath = $@"C:\videos\{animal}_{number}.mp4", FileName = $"{animal}_{number}.mp4",
                };
                store.Document.Sessions.Add(s);
                return s;
            }
            var a1 = Add("M10", "KO", 1);
            var a2 = Add("M2", "WT", 1);
            var a3 = Add("M2", "WT", 2);
            var a4 = Add("M3", "", 1);
            var a5 = Add("", null, null, null);
            store.MarkChanged();

            report(string.Join(",", store.GroupsOf(task.Id)) == "WT,KO,", "   groups: control first, \"no group\" last");
            var order = store.OrderedSessions(task.Id).Select(s => s.AnimalKey + "#" + s.SessionNumber).ToList();
            report(order.Take(3).SequenceEqual(new[] { "M2#1", "M2#2", "M10#1" }),
                   "   tree order: group, animal (natural), session: " + string.Join(" ", order));
            report(store.NextSessionNumber(task.Id, "M2") == 3 && store.NextSessionNumber(task.Id, "M2", [3]) == 4
                   && store.NextSessionNumber(task.Id, "new") == 1, "   next free session number");
            report(store.SessionConflict(task.Id, "M2", 2, excluding: null) == a3
                   && store.SessionConflict(task.Id, "M2", 2, excluding: a3.Id) is null, "   session conflicts");
            report(!a5.HasSessionInfo && a1.HasSessionInfo && a5.AnimalKey.StartsWith("video-"),
                   "   required info; a session without an animal ID is an animal of its own");

            store.SetAnimalAttributes(task.Id, "M2", "WT-2", "F");
            report(a2.Group == "WT-2" && a3.Group == "WT-2" && a3.Sex == "F" && a1.Group == "KO",
                   "   group and sex belong to the animal (all its sessions change)");

            // Stages and lists.
            report(a1.Stage == SessionStage.NeedsSetup, "   no placed arena: needs setup");
            a1.Setup = new SessionSetup { Confirmed = true, Params = new JsonObject { ["timeBin"] = 60 } };
            a2.RunState = RunState.Complete;
            a3.RunState = RunState.Partial;
            a4.Excluded = true;
            report(a1.Stage == SessionStage.Ready && a2.Stage == SessionStage.Analysed && a3.Stage == SessionStage.Paused,
                   "   stages: ready, analysed, paused");
            report(store.ListSessions(SmartList.ToAnalyse).Count() == 3 && store.ListSessions(SmartList.ToReview).Single() == a2
                   && store.ListSessions(SmartList.MissingInfo).Single() == a5 && store.ListSessions(SmartList.Excluded).Single() == a4,
                   "   lists: to analyse, to review, missing info, excluded");

            // Run folders: new runs get their own folder; a paused one is continued.
            string root = Path.Combine(folder, "runs");
            string first = store.RunFolderForAnalysis(a1, root);
            Directory.CreateDirectory(first);
            a1.RunFolder = first;
            a1.RunState = RunState.Complete;
            string second = store.RunFolderForAnalysis(a1, root);
            a3.RunFolder = Path.Combine(store.SessionFolder(a3, root), "run1");
            Directory.CreateDirectory(a3.RunFolder);
            report(first.EndsWith("run1") && second.EndsWith("run2") && Path.GetDirectoryName(first) == Path.GetDirectoryName(second)
                   && store.RunFolderForAnalysis(a3, root) == a3.RunFolder
                   && store.RunFolderForAnalysis(a3, root, continueIfPossible: false).EndsWith("run2"),
                   "   runs: run1, run2 … per session; a paused run continues in its folder");

            // Saved, read back; a run in progress when the app stopped comes back as paused.
            a2.RunState = RunState.Running;
            a1.Setup!.Calibration = new ArenaCalibration { Kind = ArenaKind.Circle, DiameterCM = 120 };
            report(store.Save() && File.Exists(store.FilePath), "   saved");
            var again = new WorkspaceStore(folder);
            var b1 = again.FindSession(a1.Id);
            var setup = b1?.Setup;
            report(again.Document.Sessions.Count == 5 && setup is not null && setup.Calibration.Kind == ArenaKind.Circle
                   && setup.Calibration.DiameterCM == 120 && (int?)setup.Params?["timeBin"] == 60
                   && again.FindSession(a2.Id)?.RunState == RunState.Partial && again.FindTask(task.Id)?.Name == "Open field, cohort 1",
                   "   read back: sessions, setup, parameters; a run that was running is now paused");

            // A damaged file is kept aside, never overwritten.
            File.WriteAllText(store.FilePath, "{ this is not json");
            var damaged = new WorkspaceStore(folder);
            bool keptAside = Directory.GetFiles(folder, "workspace-unreadable-*.json").Length == 1;
            report(damaged.Document.Sessions.Count == 0 && damaged.Notice is not null && keptAside,
                   "   an unreadable workspace is copied aside and the app starts empty, with a notice");
        }
        catch (Exception e)
        {
            report(false, "   workspace check failed: " + e);
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
        }
    }
}
