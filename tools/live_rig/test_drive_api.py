"""drive_api.py against a fake host that serves the real route table.

The fake host answers every route declared in
packages/skotiq_remote_protocol/lib/src/wire/routes/ and 404s anything else,
the way the headless server does.
"""
import contextlib
import io
import json
import re
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ROUTES = ROOT / 'packages' / 'skotiq_remote_protocol' / 'lib' / 'src' / 'wire' / 'routes'
sys.path.insert(0, str(HERE))
import drive_api  # noqa: E402


def declared_routes():
    """(METHOD, OpenAPI path) for every ApiRoute in the Dart route table."""
    routes = set()
    for source in ROUTES.glob('*.dart'):
        for method, path in re.findall(
                r"ApiRoute\.(get|post|put|delete|patch)\(\s*'([^']+)'", source.read_text()):
            routes.add((method.upper(), re.sub(r'<([^>|]+)(?:\|[^>]+)?>', r'{\1}', path)))
    return routes


CONNECTED = {'devices': [
    {'id': 'native:zwo:0', 'deviceType': 'camera'},
    {'id': 'native:zwo_efw:0', 'deviceType': 'filterWheel'},
    {'id': 'native:zwo_eaf:0', 'deviceType': 'focuser'},
]}


class FakeHost(ThreadingHTTPServer):
    def __init__(self, routes, missing=()):
        super().__init__(('127.0.0.1', 0), Handler)
        self.routes = [
            (method, re.compile('^' + re.sub(r'\{[^}]+\}', '[^/]+', path) + '$'))
            for method, path in routes]
        self.listed = routes
        self.missing = set(missing)
        self.requests = []
        self.not_found = []

    @staticmethod
    def spec(routes):
        paths = {}
        for method, path in routes:
            paths.setdefault(path, {})[method.lower()] = {}
        return {'paths': paths}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self):
        host = self.server
        path = self.path.split('?')[0]
        host.requests.append((self.command, self.path))
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        known = any(m == self.command and r.match(path) for m, r in host.routes)
        if path == '/api/info':
            status, body = 200, {'version': '9.1.0'}
        elif not known or (self.command, path) in host.missing:
            status, body = 404, {'error': 'not_found'}
            host.not_found.append((self.command, path))
        elif path == '/api/openapi.json':
            status, body = 200, FakeHost.spec(host.listed)
        elif path == '/api/devices/connected':
            status, body = 200, CONNECTED
        else:
            status, body = 200, {'status': 'ok'}
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_DELETE = answer


@contextlib.contextmanager
def fake_host(routes, missing=()):
    host = FakeHost(routes, missing)
    thread = threading.Thread(target=host.serve_forever, daemon=True)
    thread.start()
    try:
        yield host
    finally:
        host.shutdown()
        host.server_close()


def run_driver(host, *extra):
    with tempfile.TemporaryDirectory() as out:
        argv = ['drive_api.py', '--host', '127.0.0.1', '--port', str(host.server_address[1]),
                '--token', 't', '--out', out, *extra]
        with mock.patch.object(sys, 'argv', argv), mock.patch.object(drive_api.time, 'sleep'), \
                contextlib.redirect_stdout(io.StringIO()) as printed:
            code = drive_api.main()
    return code, printed.getvalue()


ALL_STEPS = ('--expose', '1', '--move-focuser', '10', '--set-filter', '2')


class DriveApiTest(unittest.TestCase):
    def test_every_call_is_a_declared_route(self):
        with fake_host(declared_routes()) as host:
            code, printed = run_driver(host, *ALL_STEPS)
        self.assertEqual(host.not_found, [])
        self.assertEqual(code, 0, printed)
        self.assertGreater(len(host.requests), 10)

    def test_a_404_fails_the_run(self):
        with fake_host(declared_routes(), missing={('GET', '/api/system/disk-space')}) as host:
            code, printed = run_driver(host)
        self.assertEqual(code, 1)
        self.assertIn('/api/system/disk-space -> 404', printed)

    def test_a_path_outside_the_route_table_is_not_sent(self):
        routes = declared_routes() - {('GET', '/api/status')}
        with fake_host(routes) as host:
            code, printed = run_driver(host)
        self.assertEqual(code, 1)
        self.assertNotIn(('GET', '/api/status'), host.requests)
        self.assertIn('not in the host route table', printed)


if __name__ == '__main__':
    unittest.main()
