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
import base64, json, os, pathlib, secrets, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['AF_TEST_LOG'], 'a') as f:
    f.write(json.dumps([name, *args]) + '\n')
if name == 'id': print('1000')
elif name == 'uname': print('Linux' if args == ['-s'] else 'x86_64')
elif name == 'podman':
    if args[:2] == ['info', '--format'] and args[2:] == ['{{.Host.NetworkBackend}}']:
        print(os.environ.get('AF_TEST_NETWORK_BACKEND', 'netavark'))
    elif args[:2] == ['container', 'exists']:
        sys.exit(0 if int(os.environ.get('AF_TEST_LEGACY_ARTIFACT_HOST', '0')) else 1)
    elif args[:2] == ['network', 'inspect']:
        print('true' if int(os.environ.get('AF_TEST_ARTIFACT_NETWORK_INTERNAL', '1')) else 'false')
    elif args[0] == 'inspect':
        if '{{json .NetworkSettings.Networks}}' in args and 'artifactflow-postgres' in args:
            networks = {'artifactflow': {}}
            reattached = pathlib.Path(os.environ['AF_TEST_LOG'] + '.postgres-reattached').exists()
            if not int(os.environ.get('AF_TEST_POSTGRES_LEGACY_NETWORK', '0')) or (
                    reattached and not int(os.environ.get('AF_TEST_POSTGRES_REATTACH_FAIL', '0'))):
                networks['artifactflow-artifact'] = {}
            print(json.dumps(networks))
        elif 'artifactflow-artifact-host' in args and any(
                '.NetworkSettings.Networks' in a for a in args):
            restarted = pathlib.Path(os.environ['AF_TEST_LOG'] + '.artifact-host-restarted').exists()
            legacy = int(os.environ.get('AF_TEST_LEGACY_ARTIFACT_HOST', '0')) and not restarted
            bad = int(os.environ.get('AF_TEST_EFFECTIVE_HOST_NETWORK_BAD', '0')) and restarted
            networks = {'artifactflow': {}} if legacy or bad else {
                'artifactflow-artifact': {}, 'artifactflow-artifact-ingress': {}}
            if '{{len .NetworkSettings.Networks}}' in args:
                print(len(networks))
            else: print(json.dumps(networks))
        elif os.environ.get('AF_TEST_UNHEALTHY_PROCESSOR', '') in args and os.environ.get('AF_TEST_UNHEALTHY_PROCESSOR', ''):
            print('unhealthy')
        else: print('healthy')
    elif args[0] == 'exec':
        if 'cat' in args: print('synthetic-public-ca')
        if '-i' in args: sys.stdin.read()
        if '-f' in args: sys.exit(int(os.environ.get('AF_TEST_GRANTS_PSQL_EXIT', '0')))
        if any('SELECT 1 FROM public.pages LIMIT 0' in a for a in args):
            sys.exit(int(os.environ.get('AF_TEST_ARTIFACT_ROLE_READ_EXIT', '0')))
        if any('artifactflow:doctor' in a for a in args):
            sys.exit(int(os.environ.get('AF_TEST_DOCTOR_EXIT', '0')))
elif name == 'systemctl':
    if 'daemon-reload' in args: sys.exit(int(os.environ.get('AF_TEST_RELOAD_EXIT', '0')))
    if 'restart' in args and 'artifactflow-postgres' in args:
        pathlib.Path(os.environ['AF_TEST_LOG'] + '.postgres-reattached').touch()
    if 'restart' in args and 'artifactflow-artifact-host' in args:
        pathlib.Path(os.environ['AF_TEST_LOG'] + '.artifact-host-restarted').touch()
elif name == 'sleep': pass
elif name == 'gh':
    processor = os.environ.get('AF_TEST_VERIFY_PROCESSOR', '').lower()
    if processor and any(f'artifactflow-{processor}-processor@' in a for a in args): sys.exit(1)
    sys.exit(int(os.environ.get('AF_TEST_VERIFY_EXIT', '0')))
elif name == 'curl':
    if any('artifact-host-database-grants.sql' in a for a in args):
        if int(os.environ.get('AF_TEST_GRANTS_FETCH_EXIT', '0')): sys.exit(22)
        if not int(os.environ.get('AF_TEST_GRANTS_EMPTY', '0')): print('-- synthetic grants')
    elif any('127.0.0.1:8081' in a for a in args):
        if int(os.environ.get('AF_TEST_ARTIFACT_PORT_EXIT', '0')): sys.exit(7)
        print(os.environ.get('AF_TEST_ARTIFACT_HTTP_STATUS', '404'))
    else: print('192.0.2.20')
elif name == 'openssl':
    if args[:2] == ['rand', '-base64']: print(base64.b64encode(secrets.token_bytes(int(args[2]))).decode())
    elif args[:2] == ['rand', '-hex']: print(secrets.token_hex(int(args[2])))
    else: sys.exit(2)
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
            # CFG is now env-driven (ARTIFACTFLOW_CONFIG_DIR); leave the
            # /etc/artifactflow literals (container path + host-rewrite rules) intact.
            content = (ROOT/name).read_text().replace('$HOME/.config/containers/systemd', str(self.units))
            content = content.replace('.env', '.fixture')
            (self.repo/name).write_text(content)
        for name in ('id', 'uname', 'podman', 'systemctl', 'gh', 'curl', 'openssl', 'sleep'):
            target = self.bin/name
            target.write_text(MOCK)
            target.chmod(0o755)
        self.log = self.base/'commands.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'],
                        AF_TEST_LOG=str(self.log), ARTIFACTFLOW_CONFIG_DIR=str(self.cfg))

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

    def test_enable_reverb_wires_app_origin_socket_with_dedicated_secret(self):
        self.existing()
        before = settings(self.cfg/'app.fixture')
        result = self.run_script('install.sh', '--enable-reverb')
        self.assertEqual(result.returncode, 0, result.stdout)
        after = settings(self.cfg/'app.fixture')
        for key in ('APP_KEY', 'IMAGE_PARSER_SHARED_SECRET'):
            self.assertEqual(before[key], after[key])
        self.assertEqual(after['BROADCAST_CONNECTION'], 'reverb')
        self.assertTrue(after['REVERB_APP_SECRET'])
        self.assertNotIn(after['REVERB_APP_SECRET'],
                         (after['APP_KEY'], after.get('ARTIFACT_URL_SIGNING_KEY', '')))
        # Both public origins must equal the app origin; the internal publish
        # target is the reverb container, never the artifact host.
        self.assertEqual(after['REVERB_PUBLIC_URL'], after['APP_URL'])
        self.assertEqual(after['REVERB_ALLOWED_ORIGINS'], after['APP_URL'])
        self.assertEqual(after['REVERB_HOST'], 'artifactflow-reverb')
        self.assertEqual(after['REVERB_APP_RATE_LIMITING_ENABLED'], 'true')
        self.assertTrue((self.units/'artifactflow-reverb.container').exists())
        calls = self.calls()
        doctor = next(i for i, c in enumerate(calls) if any('artifactflow:doctor' in a for a in c))
        self.assertTrue(any(c[:3] == ['systemctl', '--user', 'restart'] and 'artifactflow-reverb' in c[3:]
                            for c in calls[:doctor]), 'reverb restarted before doctor')
        # Idempotent: re-enabling keeps the same secret and the same config.
        result = self.run_script('install.sh', '--enable-reverb')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(after, settings(self.cfg/'app.fixture'))

    def test_enable_reverb_is_not_committed_when_image_verification_fails(self):
        self.existing()
        before = (self.cfg/'app.fixture').read_bytes()
        self.env['AF_TEST_VERIFY_EXIT'] = '1'
        result = self.run_script('install.sh', '--enable-reverb')
        self.assertNotEqual(result.returncode, 0)
        # A failed attestation must not leave BROADCAST_CONNECTION=reverb behind
        # without the reverb unit, and must not install or start anything.
        self.assertEqual(before, (self.cfg/'app.fixture').read_bytes())
        self.assertFalse((self.units/'artifactflow-reverb.container').exists())
        self.assertFalse(any(c[0] == 'systemctl' for c in self.calls()))

    def test_enable_reverb_is_not_committed_when_unit_registration_fails(self):
        self.existing()
        before = (self.cfg/'app.fixture').read_bytes()
        self.env['AF_TEST_RELOAD_EXIT'] = '1'
        result = self.run_script('install.sh', '--enable-reverb')
        self.assertNotEqual(result.returncode, 0)
        # A daemon-reload failure (reverb unit not registered with systemd) must
        # not persist BROADCAST_CONNECTION=reverb: the config is committed only
        # after the unit is copied and registered.
        self.assertEqual(before, (self.cfg/'app.fixture').read_bytes())

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

    def test_grants_manifest_uses_pinned_release_commit(self):
        self.existing()
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stdout)
        source_commit = next(line.split('=', 1)[1] for line in
                             (self.repo/'Dockerfile.image-parser').read_text().splitlines()
                             if line.startswith('ARG ARTIFACTFLOW_COMMIT='))
        expected = ('https://raw.githubusercontent.com/Gadsotek/artifactflow/'
                    f'{source_commit}/docs/operations/artifact-host-database-grants.sql')
        grants_curls = [call for call in self.calls() if call[0] == 'curl' and
                        any('artifact-host-database-grants.sql' in arg for arg in call)]
        self.assertEqual([['curl', '-fsSL', expected]], grants_curls)

    def _assert_grants_failure_stops_install(self, failure):
        self.existing()
        self.env[failure] = '1'
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('DONE on the server side', result.stdout)
        self.assertFalse(any(call[:3] == ['systemctl', '--user', 'restart'] and
                             'artifactflow-artifact-host' in call[3:] for call in self.calls()))

    def test_grants_fetch_failure_stops_install_before_artifact_host(self):
        self._assert_grants_failure_stops_install('AF_TEST_GRANTS_FETCH_EXIT')

    def test_empty_grants_response_stops_install_before_artifact_host(self):
        self._assert_grants_failure_stops_install('AF_TEST_GRANTS_EMPTY')

    def test_grants_psql_failure_stops_install_before_artifact_host(self):
        self._assert_grants_failure_stops_install('AF_TEST_GRANTS_PSQL_EXIT')

    def test_artifact_role_read_failure_stops_install_before_artifact_host(self):
        self._assert_grants_failure_stops_install('AF_TEST_ARTIFACT_ROLE_READ_EXIT')

    def test_installer_rejects_role_name_not_used_by_pinned_manifest(self):
        self.existing()
        path = self.cfg/'artifact-host.fixture'
        path.write_text(path.read_text().replace('DB_USERNAME=artifactflow_artifact_host',
                                                'DB_USERNAME=another_role'))
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('requires DB_USERNAME=artifactflow_artifact_host', result.stdout)
        self.assertNotIn('DONE on the server side', result.stdout)
        self.assertFalse(any(call[:3] == ['systemctl', '--user', 'restart'] and
                             'artifactflow-artifact-host' in call[3:] for call in self.calls()))

    def _assert_failed_processor_attestation_preserves_config(self, kind, expected_units):
        self.existing()
        before = (self.cfg/'app.fixture').read_bytes()
        self.env['AF_TEST_VERIFY_PROCESSOR'] = kind
        result = self.run_script('install.sh', f'--enable-{kind.lower()}')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f'{kind} processor attestation verification failed', result.stdout)
        self.assertTrue(before == (self.cfg/'app.fixture').read_bytes(),
                        f'{kind} attestation failure changed app configuration')
        for unit in expected_units:
            self.assertFalse((self.units/f'artifactflow-{unit}-processor.container').exists())
        self.assertFalse(any(call[0] == 'systemctl' for call in self.calls()))

    def test_failed_pdf_attestation_does_not_enable_pdf(self):
        self._assert_failed_processor_attestation_preserves_config('PDF', ('pdf',))

    def test_failed_xlsx_attestation_does_not_enable_xlsx(self):
        self._assert_failed_processor_attestation_preserves_config('XLSX', ('xlsx',))

    def test_failed_docx_attestation_does_not_enable_docx_or_pdf(self):
        self._assert_failed_processor_attestation_preserves_config('DOCX', ('docx', 'pdf'))

    def test_unhealthy_new_processor_does_not_enable_format(self):
        self.existing()
        before = (self.cfg/'app.fixture').read_bytes()
        self.env['AF_TEST_UNHEALTHY_PROCESSOR'] = 'artifactflow-xlsx-processor'
        result = self.run_script('install.sh', '--enable-xlsx')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('did not become healthy', result.stdout)
        self.assertEqual(before, (self.cfg/'app.fixture').read_bytes())

    def _assert_legacy_postgres_network_is_refreshed(self, script, *args):
        self.existing()
        self.env['AF_TEST_POSTGRES_LEGACY_NETWORK'] = '1'
        result = self.run_script(script, *args)
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        postgres_restart = next((i for i, call in enumerate(calls)
                                 if call[:3] == ['systemctl', '--user', 'restart'] and
                                 'artifactflow-postgres' in call[3:]), None)
        artifact_host_restart = next((i for i, call in enumerate(calls)
                                      if call[:3] == ['systemctl', '--user', 'restart'] and
                                      'artifactflow-artifact-host' in call[3:]), None)
        self.assertIsNotNone(postgres_restart, 'legacy PostgreSQL network was not refreshed')
        self.assertIsNotNone(artifact_host_restart, 'artifact host was not restarted')
        self.assertLess(postgres_restart, artifact_host_restart)

    def test_install_refreshes_legacy_postgres_network_before_artifact_host(self):
        self._assert_legacy_postgres_network_is_refreshed('install.sh')

    def test_deploy_refreshes_legacy_postgres_network_before_artifact_host(self):
        self._assert_legacy_postgres_network_is_refreshed('deploy.sh', '--no-pull')

    def test_deploy_keeps_postgres_running_when_artifact_network_is_present(self):
        self.existing()
        result = self.run_script('deploy.sh', '--no-pull')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:3] == ['systemctl', '--user', 'restart'] and
                             'artifactflow-postgres' in call[3:] for call in self.calls()))

    def test_failed_postgres_network_reattachment_stops_before_artifact_host(self):
        self.existing()
        self.env['AF_TEST_POSTGRES_LEGACY_NETWORK'] = '1'
        self.env['AF_TEST_POSTGRES_REATTACH_FAIL'] = '1'
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('did not join the isolated artifact database network', result.stdout)
        self.assertFalse(any(call[:3] == ['systemctl', '--user', 'restart'] and
                             'artifactflow-artifact-host' in call[3:] for call in self.calls()))

    def test_cni_backend_is_rejected_before_processor_enablement(self):
        self.existing()
        before = (self.cfg/'app.fixture').read_bytes()
        self.env['AF_TEST_NETWORK_BACKEND'] = 'cni'
        result = self.run_script('install.sh', '--enable-xlsx')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(before == (self.cfg/'app.fixture').read_bytes(),
                        'unsupported network backend changed app configuration')
        self.assertFalse((self.units/'artifactflow-xlsx-processor.container').exists())
        self.assertFalse(any(call[0] == 'systemctl' for call in self.calls()))

    def test_non_internal_artifact_network_stops_before_artifact_host(self):
        self.existing()
        self.env['AF_TEST_ARTIFACT_NETWORK_INTERNAL'] = '0'
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('DONE on the server side', result.stdout)
        self.assertFalse(any(call[:3] == ['systemctl', '--user', 'restart'] and
                             'artifactflow-artifact-host' in call[3:] for call in self.calls()))

    def test_failed_network_preflight_leaves_legacy_artifact_host_stopped(self):
        self.existing()
        self.env['AF_TEST_LEGACY_ARTIFACT_HOST'] = '1'
        self.env['AF_TEST_ARTIFACT_NETWORK_INTERNAL'] = '0'
        for script, args in (('install.sh', ()), ('deploy.sh', ('--no-pull',))):
            result = self.run_script(script, *args)
            self.assertNotEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        stops = [i for i, call in enumerate(calls) if
                 call == ['systemctl', '--user', 'stop', 'artifactflow-artifact-host']]
        self.assertEqual(len(stops), 2)
        for stop in stops:
            self.assertTrue(any(call[:3] == ['systemctl', '--user', 'start'] and
                                'artifactflow-artifact-network' in call[3:]
                                for call in calls[stop+1:]))
        self.assertFalse(any(call[:3] == ['systemctl', '--user', 'restart'] and
                             'artifactflow-artifact-host' in call[3:] for call in calls))

    def test_misnetworked_restarted_artifact_host_is_stopped(self):
        self.existing()
        self.env['AF_TEST_EFFECTIVE_HOST_NETWORK_BAD'] = '1'
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('did not start on exactly its two internal networks', result.stdout)
        calls = self.calls()
        restart = next(i for i, call in enumerate(calls) if
                       call[:3] == ['systemctl', '--user', 'restart'] and
                       'artifactflow-artifact-host' in call[3:])
        self.assertTrue(any(call == ['systemctl', '--user', 'stop',
                                     'artifactflow-artifact-ingress',
                                     'artifactflow-artifact-host']
                            for call in calls[restart+1:]))

    def test_inaccessible_artifact_loopback_port_stops_install(self):
        self.existing()
        self.env['AF_TEST_ARTIFACT_PORT_EXIT'] = '1'
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('DONE on the server side', result.stdout)

    def test_inaccessible_artifact_loopback_port_stops_deploy(self):
        self.existing()
        self.env['AF_TEST_ARTIFACT_PORT_EXIT'] = '1'
        result = self.run_script('deploy.sh', '--no-pull')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('Deployed v', result.stdout)

    def test_artifact_loopback_probe_requires_expected_host_and_404(self):
        self.existing()
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stdout)
        probe = next(call for call in self.calls() if call[0] == 'curl' and
                     'http://127.0.0.1:8081/login' in call)
        self.assertIn('Host: artifacts.example.com', probe)
        self.env['AF_TEST_ARTIFACT_HTTP_STATUS'] = '500'
        result = self.run_script('deploy.sh', '--no-pull')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('returned HTTP 500', result.stdout)


if __name__ == '__main__':
    unittest.main()
