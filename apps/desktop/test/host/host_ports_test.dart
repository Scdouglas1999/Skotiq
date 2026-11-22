// The updater cannot import the protocol package, so both declare the LAN
// update-push port; the host uses the updater's and clients probe the
// protocol's.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show kLanUpdatePushPort;
import 'package:skotiq_updater/skotiq_updater.dart' show LanPushReceiver;

void main() {
  test('the updater and the protocol name the same push port', () {
    expect(LanPushReceiver.pushPort, kLanUpdatePushPort);
  });
}
