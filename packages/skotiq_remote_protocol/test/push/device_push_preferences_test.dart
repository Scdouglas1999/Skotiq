import 'package:skotiq_remote_protocol/host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const allMuted = DevicePushPreferences(
    muteSequenceFailed: true,
    muteWeatherUnsafe: true,
    muteGuidingLost: true,
    muteAutofocusFailed: true,
    muteEquipmentDisconnected: true,
  );

  test('each switch mutes its own event types', () {
    expect(
      const DevicePushPreferences(
        muteSequenceFailed: true,
      ).allows('exposureFailed'),
      isFalse,
    );
    expect(
      const DevicePushPreferences(
        muteGuidingLost: true,
      ).allows('weatherUnsafe'),
      isTrue,
    );
    for (final type in DevicePushPreferences.mutableEventTypes) {
      expect(allMuted.allows(type), isFalse, reason: type);
      expect(
        DevicePushPreferences.allEnabled.allows(type),
        isTrue,
        reason: type,
      );
    }
  });

  test('an event type no switch names, or none, is never muted', () {
    expect(allMuted.allows('sequenceCompleted'), isTrue);
    expect(allMuted.allows(null), isTrue);
    expect(
      const DevicePushPreferences(enabled: false).allows('sequenceCompleted'),
      isFalse,
    );
  });
}
