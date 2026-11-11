#!/usr/bin/env python3
"""gen_xaml_part.py <MainWindow.xaml> <out.cs> — what the XAML compiler would generate, for the stub build.

Emits the x:Name fields with their element types, an empty InitializeComponent, and one statement
per event attribute (Click="PickVideo" → element.Click += PickVideo;), so a handler that is missing
or has the wrong signature for its event fails to compile, as it would in the real XAML build.
"""
import sys
import xml.etree.ElementTree as ET

X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
EVENTS = {'Click', 'SelectionChanged', 'ValueChanged', 'TextChanged', 'SizeChanged', 'PointerMoved',
          'PointerReleased', 'PointerCaptureLost', 'PointerPressed', 'KeyDown', 'LostFocus'}

tree = ET.parse(sys.argv[1])
root = tree.getroot()
cls = root.attrib[X + 'Class']
ns, name = cls.rsplit('.', 1)

fields, wiring, n = [], [], 0
for el in root.iter():
    tag = el.tag.split('}')[1]
    if '.' in tag or tag in ('Window', 'DataTemplate'):
        continue
    typ = f'global::Microsoft.UI.Xaml.Controls.{tag}'
    xname = el.attrib.get(X + 'Name')
    if xname:
        fields.append(f'    internal {typ} {xname} = null!;')
    for attr, handler in el.attrib.items():
        if attr in EVENTS:
            n += 1
            target = xname or f'__e{n}'
            if not xname:
                wiring.append(f'        {typ} {target} = null!;')
            wiring.append(f'        {target}.{attr} += {handler};')

out = [f'namespace {ns};', '', f'partial class {name}', '{']
out += fields
out += ['    private void InitializeComponent() { }', '', '    private void __WireXamlEvents()', '    {']
out += wiring
out += ['    }', '}']
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
print(f'{len(fields)} named elements, {sum(1 for w in wiring if "+=" in w)} event handlers')
