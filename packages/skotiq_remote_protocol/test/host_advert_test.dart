// The identity a host advertises, in the shapes other releases read. These
// maps are the ones the host wrote by hand before HostAdvert; a key may be
// added, never dropped or renamed.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  const advert = HostAdvert(
    hostName: 'OBS-PC',
    hostMode: SkotiqHostMode.gui,
    version: '9.1.0',
    scheme: 'https',
    fingerprint: 'abcdef0123456789',
    authRequired: true,
  );

  test('the TXT record', () {
    expect(advert.toTxt(), {
      'version': '9.1.0',
      'scheme': 'https',
      'fingerprint': 'abcdef0123456789',
      'pairingSupported': 'true',
      'name': 'OBS-PC',
      'hostName': 'OBS-PC',
      'hostMode': 'gui',
    });
  });

  test('the identity keys of /api/info', () {
    expect(advert.toInfoJson(), {
      'name': 'OBS-PC',
      'hostName': 'OBS-PC',
      'product': 'Skotiq',
      'hostMode': 'gui',
      'version': '9.1.0',
      'mode': 'gui',
      'authRequired': true,
      'authenticationMode': 'token',
      'pairingSupported': true,
      'fingerprint': 'abcdef0123456789',
    });
  });

  test('the UDP beacon, and a client reads it back', () {
    final payload = SkotiqDiscovery.beaconPayload(
      advert,
      webPort: 8080,
      signalingPort: 8080,
    );
    expect(payload, {
      'protocol': '2',
      'name': 'OBS-PC',
      'version': '9.1.0',
      'webPort': 8080,
      'signalingPort': 8080,
      'scheme': 'https',
      'authRequired': true,
      'authenticationMode': 'token',
      'pairingSupported': true,
      'fingerprint': 'abcdef0123456789',
      'hostName': 'OBS-PC',
      'hostMode': 'gui',
    });
    final server = SkotiqDiscovery.tryParseResponsePacket(
      'SKOTIQ_RESPONSE_V2:${jsonEncode(payload)}',
      '192.168.1.20',
    )!;
    expect(server.name, 'OBS-PC');
    expect(server.version, '9.1.0');
    expect(server.scheme, 'https');
    expect(server.fingerprint, 'abcdef0123456789');
    expect(server.hostMode, 'gui');
  });

  test('a TXT record reads back; missing or unusable values are null', () {
    final read = HostTxt.parse(advert.toTxt());
    expect(read.version, '9.1.0');
    expect(read.name, 'OBS-PC');
    expect(read.scheme, 'https');
    expect(read.fingerprint, 'abcdef0123456789');
    expect(read.pairingSupported, isTrue);
    expect(read.hostName, 'OBS-PC');
    expect(read.hostMode, 'gui');
    expect(read.signalingPort, isNull);

    final sparse = HostTxt.parse(const {
      'scheme': 'ftp',
      'fingerprint': '',
      'pairingSupported': 'no',
      'signaling_port': '45678',
    });
    expect(sparse.version, isNull);
    expect(sparse.scheme, isNull);
    expect(sparse.fingerprint, isNull);
    expect(sparse.pairingSupported, isFalse);
    expect(sparse.signalingPort, 45678);
  });
}
