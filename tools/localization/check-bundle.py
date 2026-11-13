#!/usr/bin/env python3
import pathlib,plistlib,sys,subprocess,json
app=pathlib.Path(sys.argv[1]);root=pathlib.Path(__file__).resolve().parents[2]
resources=app/'Contents/Resources';info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert set(info['CFBundleLocalizations'])=={'en','zh-Hans'}
for language in ['en','zh-Hans']:
    path=resources/(language+'.lproj')/'InfoPlist.strings'
    strings=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]))
    assert strings['NSMicrophoneUsageDescription']
    assert strings['NSLocalNetworkUsageDescription']
    for source in (root/'Resources'/(language+'.lproj')).glob('*.png'):
        assert source.read_bytes()==(resources/(language+'.lproj')/source.name).read_bytes()
assert (resources/'SettingsMenuBarBoard.png').read_bytes()==(root/'Resources/SettingsMenuBarBoard.png').read_bytes()
assert info['NSBonjourServices']==['_macosx-nearby._tcp'] and info['NSLocalNetworkUsageDescription']
print('PASS bundle: two languages, permission descriptions, English bitmaps and original Chinese artwork')
