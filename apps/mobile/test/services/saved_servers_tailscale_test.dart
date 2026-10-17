// Mobile Companion — Internet Reachability via Tailscale (P3).
//
// Tests for the Tailscale additions to SavedServer / SavedServersService:
//   * scheme (http/https) round-trips and validates fail-closed.
//   * tailscaleHost round-trips and is gated to tailnet endpoints.
//   * isTailscaleEndpoint accepts 100.x / fd7a:115c:: literals and
//     *.ts.net MagicDNS names, rejects everything else.
//   * the tier/preferred-host helpers behave for single- and dual-homed
//     rigs.
//   * setTailscaleHost mutates / clears / rejects.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/saved_servers_service.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Random fixedRandom() => Random(1);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedServersStorageKeys.migrated: true,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('SavedServer.isTailscaleEndpoint', () {
    test('accepts CGNAT 100.64.0.0/10 literals', () {
      expect(SavedServer.isTailscaleEndpoint('100.64.0.1'), isTrue);
      expect(SavedServer.isTailscaleEndpoint('100.101.102.103'), isTrue);
      expect(SavedServer.isTailscaleEndpoint('100.127.255.255'), isTrue);
    });

    test('rejects 100.x outside the /10 CGNAT block', () {
      // 100.0.0.0/8 below the CGNAT block is public space.
      expect(SavedServer.isTailscaleEndpoint('100.0.0.1'), isFalse);
      expect(SavedServer.isTailscaleEndpoint('100.63.255.255'), isFalse);
      expect(SavedServer.isTailscaleEndpoint('100.128.0.1'), isFalse);
    });

    test('accepts fd7a:115c::/32 IPv6 tailnet literals', () {
      expect(SavedServer.isTailscaleEndpoint('fd7a:115c:a1e0::1'), isTrue);
    });

    test('accepts *.ts.net MagicDNS hostnames (case-insensitive)', () {
      expect(SavedServer.isTailscaleEndpoint('my-rig.tail1a2b.ts.net'), isTrue);
      expect(SavedServer.isTailscaleEndpoint('MyRig.Tailnet.TS.NET'), isTrue);
    });

    test('rejects bare ts.net and LAN / public hosts', () {
      // The suffix alone, with nothing in front, is not a host.
      expect(SavedServer.isTailscaleEndpoint('.ts.net'), isFalse);
      expect(SavedServer.isTailscaleEndpoint('192.168.1.10'), isFalse);
      expect(SavedServer.isTailscaleEndpoint('example.com'), isFalse);
      expect(SavedServer.isTailscaleEndpoint('8.8.8.8'), isFalse);
      expect(SavedServer.isTailscaleEndpoint(''), isFalse);
    });
  });

  group('SavedServer tier + preferred-host helpers', () {
    test('LAN single-homed rig has no remote path', () {
      const s = SavedServer(
        id: 'a',
        displayName: 'Backyard',
        host: '192.168.1.50',
        port: 8080,
      );
      expect(s.hostTier, HostReachabilityTier.lan);
      expect(s.isPrimaryTailscale, isFalse);
      expect(s.hasTailscaleHost, isFalse);
      expect(s.preferredRemoteHost, isNull);
    });

    test('tailnet-primary rig prefers its own host', () {
      const s = SavedServer(
        id: 'b',
        displayName: 'Remote obs',
        host: 'obs.tailnet.ts.net',
        port: 8080,
        scheme: 'https',
      );
      expect(s.isPrimaryTailscale, isTrue);
      expect(s.preferredRemoteHost, 'obs.tailnet.ts.net');
    });

    test('dual-homed LAN rig prefers the explicit tailscaleHost', () {
      const s = SavedServer(
        id: 'c',
        displayName: 'Observatory',
        host: '192.168.1.50',
        port: 8080,
        tailscaleHost: '100.101.102.103',
      );
      expect(s.hostTier, HostReachabilityTier.lan);
      expect(s.hasTailscaleHost, isTrue);
      expect(s.preferredRemoteHost, '100.101.102.103');
    });
  });

  group('SavedServer JSON round-trip with scheme + tailscaleHost', () {
    test('https + tailscaleHost survive serialization', () {
      const s = SavedServer(
        id: 'd',
        displayName: 'Observatory',
        host: '192.168.1.50',
        port: 8443,
        scheme: 'https',
        tailscaleHost: '100.101.102.103',
      );
      final json = s.toJsonNonSecret();
      expect(json['scheme'], 'https');
      expect(json['tailscaleHost'], '100.101.102.103');
      final reloaded = SavedServer.fromJsonNonSecret(json);
      expect(reloaded.scheme, 'https');
      expect(reloaded.tailscaleHost, '100.101.102.103');
    });

    test('default http scheme is omitted from the blob for compactness', () {
      const s = SavedServer(
        id: 'e',
        displayName: 'LAN rig',
        host: '10.0.0.4',
        port: 8080,
      );
      expect(s.toJsonNonSecret().containsKey('scheme'), isFalse);
      // A blob with no scheme deserialises to the http default (backward
      // compatibility with pre-2.6 rows).
      final reloaded = SavedServer.fromJsonNonSecret(s.toJsonNonSecret());
      expect(reloaded.scheme, 'http');
    });

    test('a bogus scheme is rejected rather than silently coerced', () {
      expect(
        () => SavedServer.fromJsonNonSecret(<String, dynamic>{
          'id': 'x',
          'displayName': 'y',
          'host': '10.0.0.4',
          'port': 8080,
          'scheme': 'ftp',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-tailnet tailscaleHost is rejected (fail-closed)', () {
      expect(
        () => SavedServer.fromJsonNonSecret(<String, dynamic>{
          'id': 'x',
          'displayName': 'y',
          'host': '10.0.0.4',
          'port': 8080,
          'tailscaleHost': '8.8.8.8',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SavedServersService Tailscale mutations', () {
    test('add persists scheme + tailscaleHost and reloads them', () async {
      final service = SavedServersService(random: fixedRandom());
      final added = await service.add(
        displayName: 'Observatory',
        host: '192.168.1.50',
        port: 8443,
        scheme: 'https',
        tailscaleHost: '100.101.102.103',
      );
      final reloaded = (await service.loadAll()).single;
      expect(reloaded.id, added.id);
      expect(reloaded.scheme, 'https');
      expect(reloaded.tailscaleHost, '100.101.102.103');
    });

    test('setTailscaleHost adds, then clears, the tailnet host', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'Observatory',
        host: '192.168.1.50',
        port: 8080,
      );
      await service.setTailscaleHost(row.id, 'obs.tailnet.ts.net');
      expect(
        (await service.loadAll()).single.tailscaleHost,
        'obs.tailnet.ts.net',
      );
      await service.setTailscaleHost(row.id, '');
      expect((await service.loadAll()).single.tailscaleHost, isNull);
    });

    test('setTailscaleHost refuses a public address', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'Observatory',
        host: '192.168.1.50',
        port: 8080,
      );
      expect(
        () => service.setTailscaleHost(row.id, '8.8.8.8'),
        throwsArgumentError,
      );
      // The row must be unchanged after the rejection.
      expect((await service.loadAll()).single.tailscaleHost, isNull);
    });

    test('toDiscoveredServer carries the recorded scheme', () async {
      final service = SavedServersService(random: fixedRandom());
      final row = await service.add(
        displayName: 'Remote obs',
        host: '100.101.102.103',
        port: 8443,
        scheme: 'https',
        authToken: 'paired-token',
      );
      final ds = await service.toDiscoveredServer(row.id);
      expect(ds, isNotNull);
      expect(ds!.scheme, 'https');
      expect(ds.host, '100.101.102.103');
    });

    test(
      'upsert by host:port preserves an existing tailscaleHost when null',
      () async {
        final service = SavedServersService(random: fixedRandom());
        final first = await service.add(
          displayName: 'Observatory',
          host: '192.168.1.50',
          port: 8080,
          tailscaleHost: '100.101.102.103',
        );
        // Re-upsert the same host:port without a tailscaleHost — copyWith
        // leaves the existing value intact (null means "leave alone").
        await service.upsert(
          id: first.id,
          displayName: 'Observatory (renamed)',
          host: '192.168.1.50',
          port: 8080,
        );
        final reloaded = (await service.loadAll()).single;
        expect(reloaded.tailscaleHost, '100.101.102.103');
        expect(reloaded.displayName, 'Observatory (renamed)');
      },
    );

    test(
      'a v1 (pre-2.6) blob with no scheme/tailscaleHost loads cleanly',
      () async {
        final legacyRow = {
          'id': 'legacy-1',
          'displayName': 'Legacy LAN',
          'host': '10.0.0.4',
          'port': 8080,
        };
        SharedPreferences.setMockInitialValues(<String, Object>{
          SavedServersStorageKeys.list: jsonEncode([legacyRow]),
          SavedServersStorageKeys.migrated: true,
        });
        final service = SavedServersService(random: fixedRandom());
        final all = await service.loadAll();
        expect(all, hasLength(1));
        expect(all.single.scheme, 'http');
        expect(all.single.tailscaleHost, isNull);
      },
    );
  });
}
