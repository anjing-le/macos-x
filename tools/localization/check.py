#!/usr/bin/env python3
"""Fail when visible Chinese text bypasses localization or artwork is missing."""
import extract, json, pathlib, re, struct, subprocess
root=pathlib.Path(__file__).resolve().parents[2]
en=json.loads((root/'Resources/Localization/en.json').read_text())
errors=[]
for p in (root/'Sources').rglob('*.swift'):
    if p.name=='AppLanguage.swift': continue
    text=p.read_text()
    extract.process(text,p.relative_to(root))
    assert not re.search(r'Bundle.main.url\(forResource: "(?:Settings\w+Board|CardArtwork)"',text), str(p)
    for match in re.finditer(r'AppLanguage.text\(("(?:\\.|[^"\\])*")',text):
        key=json.loads(match[1])
        if key not in en: errors.append('Missing catalog key: '+key)
for key, occurrences in extract.records.items():
    errors.append('Unwrapped: '+key+' '+str(occurrences))
for name in ['SettingsCaptureBoard','SettingsSwitcherBoard','SettingsPromptsBoard','SettingsMenuBarBoard','CardArtwork']:
    original=(root/'Resources'/f'{name}.png').read_bytes()
    localized=(root/'Resources/en.lproj'/f'{name}.png').read_bytes()
    a=struct.unpack('>II',original[16:24]);b=struct.unpack('>II',localized[16:24])
    assert abs(a[0]/a[1]-b[0]/b[1]) < .002,(name,a,b)
    assert original != localized,name
source=root/'Sources/MacOSXCore/AppLanguage.swift';before=source.read_bytes()
subprocess.run(['python3',str(root/'tools/localization/generate.py')],check=True)
assert before==source.read_bytes(),'Regenerate AppLanguage.swift before committing'
assert not errors,'\n'.join(errors)
print(f'PASS localization: {len(en)} translations, native source coverage, placeholders and five English bitmap variants')
