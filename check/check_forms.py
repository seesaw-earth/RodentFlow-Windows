#!/usr/bin/env python3
"""check_forms.py — the Windows parameter forms against the Mac app and the engine.

    python check/check_forms.py <PoseCalibrationEditor.swift> <SessionModels.swift> <Paradigms.swift> <AssayForms.cs>

For every task, the set of AnalysisParams keys the Mac's PoseParamsEditor section binds
($params.key / params.key, with the helper rows expanded) must equal the set the C# form in
AssayForms.cs uses. Every key the C# forms use must be one of AnalysisParams.CodingKeys.
It also checks the rows every task has (PoseCommonParamsEditor).

What it does not check: titles, units, ranges and conditions. Those were copied by hand; this
script makes sure no parameter was missed, added or misspelt.
"""
import re
import sys
import pathlib


def body_after(text, start):
    """Text of the brace block that opens at or after `start`."""
    i = text.index('{', start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == '{':
            depth += 1
        elif text[j] == '}':
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    raise ValueError('unbalanced braces')


def swift_keys(block, helpers):
    keys = set(re.findall(r'\$?params\.([A-Za-z_]\w*)', block))
    keys.discard('nsfConfirmed')          # computed property (nsfNoFeeding || nsfFeedingTime >= 0)
    for name, helper_keys in helpers.items():
        if re.search(r'\b' + re.escape(name) + r'\b', block):
            keys |= helper_keys
    return keys


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 2
    editor, models, paradigms, forms = (pathlib.Path(a).read_text(encoding='utf-8') for a in sys.argv[1:])

    # Engine: AnalysisParams.CodingKeys
    start = models.index('struct AnalysisParams')
    ck = models.index('enum CodingKeys', start)
    coding = set(re.findall(r'\b([a-z]\w*)\b', body_after(models, ck).replace('case', ' ')))

    # Paradigm case name → raw value
    raw = dict(re.findall(r'case (\w+) = "(\w+)"', paradigms[paradigms.index('enum Paradigm:'):]))

    # Mac: helpers first, then the switch in PoseParamsEditor.body
    ed_start = editor.index('struct PoseParamsEditor')
    ed_end = editor.index('struct PoseCommonParamsEditor')
    ed = editor[ed_start:ed_end]

    def var_body(name):
        m = re.search(r'(?:private )?(?:var|func) ' + re.escape(name) + r'\b', ed)
        return body_after(ed, m.end()) if m else ''

    helpers = {
        'freezeRows': {'freezeSpeed', 'freezeMin'},
        'entryRule': {'entryRule'},
        'FeedingConfirmationStatus': {'nsfFeedingTime', 'nsfNoFeeding'},
    }
    helpers['hungerControlOn'] = swift_keys(var_body('hungerControlOn'), {})
    helpers['loomingFreezeAndThreatRows'] = swift_keys(var_body('loomingFreezeAndThreatRows'), helpers)

    switch = body_after(ed, ed.index('switch paradigm'))
    mac = {}
    for case, member in re.findall(r'case \.(\w+): (\w+)', switch):
        block = var_body(member) if member != 'entryRule' else 'entryRule'
        mac[raw[case]] = swift_keys(block, helpers)

    common_start = editor.index('struct PoseCommonParamsEditor')
    mac_common = swift_keys(body_after(editor, editor.index('var body', common_start)), {})

    # C#: one block per ["task_id"] = [ … ],
    cs_helpers = {
        'Freeze(': {'freezeSpeed', 'freezeMin'},
        'EntryRule()': {'entryRule'},
        'HungerKeys': {'nsfHomeCageFood', 'nsfWeightBefore', 'nsfWeightTest'},
    }

    def cs_keys(block):
        keys = set(re.findall(r'\b(?:N|P|C|T|Onsets)\(\s*"(\w+)"', block))
        for arr in re.findall(r'Keys = \[([^\]]*)\]', block):
            keys |= set(re.findall(r'"(\w+)"', arr))
        for token, ks in cs_helpers.items():
            if token in block:
                keys |= ks
        return keys

    tasks_start = forms.index('Tasks = new Dictionary')
    tasks_text = body_after(forms, tasks_start)
    # A task entry is `["task_id"] =` alone on its line, then `[` — not an index inside a lambda.
    ids = list(re.finditer(r'^[ \t]*\["([a-z_]+)"\] =[ \t]*\n[ \t]*\[', tasks_text, re.M))
    cs = {}
    for k, m in enumerate(ids):
        end = ids[k + 1].start() if k + 1 < len(ids) else len(tasks_text)
        cs[m.group(1)] = cs_keys(tasks_text[m.end():end])
    common_text = body_after(forms, forms.index('public static FormGroup[] Common('))
    cs_common = cs_keys(common_text)

    problems = []
    for task in sorted(set(mac) | set(cs)):
        if task not in cs:
            problems.append(f'{task}: on the Mac, missing from AssayForms.cs')
            continue
        if task not in mac:
            problems.append(f'{task}: in AssayForms.cs, not a task of the Mac editor')
            continue
        missing, extra = mac[task] - cs[task], cs[task] - mac[task]
        if missing:
            problems.append(f'{task}: the Mac binds {sorted(missing)}, the Windows form does not')
        if extra:
            problems.append(f'{task}: the Windows form binds {sorted(extra)}, the Mac does not')
    if mac_common != cs_common:
        problems.append(f'common rows: Mac {sorted(mac_common)} vs Windows {sorted(cs_common)}')

    every_cs = set().union(*cs.values(), cs_common)
    unknown = every_cs - coding
    if unknown:
        problems.append(f'not AnalysisParams keys: {sorted(unknown)}')

    print(f'engine: {len(coding)} AnalysisParams keys')
    print(f'Mac editor: {len(mac)} tasks, {len(set().union(*mac.values()))} keys + {len(mac_common)} common')
    print(f'Windows forms: {len(cs)} tasks, {len(set().union(*cs.values()))} keys + {len(cs_common)} common')
    if problems:
        print(f'\n{len(problems)} to look at:')
        for p in problems:
            print('  ' + p)
        return 1
    print('\nevery task binds the same parameters on both, and all are engine keys')
    return 0


if __name__ == '__main__':
    sys.exit(main())
