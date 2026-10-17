#!/usr/bin/env python3
"""Drive a live Skotiq rig over the headless REST API and record what it does.

Why this exists
---------------
The owner's rule is that no bug gets fixed on the strength of reading code — a
finding has to be reproduced in the running app first. For hardware-facing
behaviour that is impossible from a workstation: the only place the ZWO camera,
the mount, the wheel and the focuser exist is the imaging laptop. This is the
reproduction harness for that half of the app.

It is deliberately READ-HEAVY and cautious about motion. Every write it performs
is either reversible (a filter slot, a small focuser step, cooling setpoint) or
explicitly opted into with a flag. It never slews.

Usage
-----
    python3 tools/live_rig/drive_api.py --host 192.168.1.50 --token <token>
    python3 tools/live_rig/drive_api.py --host … --token … --expose 2.0
    python3 tools/live_rig/drive_api.py --host … --token … --move-focuser 50

Everything it observes is appended to reports/live-rig/<timestamp>.json so a
finding can cite what the rig actually returned rather than what the code says
it should.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

DEVICE_TYPES = [
    'camera', 'mount', 'focuser', 'filterwheel', 'rotator',
    'dome', 'weather', 'safetymonitor', 'switch', 'covercalibrator',
]


class Rig:
    def __init__(self, host, port, token, timeout=30):
        self.base = 'http://%s:%d' % (host, port)
        self.token = token
        self.timeout = timeout
        self.log = []

    def call(self, method, path, body=None, timeout=None):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header('Content-Type', 'application/json')
        if self.token:
            req.add_header('Authorization', 'Bearer ' + self.token)
        started = time.time()
        entry = {'method': method, 'path': path, 'body': body}
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                raw = r.read().decode('utf-8', 'replace')
                entry['status'] = r.status
        except urllib.error.HTTPError as e:
            raw = e.read().decode('utf-8', 'replace')
            entry['status'] = e.code
        except Exception as e:                       # noqa: BLE001
            entry['status'] = None
            entry['error'] = str(e)
            entry['elapsed_ms'] = int((time.time() - started) * 1000)
            self.log.append(entry)
            return entry
        entry['elapsed_ms'] = int((time.time() - started) * 1000)
        try:
            entry['json'] = json.loads(raw)
        except ValueError:
            entry['text'] = raw[:2000]
        self.log.append(entry)
        return entry


def show(entry, label=None):
    tag = label or ('%s %s' % (entry['method'], entry['path']))
    if entry.get('error'):
        print('  %-46s ERROR %s' % (tag, entry['error'][:80]))
        return
    payload = entry.get('json', entry.get('text', ''))
    text = json.dumps(payload) if not isinstance(payload, str) else payload
    print('  %-46s %s  %s' % (tag, entry['status'], text[:150]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', required=True)
    ap.add_argument('--port', type=int, default=8080)
    ap.add_argument('--token', default=os.environ.get('SKOTIQ_TOKEN', ''))
    ap.add_argument('--expose', type=float, default=0.0,
                    help='take a light frame of this many seconds (0 = skip)')
    ap.add_argument('--move-focuser', type=int, default=0,
                    help='relative focuser steps to move and then undo')
    ap.add_argument('--set-filter', type=int, default=-1,
                    help='filter slot to select (-1 = skip)')
    ap.add_argument('--out', default='reports/live-rig')
    args = ap.parse_args()

    rig = Rig(args.host, args.port, args.token)

    print('== system')
    for path in ('/api/system/version', '/api/system/health',
                 '/api/system/disk-space', '/api/system/endpoints'):
        show(rig.call('GET', path))

    print('== discovery (per type)')
    found = {}
    for t in DEVICE_TYPES:
        e = rig.call('GET', '/api/devices?type=' + t, timeout=90)
        payload = e.get('json')
        devices = payload.get('devices', payload) if isinstance(payload, dict) else payload
        n = len(devices) if isinstance(devices, list) else '?'
        print('  %-18s %s  %s' % (t, e['status'], n))
        if isinstance(devices, list) and devices:
            found[t] = devices
            for d in devices:
                if isinstance(d, dict):
                    print('        %s  [%s]' % (d.get('displayName') or d.get('name'),
                                                d.get('driverType') or d.get('driver')))

    print('== already connected')
    show(rig.call('GET', '/api/devices/connected'))

    print('== camera')
    for path in ('/api/camera/cooling', '/api/camera/gain', '/api/camera/offset',
                 '/api/camera/readout-modes', '/api/camera/recommended-settings'):
        show(rig.call('GET', path))

    if args.set_filter >= 0:
        print('== filter wheel')
        show(rig.call('POST', '/api/filterwheel/position',
                      {'position': args.set_filter}, timeout=120))
        show(rig.call('GET', '/api/filterwheel/position'))

    if args.move_focuser:
        print('== focuser (relative move, then undone)')
        before = rig.call('GET', '/api/focuser/position')
        show(before, 'position before')
        show(rig.call('POST', '/api/focuser/move-relative',
                      {'steps': args.move_focuser}, timeout=180))
        show(rig.call('GET', '/api/focuser/position'), 'position after')
        show(rig.call('POST', '/api/focuser/move-relative',
                      {'steps': -args.move_focuser}, timeout=180), 'undo')

    if args.expose > 0:
        print('== exposure %.2fs' % args.expose)
        show(rig.call('POST', '/api/camera/expose',
                      {'exposureSeconds': args.expose, 'frameType': 'light'},
                      timeout=args.expose + 180))
        time.sleep(min(args.expose + 3, 60))
        show(rig.call('GET', '/api/camera/last-image'), 'last-image metadata')

    os.makedirs(args.out, exist_ok=True)
    stamp = time.strftime('%Y%m%dT%H%M%S')
    path = os.path.join(args.out, '%s.json' % stamp)
    with open(path, 'w') as fh:
        json.dump({'host': args.host, 'calls': rig.log}, fh, indent=2)
    print('\nwrote %s (%d calls)' % (path, len(rig.log)))

    bad = [c for c in rig.log if c.get('error') or (c.get('status') or 0) >= 500]
    if bad:
        print('\n%d call(s) errored or returned 5xx:' % len(bad))
        for c in bad:
            print('  %s %s -> %s %s' % (c['method'], c['path'],
                                        c.get('status'), c.get('error', '')[:80]))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
