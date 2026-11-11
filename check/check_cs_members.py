#!/usr/bin/env python3
"""Project-internal C# references, without a compiler.

    python check/check_cs_members.py              (from the top of the repository)
    python check/check_cs_members.py --selftest

Indexes every type the repository declares (classes, records — with their positional parameters —, structs,
enums, interfaces; partial classes merged; members of project base types inherited) and checks two kinds of use:

  * Type.Member      a project type followed by a member (static members, constants, enum members, nested types),
                     also inside a qualified chain such as RodentFlow.Engine.Engine.Analyze or Core.Workspace.RunState.X;
  * field.Member     a field or property of a project type declared in the same class (e.g. _model.UpdateResultsAsync,
                     _store.FindTask), one level deep.

Types that derive from a framework type (a Grid, a Window, an Exception …) are skipped for field.Member, since their
members are not all declared here. Everything outside the project (WinUI, .NET) is not checked — that needs the
compiler — but renamed or misspelt project members are the commonest error in code written without one.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIRS = ["src", "tools"]
KEYWORDS = {"class", "record", "struct", "enum", "interface"}
FRAMEWORK_OK = {"ToString", "Equals", "GetHashCode", "GetType", "Clone"}


def strip(src):
    """Comments and string / char literals removed (interpolation holes kept as plain code is not needed)."""
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        k = i
        while k < n and src[k] in "$@":
            k += 1
        if src.startswith('"""', k):
            q = k
            while q < n and src[q] == '"':
                q += 1
            quotes = q - k
            end = src.find('"' * quotes, q)
            i = n if end < 0 else end + quotes
            out.append('""')
            continue
        if k < n and src[k] == '"':
            verbatim = "@" in src[i:k]
            j = k + 1
            while j < n:
                if verbatim:
                    if src[j] == '"':
                        if j + 1 < n and src[j + 1] == '"':
                            j += 2
                            continue
                        break
                else:
                    if src[j] == "\\":
                        j += 2
                        continue
                    if src[j] in '"\n':
                        break
                j += 1
            i = j + 1
            out.append('""')
            continue
        if src[i] == "'":
            j = i + 1
            j += 2 if j < n and src[j] == "\\" else 1
            while j < n and src[j] != "'" and j - i < 12:
                j += 1
            i = j + 1
            out.append("' '")
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


def block(text, start):
    """The text from the brace at `start` to its partner."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def top_level(body):
    """Body text with nested braces' content blanked (members of this type only)."""
    out, depth = [], 0
    for ch in body[1:-1]:
        if ch == "{":
            depth += 1
            out.append("{")
            continue
        if ch == "}":
            depth -= 1
            out.append("}")
            continue
        out.append(ch if depth == 0 else " ")
    return "".join(out)


class Type:
    def __init__(self, name, kind):
        self.name, self.kind = name, kind
        self.members, self.bases, self.fields = set(), [], {}
        self.nested = set()
        # Declared inside another type: usable only qualified (VideoFrameGrabber.Frame), never as a bare name.
        self.parent = None


TYPE_DECL = re.compile(r"\b(class|record|struct|enum|interface)\s+(?:struct\s+|class\s+)?([A-Z]\w*)(\s*<[^>{(;]*>)?")
# A member declaration: modifiers, a type (a tuple in parentheses, or a name with generics / arrays / ?), the name,
# then what follows a member name. The type has no free spaces, so the pattern cannot backtrack badly.
TYPE_TOKEN = r"(?:\([^()\n]*\)\??|[\w.]+(?:<[^<>\n]*(?:<[^<>\n]*>[^<>\n]*)*>)?(?:\[\])*\??)"
MEMBER = re.compile(r"(?:^|[;{}\]\n])[ \t]*(?:\[[^\]\n]*\][ \t\n]*)*((?:(?:public|private|protected|internal|static|readonly|const|"
                    r"override|virtual|abstract|sealed|async|partial|required|unsafe|extern|new|volatile|event)[ \t]+)*)"
                    r"(" + TYPE_TOKEN + r")[ \t]+([A-Za-z_]\w*)[ \t]*(?:<[\w\s,]*>)?\s*(\(|\{|=>|=|;)", re.M)


def index(files):
    types = {}
    for f in files:
        text = strip(f.read_text(encoding="utf-8"))
        spans = []
        for m in TYPE_DECL.finditer(text):
            brace = text.find("{", m.end())
            semi = text.find(";", m.end())
            if brace >= 0 and not (0 <= semi < brace):
                spans.append((m.start(), brace + len(block(text, brace)), m.group(2)))
        def parent_of(pos, name):
            inner = [sp for sp in spans if sp[0] < pos < sp[1] and sp[2] != name]
            return max(inner, key=lambda sp: sp[0])[2] if inner else None
        for m in TYPE_DECL.finditer(text):
            kind, name = m.group(1), m.group(2)
            if kind == "record" and text[m.end():m.end() + 1] == "(":
                pass
            t = types.setdefault(name, Type(name, kind))
            owner = parent_of(m.start(), name)
            if owner and t.parent is None:
                t.parent = owner
            rest = text[m.end():]
            # positional parameters
            par = re.match(r"\s*\(", rest)
            if kind == "record" and par:
                depth, j = 0, m.end() + par.end() - 1
                for j2 in range(j, len(text)):
                    if text[j2] == "(":
                        depth += 1
                    elif text[j2] == ")":
                        depth -= 1
                        if depth == 0:
                            params = text[j + 1:j2]
                            break
                else:
                    params = ""
                depth, part, parts = 0, "", []
                for ch in params:
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
                for p in parts:
                    words = re.findall(r"\w+", p.split("=")[0])
                    if words:
                        t.members.add(words[-1])
            # base list and body
            brace = text.find("{", m.end())
            semi = text.find(";", m.end())
            head = text[m.end():brace if brace >= 0 else len(text)]
            if ":" in head and (semi < 0 or brace < semi):
                for b in head.split(":", 1)[1].split(","):
                    b = re.sub(r"\(.*", "", b).strip()
                    b = re.sub(r"<.*", "", b).split(".")[-1].strip()
                    if b and not b.startswith("where"):
                        t.bases.append(b)
            if brace < 0 or (0 <= semi < brace):
                continue
            body = block(text, brace)
            top = top_level(body)
            if kind == "enum":
                for e in re.findall(r"([A-Za-z_]\w*)\s*(?:=[^,]*)?(?:,|$)", top):
                    t.members.add(e)
                continue
            for mm in MEMBER.finditer(top):
                mods, typ, name, after = mm.group(1), mm.group(2).strip(), mm.group(3), mm.group(4)
                if typ in ("return", "new", "else", "case", "throw", "await", "using", "goto", "yield", "in", "out", "ref", "is", "as"):
                    continue
                if name in KEYWORDS:
                    continue
                t.members.add(name)
                # Only plain project types: an array or a generic of one is not the type itself.
                if after in ("{", "=", ";", "=>") and "[" not in typ and "<" not in typ and "(" not in typ:
                    t.fields[name] = typ.rstrip("?").split(".")[-1].strip()
            for nm in TYPE_DECL.finditer(top):
                t.nested.add(nm.group(2))
                t.members.add(nm.group(2))
            # Several names in one declaration: const byte A = 1, B = 2; — every name before an "=".
            for stmt in top.split(";"):
                if re.search(r"\bconst\b|\bstatic\s+readonly\b", stmt) and "(" not in stmt.split("=")[0]:
                    for extra in re.findall(r"([A-Za-z_]\w*)\s*=(?![=>])", stmt):
                        t.members.add(extra)
            # constructors / methods declared with the type's own name are fine; events ("event X Name;") are in MEMBER
    return types


def all_members(types, name, seen=None):
    seen = seen or set()
    if name in seen or name not in types:
        return set(), False
    seen.add(name)
    t = types[name]
    members = set(t.members) | FRAMEWORK_OK
    external = False
    for b in t.bases:
        if b in types:
            m, ext = all_members(types, b, seen)
            members |= m
            external |= ext
        elif b not in ("IDisposable", "IComparer", "IFigureCanvas", "INotifyPropertyChanged", "IEquatable"):
            external = True
    if t.kind == "record":
        members |= {"EqualityContract", "Deconstruct"}
    return members, external


CHAIN = re.compile(r"(?<![\w.])((?:[A-Za-z_]\w*\s*\.\s*)+[A-Za-z_]\w*)")
EXTERNAL_ROOTS = {"Microsoft", "Windows", "System", "WinRT"}


def namespaces(files):
    out = set()
    for f in files:
        for m in re.finditer(r"\bnamespace\s+([\w.]+)", f.read_text(encoding="utf-8")):
            out.update(m.group(1).split("."))
    return out


def xaml_names():
    out = set()
    for x in (ROOT / "src").rglob("*.xaml"):
        out.update(re.findall(r'x:Name="(\w+)"', x.read_text(encoding="utf-8")))
    return out


def check(files, types):
    problems = []
    spaces = namespaces(files)
    controls = xaml_names()
    for f in files:
        text = strip(f.read_text(encoding="utf-8"))
        rel = f.relative_to(ROOT) if f.is_relative_to(ROOT) else f
        # fields of the classes declared in this file
        field_types, local_fields = {}, set()
        for m in TYPE_DECL.finditer(text):
            t = types.get(m.group(2))
            if t:
                for fname, ftype in t.fields.items():
                    local_fields.add(fname)
                    if ftype in types and types[ftype].parent is None:
                        field_types.setdefault(fname, ftype)
        for cm in CHAIN.finditer(text):
            before = text[max(0, cm.start() - 12):cm.start()]
            if re.search(r"(namespace|using)\s+(static\s+)?$", before):
                continue
            parts = [p.strip() for p in cm.group(1).split(".")]
            if parts[0] in EXTERNAL_ROOTS or parts[0] in controls:
                continue
            line = text.count("\n", 0, cm.start()) + 1
            # A property pattern ({ Frame.IsMetric: true }) names members, not types.
            after = text[cm.end():cm.end() + 3]
            if re.match(r"\s*:(?!:)", after) and re.search(r"[{,]\s*$", text[max(0, cm.start() - 3):cm.start()]):
                continue
            previous_type = None
            for k in range(len(parts) - 1):
                head, member = parts[k], parts[k + 1]
                t = types.get(head)
                is_type = t is not None and (t.parent is None or t.parent == previous_type)
                # A field or property of a class in this file shadows a type of the same name (Row.Session is a NumberBox).
                if k == 0 and head in local_fields and field_types.get(head) != head:
                    is_type = False
                if head in spaces and (not is_type or parts[k + 1] in types or parts[k + 1] == head):
                    previous_type = None
                    continue  # a namespace segment (RodentFlow.Engine.Engine, Core.Workspace.RunState)
                if is_type:
                    members, external = all_members(types, head)
                    if member not in members and not external:
                        problems.append(f"{rel}:{line}: {head}.{member} — {head} declares no member '{member}'")
                    if member in types and types[member].parent == head:
                        previous_type = head
                        continue  # a nested type: check its member too
                    break
                if k == 0 and head in field_types:
                    ftype = field_types[head]
                    members, external = all_members(types, ftype)
                    if not external and member not in members:
                        problems.append(f"{rel}:{line}: {head}.{member} — {head} is a {ftype}, which declares no '{member}'")
                break
    return problems


def files():
    out = []
    for d in DIRS:
        out += [p for p in (ROOT / d).rglob("*.cs") if "/obj/" not in p.as_posix() and "/bin/" not in p.as_posix()
                and "winui_stub" not in p.as_posix()]
    return sorted(out)


def run():
    fs = files()
    types = index(fs)
    problems = check(fs, types)
    print(f"C# members: {len(fs)} files, {len(types)} project types")
    for p in problems:
        print("  ", p)
    print("no problems found" if not problems else f"{len(problems)} to look at")
    return 1 if problems else 0


def selftest():
    import tempfile, shutil
    fs = files()
    base = {f: f.read_text(encoding="utf-8") for f in fs}
    types = index(fs)
    assert not check(fs, types), "the unchanged files must pass"
    injections = [
        ("a method renamed at its call", "src/RodentFlow.App/MainWindow.Review.cs", "_model.SwapIdentityAsync(", "_model.SwapIdentitiesAsync("),
        ("a static member misspelt", "src/RodentFlow.Core/Figures/ReportFigures.cs", "Palette.HeatStepCount", "Palette.HeatStepsCount"),
        ("an enum member that does not exist", "src/RodentFlow.App/MainWindow.Workspace.cs", "SessionStage.NeedsSetup =>", "SessionStage.NeedSetup =>"),
        ("a store method misspelt", "src/RodentFlow.App/MainWindow.Workspace.cs", "_store.OrderedSessions(", "_store.OrderSessions("),
    ]
    missed = 0
    tmp = pathlib.Path(tempfile.mkdtemp())
    try:
        for name, rel, old, new in injections:
            target = ROOT / rel
            text = base[target]
            assert old in text, (name, old)
            copies = []
            for f in fs:
                dest = tmp / f.relative_to(ROOT)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(base[f].replace(old, new, 1) if f == target else base[f], encoding="utf-8")
                copies.append(dest)
            found = check(copies, index(copies))
            print(f"  {'caught' if found else 'MISSED':7} {name}" + (f"  → {found[0]}" if found else ""))
            missed += 0 if found else 1
    finally:
        shutil.rmtree(tmp)
    print("selftest:", "all injected errors caught" if missed == 0 else f"{missed} missed")
    return 1 if missed else 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv else run())
