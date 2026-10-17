import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/bridge_error_message.dart';

void main() {
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
        bridgeErrorMessage(
          const bridge.SkotiqError.deviceNotFound('Camera 1'),
        ),
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
