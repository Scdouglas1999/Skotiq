// The pairing QR payloads the Paired devices and Tailscale panels show, for a
// running Remote access server (the arguments both panels passed when this
// was recorded). Printed codes and older phones read these
// strings, so a change of structure must leave them byte for byte.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

const _lan =
    '{"service":"skotiq","host":"192.168.1.50","port":8080,"signalingPort":45678,"version":"9.1.0","fingerprint":"abcdef0123456789abcdef0123456789","scheme":"http","name":"Skotiq","mode":"desktop","authRequired":true,"authenticationMode":"token","pairingSupported":true,"pairingCode":"STAR-LYRA-1234"}';
const _tailnet =
    '{"service":"skotiq","host":"100.96.0.7","port":8080,"signalingPort":45678,"version":"9.1.0","fingerprint":"abcdef0123456789abcdef0123456789","scheme":"http","name":"Skotiq","mode":"desktop","authRequired":true,"authenticationMode":"token","pairingSupported":true,"pairingCode":"STAR-LYRA-1234"}';

void main() {
  test('the LAN pairing QR', () {
    expect(
      EnhancedSkotiqDiscovery.generateQrData(
        host: '192.168.1.50',
        webPort: 8080,
        version: '9.1.0',
        fingerprint: 'abcdef0123456789abcdef0123456789',
        serverName: 'Skotiq',
        mode: 'desktop',
        authRequired: true,
        authenticationMode: 'token',
        pairingSupported: true,
        pairingCode: 'STAR-LYRA-1234',
      ),
      _lan,
    );
  });

  test('the Tailscale pairing QR', () {
    expect(
      EnhancedSkotiqDiscovery.generateQrData(
        host: '100.96.0.7',
        webPort: 8080,
        version: '9.1.0',
        fingerprint: 'abcdef0123456789abcdef0123456789',
        serverName: 'Skotiq',
        mode: 'desktop',
        authRequired: true,
        authenticationMode: 'token',
        pairingSupported: true,
        pairingCode: 'STAR-LYRA-1234',
      ),
      _tailnet,
    );
  });
}
