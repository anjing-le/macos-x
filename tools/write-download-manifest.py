#!/usr/bin/env python3
"""Validate paired packages and emit concrete architecture-specific download links."""
import hashlib, importlib.util, json, pathlib, plistlib, subprocess, sys, xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('bundle_architecture', root/'tools/verify-bundle-architecture.py')
architecture=importlib.util.module_from_spec(spec);spec.loader.exec_module(architecture)


def create(arm_app,intel_app,directory):
    directory=pathlib.Path(directory)
    ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    inspected=[architecture.inspect(arm_app,'arm64'),architecture.inspect(intel_app,'x86_64')]
    for key in ['version','build','minimumSystemVersion']:
        if inspected[0][key]!=inspected[1][key]:raise ValueError('Paired release differs: '+key)
    version=inspected[0]['version'];build=inspected[0]['build']
    prefix='https://github.com/anjing-le/macos-x/releases/download/v'+version+'/'
    downloads=[]
    for app,arch in [(arm_app,'arm64'),(intel_app,'x86_64')]:
        with (pathlib.Path(app)/'Contents/Info.plist').open('rb') as file:info=plistlib.load(file)
        assets={}
        for suffix in ['zip','dmg']:
            name=f'macos-x-{version}-{arch}.{suffix}';path=directory/name
            digest=hashlib.sha256(path.read_bytes()).hexdigest()
            if (directory/(name+'.sha256')).read_text().split()!=[digest,name]:
                raise ValueError('Bad checksum sidecar: '+name)
            assets[suffix]=dict(name=name,url=prefix+name,sha256=digest,size=path.stat().st_size)
        feed_name='appcast.xml' if arch=='arm64' else 'appcast-intel.xml'
        if info.get('SUFeedURL')!='https://github.com/anjing-le/macos-x/releases/latest/download/'+feed_name:
            raise ValueError('Application uses the wrong architecture feed')
        feed=directory/feed_name;items=ET.parse(feed).findall('channel/item')
        if len(items)!=1:raise ValueError('Expected one stable item per native architecture feed')
        item=items[0];enclosure=item.find('enclosure')
        if item.findtext(ns+'version')!=build or item.findtext(ns+'shortVersionString')!=version:
            raise ValueError('Feed version does not match the app')
        if enclosure.attrib['url']!=assets['zip']['url'] or int(enclosure.attrib['length'])!=assets['zip']['size']:
            raise ValueError('Feed points to the wrong native archive')
        expected_requirement='arm64' if arch=='arm64' else None
        if item.findtext(ns+'hardwareRequirements')!=expected_requirement:
            raise ValueError('Wrong Sparkle hardware requirement')
        subprocess.run([str(root/'.build/artifacts/sparkle/Sparkle/bin/sign_update'),'--account','macos-x','--verify',str(feed)],check=True)
        subprocess.run(['swift',str(root/'scripts/verify-update.swift'),str(directory/assets['zip']['name']),enclosure.attrib[ns+'edSignature'],str(root/'Resources/update-public-key.txt')],check=True)
        downloads.append(dict(architecture=arch,label='Apple Silicon (M series)' if arch=='arm64' else 'Intel',
                              minimumSystemVersion=info['LSMinimumSystemVersion'],**assets,
                              feed=dict(name=feed_name,url=prefix+feed_name,sha256=hashlib.sha256(feed.read_bytes()).hexdigest(),size=feed.stat().st_size)))
    result=dict(schemaVersion=1,version=version,build=build,platform='macOS',downloads=downloads)
    (directory/'downloads.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    return result


if __name__=='__main__':
    if len(sys.argv)!=4:raise SystemExit('Usage: write-download-manifest.py arm64.app intel.app release-directory')
    result=create(*sys.argv[1:]);print('PASS paired release:',result['version'],'arm64 + x86_64; app, worker, feed, checksum and Ed25519 verified')
