#!/usr/bin/env python3
"""Native Linux health and Unix socket permission checks, using throwaway containers.

Build the local parser/adapter images first. Defaults match install.sh's tags.
No application database or existing container/volume is touched.
"""
import json
import os
from pathlib import Path
import secrets
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
ENGINE = os.environ.get('CONTAINER_ENGINE', 'podman')
LOCK = dict(line.split('=', 1) for line in (ROOT/'processor-images.lock').read_text().splitlines()
            if line and not line.startswith('#'))
IMAGES = {
    'pdf': os.environ.get('PDF_TEST_IMAGE', 'localhost/artifactflow-pdf-processor:pinned'),
    'image': os.environ.get('IMAGE_TEST_IMAGE', 'localhost/artifactflow-image-parser:pinned'),
    'xlsx': LOCK['XLSX_PROCESSOR_IMAGE'],
    'docx': LOCK['DOCX_PROCESSOR_IMAGE'],
}
LIMITS = {'image': ('512m', '32', '16m'), 'pdf': ('512m', '32', '32m'),
          'xlsx': ('384m', '32', '64m'), 'docx': ('768m', '128', '192m')}
GIDS = {'image': 10001, 'pdf': 10002, 'xlsx': 10003, 'docx': 10004}


def run(*args, env=None, check=True):
    result = subprocess.run([ENGINE, *args], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=240)
    if check and result.returncode:
        raise RuntimeError(result.stderr[-1200:] + result.stdout[-1200:])
    return result


containers, volumes, failures = [], [], []
try:
    for kind, image in IMAGES.items():
        name = 'af-podman-proof-'+kind+'-'+secrets.token_hex(5)
        volume = name+'-socket'
        volumes.append(volume)
        run('volume', 'create', volume)
        gid = GIDS[kind]
        run('run', '--rm', '--network', 'none', '--read-only', '--cap-drop', 'ALL',
            '--cap-add', 'CHOWN', '--cap-add', 'FOWNER', '--security-opt', 'no-new-privileges',
            '--user', '0:0', '--entrypoint', '/bin/sh', '-v', volume+':/socket', image,
            '-c', f'chmod 0755 /socket && chown {gid}:{gid} /socket')
        memory, pids, tmp = LIMITS[kind]
        directory = 'image-parser' if kind == 'image' else kind+'-processor'
        filename = 'parser.sock' if kind == 'image' else 'processor.sock'
        prefix = 'IMAGE_PARSER' if kind == 'image' else kind.upper()+'_PROCESSOR'
        socket = '/run/artifactflow/'+directory+'/'+filename
        # Fresh test credentials pass through the environment, never command arguments.
        env = dict(os.environ, **{prefix+'_SHARED_SECRET': secrets.token_hex(32)})
        flags = ['run', '-d', '--name', name, '--network', 'none', '--read-only',
                 '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                 '--memory', memory, '--cpus', '1.0', '--pids-limit', pids,
                 '--tmpfs', f'/tmp:rw,noexec,nosuid,nodev,size={tmp},mode=1777',
                 '-v', volume+':/run/artifactflow/'+directory,
                 '-e', prefix+'_SHARED_SECRET', '-e', prefix+'_SOCKET_PATH='+socket]
        if kind == 'docx':
            flags += ['--ulimit', 'nofile=256:256']
        containers.append(name)
        run(*flags, image, env=env)
        if kind == 'xlsx':
            health = ['node', '/srv/xlsx-processor-spike/healthcheck.cjs']
        else:
            folder = {'image': 'image-parser', 'pdf': 'pdf-processor-spike', 'docx': 'docx-processor'}[kind]
            health = ['php', '/srv/'+folder+'/healthcheck.php']
        healthy = False
        for attempt in range(30):
            if run('exec', name, *health, check=False).returncode == 0:
                healthy = True
                break
            if run('inspect', '-f', '{{.State.Running}}', name).stdout.strip() != 'true':
                break
            time.sleep(2)
        if not healthy:
            logs = run('logs', '--tail', '12', name, check=False)
            print(kind+': FAILED health; '+logs.stdout+logs.stderr, flush=True)
            failures.append(kind)
            continue
        # The published Alpine app runs as www-data (82). A read-only volume
        # alone must not authorize a connection; its matching group must do so.
        client = ['run', '--rm', '--network', 'none', '--cap-drop', 'ALL',
                  '--security-opt', 'no-new-privileges', '--user', '82:82',
                  '--entrypoint', 'php', '-v', volume+':/socket:ro']
        probe = f'$s=@stream_socket_client("unix:///socket/{filename}",$e,$m,2);exit(is_resource($s)?0:1);'
        denied = run(*client, IMAGES['pdf'], '-r', probe, check=False)
        allowed = run(*client, '--group-add', str(gid), IMAGES['pdf'], '-r', probe, check=False)
        if denied.returncode != 1 or allowed.returncode != 0:
            raise RuntimeError(kind+': socket group permission boundary failed')
        info = json.loads(run('inspect', name).stdout)[0]['HostConfig']
        if info['NetworkMode'] != 'none' or not info['ReadonlyRootfs']:
            raise RuntimeError(kind+': runtime isolation differs from the unit')
        print(kind+': health and socket permission boundary OK', flush=True)
finally:
    for name in containers:
        run('rm', '-f', name, check=False)
    for volume in volumes:
        run('volume', 'rm', volume, check=False)

if failures:
    raise SystemExit('Failed processor runtime checks: '+', '.join(failures))
