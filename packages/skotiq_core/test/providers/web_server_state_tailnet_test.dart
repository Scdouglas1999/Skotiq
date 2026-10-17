// Tests for the Tailscale ("tailnet") reachability fields added to
// [WebServerState] (P2 "Core backend and web server tailnet").
//
// These cover the pure state surface — the fail-closed defaults and the
// `tailscaleUrl` getter — which is the contract the operator UI
// (RemoteAccessSettings) reads. Interface enumeration in
// `WebServerStateNotifier._resolveLocalIp` is exercised by the integration
// path and isn't deterministically unit-testable (it reads the host's live
// NICs), but the state it produces is fully specified here.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/web_server_provider.dart';

void main() {
  group('WebServerState tailnet fields (fail-closed)', () {
    test('defaults: no tailnet address, not reachable, empty URL', () {
      const state = WebServerState();
      expect(state.tailscaleIp, '');
      expect(state.tailscaleReachable, isFalse);
      expect(state.tailscaleUrl, '');
    });

    test(
      'tailscaleUrl stays empty when an address is known but unreachable',
      () {
        // Address present but reachable flag false (e.g. bound loopback-only):
        // fail-closed means we must NOT advertise a URL.
        const state = WebServerState(
          tailscaleIp: '100.96.0.7',
          tailscaleReachable: false,
          actualPort: 8080,
        );
        expect(state.tailscaleUrl, '');
      },
    );

    test('tailscaleUrl stays empty when reachable but no address resolved', () {
      const state = WebServerState(
        tailscaleIp: '',
        tailscaleReachable: true,
        actualPort: 8080,
      );
      expect(state.tailscaleUrl, '');
    });

    test('tailscaleUrl renders an IPv4 tailnet URL when reachable', () {
      const state = WebServerState(
        tailscaleIp: '100.96.0.7',
        tailscaleReachable: true,
        actualPort: 8080,
      );
      // Browser-openable: must include the dashboard path, since the origin
      // root answers 401 rather than serving the SPA.
      expect(state.tailscaleUrl, 'http://100.96.0.7:8080/dashboard');
    });

    test('tailscaleUrl brackets an IPv6 tailnet literal', () {
      const state = WebServerState(
        tailscaleIp: 'fd7a:115c:a1e0::1',
        tailscaleReachable: true,
        actualPort: 9090,
      );
      expect(state.tailscaleUrl, 'http://[fd7a:115c:a1e0::1]:9090/dashboard');
    });

    test('copyWith carries the tailnet fields through', () {
      const base = WebServerState();
      final updated = base.copyWith(
        tailscaleIp: '100.96.0.7',
        tailscaleReachable: true,
      );
      expect(updated.tailscaleIp, '100.96.0.7');
      expect(updated.tailscaleReachable, isTrue);
      // Untouched fields preserved.
      expect(updated.actualPort, base.actualPort);
    });

    test('copyWith without tailnet args leaves the fields unchanged', () {
      const base = WebServerState(
        tailscaleIp: '100.96.0.7',
        tailscaleReachable: true,
      );
      final updated = base.copyWith(activeViewers: 3);
      expect(updated.tailscaleIp, '100.96.0.7');
      expect(updated.tailscaleReachable, isTrue);
      expect(updated.activeViewers, 3);
    });
  });

  group('WebServerState browser URLs', () {
    /// These strings are opened in a browser and copied for humans. The origin
    /// root is NOT a routed page — the auth middleware answers `GET /` with
    /// `401 {"error":"Authentication required"}` as raw JSON — so a URL without
    /// the dashboard path sent the operator to an error document from the very
    /// button that promises to "confirm the dashboard is working". Verified
    /// live against the desktop server: `/` -> 401, `/dashboard` -> 200.
    test('localUrl points at the dashboard page, not the origin root', () {
      const state = WebServerState(isRunning: true, actualPort: 8080);
      expect(state.localUrl, 'http://localhost:8080/dashboard');
    });

    test('networkUrl points at the dashboard page when LAN-bound', () {
      const state = WebServerState(
        isRunning: true,
        actualPort: 8080,
        localIp: '192.168.1.20',
        bindLocalOnly: false,
      );
      expect(state.networkUrl, 'http://192.168.1.20:8080/dashboard');
    });

    test('networkUrl stays empty while bound to loopback only', () {
      const state = WebServerState(
        isRunning: true,
        actualPort: 8080,
        localIp: '192.168.1.20',
      );
      expect(state.networkUrl, '');
    });
  });
}
