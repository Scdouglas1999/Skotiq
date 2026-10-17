import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/utils/equipment_disconnect.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('equipmentDisconnectShouldSkip', () {
    test('skips only disconnected state', () {
      expect(
        equipmentDisconnectShouldSkip(DeviceConnectionState.disconnected),
        isTrue,
      );
      expect(
        equipmentDisconnectShouldSkip(DeviceConnectionState.connected),
        isFalse,
      );
      expect(
        equipmentDisconnectShouldSkip(DeviceConnectionState.error),
        isFalse,
      );
    });
  });
}
