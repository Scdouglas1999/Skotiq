#!/usr/bin/env python3
"""Check the actual Linux archive in the canonical Bookworm appliance."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


def validate_fits(data):
    header = {}
    data_offset = None
    for at in range(0, len(data) - 79, 80):
        card = data[at:at + 80].decode('ascii')
        key = card[:8].strip()
        if key == 'END':
            data_offset = ((at + 80 + 2879) // 2880) * 2880
            break
        if card[8] == '=':
            header[key] = card[10:].split('/')[0].strip().strip("'").rstrip()
    expected = {'SIMPLE': 'T', 'BITPIX': '16', 'NAXIS': '2',
                'NAXIS1': '128', 'NAXIS2': '96', 'OBJECT': 'Package smoke simulator'}
    for key, value in expected.items():
        if header.get(key) != value:
            raise ValueError(f'FITS {key}: expected {value}, got {header.get(key)}')
    if float(header.get('EXPTIME', 'nan')) != 0.01 or not header.get('DATE-OBS'):
        raise ValueError('FITS exposure metadata is missing or incorrect')
    if data_offset is None or len(data) < data_offset + 128 * 96 * 2:
        raise ValueError('FITS pixel payload is truncated')
    return header


def verify(args):
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    label = 'skotiq-package-smoke-' + uuid.uuid4().hex[:10]
    image = label + ':test'
    runtime = label + '-runtime'
    closure = label + '-closure'
    report = {'archive': str(args.archive.resolve()), 'source': args.source,
              'sha256': hashlib.sha256(args.archive.read_bytes()).hexdigest(),
              'image': image, 'status': 'running'}

    def run(command, timeout=60, **kwargs):
        return subprocess.run(command, check=True, timeout=timeout, **kwargs)

    def api(path, body=None):
        command = ['docker', 'exec', runtime, 'curl', '-fsS', '--max-time', '30',
                   '-H', 'Authorization: Bearer package-smoke-admin',
                   '-H', 'Content-Type: application/json']
        if body is not None:
            command += ['-X', 'POST', '--data-binary', json.dumps(body)]
        command += ['http://127.0.0.1:8080' + path]
        return json.loads(run(command, capture_output=True, text=True).stdout)

    limits = ['--network=none', '--read-only', '--cap-drop=ALL',
              '--security-opt=no-new-privileges', '--cpus=2.5', '--memory=4g',
              '--memory-swap=4g', '--pids-limit=512']
    try:
        with tempfile.TemporaryDirectory(prefix=label) as temporary:
            context = Path(temporary)
            shutil.copytree(root / 'packaging/appliance/docker',
                            context / 'packaging/appliance/docker')
            shutil.copy2(args.archive, context / 'release.tar.gz')
            with (out / 'build.log').open('w') as log:
                run(['docker', 'build', '--cpu-period=100000', '--cpu-quota=250000',
                     '--memory=4g', '--memory-swap=4g', '--rm=true',
                     '-f', 'packaging/appliance/docker/Dockerfile', '--build-arg',
                     'BUNDLE_TARBALL=release.tar.gz', '-t', image, '.'],
                    timeout=600, cwd=context,
                    env={**os.environ, 'DOCKER_BUILDKIT': '0'},
                    stdout=log, stderr=subprocess.STDOUT)
        (out / 'image.json').write_text(run(
            ['docker', 'image', 'inspect', image], capture_output=True, text=True).stdout)

        # Check every bundled ELF, including versioned SONAMEs. glibc's version
        # floor alone cannot find a missing JPEG ABI on the target distribution.
        closure_script = r'''
set -eu
cd /opt/skotiq/bundle
test "$(cat SOURCE-COMMIT.txt)" = "$EXPECTED_SOURCE"
export LD_LIBRARY_PATH="$PWD/lib"
for binary in ./skotiq.bin ./updater ./lib/*.so ./lib/*.so.*; do
  test -f "$binary" || continue
  printf '\n== %s ==\n' "$binary"
  dependencies=$(ldd "$binary" 2>&1) || { printf '%s\n' "$dependencies"; exit 1; }
  printf '%s\n' "$dependencies"
  if printf '%s\n' "$dependencies" | grep -F 'not found'; then exit 1; fi
done
./updater --help
'''
        with (out / 'dependency-closure.log').open('w') as log:
            run(['docker', 'run', '--rm', '--name', closure, *limits,
                 '-e', 'EXPECTED_SOURCE=' + args.source,
                 '--entrypoint', '/bin/sh', image, '-c', closure_script],
                stdout=log, stderr=subprocess.STDOUT)
        report['dependency_closure'] = 'passed'

        run(['docker', 'create', '--name', runtime, *limits,
             '--tmpfs', '/tmp:rw,nosuid,size=1g',
             '--tmpfs', '/var/lib/skotiq:rw,nosuid,uid=947,gid=947,mode=750,size=1g',
             '-e', 'LIBGL_ALWAYS_SOFTWARE=1', '-e', 'GALLIUM_DRIVER=softpipe',
             '-e', 'NO_AT_BRIDGE=1', '-e', 'GTK_MODULES=',
             '-e', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus',
             '-e', 'SKOTIQ_AUTH_TOKEN=package-smoke-admin',
             '-e', 'SKOTIQ_BROWSE_ROOTS=Smoke=/var/lib/skotiq/captures', image],
            stdout=subprocess.DEVNULL)
        run(['docker', 'start', runtime], stdout=subprocess.DEVNULL)
        deadline = time.monotonic() + 90
        while True:
            state = run(['docker', 'inspect', '--format', '{{.State.Running}}', runtime],
                        capture_output=True, text=True).stdout.strip()
            if state != 'true':
                raise RuntimeError('Canonical appliance entrypoint exited before API readiness')
            try:
                info = api('/api/info')
                break
            except subprocess.CalledProcessError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('Packaged host did not become ready within90seconds')
                time.sleep(1)
        version = api('/api/system/version')
        if (info.get('version') != args.version or
                version.get('currentVersion') != args.version or
                version.get('buildNumber') != args.build_number):
            raise ValueError(f'Unexpected package version: {version}')
        run(['docker', 'exec', runtime, '/usr/local/bin/skotiq-healthcheck'])
        run(['docker', 'exec', runtime, 'mkdir', '-p', '/var/lib/skotiq/captures'])
        camera = {'deviceId': 'sim_camera_1', 'deviceType': 'camera'}
        if api('/api/devices/connect', camera).get('status') != 'connected':
            raise RuntimeError('Named simulator did not connect')
        exposed = api('/api/camera/expose', {
            'deviceId': 'sim_camera_1', 'exposureTime': 0.01, 'frameType': 'light',
            'binX': 1, 'binY': 1, 'x': 0, 'y': 0, 'width': 128, 'height': 96})
        if exposed.get('status') != 'complete':
            raise RuntimeError(f'Simulator exposure failed: {exposed}')
        saved = api('/api/imaging/save-fits-from-capture', {
            'deviceId': 'sim_camera_1', 'filePath': '/var/lib/skotiq/captures/simulator.fits',
            'keepCameraFile': False, 'headerData': {
                'objectName': 'Package smoke simulator', 'exposureTime': 0.01,
                'captureTimestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'frameType': 'Light', 'binX': 1, 'binY': 1}})
        if saved.get('status') != 'saved':
            raise RuntimeError(f'Simulator FITS save failed: {saved}')
        fits = out / 'simulator.fits'
        # Read inside the container's mount namespace: Docker's archive/cp
        # path does not consistently expose files held on a tmpfs mount.
        with fits.open('wb') as output:
            run(['docker', 'exec', runtime, 'cat',
                 '/var/lib/skotiq/captures/simulator.fits'], stdout=output)
        report['fits_header'] = validate_fits(fits.read_bytes())
        report['fits_sha256'] = hashlib.sha256(fits.read_bytes()).hexdigest()
        if api('/api/devices/disconnect', camera).get('status') != 'disconnected':
            raise RuntimeError('Simulator did not disconnect')
        report.update(status='passed', runtime_version=version,
                      native_simulator_capture='passed', healthcheck='passed')
    except Exception as error:
        report.update(status='failed', error=str(error))
        raise
    finally:
        with (out / 'runtime.log').open('w') as log:
            subprocess.run(['docker', 'logs', runtime], stdout=log, stderr=subprocess.STDOUT)
        for name in [runtime, closure]:
            subprocess.run(['docker', 'stop', '--timeout', '10', name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['docker', 'rm', '-f', name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'image', 'rm', image],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Bookworm package dependency closure and native simulator FITS smoke passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--source', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True, type=int)
    parser.add_argument('--output-dir', required=True, type=Path)
    verify(parser.parse_args())
