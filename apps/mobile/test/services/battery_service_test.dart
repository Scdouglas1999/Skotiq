// Tests for the battery-aware polling throttle.
//
// We don't instantiate the BatteryService singleton itself (that talks
// to platform channels that aren't available in the unit-test
// environment); we only exercise the pure functions and constants the
// service exposes for consumers. The integration path
// (battery_plus → BatteryService → batteryStateProvider) is covered
// indirectly by the dashboard widget test.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/battery_service.dart';
import 'package:skotiq_mobile/services/poll_rate_service.dart';

void main() {
  group('PhoneBatteryState', () {
    test('equality compares all fields', () {
      const a = PhoneBatteryState(
        level: 50,
        isCharging: false,
        isLowPower: false,
      );
      const b = PhoneBatteryState(
        level: 50,
        isCharging: false,
        isLowPower: false,
      );
      const c = PhoneBatteryState(
        level: 49,
        isCharging: false,
        isLowPower: false,
      );
      expect(a, equals(b));
      expect(a == c, isFalse);
    });

    test('unknown sentinel reads as non-throttling', () {
      expect(PhoneBatteryState.unknown.level, -1);
      expect(PhoneBatteryState.unknown.isLowPower, isFalse);
    });
  });

  group('shouldThrottlePolling', () {
    const fullCharged = PhoneBatteryState(
      level: 80,
      isCharging: true,
      isLowPower: false,
    );
    const lowDischarging = PhoneBatteryState(
      level: 15,
      isCharging: false,
      isLowPower: true,
    );

    test('full battery on WiFi does not throttle', () {
      expect(
        shouldThrottlePolling(battery: fullCharged, onCellular: false),
        isFalse,
      );
    });

    test('full battery on cellular throttles', () {
      expect(
        shouldThrottlePolling(battery: fullCharged, onCellular: true),
        isTrue,
      );
    });

    test('low battery on WiFi throttles', () {
      expect(
        shouldThrottlePolling(battery: lowDischarging, onCellular: false),
        isTrue,
      );
    });

    test('low battery on cellular throttles', () {
      expect(
        shouldThrottlePolling(battery: lowDischarging, onCellular: true),
        isTrue,
      );
    });
  });

  group('pollIntervalFor', () {
    const base = Duration(seconds: 10);

    test('returns base interval when not throttled', () {
      const battery = PhoneBatteryState(
        level: 90,
        isCharging: false,
        isLowPower: false,
      );
      final result = pollIntervalFor(
        base: base,
        battery: battery,
        onCellular: false,
      );
      expect(result, base);
    });

    test('multiplies base by 3 when battery is low', () {
      const battery = PhoneBatteryState(
        level: 15,
        isCharging: false,
        isLowPower: true,
      );
      final result = pollIntervalFor(
        base: base,
        battery: battery,
        onCellular: false,
      );
      expect(result, base * throttledPollMultiplier);
      expect(result, const Duration(seconds: 30));
    });

    test('multiplies base by 3 when on cellular', () {
      const battery = PhoneBatteryState(
        level: 80,
        isCharging: true,
        isLowPower: false,
      );
      final result = pollIntervalFor(
        base: base,
        battery: battery,
        onCellular: true,
      );
      expect(result, const Duration(seconds: 30));
    });

    test('throttledPollMultiplier is exactly 3', () {
      // Locked-in by the design doc; if this changes the dashboard tests
      // and operator-visible "Power saving on" tooltip need updating.
      expect(throttledPollMultiplier, 3);
    });

    test('low-power threshold is 20%', () {
      // Asserting the public constant so the dashboard tests can rely
      // on it without grepping the implementation.
      expect(BatteryService.lowPowerThreshold, 20);
    });
  });
}
