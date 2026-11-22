// LAN push frames are verified against the rig the phone is linked to. After
// switching rigs the saved server can still be the previous rig (the connect
// flow swaps the backend before it saves, and a relay link saves nothing), and
// its fingerprint would drop every frame of the new rig.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/mobile_sequence_hooks.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

DiscoveredServer _rig(String host, {String? fingerprint, int port = 8080}) =>
    DiscoveredServer(
      host: host,
      webPort: port,
      name: host,
      fingerprint: fingerprint,
    );

void main() {
  test('the linked rig\'s fingerprint wins over the saved rig\'s', () {
    expect(
      lanPushFingerprint(
        connected: _rig('rig-b', fingerprint: 'bb'),
        saved: _rig('rig-a', fingerprint: 'aa'),
      ),
      'bb',
    );
  });

  test('a link without a fingerprint takes the saved one of the same rig', () {
    expect(
      lanPushFingerprint(
        connected: _rig('rig-a'),
        saved: _rig('rig-a', fingerprint: 'aa'),
      ),
      'aa',
    );
    expect(
      lanPushFingerprint(
        connected: _rig('rig-b'),
        saved: _rig('rig-a', fingerprint: 'aa'),
      ),
      isNull,
    );
  });

  test('before the connect flow records a rig the saved one stands', () {
    expect(
      lanPushFingerprint(
        connected: null,
        saved: _rig('rig-a', fingerprint: 'aa'),
      ),
      'aa',
    );
  });
}
