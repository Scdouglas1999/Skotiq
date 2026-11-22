// What the phone's nsd browse makes of a `_skotiq._tcp` service before it
// reads the host's /api/info.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  test('a service whose TXT names no release has no release', () {
    final server = EnhancedSkotiqDiscovery.serverFromNsd(
      host: '192.168.1.20',
      port: 8080,
      serviceName: 'Skotiq on obs-pi',
      txt: {'scheme': _bytes('http'), 'name': _bytes('Skotiq')},
    );
    expect(
      server.version,
      isNull,
      reason: 'a made-up release would be shown, and compared, as the '
          "host's until /api/info answers",
    );
    expect(server.name, 'Skotiq');
  });

  test('the TXT values a host writes are read', () {
    final server = EnhancedSkotiqDiscovery.serverFromNsd(
      host: '192.168.1.20',
      port: 8443,
      txt: {
        'version': _bytes('9.1.0'),
        'scheme': _bytes('https'),
        'fingerprint': _bytes('abcdef0123456789'),
        'pairingSupported': _bytes('true'),
        'name': _bytes('OBS-PC'),
      },
    );
    expect(server.version, '9.1.0');
    expect(server.scheme, 'https');
    expect(server.fingerprint, 'abcdef0123456789');
    expect(server.pairingSupported, isTrue);
    expect(server.name, 'OBS-PC');
    expect(server.webPort, 8443);
  });
}
