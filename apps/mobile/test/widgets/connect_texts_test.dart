import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_mobile/widgets/connect_texts.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  test('every discovery step says where the phone is looking', () {
    expect(
      connectActivityText(const ConnectDiscovering()),
      'Looking for it on this Wi-Fi…',
    );
    expect(
      connectActivityText(const ConnectDiscovering(DiscoveryStage.lastServer)),
      'Trying the computer this phone used last…',
    );
    for (final stage in [
      DiscoveryStage.bonjour,
      DiscoveryStage.broadcast,
      DiscoveryStage.nothingFound,
    ]) {
      expect(
        connectActivityText(ConnectDiscovering(stage)),
        'Looking for it on this Wi-Fi…',
        reason: '$stage',
      );
    }
  });
}
