#!/usr/bin/env python3
"""Static cross-check of the C-ABI layer against the RodentFlow engine sources.

No Swift compiler is available here, so this does the one check that matters most: every type,
member and argument label the ABI files use must exist in the engine sources with that exact
spelling. Lexical, not a type checker. Brace-aware, so multi-line signatures and nested types are
handled.

Usage: check_abi.py ENGINE_DIR ABI_FILE [ABI_FILE ...]
"""
import re
import sys
import pathlib
import collections

WORD = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
TYPE_KW = ('struct', 'enum', 'class', 'protocol', 'actor', 'extension')


def strip_comments(text):
    """Comments out, string literals replaced by "" so their contents never parse as code."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        if text.startswith('/*', i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif text.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            out.append('""')
            i = n if j < 0 else j + 3
            continue
        if text[i] == '"':
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                if text[i] == '\n':      # unterminated: bail out of the literal
                    break
                i += 1
            out.append('""')
            continue
        out.append(text[i])
        i += 1
    return ''.join(out)


def balanced(text, start, open_ch='(', close_ch=')'):
    """Text inside the brackets that open at `start`, and the index just past the closer."""
    assert text[start] == open_ch
    depth, i, n = 0, start, len(text)
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack = []
    while i < n:
        c = text[i]
        if c in pairs:
            stack.append(pairs[c])
            depth += 1
        elif c in (')', ']', '}'):
            if stack and c == stack[-1]:
                stack.pop()
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i + 1
        i += 1
    return text[start + 1:], n


def split_top(text):
    """Comma-separated pieces at bracket depth 0."""
    parts, cur, depth = [], '', 0
    for ch in text:
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return [p for p in parts if p.strip()]


def decl_labels(param_text):
    """Argument labels of a *declaration* parameter list ('_' for unlabelled, no-colon payloads)."""
    out = []
    for p in split_top(param_text):
        p = p.strip()
        if ':' not in p:                      # enum payload like `case failed(String)`
            out.append('_')
            continue
        head = p.split(':', 1)[0].strip()
        words = head.split()
        out.append('_' if not words or words[0] == '_' else words[0])
    return out


CALL_LABEL = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)')


def call_labels(arg_text):
    """Argument labels of a *call site* ('_' for a positional argument)."""
    out = []
    for p in split_top(arg_text):
        m = CALL_LABEL.match(p)
        out.append(m.group(1) if m else '_')
    return out


def scan(text, on_type=None, on_func=None, on_prop=None, on_call=None):
    """Walk Swift source, tracking the enclosing type by brace depth."""
    i, n, depth = 0, len(text), 0
    stack = []            # (type name, depth at which its body opened)
    while i < n:
        c = text[i]
        if c == '{':
            depth += 1
            i += 1
            continue
        if c == '}':
            depth -= 1
            while stack and depth < stack[-1][1]:
                stack.pop()
            i += 1
            continue
        if not (c.isascii() and (c.isalpha() or c == '_')):
            i += 1
            continue
        if i > 0 and (text[i - 1].isalnum() or text[i - 1] in '_.'):
            i += 1
            continue
        m = WORD.match(text, i)
        if m is None:
            i += 1
            continue
        word, end = m.group(0), m.end()
        owner = stack[-1][0] if stack else None

        if word in TYPE_KW:
            nm = WORD.match(text, end + 1) if end < n and text[end] == ' ' else None
            brace = text.find('{', end)
            if nm and brace >= 0:
                name = nm.group(0)
                full = name if (word == 'extension' or not owner) else owner + '.' + name
                if on_type:
                    on_type(full, name, owner, word)
                stack.append((full, depth + 1))
                i = brace + 1
                depth += 1
                continue
            i = end
            continue

        if word in ('func', 'init'):
            if word == 'init':
                paren = text.find('(', i)
                name = 'init'
            else:
                nm = WORD.match(text, end + 1) if end < n and text[end] == ' ' else None
                if not nm:
                    i = end
                    continue
                name = nm.group(0)
                paren = text.find('(', nm.end())
            if paren < 0:
                i = end
                continue
            params, after = balanced(text, paren)
            if on_func:
                on_func(owner, name, decl_labels(params))
            i = after
            continue

        if word in ('var', 'let', 'case', 'typealias'):
            nm = WORD.match(text, end + 1) if end < n and text[end] == ' ' else None
            if nm:
                payload = None
                if word == 'case' and nm.end() < n and text[nm.end()] == '(':
                    payload = decl_labels(balanced(text, nm.end())[0])
                if on_prop:
                    on_prop(owner, nm.group(0), payload)
                    if word == 'case':
                        # `case none, rectangle, circle` declares every name on the line, not just the first.
                        eol = text.find('\n', nm.end())
                        rest = text[nm.end():eol if eol >= 0 else n]
                        rest = re.sub(r'"(?:[^"\\]|\\.)*"', '""', rest)    # raw values
                        while re.search(r'\([^()]*\)', rest):              # payloads
                            rest = re.sub(r'\([^()]*\)', '', rest)
                        rest = rest.split('//')[0]
                        for more in re.findall(r',\s*([A-Za-z_]\w*)', rest):
                            on_prop(owner, more, None)
                i = nm.end()
                continue
            i = end
            continue

        # a call or a property read: Ident.member( … )  /  Ident.member
        if on_call and word[0].isupper():
            j = end
            chain = []
            while j < n and text[j] == '.':
                nm = WORD.match(text, j + 1)
                if not nm:
                    break
                chain.append(nm.group(0))
                j = nm.end()
                if j < n and text[j] == '(':
                    args, j = balanced(text, j)
                    on_call(word, chain, call_labels(args))
                    chain = []
                    break
            if chain:
                on_call(word, chain, None)
            i = max(j, end)
            continue
        i = end
    return


def index_engine(root):
    types = collections.defaultdict(lambda: {'members': collections.defaultdict(list), 'props': set()})
    globals_ = set()
    files = sorted(pathlib.Path(root).rglob('*.swift'))
    for path in files:
        text = strip_comments(path.read_text(errors='replace'))

        def on_type(full, name, owner, kind):
            types[full]
            if owner:
                types[owner]['props'].add(name)
            else:
                globals_.add(name)

        def on_func(owner, name, labels):
            if owner:
                types[owner]['members'][name].append(labels)
            else:
                globals_.add(name)

        def on_prop(owner, name, payload):
            if owner:
                types[owner]['props'].add(name)
                if payload is not None:
                    types[owner]['members'][name].append(payload)
            else:
                globals_.add(name)

        scan(text, on_type=on_type, on_func=on_func, on_prop=on_prop)
    return types, globals_, len(files)


# Members the compiler synthesizes (CaseIterable, RawRepresentable, Codable …): never in the source.
SYNTHESIZED = {'allCases', 'rawValue', 'init', 'self', 'hashValue', 'description'}

# Foundation / stdlib members used by the ABI layer on non-engine receivers.
FOUNDATION_MEMBERS = {
    'utf8', 'count', 'isEmpty', 'first', 'last', 'map', 'filter', 'reduce', 'append', 'contains',
    'reserveCapacity', 'removeAll', 'removeValue', 'keepingCapacity', 'sorted', 'sort', 'path',
    'appendingPathComponent', 'lastPathComponent', 'write', 'read', 'close', 'synchronize',
    'truncate', 'seekToEnd', 'pointee', 'deallocate', 'allocate', 'rawValue', 'shared', 'lock',
    'unlock', 'now', 'timeIntervalSinceReferenceDate', 'timeIntervalSince1970', 'rounded',
    'squareRoot', 'isFinite', 'isNaN', 'data', 'string', 'joined', 'split', 'prefix', 'suffix',
    'dropFirst', 'dropLast', 'hasPrefix', 'hasSuffix', 'lowercased', 'uppercased', 'enumerated',
    'flatMap', 'compactMap', 'max', 'min', 'abs', 'description', 'localizedDescription',
    'errorDescription', 'fileExists', 'createDirectory', 'createFile', 'removeItem', 'moveItem',
    'contentsOfDirectory', 'outputFormatting', 'decode', 'encode', 'processInfo', 'environment',
    'default', 'isValidJSONObject', 'jsonObject', 'insert', 'remove', 'get', 'values', 'keys',
    'withIntermediateDirectories', 'atomic', 'sortedKeys', 'prettyPrinted', 'clamping',
    'bitPattern', 'capacity', 'start', 'self', 'init',
    'lowerBound', 'upperBound',          # ClosedRange (MetricScale.range, LineData.yRange)
    'infinity',                          # Float.infinity
    'nonConformingFloatDecodingStrategy', 'convertFromString',   # JSONDecoder (Foundation)
    'nonConformingFloatEncodingStrategy', 'convertToString',     # JSONEncoder (Foundation)
}

SKIP = {
    'String', 'Data', 'Date', 'URL', 'Int', 'Int32', 'Int64', 'UInt8', 'UInt64', 'Double', 'Float',
    'Bool', 'Array', 'Dictionary', 'Set', 'Optional', 'JSONSerialization', 'JSONDecoder',
    'JSONEncoder', 'FileManager', 'FileHandle', 'NSLock', 'NSNull', 'ProcessInfo', 'UUID',
    'CGSize', 'CGFloat', 'CGPoint', 'CGRect', 'UnsafeBufferPointer', 'UnsafePointer',
    'UnsafeMutablePointer', 'CChar', 'Self', 'ISO8601DateFormatter', 'Error', 'LocalizedError',
    'Decodable', 'Encodable', 'Codable', 'Any', 'AnyObject', 'MainActor', 'Task',
}


def main():
    engine_dir, abi_files = sys.argv[1], sys.argv[2:]
    types, globals_, nfiles = index_engine(engine_dir)
    known = set(types) | globals_
    problems = []
    stats = collections.Counter()

    for path in abi_files:
        text = strip_comments(pathlib.Path(path).read_text(errors='replace'))
        fname = pathlib.Path(path).name
        offsets = [0]
        for line in text.split('\n'):
            offsets.append(offsets[-1] + len(line) + 1)

        def on_call(root_name, chain, labels, _t=text, _f=fname):
            if root_name in SKIP or not chain:
                return
            if root_name not in types:
                if root_name not in known:
                    problems.append((_f, f'unknown type `{root_name}`'))
                return
            member = chain[0]
            info = types[root_name]
            if labels is None:
                if member in SYNTHESIZED:
                    stats['synthesized'] += 1
                    return
                if member in info['props'] or member in info['members']:
                    stats['reads'] += 1
                else:
                    problems.append((_f, f'`{root_name}` has no property `{member}`'))
                return
            if member in SYNTHESIZED:
                stats['synthesized'] += 1
                return
            decls = info['members'].get(member)
            if decls is None:
                if member in info['props']:
                    stats['reads'] += 1
                else:
                    problems.append((_f, f'`{root_name}` has no member `{member}`'))
                return
            stats['calls'] += 1
            ok = False
            for d in decls:
                di, good = 0, True
                for lab in labels:
                    while di < len(d) and d[di] != lab:
                        di += 1
                    if di == len(d):
                        good = False
                        break
                    di += 1
                if good:
                    ok = True
                    break
            if not ok:
                shown = ' | '.join('(' + ', '.join(d) + ')' for d in decls)
                problems.append((_f, f'`{root_name}.{member}` called with ({", ".join(labels)}); '
                                    f'declared {shown}'))

        scan(text, on_call=on_call)

        # Second pass: any `.member` access, whatever the receiver. The receiver's type cannot be
        # inferred lexically, so this only checks that the name exists somewhere in the engine (or
        # in Foundation's small set below) — it catches typos, not wrong-type accesses.
        every = set()
        for info in types.values():
            every |= set(info['props']) | set(info['members'])
        every |= globals_ | SYNTHESIZED | FOUNDATION_MEMBERS
        for m in re.finditer(r'\.([a-z][A-Za-z0-9_]*)', text):
            name = m.group(1)
            if name in every:
                stats['members'] += 1
                continue
            problems.append((fname, f'member `.{name}` is declared nowhere in the engine'))

    # Every C entry point must answer {"ok":true,…} or {"ok":false,"error":…}: RFJSON.ok and
    # RFJSON.failure add the flag, a bare RFJSON.encode does not. Found the hard way on the first
    # live call, where rf_version reported a failure on success.
    for path in abi_files:
        text = strip_comments(pathlib.Path(path).read_text(errors='replace'))
        if 'RFJSON.encode(' in text:
            for n, line in enumerate(text.split('\n'), 1):
                if 'RFJSON.encode(' in line:
                    problems.append((pathlib.Path(path).name,
                                     f'line {n}: builds a reply with RFJSON.encode, which has no '
                                     f'"ok" field — use RFJSON.ok or RFJSON.failure'))

    print(f'engine: {nfiles} files, {len(types)} types, {len(globals_)} global names')
    print(f'checked: {stats["calls"]} calls, {stats["reads"]} property reads, '
          f'{stats["synthesized"]} compiler-synthesized, {len(abi_files)} ABI files')
    if not problems:
        print('\nno problems found')
        return 0
    seen, uniq = set(), []
    for p in problems:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    print(f'\n{len(uniq)} to look at:')
    for f, msg in uniq:
        print(f'  {f}: {msg}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
