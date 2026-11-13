import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_mobile/services/battery_service.dart';
import 'package:skotiq_mobile/services/poll_rate_service.dart';

void main() {
  const full = PhoneBatteryState(
    level: 80,
    isCharging: true,
    isLowPower: false,
  );
  const low = PhoneBatteryState(level: 15, isCharging: false, isLowPower: true);
  const saver = PhoneBatteryState(
    level: 60,
    isCharging: false,
    isLowPower: false,
    isSaverOn: true,
  );

  group('PhoneBatteryState', () {
    test('equality compares every field, battery saver included', () {
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
      expect(
        a ==
            const PhoneBatteryState(
              level: 50,
              isCharging: false,
              isLowPower: false,
              isSaverOn: true,
            ),
        isFalse,
      );
    });

    test('no reading counts as full power', () {
      expect(PhoneBatteryState.unknown.level, -1);
      expect(PhoneBatteryState.unknown.isLowPower, isFalse);
      expect(PhoneBatteryState.unknown.isSaverOn, isFalse);
    });

    test('low battery starts below 20 %', () {
      expect(BatteryService.lowPowerThreshold, 20);
    });
  });

  group('pollPaceFor', () {
    test('full speed on Wi-Fi with a good battery', () {
      expect(pollPaceFor(battery: full, onCellular: false), 1);
      expect(
        pollPaceFor(battery: PhoneBatteryState.unknown, onCellular: false),
        1,
      );
    });

    test('a third as often on low battery, battery saver or cellular', () {
      expect(pollPaceFor(battery: low, onCellular: false), throttledPollPace);
      expect(pollPaceFor(battery: saver, onCellular: false), throttledPollPace);
      expect(pollPaceFor(battery: full, onCellular: true), throttledPollPace);
      expect(pollPaceFor(battery: low, onCellular: true), throttledPollPace);
      expect(throttledPollPace, 3);
    });
  });

  group('pollPaceProvider', () {
    tearDown(() => PollPace.multiplier = 1);

    test(
      'sets the app-wide poll pace from the battery and resets it',
      () async {
        final battery = StreamController<PhoneBatteryState>();
        final container = ProviderContainer(
          overrides: [
            batteryStateProvider.overrideWith((ref) => battery.stream),
          ],
        );
        final subscription = container.listen(pollPaceProvider, (_, __) {});

        battery.add(low);
        await pumpEventQueue();
        expect(PollPace.multiplier, throttledPollPace);
        expect(subscription.read(), throttledPollPace);

        battery.add(full);
        await pumpEventQueue();
        expect(PollPace.multiplier, 1);

        battery.add(saver);
        await pumpEventQueue();
        expect(PollPace.multiplier, throttledPollPace);

        container.dispose();
        expect(PollPace.multiplier, 1);
        await battery.close();
      },
    );
  });
}
