#!/usr/bin/env python3
"""Exercise actual Mach-O rejection and the one-time Intel channel boundary."""
import importlib.util, os, pathlib, plistlib, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
bundle=module('bundle_architecture','tools/verify-bundle-architecture.py')
identity=module('update_identity','tools/verify-update-identity.py')

class FeedBoundary(unittest.TestCase):
    def test_bootstrap_is_explicit_exact_and_one_way(self):
        prefix='https://github.com/anjing-le/macos-x/releases/latest/download/'
        old,new=prefix+'appcast.xml',prefix+'appcast-intel.xml'
        check=identity.allows_initial_intel_feed
        self.assertTrue(check(old,new,{'arm64'},{'x86_64'},True))
        for arguments in [(old,new,{'arm64'},{'x86_64'},False),(new,old,{'x86_64'},{'arm64'},True),
                          (old,new,{'x86_64'},{'x86_64'},True),(old,new,{'arm64'},{'arm64'},True),
                          ('https://example.com/appcast.xml',new,{'arm64'},{'x86_64'},True),
                          (old,new+'?untrusted=1',{'arm64'},{'x86_64'},True),
                          (None,new,{'arm64'},{'x86_64'},True)]:
            with self.subTest(arguments=arguments):self.assertFalse(check(*arguments))

@unittest.skipUnless(os.environ.get('MACOSX_ARCHITECTURE_TEST_APP'),'provide a real native test bundle')
class ActualPackage(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='macos-x-architecture-check-')
        self.app=pathlib.Path(self.temp.name)/'MacOSX.app'
        shutil.copytree(os.environ['MACOSX_ARCHITECTURE_TEST_APP'],self.app,symlinks=True)
        self.arch=bundle.inspect(self.app)['architecture']
        self.other='x86_64' if self.arch=='arm64' else 'arm64'
    def tearDown(self):self.temp.cleanup()
    def test_actual_main_and_every_nested_executable_match(self):
        report=bundle.inspect(self.app,self.arch)
        self.assertGreaterEqual(report['machOCount'],8)
        self.assertIn('Contents/Helpers/FileDocumentWorker',report['binaries'])
        with self.assertRaises(ValueError):bundle.inspect(self.app,self.other)
    def test_changing_a_label_does_not_change_the_binary(self):
        path=self.app/'Contents/Info.plist';info=plistlib.loads(path.read_bytes());info['MacOSXArchitecture']=self.other
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError,'Declared architecture'):bundle.inspect(self.app)
    def test_a_wrong_architecture_worker_is_rejected(self):
        path=self.app/'Contents/Helpers/FileDocumentWorker'
        sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
        subprocess.run(['xcrun','clang','-target',self.other+'-apple-macos14.0','-isysroot',sdk,'-x','c','-','-o',str(path)],
                       input='int main(void) { return 0; }\n',text=True,check=True)
        self.assertEqual(bundle.architectures(path),{self.other})
        with self.assertRaisesRegex(ValueError,'Wrong architecture for bundled worker'):bundle.inspect(self.app)

if __name__=='__main__':unittest.main()
