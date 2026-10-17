// Security regression tests for the one-tap LAN pairing trust boundary.
//
// `isPrivateLanAddress` is the gate that decides whether a device may pair
// without a code. Getting it wrong either breaks the couch use case (rejecting
// a real LAN phone) or opens a hole (accepting a remote/relay/tailnet client).
// These cases pin the exact boundary.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/pairing_handlers.dart';

void main() {
  group('isPrivateLanAddress — ALLOWED (one-tap LAN)', () {
    for (final ip in const [
      '192.168.1.50', // home Wi-Fi
      '192.168.0.2',
      '10.0.0.5', // 10.0.0.0/8
      '10.255.1.1',
      '172.16.0.9', // 172.16.0.0/12 lower edge
      '172.31.255.254', // 172.16.0.0/12 upper edge
      '169.254.10.10', // link-local
    ]) {
      test('$ip is LAN-trusted', () {
        expect(isPrivateLanAddress(InternetAddress(ip)), isTrue);
      });
    }

    test('IPv6 ULA fc00::/7 is LAN-trusted', () {
      expect(isPrivateLanAddress(InternetAddress('fc00::1')), isTrue);
      expect(isPrivateLanAddress(InternetAddress('fd12:3456::1')), isTrue);
    });

    test('IPv6 link-local fe80::/10 is LAN-trusted', () {
      expect(isPrivateLanAddress(InternetAddress('fe80::1')), isTrue);
    });
  });

  group('isPrivateLanAddress — REJECTED (code flow required)', () {
    for (final ip in const [
      '127.0.0.1', // loopback — relay forwards arrive here
      '8.8.8.8', // public
      '1.1.1.1',
      '100.64.0.1', // CGNAT / Tailscale lower edge
      '100.100.100.100',
      '100.127.255.255', // CGNAT upper edge
      '172.15.0.1', // just below the 172.16/12 block
      '172.32.0.1', // just above the 172.16/12 block
      '192.169.0.1', // not 192.168
      '169.253.0.1', // not link-local
    ]) {
      test('$ip is NOT LAN-trusted', () {
        expect(isPrivateLanAddress(InternetAddress(ip)), isFalse);
      });
    }

    test('Tailscale ULA fd7a:115c::/32 is NOT LAN-trusted', () {
      // Inside fc00::/7 but must be excluded so tailnet stays code-required.
      expect(isPrivateLanAddress(InternetAddress('fd7a:115c::1')), isFalse);
      expect(
        isPrivateLanAddress(InternetAddress('fd7a:115c:a1b2::1')),
        isFalse,
      );
    });

    test('IPv6 loopback ::1 is NOT LAN-trusted', () {
      expect(isPrivateLanAddress(InternetAddress('::1')), isFalse);
    });

    test('public IPv6 is NOT LAN-trusted', () {
      expect(isPrivateLanAddress(InternetAddress('2606:4700::1111')), isFalse);
    });
  });
}
