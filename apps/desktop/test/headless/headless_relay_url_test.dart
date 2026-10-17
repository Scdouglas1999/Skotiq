// Regression tests for the relay-URL validation used by the headless relay
// bootstrap (apps/desktop/lib/headless/headless_relay_bootstrap.dart).
//
// startRelayUplink itself touches the filesystem and the network, so it has no
// pure seam. The one piece of validation it performs before any I/O is
// RelayUplink.normalizeRelayUrl(Uri.parse(raw)) — a misconfigured URL there is
// the path that disables the relay without stopping the daemon. That
// normaliser is the load-bearing, deterministic seam, so it is what we pin.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show RelayUplink;

void main() {
  group('RelayUplink.normalizeRelayUrl — accepted schemes', () {
    test('http is mapped to ws', () {
      final out = RelayUplink.normalizeRelayUrl(
        Uri.parse('http://relay.example:8443'),
      );
      expect(out.scheme, 'ws');
      expect(out.host, 'relay.example');
      expect(out.port, 8443);
    });

    test('https is mapped to wss', () {
      final out = RelayUplink.normalizeRelayUrl(
        Uri.parse('https://relay.example'),
      );
      expect(out.scheme, 'wss');
    });

    test('ws is preserved', () {
      final out = RelayUplink.normalizeRelayUrl(Uri.parse('ws://relay.local'));
      expect(out.scheme, 'ws');
    });

    test('wss is preserved', () {
      final out = RelayUplink.normalizeRelayUrl(Uri.parse('wss://relay.local'));
      expect(out.scheme, 'wss');
    });

    test('a reverse-proxy subpath is preserved', () {
      final out = RelayUplink.normalizeRelayUrl(
        Uri.parse('https://relay.example/tunnel'),
      );
      expect(out.scheme, 'wss');
      expect(out.path, '/tunnel');
    });

    test('a trailing slash is stripped so suffixes append uniformly', () {
      final out = RelayUplink.normalizeRelayUrl(
        Uri.parse('https://relay.example/tunnel/'),
      );
      expect(out.path, '/tunnel');
    });

    test('multiple trailing slashes are all stripped', () {
      final out = RelayUplink.normalizeRelayUrl(
        Uri.parse('https://relay.example/tunnel///'),
      );
      expect(out.path, '/tunnel');
    });
  });

  group('RelayUplink.normalizeRelayUrl — rejected schemes', () {
    test('an unsupported scheme throws ArgumentError', () {
      expect(
        () => RelayUplink.normalizeRelayUrl(Uri.parse('ftp://relay.example')),
        throwsArgumentError,
      );
    });

    test('a schemeless URI throws ArgumentError', () {
      // The bootstrap wraps this in try/catch and disables the relay, leaving
      // LAN access unaffected — but the normaliser itself must reject it.
      expect(
        () => RelayUplink.normalizeRelayUrl(Uri.parse('relay.example:8443')),
        throwsArgumentError,
      );
    });
  });
}
