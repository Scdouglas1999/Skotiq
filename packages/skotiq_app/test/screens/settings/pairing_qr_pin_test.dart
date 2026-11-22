// The pairing QR payloads the Paired devices and Tailscale panels show, for a
// running Remote access server. Printed codes and older phones read these
// strings: every key before `hostName` is what each panel built by hand, and
// the computer's name and `gui` are added after them.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_qr.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

const _lan =
    '{"service":"skotiq","host":"192.168.1.50","port":8080,"signalingPort":45678,"version":"9.1.0","fingerprint":"abcdef0123456789abcdef0123456789","scheme":"http","name":"Skotiq","mode":"desktop","authRequired":true,"authenticationMode":"token","pairingSupported":true,"pairingCode":"STAR-LYRA-1234","hostName":"OBS-PC","hostMode":"gui"}';
const _tailnet =
    '{"service":"skotiq","host":"100.96.0.7","port":8080,"signalingPort":45678,"version":"9.1.0","fingerprint":"abcdef0123456789abcdef0123456789","scheme":"http","name":"Skotiq","mode":"desktop","authRequired":true,"authenticationMode":"token","pairingSupported":true,"pairingCode":"STAR-LYRA-1234","hostName":"OBS-PC","hostMode":"gui"}';

/// The GUI host's Remote access server as the desktop starts it.
const _running = WebServerState(
  isRunning: true,
  actualPort: 8080,
  requiresAuthentication: true,
  serverFingerprint: 'abcdef0123456789abcdef0123456789',
  advert: HostAdvert(
    hostName: 'OBS-PC',
    hostMode: SkotiqHostMode.gui,
    version: '9.1.0',
    scheme: 'http',
    fingerprint: 'abcdef0123456789abcdef0123456789',
    authRequired: true,
  ),
);

void main() {
  test('the LAN pairing QR', () {
    expect(
      pairingQrData(
        _running,
        host: '192.168.1.50',
        pairingCode: 'STAR-LYRA-1234',
      ),
      _lan,
    );
  });

  test('the Tailscale pairing QR', () {
    expect(
      pairingQrData(_running,
          host: '100.96.0.7', pairingCode: 'STAR-LYRA-1234'),
      _tailnet,
    );
  });

  test('no QR before the server has advertised itself', () {
    expect(
      pairingQrData(
        const WebServerState(isRunning: true),
        host: '192.168.1.50',
        pairingCode: 'STAR-LYRA-1234',
      ),
      isNull,
    );
  });
}
