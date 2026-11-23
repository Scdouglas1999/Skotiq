import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/errors/bridge_error_message.dart';
import 'package:skotiq_core/src/errors/skotiq_error.dart';

void main() {
  test('a refusal reads as the variant it was raised as before its kind', () {
    String fields(SkotiqError e) =>
        '${e.category} ${e.message} ${e.userMessage} ${e.reason} '
        '${e.isRecoverable} ${e.shouldReconnect} ${e.isTimeout}';
    for (final kind in bridge.Refusal.values) {
      final refused = skotiqErrorFromBridge(
        bridge.SkotiqError.refused(kind: kind, message: 'words'),
      );
      final before = skotiqErrorFromBridge(switch (kind) {
        bridge.Refusal.lightLeak => const bridge.SkotiqError.invalidInput(
          'words',
        ),
        bridge.Refusal.liveStackMisaligned ||
        bridge.Refusal.liveStackOtherFilter ||
        bridge.Refusal.liveStackUnreadable =>
          const bridge.SkotiqError.imageError('words'),
        _ => const bridge.SkotiqError.operationFailed('words'),
      });
      expect(fields(refused), fields(before), reason: '$kind');
    }
  });

  group('bridgeErrorMessage', () {
    test('returns the authored reason, not the freezed debug rendering', () {
      const error = bridge.SkotiqError.connectionFailed(
        deviceId: 'localhost:11111',
        reason: 'No Alpaca server answered on port 11111',
      );

      expect(
        bridgeErrorMessage(error),
        'No Alpaca server answered on port 11111',
      );
      expect(error.toString(), contains('SkotiqError'));
    });

    test('builds a sentence for variants that carry only identifiers', () {
      expect(
        bridgeErrorMessage(
          const bridge.SkotiqError.notSupported(
            deviceId: 'Mount A',
            operation: 'pulse guiding',
          ),
        ),
        "'Mount A' does not support pulse guiding",
      );
      expect(
        bridgeErrorMessage(const bridge.SkotiqError.deviceNotFound('Camera 1')),
        "Device 'Camera 1' was not found",
      );
    });

    test('returns null for a variant whose payload is only values', () {
      expect(
        bridgeErrorMessage(
          const bridge.SkotiqError.parameterOutOfRange(
            paramName: 'gain',
            value: '900',
            min: '0',
            max: '500',
          ),
        ),
        isNull,
      );
    });

    test('returns null for errors that are not bridge errors', () {
      expect(bridgeErrorMessage(StateError('no transport')), isNull);
      expect(bridgeErrorMessage(Exception('write failed')), isNull);
    });
  });
}
