import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('TailnetDetector.classify — loopback', () {
    test('127.0.0.0/8 and localhost are loopback', () {
      expect(
        TailnetDetector.classify('127.0.0.1'),
        HostReachabilityTier.loopback,
      );
      expect(
        TailnetDetector.classify('127.255.255.254'),
        HostReachabilityTier.loopback,
      );
      expect(
        TailnetDetector.classify('localhost'),
        HostReachabilityTier.loopback,
      );
      expect(
        TailnetDetector.classify('LOCALHOST'),
        HostReachabilityTier.loopback,
      );
    });

    test('IPv6 ::1 is loopback', () {
      expect(TailnetDetector.classify('::1'), HostReachabilityTier.loopback);
      expect(TailnetDetector.classify('[::1]'), HostReachabilityTier.loopback);
    });
  });

  group('TailnetDetector.classify — LAN', () {
    test('RFC1918 ranges are LAN', () {
      expect(TailnetDetector.classify('10.0.0.1'), HostReachabilityTier.lan);
      expect(TailnetDetector.classify('172.16.0.1'), HostReachabilityTier.lan);
      expect(
        TailnetDetector.classify('172.31.255.254'),
        HostReachabilityTier.lan,
      );
      expect(
        TailnetDetector.classify('192.168.1.42'),
        HostReachabilityTier.lan,
      );
    });

    test('172.x outside /12 is not LAN', () {
      expect(
        TailnetDetector.classify('172.15.0.1'),
        HostReachabilityTier.public,
      );
      expect(
        TailnetDetector.classify('172.32.0.1'),
        HostReachabilityTier.public,
      );
    });

    test('169.254.0.0/16 link-local is LAN', () {
      expect(
        TailnetDetector.classify('169.254.10.20'),
        HostReachabilityTier.lan,
      );
    });

    test('.local mDNS names are LAN', () {
      expect(
        TailnetDetector.classify('skotiq.local'),
        HostReachabilityTier.lan,
      );
      expect(TailnetDetector.classify('PI4.LOCAL'), HostReachabilityTier.lan);
    });

    test('fe80::/10 link-local and generic fc00::/7 ULA are LAN', () {
      expect(TailnetDetector.classify('fe80::1'), HostReachabilityTier.lan);
      expect(
        TailnetDetector.classify('fe80::1%eth0'),
        HostReachabilityTier.lan,
      );
      expect(TailnetDetector.classify('fc00::1'), HostReachabilityTier.lan);
      expect(TailnetDetector.classify('fd00::1'), HostReachabilityTier.lan);
      expect(
        TailnetDetector.classify('fcff:ffff:ffff:ffff::1'),
        HostReachabilityTier.lan,
      );
    });
  });

  group('TailnetDetector.classify — tailnet (Tailscale)', () {
    test('100.64.0.0/10 CGNAT boundaries are tailnet', () {
      expect(
        TailnetDetector.classify('100.64.0.0'),
        HostReachabilityTier.tailscale,
      );
      expect(
        TailnetDetector.classify('100.64.0.1'),
        HostReachabilityTier.tailscale,
      );
      expect(
        TailnetDetector.classify('100.127.255.255'),
        HostReachabilityTier.tailscale,
      );
      expect(
        TailnetDetector.classify('100.100.0.1'),
        HostReachabilityTier.tailscale,
      );
    });

    test('just outside the CGNAT /10 is NOT tailnet', () {
      // 100.0.0.0/8 below the CGNAT block holds ~16M public IPs — must be
      // classified public, never tailnet, or a crafted QR could point at one.
      expect(
        TailnetDetector.classify('100.63.255.255'),
        HostReachabilityTier.public,
      );
      expect(
        TailnetDetector.classify('100.0.0.1'),
        HostReachabilityTier.public,
      );
      expect(
        TailnetDetector.classify('100.50.0.1'),
        HostReachabilityTier.public,
      );
      expect(
        TailnetDetector.classify('100.128.0.0'),
        HostReachabilityTier.public,
      );
    });

    test('neighbouring /8 (99.x / 101.x) is public, not tailnet', () {
      expect(
        TailnetDetector.classify('99.84.0.1'),
        HostReachabilityTier.public,
      );
      expect(
        TailnetDetector.classify('101.64.0.1'),
        HostReachabilityTier.public,
      );
    });

    test('Tailscale IPv6 fd7a:115c::/32 is tailnet (not generic ULA)', () {
      // The Tailscale /32 sits inside fd00::/8 — it must be distinguished from
      // a vanilla ULA so the reachability badge can say "via Tailscale".
      expect(
        TailnetDetector.classify('fd7a:115c:a1e0::1'),
        HostReachabilityTier.tailscale,
      );
      expect(
        TailnetDetector.classify('fd7a:115c::1'),
        HostReachabilityTier.tailscale,
      );
      expect(
        TailnetDetector.classify('[fd7a:115c:a1e0::53]'),
        HostReachabilityTier.tailscale,
      );
    });

    test('isTailscaleHost matches the tailnet tier', () {
      expect(TailnetDetector.isTailscaleHost('100.96.0.7'), isTrue);
      expect(TailnetDetector.isTailscaleHost('fd7a:115c:a1e0::1'), isTrue);
      expect(TailnetDetector.isTailscaleHost('192.168.0.1'), isFalse);
      expect(TailnetDetector.isTailscaleHost('8.8.8.8'), isFalse);
    });
  });

  group('TailnetDetector.classify — public and invalid (fail closed)', () {
    test('globally-routable IPv4 is public', () {
      expect(TailnetDetector.classify('8.8.8.8'), HostReachabilityTier.public);
      expect(TailnetDetector.classify('1.1.1.1'), HostReachabilityTier.public);
      expect(
        TailnetDetector.classify('52.85.132.10'),
        HostReachabilityTier.public,
      );
    });

    test('globally-routable IPv6 is public', () {
      expect(
        TailnetDetector.classify('2606:4700:4700::1111'),
        HostReachabilityTier.public,
      );
      expect(
        TailnetDetector.classify('2001:db8::1'),
        HostReachabilityTier.public,
      );
    });

    test('empty / malformed / non-literal hosts are invalid', () {
      expect(TailnetDetector.classify(''), HostReachabilityTier.invalid);
      expect(
        TailnetDetector.classify('192.168.0'),
        HostReachabilityTier.invalid,
      );
      expect(
        TailnetDetector.classify('192.168.0.999'),
        HostReachabilityTier.invalid,
      );
      expect(
        TailnetDetector.classify('not.an.ip'),
        HostReachabilityTier.invalid,
      );
      // A DNS name that is not *.local cannot be proven private without
      // resolution, which this classifier never performs — invalid.
      expect(
        TailnetDetector.classify('example.com'),
        HostReachabilityTier.invalid,
      );
    });
  });

  group('TailnetDetector.isAccepted — fail-closed acceptance', () {
    test('accepts loopback, LAN, and tailnet', () {
      expect(TailnetDetector.isAccepted('127.0.0.1'), isTrue);
      expect(TailnetDetector.isAccepted('192.168.1.5'), isTrue);
      expect(TailnetDetector.isAccepted('100.96.0.7'), isTrue);
      expect(TailnetDetector.isAccepted('fd7a:115c:a1e0::1'), isTrue);
      expect(TailnetDetector.isAccepted('skotiq.local'), isTrue);
    });

    test('refuses public and invalid', () {
      expect(TailnetDetector.isAccepted('8.8.8.8'), isFalse);
      expect(TailnetDetector.isAccepted('2001:db8::1'), isFalse);
      expect(TailnetDetector.isAccepted(''), isFalse);
      expect(TailnetDetector.isAccepted('example.com'), isFalse);
      expect(TailnetDetector.isAccepted('100.0.0.1'), isFalse);
    });

    test('isLocalNetworkHost delegates to isAccepted (contract pin)', () {
      // Why: enhanced_discovery.dart now defines isLocalNetworkHost as a thin
      // delegate. This pins that the two predicates never drift.
      for (final host in <String>[
        '127.0.0.1',
        '10.1.2.3',
        '172.20.0.1',
        '192.168.50.1',
        '100.64.0.1',
        'fd7a:115c:a1e0::1',
        'fe80::1',
        'fc00::1',
        'skotiq.local',
        '8.8.8.8',
        '2001:db8::1',
        '100.0.0.1',
        '',
        'garbage',
      ]) {
        expect(
          isLocalNetworkHost(host),
          TailnetDetector.isAccepted(host),
          reason: 'mismatch for "$host"',
        );
      }
    });
  });

  group('TailnetDetector.isTailscaleInterfaceAddress', () {
    test('recognises a 100.x interface address', () {
      expect(
        TailnetDetector.isTailscaleInterfaceAddress(
          InternetAddress('100.96.0.7'),
        ),
        isTrue,
      );
    });

    test('rejects a LAN interface address', () {
      expect(
        TailnetDetector.isTailscaleInterfaceAddress(
          InternetAddress('192.168.1.10'),
        ),
        isFalse,
      );
    });

    test('recognises the Tailscale IPv6 /32', () {
      expect(
        TailnetDetector.isTailscaleInterfaceAddress(
          InternetAddress('fd7a:115c:a1e0::1', type: InternetAddressType.IPv6),
        ),
        isTrue,
      );
    });
  });

  group('TailnetDetector.isTailscaleEndpoint — IP literals OR MagicDNS', () {
    test('tailnet IP literals are endpoints (same as isTailscaleHost)', () {
      expect(TailnetDetector.isTailscaleEndpoint('100.64.0.1'), isTrue);
      expect(TailnetDetector.isTailscaleEndpoint('100.127.255.255'), isTrue);
      expect(TailnetDetector.isTailscaleEndpoint('fd7a:115c:a1e0::1'), isTrue);
    });

    test(
      'a *.ts.net MagicDNS name is an endpoint (isTailscaleHost is not)',
      () {
        const magic = 'my-rig.tailnet-name.ts.net';
        // The whole point of the dedicated predicate: a MagicDNS name is a
        // tailnet endpoint even though it is not an IP literal, so the IP-only
        // isTailscaleHost returns false for it.
        expect(TailnetDetector.isTailscaleHost(magic), isFalse);
        expect(TailnetDetector.isTailscaleEndpoint(magic), isTrue);
      },
    );

    test('MagicDNS matching is case-insensitive and trims whitespace', () {
      expect(
        TailnetDetector.isTailscaleEndpoint('MyRig.Tailnet.TS.NET'),
        isTrue,
      );
      expect(
        TailnetDetector.isTailscaleEndpoint('  rig.tail.ts.net  '),
        isTrue,
      );
    });

    test('the bare suffix and non-tailnet hosts are not endpoints', () {
      expect(TailnetDetector.isTailscaleEndpoint('.ts.net'), isFalse);
      expect(TailnetDetector.isTailscaleEndpoint('192.168.1.10'), isFalse);
      expect(TailnetDetector.isTailscaleEndpoint('example.com'), isFalse);
      expect(TailnetDetector.isTailscaleEndpoint('8.8.8.8'), isFalse);
      expect(TailnetDetector.isTailscaleEndpoint(''), isFalse);
      // A host that merely contains, but does not end with, the suffix.
      expect(TailnetDetector.isTailscaleEndpoint('ts.net.evil.com'), isFalse);
    });
  });
}
