using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using RodentFlow.Engine;

namespace RodentFlow.Core.Workspace;

// How the data is organised — the Mac's (RodentStudio/Core/SessionModel.swift, WorkspaceStore.swift):
//
//   Task (one behavioural task, e.g. Open field) → Group (optional, e.g. WT / KO) → Animal → Session
//
// A session is one video of one animal: recording date + session number. The animal ID, the date and the
// session number are required. Group and sex belong to the animal: the same in every session of that animal
// within a task. Each session keeps its own setup (calibration and parameters), because the camera may move.

/// <summary>How far a session's tracking run got (VideoRunState).</summary>
public enum RunState { Running, Complete, Partial, Failed }

/// <summary>Whether the tracking of an analysed session has been checked.</summary>
public enum ReviewVerdict { Unreviewed, Accepted, Flagged }

/// <summary>Where a session is in its steps (VideoStage, AnalysisWorkflowView.swift).</summary>
public enum SessionStage { NeedsSetup, Ready, Running, Paused, Failed, Analysed }

/// <summary>The sidebar's cross-task lists (SmartList, AnalysisWorkflowView.swift).</summary>
public enum SmartList { All, ToAnalyse, ToReview, MissingInfo, Excluded }

public sealed class WorkspaceTask
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    /// <summary>Paradigm id (rf_catalogue), e.g. "open_field".</summary>
    public string Paradigm { get; set; } = "open_field";
    public string? Notes { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    /// <summary>The group comparison last shown (GroupAnalysisRequest, as the engine wrote it); null = the default.</summary>
    public JsonObject? GroupRequest { get; set; }
    /// <summary>How the group figure is drawn (GroupPlotStyle), remembered per task as on the Mac.</summary>
    public JsonObject? GroupStyle { get; set; }
}

/// <summary>A session's setup: what the analysis needs besides the video (the Mac's DesktopCalibration.pose).</summary>
public sealed class SessionSetup
{
    public ArenaCalibration Calibration { get; set; } = new();
    /// <summary>The task's complete AnalysisParams, as the engine last read them back.</summary>
    public JsonObject? Params { get; set; }
    public CoatColor Coat { get; set; } = CoatColor.Dark;
    public int Stride { get; set; } = 1;
    /// <summary>Recognise only the first N seconds; 0 = the whole video.</summary>
    public double EndTime { get; set; }
    /// <summary>Animals in a group task (other tasks fix the number).</summary>
    public int AnimalCount { get; set; } = 1;
    /// <summary>
    /// The arena has been placed on this video (or copied to it). Until then the setup is the task's default
    /// layout, and the session is not ready to analyse — as on the Mac.
    /// </summary>
    public bool Confirmed { get; set; }
    /// <summary>The session the setup was copied from ("use for all sessions of this task").</summary>
    public string? CopiedFrom { get; set; }

    public SessionSetup Clone() => new()
    {
        Calibration = Calibration,
        Params = Params is null ? null : (JsonObject)Params.DeepClone(),
        Coat = Coat,
        Stride = Stride,
        EndTime = EndTime,
        AnimalCount = AnimalCount,
        Confirmed = Confirmed,
        CopiedFrom = CopiedFrom,
    };
}

public sealed class WorkspaceSession
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid TaskId { get; set; }
    public string VideoPath { get; set; } = "";
    public string FileName { get; set; } = "";
    public long FileSize { get; set; }
    public DateTime ImportedAt { get; set; } = DateTime.Now;

    public string AnimalId { get; set; } = "";
    public string? Group { get; set; }
    /// <summary>"", "M" or "F".</summary>
    public string? Sex { get; set; }
    /// <summary>Recording day, "yyyy-MM-dd".</summary>
    public string? SessionDate { get; set; }
    public int? SessionNumber { get; set; }
    public string? Phase { get; set; }
    public int? Day { get; set; }
    public int? Trial { get; set; }
    public string? Notes { get; set; }
    public bool Excluded { get; set; }
    public string? ExclusionReason { get; set; }

    public SessionSetup? Setup { get; set; }

    public string? RunFolder { get; set; }
    public RunState? RunState { get; set; }
    public string? RunModel { get; set; }
    public int? RunFrames { get; set; }
    public DateTime? RunFinishedAt { get; set; }
    public string? RunMessage { get; set; }
    public ReviewVerdict Review { get; set; } = ReviewVerdict.Unreviewed;

    /// <summary>
    /// Every measure of the session's last results (key → value), for pairing: the other phase of the same animal
    /// reads these as its companion (social interaction, place preference, step-down), as the Mac's saved summaries.
    /// </summary>
    public Dictionary<string, double>? Values { get; set; }

    /// <summary>
    /// The session's summary for the group comparison (SessionMetricSummary, as rf_analyze returned it with the last
    /// results), kept unchanged and handed back to rf_group_analysis. Null before the first results.
    /// </summary>
    public JsonObject? Summary { get; set; }

    /// <summary>The headline measure as last computed, for the lists (interface language of that moment).</summary>
    public string? PrimaryTitle { get; set; }
    public string? PrimaryDisplay { get; set; }
    public string? PrimaryUnit { get; set; }

    /// <summary>Animal identity within a task; a session without an animal ID is an animal of its own.</summary>
    public string AnimalKey
    {
        get
        {
            string id = AnimalId.Trim();
            return id.Length > 0 ? id : "video-" + Id.ToString("N")[..8];
        }
    }

    /// <summary>Group label ("" = no group).</summary>
    public string GroupKey => (Group ?? "").Trim();

    /// <summary>Animal ID, recording date and session number are filled in.</summary>
    public bool HasSessionInfo =>
        AnimalId.Trim().Length > 0 && SessionDates.IsValid(SessionDate) && (SessionNumber ?? 0) >= 1;

    public SessionStage Stage => RunState switch
    {
        Workspace.RunState.Running => SessionStage.Running,
        Workspace.RunState.Complete => SessionStage.Analysed,
        Workspace.RunState.Partial => SessionStage.Paused,
        Workspace.RunState.Failed => SessionStage.Failed,
        _ => Setup is { Confirmed: true } ? SessionStage.Ready : SessionStage.NeedsSetup,
    };

    /// <summary>The headline measure for a list row, e.g. "Center time 12.5 %".</summary>
    public string PrimaryLine => PrimaryDisplay is { Length: > 0 } d
        ? (PrimaryTitle ?? "") + " " + d + (PrimaryUnit is { Length: > 0 } u ? " " + u : "")
        : "";
}

public sealed class WorkspaceDocument
{
    public int SchemaVersion { get; set; } = 1;
    public List<WorkspaceTask> Tasks { get; set; } = [];
    public List<WorkspaceSession> Sessions { get; set; } = [];
}

/// <summary>Recording dates as calendar days, "yyyy-MM-dd" (Shared/Tasks/SessionDate.swift).</summary>
public static class SessionDates
{
    public static string Text(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static DateTime? Parse(string? text) =>
        text is { Length: 10 } && DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                                         DateTimeStyles.None, out var d) ? d : null;

    public static bool IsValid(string? text) => Parse(text) is not null;

    private static readonly Regex[] FileNamePatterns =
    [
        new(@"(19|20)\d{2}[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\d|3[01])", RegexOptions.CultureInvariant),
        new(@"(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])", RegexOptions.CultureInvariant),
    ];

    /// <summary>A date written in a file name: 2026-10-17, 2026_10_17, 2026.10.17 or 20261017 (years 1990–2099 … 1900–2099).</summary>
    public static string? FromFileName(string name)
    {
        foreach (var pattern in FileNamePatterns)
        {
            var m = pattern.Match(name);
            if (!m.Success) continue;
            string digits = new(m.Value.Where(char.IsDigit).ToArray());
            if (digits.Length != 8) continue;
            string text = digits[..4] + "-" + digits[4..6] + "-" + digits[6..];
            if (IsValid(text)) return text;
        }
        return null;
    }

    /// <summary>The file name without a date in it — the starting animal ID (ImportVideosSheet.animalGuess).</summary>
    public static string AnimalGuess(string stem)
    {
        string s = stem;
        if (FromFileName(stem) is { } date)
        {
            foreach (string v in new[] { date, date.Replace("-", ""), date.Replace("-", "_"), date.Replace("-", ".") })
                s = s.Replace(v, "");
        }
        string trimmed = s.Trim(' ', '_', '-', '.');
        return trimmed.Length > 0 ? trimmed : stem;
    }
}

/// <summary>"M2" before "M10" (localizedStandardCompare).</summary>
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    public int Compare(string? a, string? b)
    {
        a ??= "";
        b ??= "";
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                string na = a[si..i].TrimStart('0'), nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length.CompareTo(nb.Length);
                int c = string.CompareOrdinal(na, nb);
                if (c != 0) return c;
            }
            else
            {
                int c = string.Compare(a[i].ToString(), b[j].ToString(), StringComparison.CurrentCultureIgnoreCase);
                if (c != 0) return c;
                i++;
                j++;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }
}

/// <summary>
/// The workspace: every task and session, kept in <c>%LOCALAPPDATA%\RodentFlow\workspace.json</c>
/// (the Mac's WorkspaceStore). Run folders stay where the analyses wrote them.
/// </summary>
/// <remarks>
/// Changes are made on the objects in <see cref="Document"/> and announced with <see cref="MarkChanged"/>;
/// <see cref="Save"/> writes the file (atomically: a new file, then a replace). A workspace that cannot be
/// read is never overwritten: it is copied aside first and the app starts empty, with a notice.
/// </remarks>
public sealed class WorkspaceStore
{
    private static readonly JsonSerializerOptions Json = new(EngineJson.Options) { WriteIndented = true };

    public WorkspaceStore(string folder)
    {
        Folder = folder;
        Directory.CreateDirectory(folder);
        FilePath = Path.Combine(folder, "workspace.json");
        Document = Load(out string? notice);
        Notice = notice;
    }

    public static string DefaultFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RodentFlow");

    public string Folder { get; }
    public string FilePath { get; }
    public WorkspaceDocument Document { get; private set; }

    /// <summary>Something to tell the user once (an unreadable workspace kept aside).</summary>
    public string? Notice { get; }

    /// <summary>The document changed and has not been written yet.</summary>
    public bool Dirty { get; private set; }

    /// <summary>Raised after every change (the sidebar and lists redraw from it).</summary>
    public event Action? Changed;

    private WorkspaceDocument Load(out string? notice)
    {
        notice = null;
        if (!File.Exists(FilePath)) return new WorkspaceDocument();
        try
        {
            var doc = JsonSerializer.Deserialize<WorkspaceDocument>(File.ReadAllText(FilePath), Json) ?? new WorkspaceDocument();
            // A run that was in progress when the app quit keeps its finished segments and can be resumed.
            foreach (var s in doc.Sessions.Where(s => s.RunState == RunState.Running)) s.RunState = RunState.Partial;
            return doc;
        }
        catch (Exception e) when (e is JsonException or IOException or NotSupportedException)
        {
            string copy = Path.Combine(Folder, $"workspace-unreadable-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            try { File.Copy(FilePath, copy, overwrite: false); }
            catch (IOException) { copy = FilePath; }
            notice = "The saved workspace could not be read and was kept unchanged as " + copy
                     + ". Please send it to the developer. (" + e.Message + ")";
            return new WorkspaceDocument();
        }
    }

    public void MarkChanged()
    {
        Dirty = true;
        Changed?.Invoke();
    }

    /// <summary>Writes the workspace if it changed. Returns false (and keeps it dirty) when the disk refuses.</summary>
    public bool Save()
    {
        if (!Dirty && File.Exists(FilePath)) return true;
        string tmp = FilePath + ".tmp";
        try
        {
            File.WriteAllText(tmp, JsonSerializer.Serialize(Document, Json));
            File.Move(tmp, FilePath, overwrite: true);
            Dirty = false;
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // ---------------------------------------------------------------- tasks

    public WorkspaceTask? FindTask(Guid id) => Document.Tasks.FirstOrDefault(t => t.Id == id);

    public WorkspaceSession? FindSession(Guid id) => Document.Sessions.FirstOrDefault(s => s.Id == id);

    public WorkspaceTask AddTask(string paradigm, string name)
    {
        var task = new WorkspaceTask { Paradigm = paradigm, Name = name.Trim() };
        Document.Tasks.Add(task);
        MarkChanged();
        return task;
    }

    /// <summary>Takes a task and its sessions out of the workspace. Videos and run folders are left on disk.</summary>
    public void RemoveTask(Guid id)
    {
        Document.Tasks.RemoveAll(t => t.Id == id);
        Document.Sessions.RemoveAll(s => s.TaskId == id);
        MarkChanged();
    }

    public void RemoveSession(Guid id)
    {
        Document.Sessions.RemoveAll(s => s.Id == id);
        MarkChanged();
    }

    public IEnumerable<WorkspaceSession> SessionsOf(Guid taskId) => Document.Sessions.Where(s => s.TaskId == taskId);

    /// <summary>Group labels of a task: a likely control first, then alphabetical; "" (no group) last.</summary>
    public List<string> GroupsOf(Guid taskId)
    {
        var labels = SessionsOf(taskId).Select(s => s.GroupKey).ToHashSet();
        var named = labels.Where(g => g.Length > 0).ToList();
        named.Sort((a, b) =>
        {
            bool ca = IsLikelyControl(a), cb = IsLikelyControl(b);
            if (ca != cb) return ca ? -1 : 1;
            return NaturalComparer.Instance.Compare(a, b);
        });
        if (labels.Contains("")) named.Add("");
        return named;
    }

    /// <summary>GroupAnalysisEngine.isLikelyControl (Shared/Groups/GroupAnalysis.swift).</summary>
    public static bool IsLikelyControl(string name)
    {
        string lower = name.ToLowerInvariant();
        string[] hints = ["control", "ctrl", "wt", "wild", "vehicle", "veh", "saline", "sham", "naive", "con"];
        return hints.Any(h => lower == h || lower.StartsWith(h + " ") || lower.StartsWith(h + "-")
                              || lower.StartsWith(h + "_") || lower.StartsWith(h + "/"));
    }

    /// <summary>Animal keys of a task (of one group, when given), in natural order.</summary>
    public List<string> AnimalsOf(Guid taskId, string? group = null) =>
        SessionsOf(taskId).Where(s => group is null || s.GroupKey == group).Select(s => s.AnimalKey)
                          .Distinct().OrderBy(k => k, NaturalComparer.Instance).ToList();

    /// <summary>Sessions within an animal: session number, then date, then import time.</summary>
    public static int SessionOrder(WorkspaceSession a, WorkspaceSession b)
    {
        int na = a.SessionNumber ?? int.MaxValue, nb = b.SessionNumber ?? int.MaxValue;
        if (na != nb) return na.CompareTo(nb);
        string da = a.SessionDate ?? "~", db = b.SessionDate ?? "~";
        int c = string.CompareOrdinal(da, db);
        return c != 0 ? c : a.ImportedAt.CompareTo(b.ImportedAt);
    }

    /// <summary>Sessions of a task in tree order: group, animal, session.</summary>
    public List<WorkspaceSession> OrderedSessions(Guid taskId, string? group = null)
    {
        var all = SessionsOf(taskId).ToList();
        var out_ = new List<WorkspaceSession>();
        foreach (string g in GroupsOf(taskId))
        {
            if (group is not null && g != group) continue;
            foreach (string a in AnimalsOf(taskId, g))
            {
                var mine = all.Where(s => s.GroupKey == g && s.AnimalKey == a).ToList();
                mine.Sort(SessionOrder);
                out_.AddRange(mine);
            }
        }
        return out_;
    }

    /// <summary>Next free session number of an animal in a task.</summary>
    public int NextSessionNumber(Guid taskId, string animalKey, IEnumerable<int>? alsoTaken = null)
    {
        var used = SessionsOf(taskId).Where(s => s.AnimalKey == animalKey && s.SessionNumber is not null)
                                     .Select(s => s.SessionNumber!.Value).ToHashSet();
        if (alsoTaken is not null) used.UnionWith(alsoTaken);
        int n = 1;
        while (used.Contains(n)) n++;
        return n;
    }

    /// <summary>Another session of the same animal with the same session number in the task.</summary>
    public WorkspaceSession? SessionConflict(Guid taskId, string animalKey, int number, Guid? excluding) =>
        SessionsOf(taskId).FirstOrDefault(s => s.AnimalKey == animalKey && s.SessionNumber == number && s.Id != excluding);

    /// <summary>Group and sex an animal already has in a task (from its other sessions).</summary>
    public (string Group, string Sex)? AnimalAttributes(Guid taskId, string animalKey, Guid? excluding = null) =>
        SessionsOf(taskId).FirstOrDefault(s => s.AnimalKey == animalKey && s.Id != excluding) is { } other
            ? (other.GroupKey, other.Sex ?? "")
            : null;

    /// <summary>Group and sex belong to the animal: setting them on one session sets them on all its sessions.</summary>
    public void SetAnimalAttributes(Guid taskId, string animalKey, string? group, string? sex)
    {
        foreach (var s in SessionsOf(taskId).Where(s => s.AnimalKey == animalKey))
        {
            if (group is not null) s.Group = group.Trim();
            if (sex is not null) s.Sex = sex;
        }
        MarkChanged();
    }

    public IEnumerable<WorkspaceSession> ListSessions(SmartList list) => Document.Sessions.Where(s => list switch
    {
        SmartList.ToAnalyse => s.RunState != RunState.Complete && !s.Excluded,
        SmartList.ToReview => s.RunState == RunState.Complete && s.Review == ReviewVerdict.Unreviewed && !s.Excluded,
        SmartList.MissingInfo => !s.HasSessionInfo,
        SmartList.Excluded => s.Excluded,
        _ => true,
    });

    // ---------------------------------------------------------------- pairing

    /// <summary>
    /// The values a session is analysed with from its other phase (SessionResultsEngine.companion): the most recently
    /// analysed session of the same animal in the task, in the phase the paradigm pairs it with (place preference:
    /// the pre-test of a post-test; step-down: the training of a test), or — social interaction — in its other phase.
    /// Empty when there is none.
    /// </summary>
    public Dictionary<string, double> Companion(WorkspaceSession s, IReadOnlyDictionary<string, string> companions,
                                                string paradigm, string phase)
    {
        string? wanted = companions.TryGetValue(phase, out var p) ? p : null;
        if (paradigm != "social_interaction" && wanted is null) return new Dictionary<string, double>();
        string animal = s.AnimalId.Trim();
        if (animal.Length == 0) return new Dictionary<string, double>();
        var other = SessionsOf(s.TaskId)
            .Where(o => o.Id != s.Id && o.AnimalId.Trim() == animal && (o.Phase ?? "") != phase
                        && o.RunState == Workspace.RunState.Complete && o.Values is { Count: > 0 }
                        && (wanted is null || o.Phase == wanted))
            .OrderByDescending(o => o.RunFinishedAt ?? DateTime.MinValue)
            .FirstOrDefault();
        return other?.Values is { } values ? new Dictionary<string, double>(values) : new Dictionary<string, double>();
    }

    // ---------------------------------------------------------------- run folders

    /// <summary>A file-name-safe piece of a name.</summary>
    public static string Slug(string text, int max = 40)
    {
        var chars = text.Trim().Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray();
        string s = Regex.Replace(new string(chars), "_+", "_").Trim('_');
        if (s.Length == 0) s = "x";
        return s.Length > max ? s[..max] : s;
    }

    /// <summary>The folder a session's runs live in: work folder › task › animal_date_s#_id.</summary>
    public string SessionFolder(WorkspaceSession s, string workRoot)
    {
        string task = FindTask(s.TaskId) is { } t ? Slug(t.Name.Length > 0 ? t.Name : t.Paradigm) : "task";
        string name = Slug(s.AnimalKey) + "_" + (s.SessionDate ?? "nodate") + "_s" + (s.SessionNumber?.ToString(CultureInfo.InvariantCulture) ?? "x")
                      + "_" + s.Id.ToString("N")[..8];
        return Path.Combine(workRoot, task, name);
    }

    /// <summary>
    /// Where the next analysis of a session goes. A paused or failed run is continued in its own folder (the engine
    /// resumes after the last saved frame); otherwise — never analysed, or analysed again — a new run1, run2 …
    /// folder, so an earlier analysis is never overwritten.
    /// </summary>
    public string RunFolderForAnalysis(WorkspaceSession s, string workRoot, bool continueIfPossible = true)
    {
        if (continueIfPossible && s.RunFolder is { } current && Directory.Exists(current)
            && s.RunState is RunState.Partial or RunState.Failed)
            return current;
        string root = SessionFolder(s, workRoot);
        int k = 1;
        while (Directory.Exists(Path.Combine(root, "run" + k.ToString(CultureInfo.InvariantCulture)))) k++;
        return Path.Combine(root, "run" + k.ToString(CultureInfo.InvariantCulture));
    }
}
