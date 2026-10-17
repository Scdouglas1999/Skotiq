import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_capabilities.dart';

/// Tests for the capability-range fields added for the Device Capability
/// Completeness work (component C4):
///   - [CameraCapabilities.coolerMinTempC] / [CameraCapabilities.coolerMaxTempC]
///   - [MountCapabilities.minPulseGuideMs] / [MountCapabilities.maxPulseGuideMs]
///   - [RotatorCapabilities.minAngleDeg] / [RotatorCapabilities.maxAngleDeg]
///
/// Each field follows the established dual-key (camelCase ?? snake_case)
/// `fromJson` + `toJson` pattern. These tests lock in:
///   1. camelCase and snake_case keys decode to identical values.
///   2. Maps missing the new keys decode to `null` (back-compat — these are
///      honest-`null` optionals, never fabricated defaults).
///   3. `toJson` always emits the new keys.
///   4. A `toJson` -> `fromJson` round-trip preserves populated values.
void main() {
  group('CameraCapabilities cooler temperature range', () {
    test('camelCase and snake_case keys decode to the same values', () {
      final camel = CameraCapabilities.fromJson(const {
        'maxWidth': 100,
        'maxHeight': 100,
        'bitDepth': 16,
        'coolerMinTempC': -45.0,
        'coolerMaxTempC': 30.5,
      });
      final snake = CameraCapabilities.fromJson(const {
        'max_width': 100,
        'max_height': 100,
        'bit_depth': 16,
        'cooler_min_temp_c': -45.0,
        'cooler_max_temp_c': 30.5,
      });

      expect(camel.coolerMinTempC, -45.0);
      expect(camel.coolerMaxTempC, 30.5);
      expect(snake.coolerMinTempC, camel.coolerMinTempC);
      expect(snake.coolerMaxTempC, camel.coolerMaxTempC);
    });

    test('integer JSON numbers are coerced to double', () {
      final caps = CameraCapabilities.fromJson(const {
        'maxWidth': 100,
        'maxHeight': 100,
        'bitDepth': 16,
        'coolerMinTempC': -40,
        'coolerMaxTempC': 25,
      });

      expect(caps.coolerMinTempC, -40.0);
      expect(caps.coolerMaxTempC, 25.0);
    });

    test('missing keys decode to null (back-compat)', () {
      final caps = CameraCapabilities.fromJson(const {
        'maxWidth': 100,
        'maxHeight': 100,
        'bitDepth': 16,
      });

      expect(caps.coolerMinTempC, isNull);
      expect(caps.coolerMaxTempC, isNull);
    });

    test('toJson includes the new keys', () {
      const caps = CameraCapabilities(
        maxWidth: 100,
        maxHeight: 100,
        bitDepth: 16,
        coolerMinTempC: -45.0,
        coolerMaxTempC: 30.5,
      );
      final json = caps.toJson();

      expect(json.containsKey('coolerMinTempC'), isTrue);
      expect(json.containsKey('coolerMaxTempC'), isTrue);
      expect(json['coolerMinTempC'], -45.0);
      expect(json['coolerMaxTempC'], 30.5);
    });

    test('toJson emits null keys when values are absent', () {
      const caps = CameraCapabilities(
        maxWidth: 100,
        maxHeight: 100,
        bitDepth: 16,
      );
      final json = caps.toJson();

      expect(json.containsKey('coolerMinTempC'), isTrue);
      expect(json.containsKey('coolerMaxTempC'), isTrue);
      expect(json['coolerMinTempC'], isNull);
      expect(json['coolerMaxTempC'], isNull);
    });

    test('round-trip toJson -> fromJson preserves populated values', () {
      const original = CameraCapabilities(
        maxWidth: 100,
        maxHeight: 100,
        bitDepth: 16,
        coolerMinTempC: -45.0,
        coolerMaxTempC: 30.5,
      );
      final restored = CameraCapabilities.fromJson(original.toJson());

      expect(restored.coolerMinTempC, original.coolerMinTempC);
      expect(restored.coolerMaxTempC, original.coolerMaxTempC);
    });
  });

  group('MountCapabilities pulse-guide range', () {
    test('camelCase and snake_case keys decode to the same values', () {
      final camel = MountCapabilities.fromJson(const {
        'minPulseGuideMs': 10.0,
        'maxPulseGuideMs': 9999.0,
      });
      final snake = MountCapabilities.fromJson(const {
        'min_pulse_guide_ms': 10.0,
        'max_pulse_guide_ms': 9999.0,
      });

      expect(camel.minPulseGuideMs, 10.0);
      expect(camel.maxPulseGuideMs, 9999.0);
      expect(snake.minPulseGuideMs, camel.minPulseGuideMs);
      expect(snake.maxPulseGuideMs, camel.maxPulseGuideMs);
    });

    test('integer JSON numbers are coerced to double', () {
      final caps = MountCapabilities.fromJson(const {
        'minPulseGuideMs': 5,
        'maxPulseGuideMs': 60000,
      });

      expect(caps.minPulseGuideMs, 5.0);
      expect(caps.maxPulseGuideMs, 60000.0);
    });

    test('missing keys decode to null (back-compat)', () {
      final caps = MountCapabilities.fromJson(const {});

      expect(caps.minPulseGuideMs, isNull);
      expect(caps.maxPulseGuideMs, isNull);
    });

    test('toJson includes the new keys', () {
      const caps = MountCapabilities(
        minPulseGuideMs: 10.0,
        maxPulseGuideMs: 9999.0,
      );
      final json = caps.toJson();

      expect(json.containsKey('minPulseGuideMs'), isTrue);
      expect(json.containsKey('maxPulseGuideMs'), isTrue);
      expect(json['minPulseGuideMs'], 10.0);
      expect(json['maxPulseGuideMs'], 9999.0);
    });

    test('toJson emits null keys when values are absent', () {
      const caps = MountCapabilities();
      final json = caps.toJson();

      expect(json.containsKey('minPulseGuideMs'), isTrue);
      expect(json.containsKey('maxPulseGuideMs'), isTrue);
      expect(json['minPulseGuideMs'], isNull);
      expect(json['maxPulseGuideMs'], isNull);
    });

    test('round-trip toJson -> fromJson preserves populated values', () {
      const original = MountCapabilities(
        minPulseGuideMs: 10.0,
        maxPulseGuideMs: 9999.0,
      );
      final restored = MountCapabilities.fromJson(original.toJson());

      expect(restored.minPulseGuideMs, original.minPulseGuideMs);
      expect(restored.maxPulseGuideMs, original.maxPulseGuideMs);
    });
  });

  group('RotatorCapabilities angle range', () {
    test('camelCase and snake_case keys decode to the same values', () {
      final camel = RotatorCapabilities.fromJson(const {
        'minAngleDeg': 0.0,
        'maxAngleDeg': 360.0,
      });
      final snake = RotatorCapabilities.fromJson(const {
        'min_angle_deg': 0.0,
        'max_angle_deg': 360.0,
      });

      expect(camel.minAngleDeg, 0.0);
      expect(camel.maxAngleDeg, 360.0);
      expect(snake.minAngleDeg, camel.minAngleDeg);
      expect(snake.maxAngleDeg, camel.maxAngleDeg);
    });

    test('integer JSON numbers are coerced to double', () {
      final caps = RotatorCapabilities.fromJson(const {
        'minAngleDeg': 0,
        'maxAngleDeg': 360,
      });

      expect(caps.minAngleDeg, 0.0);
      expect(caps.maxAngleDeg, 360.0);
    });

    test('missing keys decode to null (back-compat)', () {
      final caps = RotatorCapabilities.fromJson(const {});

      expect(caps.minAngleDeg, isNull);
      expect(caps.maxAngleDeg, isNull);
    });

    test('toJson includes the new keys', () {
      const caps = RotatorCapabilities(minAngleDeg: 0.0, maxAngleDeg: 360.0);
      final json = caps.toJson();

      expect(json.containsKey('minAngleDeg'), isTrue);
      expect(json.containsKey('maxAngleDeg'), isTrue);
      expect(json['minAngleDeg'], 0.0);
      expect(json['maxAngleDeg'], 360.0);
    });

    test('toJson emits null keys when values are absent', () {
      const caps = RotatorCapabilities();
      final json = caps.toJson();

      expect(json.containsKey('minAngleDeg'), isTrue);
      expect(json.containsKey('maxAngleDeg'), isTrue);
      expect(json['minAngleDeg'], isNull);
      expect(json['maxAngleDeg'], isNull);
    });

    test('round-trip toJson -> fromJson preserves populated values', () {
      const original = RotatorCapabilities(
        minAngleDeg: 0.0,
        maxAngleDeg: 360.0,
      );
      final restored = RotatorCapabilities.fromJson(original.toJson());

      expect(restored.minAngleDeg, original.minAngleDeg);
      expect(restored.maxAngleDeg, original.maxAngleDeg);
    });
  });
}
