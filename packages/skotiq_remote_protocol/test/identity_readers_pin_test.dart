// What each reader of a host's identity makes of the same advertised keys:
// the /api/info merge, the UDP beacon, the mDNS TXT record and the probe.
// The rows include keys of the wrong type, which no Skotiq release writes
// but a foreign service on the LAN can: each reader takes such a key as
// missing, where the merge used to throw and the beacon was dropped.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

String _show(DiscoveredServer s) =>
    'name=${s.name} version=${s.version} mode=${s.mode} '
    'auth=${s.authRequired}/${s.authenticationMode} '
    'pairing=${s.pairingSupported} fp=${s.fingerprint} scheme=${s.scheme} '
    'hostName=${s.hostName} hostMode=${s.hostMode} '
    'display=${s.displayName}';

String _attempt(DiscoveredServer? Function() read) {
  try {
    final server = read();
    return server == null ? 'dropped' : _show(server);
  } catch (error) {
    return 'throws ${error is TypeError ? 'TypeError' : error.runtimeType}';
  }
}

const _full = <String, Object?>{
  'name': 'OBS-PC',
  'hostName': 'OBS-PC',
  'hostMode': 'gui',
  'version': '9.1.0',
  'mode': 'gui',
  'scheme': 'https',
  'authRequired': true,
  'authenticationMode': 'token',
  'pairingSupported': true,
  'fingerprint': 'abcdef0123456789',
};

/// Each row: the identity keys a host sent, starting from [_full].
final _rows = <String, Map<String, Object?>>{
  'current host': _full,
  'older host': {..._full}
    ..remove('hostName')
    ..remove('hostMode'),
  'blank computer name': {..._full, 'hostName': '  ', 'hostMode': ''},
  'name of another type': {..._full, 'name': 5},
  'version of another type': {..._full, 'version': 9},
  'mode of another type': {..._full, 'mode': 1},
  'authRequired of another type': {..._full, 'authRequired': 'yes'},
  'authenticationMode of another type': {..._full, 'authenticationMode': false},
  'pairingSupported of another type': {..._full, 'pairingSupported': 1},
  'fingerprint of another type': {..._full, 'fingerprint': 7},
  'hostName of another type': {..._full, 'hostName': 3},
  'hostMode of another type': {..._full, 'hostMode': true},
};

DiscoveredServer _seed() =>
    DiscoveredServer(host: '192.168.1.50', webPort: 8080, name: 'Skotiq');

const _merged = <String, String>{
  'current host':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'older host':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=null hostMode=null display=OBS-PC',
  'blank computer name':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=null hostMode=null display=OBS-PC',
  'name of another type':
      'name=Skotiq version=9.1.0 mode=gui auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'version of another type':
      'name=OBS-PC version=null mode=gui auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'mode of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'authRequired of another type':
      'name=OBS-PC version=9.1.0 mode=gui auth=false/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'authenticationMode of another type':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/none pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'pairingSupported of another type':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/token pairing=false fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'fingerprint of another type':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/token pairing=true fp=null scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'hostName of another type':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=null hostMode=gui display=OBS-PC',
  'hostMode of another type':
      'name=OBS-PC version=9.1.0 mode=gui auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=null display=OBS-PC',
};

const _beacons = <String, String>{
  'current host':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'older host':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=null hostMode=null display=OBS-PC',
  'blank computer name':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=null hostMode=null display=OBS-PC',
  'name of another type':
      'name=Skotiq version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'version of another type':
      'name=OBS-PC version=null mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'mode of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'authRequired of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=false/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'authenticationMode of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/none pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'pairingSupported of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=false fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'fingerprint of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=null scheme=https hostName=OBS-PC hostMode=gui display=OBS-PC',
  'hostName of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=null hostMode=gui display=OBS-PC',
  'hostMode of another type':
      'name=OBS-PC version=9.1.0 mode=desktop auth=true/token pairing=true fp=abcdef0123456789 scheme=https hostName=OBS-PC hostMode=null display=OBS-PC',
};

/// TXT records carry strings only, so their rows are of what a TXT can hold.
final _txtRows = <String, Map<String, String>>{
  'current host': {
    'version': '9.1.0',
    'scheme': 'https',
    'fingerprint': 'abcdef0123456789',
    'pairingSupported': 'true',
    'name': 'OBS-PC',
    'hostName': 'OBS-PC',
    'hostMode': 'gui',
  },
  'older host': {
    'version': '9.1.0',
    'scheme': 'http',
    'fingerprint': 'abcdef0123456789',
    'pairingSupported': 'true',
    'name': 'Skotiq',
  },
  'blank computer name': {
    'version': '9.1.0',
    'name': 'Skotiq',
    'hostName': ' ',
  },
};

const _nsd = <String, String>{
  'current host':
      'name=OBS-PC version=9.1.0 mode=desktop auth=false/none pairing=true fp=abcdef0123456789 scheme=https hostName=null hostMode=null display=OBS-PC',
  'older host':
      'name=Skotiq version=9.1.0 mode=desktop auth=false/none pairing=true fp=abcdef0123456789 scheme=http hostName=null hostMode=null display=192.168.1.50',
  'blank computer name':
      'name=Skotiq version=9.1.0 mode=desktop auth=false/none pairing=false fp=null scheme=http hostName=null hostMode=null display=192.168.1.50',
};

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

/// What [EnhancedSkotiqDiscovery.probeServer] says of a host with no
/// credential, by the keys its /api/info carries.
const _probes = <String, ServerProbeOutcome>{
  'current host': ServerProbeOutcome.reachable,
  'older host': ServerProbeOutcome.reachable,
  'blank computer name': ServerProbeOutcome.reachable,
  'name of another type': ServerProbeOutcome.reachable,
  'version of another type': ServerProbeOutcome.unreachable,
  'mode of another type': ServerProbeOutcome.reachable,
  'authRequired of another type': ServerProbeOutcome.reachable,
  'authenticationMode of another type': ServerProbeOutcome.reachable,
  'pairingSupported of another type': ServerProbeOutcome.unreachable,
  'fingerprint of another type': ServerProbeOutcome.reachable,
  'hostName of another type': ServerProbeOutcome.reachable,
  'hostMode of another type': ServerProbeOutcome.reachable,
};

void main() {
  for (final MapEntry(key: row, value: keys) in _rows.entries) {
    test('/api/info merge: $row', () {
      expect(
        _attempt(() => EnhancedSkotiqDiscovery.mergeServerInfo(_seed(), keys)),
        _merged[row],
      );
    });

    test('UDP beacon: $row', () {
      final packet =
          'SKOTIQ_RESPONSE_V2:${jsonEncode({'protocol': 1, ...keys, 'webPort': 8080, 'signalingPort': 8080})}';
      expect(
        _attempt(
          () => SkotiqDiscovery.tryParseResponsePacket(packet, '192.168.1.50'),
        ),
        _beacons[row],
      );
    });

    test('probe: $row', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(keys));
        await request.response.close();
      });
      final outcome = await EnhancedSkotiqDiscovery.probeServer(
        InternetAddress.loopbackIPv4.address,
        server.port,
      );
      expect(outcome, _probes[row]);
    });
  }

  for (final MapEntry(key: row, value: txt) in _txtRows.entries) {
    test('mDNS TXT: $row', () {
      expect(
        _attempt(
          () => EnhancedSkotiqDiscovery.serverFromNsd(
            host: '192.168.1.50',
            port: 8080,
            txt: {
              for (final MapEntry(:key, :value) in txt.entries)
                key: _bytes(value),
            },
          ),
        ),
        _nsd[row],
      );
    });
  }
}
