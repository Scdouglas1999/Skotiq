import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('isLocalNetworkHost — RFC1918 / loopback / link-local', () {
    test('accepts 10.0.0.0/8', () {
      expect(isLocalNetworkHost('10.0.0.1'), isTrue);
      expect(isLocalNetworkHost('10.255.255.254'), isTrue);
    });

    test('accepts 172.16.0.0/12 boundaries', () {
      expect(isLocalNetworkHost('172.16.0.1'), isTrue);
      expect(isLocalNetworkHost('172.31.255.254'), isTrue);
      expect(isLocalNetworkHost('172.15.0.1'), isFalse);
      expect(isLocalNetworkHost('172.32.0.1'), isFalse);
    });

    test('accepts 192.168.0.0/16', () {
      expect(isLocalNetworkHost('192.168.0.1'), isTrue);
      expect(isLocalNetworkHost('192.168.1.42'), isTrue);
    });

    test('accepts 127.0.0.0/8 loopback', () {
      expect(isLocalNetworkHost('127.0.0.1'), isTrue);
      expect(isLocalNetworkHost('localhost'), isTrue);
    });

    test('accepts 169.254.0.0/16 link-local', () {
      expect(isLocalNetworkHost('169.254.10.20'), isTrue);
    });

    test('accepts .local mDNS names', () {
      expect(isLocalNetworkHost('skotiq.local'), isTrue);
      expect(isLocalNetworkHost('PI4.LOCAL'), isTrue);
    });

    test('rejects public IPv4 addresses', () {
      expect(isLocalNetworkHost('8.8.8.8'), isFalse);
      expect(isLocalNetworkHost('1.1.1.1'), isFalse);
      expect(isLocalNetworkHost('52.85.132.10'), isFalse);
    });
  });

  group('isLocalNetworkHost — Tailscale CGNAT (100.64.0.0/10)', () {
    // The /10 boundary is precisely 100.64.0.0 through 100.127.255.255, and
    // every Tailscale node address lives inside it, so QR pairing depends on
    // both bounds being accepted.
    test('accepts lower boundary 100.64.0.0', () {
      expect(isLocalNetworkHost('100.64.0.0'), isTrue);
      expect(isLocalNetworkHost('100.64.0.1'), isTrue);
    });

    test('accepts upper boundary 100.127.255.255', () {
      expect(isLocalNetworkHost('100.127.255.255'), isTrue);
      expect(isLocalNetworkHost('100.127.0.1'), isTrue);
    });

    test('accepts addresses in the middle of the range', () {
      expect(isLocalNetworkHost('100.100.0.1'), isTrue);
      expect(isLocalNetworkHost('100.80.42.7'), isTrue);
    });

    test('rejects just outside lower boundary 100.63.255.255', () {
      expect(isLocalNetworkHost('100.63.255.255'), isFalse);
      expect(isLocalNetworkHost('100.63.0.0'), isFalse);
    });

    test('rejects just outside upper boundary 100.128.0.0', () {
      expect(isLocalNetworkHost('100.128.0.0'), isFalse);
      expect(isLocalNetworkHost('100.128.255.255'), isFalse);
    });

    test('rejects 100.0.0.0/8 outside the CGNAT range', () {
      // Critical guard: accepting 100.0.0.0/8 wholesale would leak ~16M
      // public-Internet IPs into the trust boundary.
      expect(isLocalNetworkHost('100.0.0.1'), isFalse);
      expect(isLocalNetworkHost('100.5.0.1'), isFalse);
      expect(isLocalNetworkHost('100.50.0.1'), isFalse);
    });

    test('rejects neighbouring /8 (99.x and 101.x)', () {
      // Why: typo-resilience. Make sure a transposed first octet does not
      // accidentally fall into the accepted range.
      expect(isLocalNetworkHost('99.84.0.1'), isFalse);
      expect(isLocalNetworkHost('101.64.0.1'), isFalse);
    });
  });

  group('isLocalNetworkHost — IPv6', () {
    test('accepts IPv6 loopback', () {
      expect(isLocalNetworkHost('::1'), isTrue);
      expect(isLocalNetworkHost('[::1]'), isTrue);
    });

    test('accepts fe80::/10 link-local', () {
      expect(isLocalNetworkHost('fe80::1'), isTrue);
      expect(isLocalNetworkHost('FE80::1'), isTrue);
    });

    test('strips zone-id suffix for IPv6 link-local', () {
      expect(isLocalNetworkHost('fe80::1%eth0'), isTrue);
    });

    test('accepts fc00::/7 unique-local (Tailscale ULA)', () {
      // Tailscale tailnets get a /48 inside fd7a:115c::/32, which lives in the
      // fc00::/7 ULA range — rejecting it rejects Tailscale-over-IPv6 QR
      // payloads.
      expect(isLocalNetworkHost('fd7a:115c:a1e0::1'), isTrue);
      expect(isLocalNetworkHost('fd00::1'), isTrue);
      expect(isLocalNetworkHost('fc00::1'), isTrue);
      expect(isLocalNetworkHost('fcff:ffff:ffff:ffff::1'), isTrue);
    });

    test('rejects globally-routable IPv6', () {
      expect(isLocalNetworkHost('2606:4700:4700::1111'), isFalse);
      expect(isLocalNetworkHost('2001:db8::1'), isFalse);
    });
  });

  group('isLocalNetworkHost — defensive edges', () {
    test('rejects empty host', () {
      expect(isLocalNetworkHost(''), isFalse);
    });

    test('rejects malformed IPv4', () {
      expect(isLocalNetworkHost('192.168.0'), isFalse);
      expect(isLocalNetworkHost('192.168.0.999'), isFalse);
      expect(isLocalNetworkHost('not.an.ip'), isFalse);
    });
  });

  group('MdnsServiceRegistration', () {
    test('constructs with the expected TXT contract', () {
      // Why this test: contract pinning. The TXT-record key set is shared
      // between the server (this class) and the client mDNS browse code in
      // enhanced_discovery.dart. A maintainer dropping or renaming one of
      // these keys would silently break the cross-process integration; this
      // test makes the contract violation a build-time failure.
      final registration = MdnsServiceRegistration(
        name: 'Skotiq Test',
        port: 8080,
        txt: const {
          'version': '2.5.0',
          'scheme': 'http',
          'fingerprint': 'abc123def456',
          'pairingSupported': 'true',
          'name': 'Skotiq Test',
        },
      );
      expect(registration.name, 'Skotiq Test');
      expect(registration.port, 8080);
      expect(
        registration.txt.keys,
        containsAll(<String>[
          'version',
          'scheme',
          'fingerprint',
          'pairingSupported',
          'name',
        ]),
      );
      expect(registration.isRegistered, isFalse);
    });
  });

  group('DiscoveredServer scheme', () {
    test('webUrl honours scheme=http (default)', () {
      final server = DiscoveredServer(
        host: '192.168.1.10',
        webPort: 8080,
        signalingPort: 8080,
        name: 'Skotiq',
        version: '2.5.0',
      );
      expect(server.scheme, 'http');
      expect(server.isTls, isFalse);
      expect(server.webUrl, 'http://192.168.1.10:8080');
    });

    test('webUrl honours scheme=https', () {
      // Why: the mDNS browse path sets scheme=https when the server published
      // `scheme=https` in its TXT records. If `webUrl` ignored that, the
      // first `GET /api/info` would hit plain HTTP on an HTTPS socket and
      // the enrichment would silently fail.
      final server = DiscoveredServer(
        host: '100.64.0.5',
        webPort: 8443,
        signalingPort: 8443,
        name: 'Skotiq Headless',
        version: '2.5.0',
        scheme: 'https',
      );
      expect(server.scheme, 'https');
      expect(server.isTls, isTrue);
      expect(server.webUrl, 'https://100.64.0.5:8443');
      expect(server.copyWith(scheme: 'http').webUrl, 'http://100.64.0.5:8443');
    });

    test('webUrl brackets IPv6 literals', () {
      final server = DiscoveredServer(
        host: 'fd7a:115c:a1e0::1',
        webPort: 8080,
        name: 'Tailnet rig',
      );

      expect(server.webUrl, 'http://[fd7a:115c:a1e0::1]:8080');
    });
  });

  group('EnhancedSkotiqDiscovery saved server persistence', () {
    test('round-trips the transport scheme for HTTPS rigs', () async {
      await EnhancedSkotiqDiscovery.saveLastServer(
        DiscoveredServer(
          host: '100.64.0.5',
          webPort: 8443,
          signalingPort: 8443,
          name: 'Skotiq Headless',
          version: '4.0.0',
          scheme: 'https',
          authRequired: true,
          authenticationMode: 'token',
          pairingSupported: true,
          fingerprint: 'abcdef1234567890',
        ),
      );

      final loaded = await EnhancedSkotiqDiscovery.loadLastServer();

      expect(loaded, isNotNull);
      expect(loaded!.scheme, 'https');
      expect(loaded.webUrl, 'https://100.64.0.5:8443');
      expect(loaded.authRequired, isTrue);
      expect(loaded.fingerprint, 'abcdef1234567890');
    });
  });

  group('SkotiqDiscovery UDP response parsing', () {
    test('preserves transport, auth, pairing, and fingerprint metadata', () {
      const raw =
          'SKOTIQ_RESPONSE_V2:'
          '{"protocol":"2","name":"Skotiq Headless","version":"4.0.0",'
          '"webPort":8080,"signalingPort":8080,"scheme":"https",'
          '"authRequired":true,"authenticationMode":"token",'
          '"pairingSupported":true,"fingerprint":"abc123def456"}';

      final server = SkotiqDiscovery.tryParseResponsePacket(
        raw,
        '192.168.1.42',
      );

      expect(server, isNotNull);
      expect(server!.host, '192.168.1.42');
      expect(server.name, 'Skotiq Headless');
      expect(server.version, '4.0.0');
      expect(server.webPort, 8080);
      expect(server.scheme, 'https');
      expect(server.isTls, isTrue);
      expect(server.authRequired, isTrue);
      expect(server.authenticationMode, 'token');
      expect(server.pairingSupported, isTrue);
      expect(server.fingerprint, 'abc123def456');
    });

    test('rejects malformed or non-Skotiq packets', () {
      expect(
        SkotiqDiscovery.tryParseResponsePacket('{"webPort":8080}', 'host'),
        isNull,
      );
      expect(
        SkotiqDiscovery.tryParseResponsePacket(
          'SKOTIQ_RESPONSE_V2:{"webPort":"8080"}',
          'host',
        ),
        isNull,
      );
    });

    test('computes likely /24 directed broadcast targets', () {
      expect(
        SkotiqDiscovery.likelyIpv4DirectedBroadcastTargets([
          '192.168.1.23',
          '10.0.4.55',
          '127.0.0.1',
          'not-an-ip',
          '192.168.1.255',
        ]),
        {'192.168.1.255', '10.0.4.255'},
      );
    });
  });

  group('QrConnectionData scheme field', () {
    test('defaults to http and round-trips through JSON', () {
      final data = QrConnectionData(
        host: '192.168.1.10',
        webPort: 8080,
        version: '2.5.0',
        fingerprint: 'abcdef1234567890',
      );
      expect(data.scheme, 'http');
      expect(data.isTls, isFalse);
      expect(data.toJson()['scheme'], 'http');

      final parsed = QrConnectionData.parseStrict(data.toQrString());
      expect(parsed.scheme, 'http');
    });

    test('https survives encode → decode and flows into DiscoveredServer', () {
      final data = QrConnectionData(
        host: '100.64.0.5',
        webPort: 8443,
        version: '2.6.0',
        fingerprint: 'fingerprint-https-0001',
        scheme: 'https',
      );
      expect(data.isTls, isTrue);
      expect(data.toJson()['scheme'], 'https');

      final parsed = QrConnectionData.parseStrict(data.toQrString());
      expect(parsed.scheme, 'https');
      expect(parsed.toDiscoveredServer().scheme, 'https');
      expect(parsed.toDiscoveredServer().isTls, isTrue);
    });

    test('parseStrict lower-cases an upper-case scheme', () {
      const payload =
          '{"service":"skotiq","host":"100.96.0.7","port":8443,'
          '"version":"2.6.0","fingerprint":"abcdef1234567890",'
          '"scheme":"HTTPS"}';
      expect(QrConnectionData.parseStrict(payload).scheme, 'https');
    });

    test('parseStrict treats a missing scheme as http (back-compat)', () {
      const payload =
          '{"service":"skotiq","host":"192.168.1.10","port":8080,'
          '"version":"2.5.0","fingerprint":"abcdef1234567890"}';
      expect(QrConnectionData.parseStrict(payload).scheme, 'http');
    });

    test('parseStrict rejects a bogus scheme with invalidScheme', () {
      const payload =
          '{"service":"skotiq","host":"192.168.1.10","port":8080,'
          '"version":"2.5.0","fingerprint":"abcdef1234567890",'
          '"scheme":"ftp"}';
      expect(
        () => QrConnectionData.parseStrict(payload),
        throwsA(
          isA<QrValidationException>().having(
            (e) => e.reason,
            'reason',
            QrRejectionReason.invalidScheme,
          ),
        ),
      );
    });

    test('generateQrData embeds and lower-cases the scheme', () {
      final qr = EnhancedSkotiqDiscovery.generateQrData(
        host: '100.64.0.5',
        webPort: 8443,
        version: '2.6.0',
        fingerprint: 'abcdef1234567890',
        scheme: 'HTTPS',
      );
      expect(QrConnectionData.parseStrict(qr).scheme, 'https');
    });

    test('generateQrData rejects an invalid scheme', () {
      expect(
        () => EnhancedSkotiqDiscovery.generateQrData(
          host: '100.64.0.5',
          webPort: 8443,
          version: '2.6.0',
          fingerprint: 'abcdef1234567890',
          scheme: 'gopher',
        ),
        throwsArgumentError,
      );
    });
  });

  group('testServerConnection scheme validation', () {
    test('rejects an invalid scheme before any network call', () {
      expect(
        () => EnhancedSkotiqDiscovery.testServerConnection(
          '192.168.1.10',
          8080,
          scheme: 'ftp',
        ),
        throwsArgumentError,
      );
    });

    test('prefers compatible apiVersion over a newer app version', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'version': '3.0.0',
              'apiVersion': '2.6.0',
              'authRequired': false,
            }),
          );
        await request.response.close();
      });

      expect(
        await EnhancedSkotiqDiscovery.testServerConnection(
          InternetAddress.loopbackIPv4.address,
          server.port,
        ),
        isTrue,
      );
    });
  });

  // A live host that REJECTS the credential must not be reported as
  // unreachable. A Skotiq host invalidates every paired token when it
  // restarts, so a stale token against a healthy host is the commonest failure
  // an operator hits, and "Could not reach <name> at <host>" sends them to
  // debug their network instead of pairing again.
  group('probeServer distinguishes auth rejection from unreachability', () {
    Future<int> serveStatus(
      int statusCode, {
      Map<String, Object?>? info,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/api/info' && info != null) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(info));
        } else {
          request.response.statusCode = statusCode;
        }
        await request.response.close();
      });
      return server.port;
    }

    for (final code in [401, 403]) {
      test(
        '$code on /api/info reports authRejected, not unreachable',
        () async {
          final port = await serveStatus(code);
          expect(
            await EnhancedSkotiqDiscovery.probeServer(
              InternetAddress.loopbackIPv4.address,
              port,
              authToken: 'stale-token',
            ),
            ServerProbeOutcome.authRejected,
          );
        },
      );

      test(
        '$code on /api/status reports authRejected, not unreachable',
        () async {
          final port = await serveStatus(
            code,
            info: {
              'version': '3.0.0',
              'apiVersion': '2.6.0',
              'authRequired': true,
            },
          );
          expect(
            await EnhancedSkotiqDiscovery.probeServer(
              InternetAddress.loopbackIPv4.address,
              port,
              authToken: 'stale-token',
            ),
            ServerProbeOutcome.authRejected,
          );
        },
      );
    }

    test('a refused connection is still unreachable', () async {
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close(force: true);
      expect(
        await EnhancedSkotiqDiscovery.probeServer(
          InternetAddress.loopbackIPv4.address,
          deadPort,
          timeout: const Duration(seconds: 2),
        ),
        ServerProbeOutcome.unreachable,
      );
    });

    test(
      'testServerConnection stays false for a rejected credential',
      () async {
        final port = await serveStatus(403);
        expect(
          await EnhancedSkotiqDiscovery.testServerConnection(
            InternetAddress.loopbackIPv4.address,
            port,
            authToken: 'stale-token',
          ),
          isFalse,
        );
      },
    );
  });
}
