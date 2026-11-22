// A pairing QR names the computer and says whether it is the desktop app or
// the daemon, as /api/info does, without changing a key older phones read.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

const _advert = HostAdvert(
  hostName: 'observatory-pi',
  hostMode: SkotiqHostMode.headless,
  version: '9.1.0',
  scheme: 'http',
  fingerprint: 'abcdef0123456789',
  authRequired: true,
);

void main() {
  test('the QR carries the computer name and host mode in their own keys', () {
    final qr = QrConnectionData.parseStrict(
      EnhancedSkotiqDiscovery.generateQrData(
        _advert,
        host: '192.168.1.60',
        webPort: 8080,
        pairingCode: 'STAR-LYRA-1234',
      ),
    );
    expect(qr.serverName, 'Skotiq');
    expect(qr.mode, 'desktop');
    expect(qr.hostName, 'observatory-pi');
    expect(qr.hostMode, 'headless');

    final server = qr.toDiscoveredServer();
    expect(server.displayName, 'observatory-pi');
    expect(server.hostMode, 'headless');
  });

  test('a code printed before those keys still names the host by address', () {
    final qr = QrConnectionData.parseStrict(
      '{"service":"skotiq","host":"192.168.1.60","port":8080,'
      '"version":"9.0.2","fingerprint":"abcdef0123456789","name":"Skotiq",'
      '"mode":"desktop"}',
    );
    expect(qr.hostName, isNull);
    expect(qr.hostMode, isNull);
    expect(qr.toDiscoveredServer().displayName, '192.168.1.60');
  });
}
