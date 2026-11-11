#!/usr/bin/env python3
"""Checks the result-page contract between the engine and the window, key by key.

    python check/check_report_contract.py            (from the top of the repository)
    python check/check_report_contract.py --selftest (injects errors and makes sure they are caught)

The engine writes the report as dictionaries (engine/Sources/RodentFlowABI/ABI/ReportView.swift); the window
reads it into records (src/RodentFlow.Engine/ReportModels.cs). The reader is tolerant: a property whose key
the engine does not write simply keeps its default, without a word. So every C# property must be a key the
engine writes for that object. The other way round (a key nobody reads) is only reported.

Also checked: the request fields the window sends to rf_analyze (AnalysisRequest) are fields the engine
decodes (AnalysisRun.Request) — an unknown field would be ignored just as quietly.
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT = ROOT / "engine/Sources/RodentFlowABI/ABI/ReportView.swift"
REVIEW_SWIFT = ROOT / "engine/Sources/RodentFlowABI/ABI/ReviewABI.swift"
MARBLE_SWIFT = ROOT / "engine/Sources/RodentFlowABI/ABI/MarbleABI.swift"
GROUP_SWIFT = ROOT / "engine/Sources/RodentFlowABI/ABI/GroupABI.swift"
GROUP_CS = ROOT / "src/RodentFlow.Engine/GroupModels.cs"
RUN_SWIFT = ROOT / "engine/Sources/RodentFlowABI/ABI/AnalysisRun.swift"
CS = ROOT / "src/RodentFlow.Engine/ReportModels.cs"
MODELS_CS = ROOT / "src/RodentFlow.Engine/Models.cs"

# (Swift function, dictionary variable) → the C# record that reads it.
BY_VARIABLE = {
    ("json", "out"): "DisplayReport",
    ("json", "review"): "ReportReview",
    ("metric", "d"): "ReportMetric",
    ("metric", "s"): "ReportMetricScale",
    ("quality", "d"): "ReportQuality",
    ("block", "d"): "ReportBlock",
    ("arena", "d"): "ReportArena",
    ("arena", "pd"): "ReportPath",
    ("arena", "dd"): "ReportDot",
    ("arena", "ad"): "ReportArrow",
    ("arena", "hd"): "ReportHeat",
    ("arena", "f"): "ReportFrame",
    ("zone", "d"): "ReportZone",
    ("timeline", "d"): "ReportTimeline",
    ("track", "d"): "ReportTrack",
    ("epoch", "d"): "ReportEpoch",
    ("bars", "it"): "ReportBar",
    ("bars", "d"): "ReportBars",
    ("line", "sd"): "ReportSeries",
    ("line", "d"): "ReportLine",
    ("polar", "d"): "ReportPolar",
    ("table", "d"): "ReportTable",
    ("qcEvents", "e"): "ReviewEvent",
    ("plan", "d"): "MarblePlan",
    ("run", "out"): "GroupReply",
    ("options", "d"): "GroupOptions",
    ("result", "d"): "GroupResultInfo",
    ("result", "row"): "GroupDescriptives",
    ("figure", "d"): "PubFigureData",
    ("figure", "shape"): "PubItemData",
    ("figure", "text"): "PubItemData",
    ("figure", "st"): "PubStrokeData",
}

# Dictionary literals: (Swift function, text just before the literal's "[") → record.
BY_LITERAL = {
    ("quality", 'keypoints.append('): "KeypointLabel",
    ("arena", 'f["crop"] = '): "ReportBox",
    ("arena", 'families.append('): "ZoneFamilyInfo",
    ("rf_translate", 'RFJSON.ok('): "TranslateReply",
    ("swap", 'return '): "SwapResult",
    ("segments", 'return '): "IdentitySegmentsReply",
    ("options", '-> [String: Any] { '): "GroupOption",
    ("options", 'm -> [String: Any] in'): "GroupOption",
}

# Requests the window sends: C# record → the Swift struct that decodes it (file, struct name).
REQUESTS = [
    ("AnalysisRequest", "AnalysisRun", "Request"),
    ("GroupAnalysisCall", "GroupABI", "Request"),
    ("GroupSessionInput", "GroupABI", "SessionInput"),
]

# Properties every reply has (EngineReply), not written by these functions.
INHERITED = {"ok", "error"}


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def balanced(text, start, open_ch, close_ch):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def swift_functions(text):
    """name → body of every `func name(` (static or free)."""
    out = {}
    for m in re.finditer(r"\bfunc\s+(\w+)\s*\(", text):
        brace = text.find("{", m.end())
        if brace < 0:
            continue
        out[m.group(1)] = balanced(text, brace, "{", "}")
    return out


def swift_keys(text):
    funcs = swift_functions(strip_comments(text))
    found = {}
    for (fn, var), record in BY_VARIABLE.items():
        body = funcs.get(fn, "")
        keys = set(re.findall(r"\b" + re.escape(var) + r'\["(\w+)"\]\s*=', body))
        if not keys:
            raise SystemExit(f"check_report_contract: no keys for {var} in func {fn} — has ReportView.swift changed shape?")
        found.setdefault(record, set()).update(keys)
    for (fn, marker), record in BY_LITERAL.items():
        body = funcs.get(fn, "")
        at = body.find(marker)
        if at < 0:
            raise SystemExit(f"check_report_contract: literal '{marker}' not found in func {fn}")
        bracket = body.find("[", at + len(marker) - 1)
        literal = balanced(body, bracket, "[", "]")
        found.setdefault(record, set()).update(re.findall(r'"(\w+)"\s*:', literal))
    return found


def camel(name):
    return name[:1].lower() + name[1:]


def cs_records(text):
    """record name → camelCase names of its { get; init; } properties."""
    text = strip_comments(text)
    out = {}
    for m in re.finditer(r"\brecord\s+(\w+)\b", text):
        name = m.group(1)
        brace = text.find("{", m.end())
        semicolon = text.find(";", m.end())
        if brace < 0 or (0 <= semicolon < brace):
            # positional record: record X(int A, string? B, …); parameters split at top-level commas.
            params = text[m.end():semicolon]
            start, end = params.find("("), params.rfind(")")
            body, depth, part, parts = params[start + 1:end], 0, "", []
            for ch in body:
                if ch in "<[(":
                    depth += 1
                elif ch in ">])":
                    depth -= 1
                if ch == "," and depth == 0:
                    parts.append(part)
                    part = ""
                else:
                    part += ch
            parts.append(part)
            out[name] = {camel(re.findall(r"\w+", q.split("=")[0])[-1]) for q in parts if re.findall(r"\w+", q)}
            continue
        body = balanced(text, brace, "{", "}")
        out[name] = {camel(p) for p in re.findall(r"public\s+[\w<>\[\]?,\s]+?\s+(\w+)\s*\{\s*get;\s*init;", body)}
    return out


def swift_request_fields(text, name="Request"):
    text = strip_comments(text)
    m = re.search(r"struct\s+" + name + r"\s*:\s*Decodable\s*\{", text)
    if not m:
        raise SystemExit(f"check_report_contract: struct {name} not found")
    body = balanced(text, m.end() - 1, "{", "}")
    return set(re.findall(r"\bvar\s+(\w+)\s*:", body))


def check(swift_text, cs_text, run_swift_text, models_text, group_swift_text=None):
    problems, notes = [], []
    written = swift_keys(swift_text)
    records = cs_records(cs_text)
    for record, keys in sorted(written.items()):
        props = records.get(record)
        if props is None:
            problems.append(f"{record}: the engine writes it, but ReportModels.cs has no such record")
            continue
        for p in sorted(props - keys - INHERITED):
            problems.append(f"{record}.{p}: read by the window, never written by the engine (it would always be its default)")
        for k in sorted(keys - props):
            notes.append(f"{record}: the engine writes \"{k}\", the window does not read it")

    sources = {"AnalysisRun": run_swift_text, "GroupABI": group_swift_text if group_swift_text is not None else GROUP_SWIFT.read_text()}
    cs_all = cs_records(models_text + "\n" + cs_text)
    for record, swift_file, struct in REQUESTS:
        sent = cs_all.get(record)
        if sent is None:
            problems.append(f"{record}: no such C# record")
            continue
        fields = swift_request_fields(sources[swift_file], struct)
        for p in sorted(sent - fields):
            problems.append(f"{record}.{p}: sent by the window, not a field of {swift_file}.{struct} (ignored)")
    return problems, notes, sum(len(v) for v in written.values())


def run():
    problems, notes, count = check(SWIFT.read_text() + "\n" + REVIEW_SWIFT.read_text() + "\n" + MARBLE_SWIFT.read_text() + "\n" + GROUP_SWIFT.read_text(), CS.read_text() + "\n" + GROUP_CS.read_text(), RUN_SWIFT.read_text(), MODELS_CS.read_text())
    print(f"report contract: {count} keys written by the engine, {len(BY_VARIABLE) + len(BY_LITERAL)} objects")
    for n in notes:
        print("  note:", n)
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for p in problems:
            print("  ", p)
        return 1
    print("no problems found")
    return 0


def selftest():
    """Each injected error must be reported; the unchanged files must pass."""
    base = (SWIFT.read_text() + "\n" + REVIEW_SWIFT.read_text() + "\n" + MARBLE_SWIFT.read_text() + "\n" + GROUP_SWIFT.read_text(), CS.read_text() + "\n" + GROUP_CS.read_text(), RUN_SWIFT.read_text(), MODELS_CS.read_text())
    assert not check(*base)[0], "the unchanged files must pass"
    injections = [
        ("engine renames a key", lambda s, c, r, m: (s.replace('d["displayUnit"]', 'd["unitShown"]'), c, r, m)),
        ("window reads a key that is not written", lambda s, c, r, m:
            (s, c.replace("public string? KeyNote { get; init; }", "public string? KeyNote { get; init; }\n    public string Subtitle { get; init; } = \"\";"), r, m)),
        ("a literal key is misspelt", lambda s, c, r, m: (s.replace('"short": k.short', '"shortName": k.short'), c, r, m)),
        ("a request field the engine does not decode", lambda s, c, r, m: (s, c, r.replace("var reportLanguage: String?", "var reportLang: String?"), m)),
        ("a whole record renamed", lambda s, c, r, m: (s, c.replace("public record ReportEpoch", "public record ReportPeriod"), r, m)),
        ("a group request field the engine does not decode", lambda s, c, r, m:
            (s, c.replace("public bool? ShowAnimals { get; init; }", "public bool? ShowAnimal { get; init; }"), r, m)),
    ]
    failed = 0
    for name, inject in injections:
        problems = check(*inject(*base))[0]
        status = "caught" if problems else "MISSED"
        if not problems:
            failed += 1
        print(f"  {status:7} {name}" + (f"  → {problems[0]}" if problems else ""))
    print("selftest:", "all injected errors caught" if failed == 0 else f"{failed} missed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv else run())
