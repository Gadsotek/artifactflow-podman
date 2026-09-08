#!/usr/bin/env python3
"""Linux-only: actual scripts, fake host commands, synthetic fixture files.

No real service, database, credential file, or external connection is used.
Scratch directories are left under the OS temporary directory for inspection.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['AF_TEST_LOG'], 'a') as f:
    f.write(json.dumps([name, *args]) + '\n')
if name == 'id': print('1000')
elif name == 'uname': print('Linux' if args == ['-s'] else 'x86_64')
elif name == 'podman':
    if args[0] == 'inspect': print('healthy')
    elif args[0] == 'exec':
        if 'cat' in args: print('synthetic-public-ca')
        if '-i' in args: sys.stdin.read()
        if any('artifactflow:doctor' in a for a in args):
            sys.exit(int(os.environ.get('AF_TEST_DOCTOR_EXIT', '0')))
elif name == 'gh': sys.exit(int(os.environ.get('AF_TEST_VERIFY_EXIT', '0')))
elif name == 'curl': print('192.0.2.20' if any('ipify' in a for a in args) else '-- synthetic grants')
'''


def settings(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines()
                if line and not line.startswith('#') and '=' in line)


class InstallerBehavior(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix='af-podman-contract-'))
        self.repo, self.cfg, self.units, self.bin = (self.base/n for n in ('repo', 'config', 'units', 'bin'))
        for path in (self.repo, self.cfg, self.bin):
            path.mkdir()
        shutil.copytree(ROOT/'quadlet', self.repo/'quadlet')
        (self.repo/'env').mkdir()
        for p in (ROOT/'env').glob('*.example'):
            shutil.copyfile(p, self.repo/'env'/p.name.replace('.env', '.fixture'))
        for name in ('install.sh', 'deploy.sh', 'processor-images.lock', 'Dockerfile.image-parser', 'Dockerfile.pdf-processor'):
            content = (ROOT/name).read_text().replace('/etc/artifactflow', str(self.cfg))
            content = content.replace('$HOME/.config/containers/systemd', str(self.units))
            content = content.replace('.env', '.fixture')
            (self.repo/name).write_text(content)
        for name in ('id', 'uname', 'podman', 'systemctl', 'gh', 'curl'):
            target = self.bin/name
            target.write_text(MOCK)
            target.chmod(0o755)
        self.log = self.base/'commands.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], AF_TEST_LOG=str(self.log))

    def existing(self):
        for name in ('app', 'postgres', 'parser', 'artifact-host'):
            target = self.cfg/(name+'.fixture')
            shutil.copyfile(self.repo/'env'/(name+'.fixture.example'), target)
            target.chmod(0o600)
        p = self.cfg/'app.fixture'
        p.write_text(p.read_text().replace('APP_KEY=', 'APP_KEY=synthetic-existing-app-key')
                     .replace('IMAGE_PARSER_SHARED_SECRET=', 'IMAGE_PARSER_SHARED_SECRET=synthetic-parser-secret'))

    def run_script(self, name, *args, input=''):
        return subprocess.run(['bash' if name == 'install.sh' else 'sh', str(self.repo/name), *args],
                              input=input, text=True, env=self.env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=30)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_fresh_install_defaults_all_documents_off(self):
        answers = 'flow.test.invalid\nartifacts.test.invalid\nresend\nfixture-key\nfixture-key\nmail@test.invalid\n\n\n\n'
        result = self.run_script('install.sh', '--no-admin', input=answers)
        self.assertEqual(result.returncode, 0, result.stdout)
        config = settings(self.cfg/'app.fixture')
        for fmt in ('PDF', 'XLSX', 'DOCX'):
            self.assertEqual(config[fmt+'_PROCESSOR_ENABLED'], 'false')
            self.assertFalse((self.units/f'artifactflow-{fmt.lower()}-processor.container').exists())

    def test_enable_docx_dependency_preserves_keys_and_reloads_both_origins(self):
        self.existing()
        before = settings(self.cfg/'app.fixture')
        result = self.run_script('install.sh', '--enable-docx', '--enable-xlsx')
        self.assertEqual(result.returncode, 0, result.stdout)
        after = settings(self.cfg/'app.fixture')
        for key in ('APP_KEY', 'IMAGE_PARSER_SHARED_SECRET'):
            self.assertEqual(before[key], after[key])
        for fmt in ('PDF', 'XLSX', 'DOCX'):
            self.assertEqual(after[fmt+'_PROCESSOR_ENABLED'], 'true')
            file = self.cfg/(fmt.lower()+'-processor.fixture')
            self.assertEqual(settings(file)[fmt+'_PROCESSOR_SHARED_SECRET'], after[fmt+'_PROCESSOR_SHARED_SECRET'])
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len({after[f+'_PROCESSOR_SHARED_SECRET'] for f in ('PDF', 'XLSX', 'DOCX')}), 3)
        calls = self.calls()
        doctor = next(i for i, c in enumerate(calls) if any('artifactflow:doctor' in a for a in c))
        for name in ('app', 'pdf-processor', 'xlsx-processor', 'docx-processor', 'artifact-host'):
            self.assertTrue(any(c[:3] == ['systemctl', '--user', 'restart'] and 'artifactflow-'+name in c[3:]
                                for c in calls[:doctor]), name)
        result = self.run_script('install.sh', '--enable-docx', '--enable-xlsx')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(after, settings(self.cfg/'app.fixture'))

    def test_missing_docx_pin_leaves_dependency_disabled(self):
        self.existing()
        p = self.repo/'processor-images.lock'
        p.write_text('\n'.join('DOCX_PROCESSOR_IMAGE=' if l.startswith('DOCX_PROCESSOR_IMAGE=') else l
                               for l in p.read_text().splitlines())+'\n')
        before = (self.cfg/'app.fixture').read_bytes()
        result = self.run_script('install.sh', '--enable-docx')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, (self.cfg/'app.fixture').read_bytes())
        self.assertFalse(any(c[0] == 'systemctl' for c in self.calls()))

    def test_doctor_failure_is_not_reported_as_success(self):
        self.existing()
        self.env['AF_TEST_DOCTOR_EXIT'] = '1'
        result = self.run_script('install.sh', '--enable-docx')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('DONE on the server side', result.stdout)
        result = self.run_script('deploy.sh', '--no-pull')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Deployed v', result.stdout)

    def test_failed_attestation_never_restarts_services(self):
        self.existing()
        self.env['AF_TEST_VERIFY_EXIT'] = '1'
        result = self.run_script('install.sh', '--enable-xlsx')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == 'systemctl' for c in self.calls()))


if __name__ == '__main__':
    unittest.main()
