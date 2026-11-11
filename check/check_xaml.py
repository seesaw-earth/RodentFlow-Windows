#!/usr/bin/env python3
"""XAML ↔ code-behind, without a compiler: every event handler a XAML file names exists in its code-behind
with the parameter count WinUI calls it with, and every control the code-behind uses by name is named in
the XAML. (check/winui_stub does the full type check, but needs the .NET SDK.)

    python check/check_xaml.py src/RodentFlow.App/MainWindow.xaml
    python check/check_xaml.py --selftest
"""
import pathlib
import re
import sys

EVENT_ATTR = re.compile(r'\b(Click|SelectionChanged|ValueChanged|TextChanged|SizeChanged|PointerMoved|PointerReleased|'
                        r'PointerCaptureLost|PointerPressed|Loaded|Unloaded|Checked|Unchecked|Toggled|DateChanged|KeyDown)="(\w+)"')


def check(xaml, code):
    problems = []
    names = set(re.findall(r'x:Name="(\w+)"', xaml))
    for event, handler in EVENT_ATTR.findall(xaml):
        m = re.search(r'\bvoid\s+' + handler + r'\s*\(([^)]*)\)', code)
        if not m:
            problems.append(f'{event}="{handler}": no method {handler} in the code-behind')
            continue
        params = [p for p in m.group(1).split(',') if p.strip()]
        if len(params) != 2:
            problems.append(f'{handler}: takes {len(params)} parameters; a XAML event handler takes 2 (sender, args)')
    # Names used as members in the code: Word.Something or Word = / Word, at the start of an expression.
    declared = set(re.findall(r'\b(?:private|public|internal|protected)\s+[\w<>\[\]?.,\s]+?\s+(\w+)\s*(?:[;={(]|=>)', code))
    locals_ = set(re.findall(r'\b(?:var|bool|int|double|string)\s+(\w+)\s*=', code))
    for used in sorted(set(re.findall(r'(?<![\w.])([A-Z]\w+)\.(?:Text|IsEnabled|Visibility|Value|Items|SelectedItem|'
                                       r'SelectedIndex|Children|Width|Height|Source|Background|Header|ItemsSource|'
                                       r'IsOpen|Message|ActualTheme|ActualThemeChanged|ActualWidth|ActualHeight|Opacity)\b', code))):
        if used in names or used in declared or used in locals_:
            continue
        if used in {'Visibility', 'Math', 'Path', 'File', 'Directory', 'Environment', 'Colors', 'Task', 'Array', 'Enum',
                    'Window', 'Application', 'Grid', 'Canvas', 'ToolTipService', 'AppText', 'Engine', 'RodentFlow',
                    'SessionDates', 'Printf', 'Fmt', 'Tr'}:
            continue
        problems.append(f'{used}: used in the code-behind, but no control has x:Name="{used}"')
    return problems


def selftest(xaml, code):
    cases = [
        ('a handler missing', xaml.replace('Click="Start"', 'Click="Begin"'), code),
        ('a handler with the wrong signature', xaml, re.sub(r'void StepChanged\([^)]*\)', 'void StepChanged(SelectorBar sender)', code)),
        ('a control renamed in XAML only', xaml.replace('x:Name="ResultsEmpty"', 'x:Name="NoResults"'), code),
    ]
    missed = 0
    for name, x, c in cases:
        found = check(x, c)
        print(f"  {'caught' if found else 'MISSED':7} {name}" + (f"  → {found[0]}" if found else ""))
        missed += 0 if found else 1
    return missed


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    xaml_path = pathlib.Path(args[0] if args else 'src/RodentFlow.App/MainWindow.xaml')
    xaml = xaml_path.read_text()
    # The code-behind and every other part of the same partial class (MainWindow.*.cs next to it).
    stem = xaml_path.name[:-len('.xaml')]
    parts = [pathlib.Path(str(xaml_path) + '.cs')] + sorted(
        f for f in xaml_path.parent.glob(stem + '.*.cs') if f.name != xaml_path.name + '.cs')
    code = '\n'.join(f.read_text() for f in parts)
    if '--selftest' in sys.argv:
        assert not check(xaml, code), check(xaml, code)
        missed = selftest(xaml, code)
        print('selftest:', 'all injected errors caught' if missed == 0 else f'{missed} missed')
        return 1 if missed else 0
    problems = check(xaml, code)
    handlers = len(EVENT_ATTR.findall(xaml))
    named = len(set(re.findall(r'x:Name="(\w+)"', xaml)))
    print(f"{xaml_path.name}: {named} named controls, {handlers} event handlers, code in {len(parts)} file(s)")
    for p in problems:
        print('  ', p)
    print('no problems found' if not problems else f'{len(problems)} problem(s)')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
