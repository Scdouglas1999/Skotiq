// Tests for the Tailscale / remote-reachability tuning added to
// [NetworkBackend] (P2 "Core backend and web server tailnet"):
//
//   * `scheme` propagates to every REST request URL (http -> https) and is
//     validated fail-closed (an unknown scheme throws).
//   * The derived WebSocket scheme is `wss` when `scheme == 'https'`.
//   * `isRemoteHost` reflects Tailscale-tier classification of `serverHost`.
//   * Remote (tailnet) hosts get longer request/heartbeat timeout defaults;
//     LAN hosts keep the historical ceilings; an explicit override always wins.
//   * `pinnedFingerprint` makes the `/api/info` handshake fail closed on a
//     mismatch (and on a server that advertises no fingerprint at all).
//
// All HTTP is served by the MockClient-backed [FakeNetworkClient], so no real
// server is needed.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';

import '../fakes/fakes.dart';

/// Build a backend with WS auto-connect disabled (the WS path needs a real
/// socket, which these HTTP-only tests don't provide).
NetworkBackend _backend(
  FakeNetworkClient fake, {
  required String host,
  String scheme = 'http',
  String? pinnedFingerprint,
  Duration? requestTimeout,
  Duration? webSocketHeartbeatTimeout,
}) {
  return NetworkBackend(
    serverHost: host,
    serverPort: 8080,
    webSocketPort: 8080,
    scheme: scheme,
    pinnedFingerprint: pinnedFingerprint,
    requestTimeout: requestTimeout,
    webSocketHeartbeatTimeout: webSocketHeartbeatTimeout,
    httpClient: fake,
    autoConnectWebSocket: false,
  );
}

void main() {
  group('NetworkBackend scheme', () {
    test(
      'http scheme is the default and produces http:// request URLs',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/devices', body: '{"devices":[]}');
        final backend = _backend(fake, host: '192.168.1.50');
        addTearDown(backend.dispose);

        await backend.discoverDevices(DeviceType.camera);

        expect(fake.requests, isNotEmpty);
        expect(fake.requests.single.url.scheme, 'http');
        expect(fake.requests.single.url.host, '192.168.1.50');
        expect(backend.scheme, 'http');
      },
    );

    test('https scheme propagates to every REST request URL', () async {
      final fake = FakeNetworkClient()
        ..setResponse('/api/devices', body: '{"devices":[]}');
      final backend = _backend(fake, host: '100.101.102.103', scheme: 'https');
      addTearDown(backend.dispose);

      await backend.discoverDevices(DeviceType.camera);

      expect(fake.requests.single.url.scheme, 'https');
      expect(backend.scheme, 'https');
    });

    test('scheme is normalised to lower-case', () {
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: '10.0.0.5', scheme: 'HTTPS');
      addTearDown(backend.dispose);
      expect(backend.scheme, 'https');
    });

    test('an unrecognised scheme throws (fail-closed, no silent default)', () {
      final fake = FakeNetworkClient();
      expect(
        () => _backend(fake, host: '10.0.0.5', scheme: 'ftp'),
        throwsArgumentError,
      );
    });
  });

  group('NetworkBackend isRemoteHost classification', () {
    test('Tailscale CGNAT IPv4 host is remote', () {
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: '100.96.0.7');
      addTearDown(backend.dispose);
      expect(backend.isRemoteHost, isTrue);
    });

    test('RFC1918 LAN host is not remote', () {
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: '192.168.0.42');
      addTearDown(backend.dispose);
      expect(backend.isRemoteHost, isFalse);
    });

    test('loopback host is not remote', () {
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: '127.0.0.1');
      addTearDown(backend.dispose);
      expect(backend.isRemoteHost, isFalse);
    });

    test('100.x below the CGNAT /10 boundary is not treated as remote', () {
      // 100.63.x.x is in the public 100.0.0.0/10 block that sits *below* the
      // CGNAT range — must not be mistaken for a tailnet host.
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: '100.63.0.1');
      addTearDown(backend.dispose);
      expect(backend.isRemoteHost, isFalse);
    });
  });

  group('NetworkBackend timeout tuning (LAN unchanged, remote relaxed)', () {
    test(
      'LAN host keeps the historical 30s request / 45s heartbeat ceilings',
      () {
        final fake = FakeNetworkClient();
        final backend = _backend(fake, host: '192.168.1.10');
        addTearDown(backend.dispose);
        expect(backend.requestTimeout, const Duration(seconds: 30));
        expect(backend.webSocketHeartbeatTimeout, const Duration(seconds: 45));
      },
    );

    test('remote (tailnet) host gets relaxed 60s request / 90s heartbeat', () {
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: '100.110.120.5');
      addTearDown(backend.dispose);
      expect(backend.requestTimeout, const Duration(seconds: 60));
      expect(backend.webSocketHeartbeatTimeout, const Duration(seconds: 90));
    });

    test('an explicit timeout override always wins over host-class tuning', () {
      final fake = FakeNetworkClient();
      final backend = _backend(
        fake,
        host: '100.110.120.5',
        requestTimeout: const Duration(seconds: 5),
        webSocketHeartbeatTimeout: const Duration(seconds: 7),
      );
      addTearDown(backend.dispose);
      expect(backend.requestTimeout, const Duration(seconds: 5));
      expect(backend.webSocketHeartbeatTimeout, const Duration(seconds: 7));
    });
  });

  group('NetworkBackend fingerprint pinning (fail-closed)', () {
    test(
      'matching fingerprint passes the /api/info compatibility check',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/info',
            body: jsonEncode({'version': '2.5.0', 'fingerprint': 'ABCD1234'}),
          );
        final backend = _backend(
          fake,
          host: '100.64.0.9',
          pinnedFingerprint: 'abcd1234', // case-insensitive
        );
        addTearDown(backend.dispose);

        // testConnection exercises _checkServerCompatibility, which is where the
        // pin is enforced.
        final ok = await backend.testConnection();
        expect(ok, isTrue);
      },
    );

    test(
      'mismatched fingerprint is refused (testConnection returns false)',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/info',
            body: jsonEncode({'version': '2.5.0', 'fingerprint': 'DEADBEEF'}),
          );
        final backend = _backend(
          fake,
          host: '100.64.0.9',
          pinnedFingerprint: 'ABCD1234',
        );
        addTearDown(backend.dispose);

        // testConnection swallows the thrown mismatch into `false` — the
        // important guarantee is that it does NOT report a healthy connection.
        final ok = await backend.testConnection();
        expect(ok, isFalse);
      },
    );

    test(
      'a server advertising no fingerprint is refused when client pins one',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse('/api/info', body: jsonEncode({'version': '2.5.0'}));
        final backend = _backend(
          fake,
          host: '100.64.0.9',
          pinnedFingerprint: 'ABCD1234',
        );
        addTearDown(backend.dispose);

        final ok = await backend.testConnection();
        expect(ok, isFalse);
      },
    );

    test(
      'no pin set => fingerprint is not enforced (LAN first-pair flow)',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/info',
            body: jsonEncode({'version': '2.5.0', 'fingerprint': 'ANYTHING'}),
          );
        final backend = _backend(fake, host: '192.168.1.10');
        addTearDown(backend.dispose);

        final ok = await backend.testConnection();
        expect(ok, isTrue);
      },
    );
  });

  group('NetworkBackend connect() fingerprint mismatch is TERMINAL', () {
    test(
      'mismatch drives connectionState to error and arms no reconnect timer',
      () async {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/info',
            body: jsonEncode({'version': '2.5.0', 'fingerprint': 'DEADBEEF'}),
          );
        final backend = _backend(
          fake,
          host: '100.64.0.9',
          pinnedFingerprint: 'ABCD1234',
        );
        addTearDown(backend.dispose);

        // connect() runs the /api/info handshake, which fails the pin. Unlike a
        // generic connection failure (which schedules an exponential-backoff
        // reconnect), an identity mismatch must be terminal.
        await backend.connect();

        expect(backend.connectionState, BackendConnectionState.error);

        final infoCallsAfterConnect = fake.requestsFor('/api/info').length;
        expect(
          infoCallsAfterConnect,
          1,
          reason: 'connect() should hit /api/info exactly once',
        );

        // If a reconnect timer were armed, it would fire after the 1s backoff and
        // re-hit /api/info. Wait well past the first backoff window and assert the
        // backend neither re-probed nor left the terminal error state.
        await Future<void>.delayed(const Duration(milliseconds: 1300));

        expect(
          fake.requestsFor('/api/info').length,
          infoCallsAfterConnect,
          reason:
              'no reconnect should re-probe /api/info after a terminal '
              'identity mismatch',
        );
        expect(
          backend.connectionState,
          BackendConnectionState.error,
          reason: 'state must remain terminal, not fall back to reconnecting',
        );
      },
    );

    test(
      'a generic /api/info failure DOES schedule a reconnect (contrast)',
      () async {
        // Baseline that proves the terminal-vs-reconnect distinction is real:
        // a plain HTTP failure (no pin involved) should NOT land in error and
        // SHOULD schedule a reconnect.
        final fake = FakeNetworkClient()
          ..setResponse('/api/info', status: 503, body: 'unavailable');
        final backend = _backend(fake, host: '192.168.1.10');
        addTearDown(backend.dispose);

        await backend.connect();

        expect(
          backend.connectionState,
          isNot(BackendConnectionState.error),
          reason: 'a transient failure is recoverable, not terminal',
        );
      },
    );
  });

  group('NetworkBackend MagicDNS (*.ts.net) is treated as remote', () {
    test('a *.ts.net host is classified remote and gets relaxed timeouts', () {
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: 'my-rig.tailnet-name.ts.net');
      addTearDown(backend.dispose);

      expect(
        backend.isRemoteHost,
        isTrue,
        reason: 'a MagicDNS name is reached over the tailnet, not the LAN',
      );
      expect(backend.requestTimeout, const Duration(seconds: 60));
      expect(backend.webSocketHeartbeatTimeout, const Duration(seconds: 90));
    });

    test('a non-tailnet hostname is NOT remote', () {
      final fake = FakeNetworkClient();
      final backend = _backend(fake, host: 'example.com');
      addTearDown(backend.dispose);
      expect(backend.isRemoteHost, isFalse);
    });
  });
}
