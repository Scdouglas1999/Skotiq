import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';

void main() {
  final start = DateTime(2026, 10, 19, 19, 20);

  test('the short list keeps its 120-point window', () {
    final notifier = TemperatureHistoryNotifier();
    addTearDown(notifier.dispose);
    for (var i = 0; i < 150; i++) {
      notifier.addPoint(-10, at: start.add(Duration(seconds: 5 * i)));
    }
    expect(notifier.state, hasLength(TemperatureHistoryNotifier.maxPoints));
    expect(
      notifier.state.first.time,
      start.add(const Duration(seconds: 5 * 30)),
    );
  });

  test('the long history keeps the last reading of each minute', () {
    final notifier = TemperatureHistoryNotifier();
    addTearDown(notifier.dispose);
    // Twelve readings a minute for ten minutes, the temperature falling one
    // hundredth of a degree per reading.
    for (var i = 0; i < 120; i++) {
      notifier.addPoint(
        -5 - i / 100,
        targetTemp: -10,
        coolerPower: 60,
        at: start.add(Duration(seconds: 5 * i)),
      );
    }
    final long = notifier.longHistory;
    expect(long, hasLength(10));
    expect(long.first.time, start.add(const Duration(seconds: 55)));
    expect(long.first.temperature, closeTo(-5.11, 1e-9));
    expect(long.last.temperature, closeTo(-6.19, 1e-9));
    expect(long.every((p) => p.targetTemp == -10), isTrue);
  });

  test(
    'the long history spans the night and drops what is older than 12 h',
    () {
      final notifier = TemperatureHistoryNotifier();
      addTearDown(notifier.dispose);
      // A reading every 30 s for 13 hours.
      for (var i = 0; i < 13 * 120; i++) {
        notifier.addPoint(-10, at: start.add(Duration(seconds: 30 * i)));
      }
      final long = notifier.longHistory;
      expect(long.length, lessThanOrEqualTo(720));
      final span = long.last.time.difference(long.first.time);
      expect(span, greaterThan(const Duration(hours: 11, minutes: 58)));
      expect(span, lessThanOrEqualTo(const Duration(hours: 12)));
      // The short list is still ten minutes of the latest readings.
      expect(notifier.state, hasLength(120));
    },
  );

  test('clear empties both lists', () {
    final notifier = TemperatureHistoryNotifier();
    addTearDown(notifier.dispose);
    notifier.addPoint(-10, at: start);
    notifier.clear();
    expect(notifier.state, isEmpty);
    expect(notifier.longHistory, isEmpty);
  });

  test('temperatureLongHistoryProvider follows each reading', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(temperatureLongHistoryProvider), isEmpty);
    final notifier = container.read(temperatureHistoryProvider.notifier);
    notifier.addPoint(-7.4, at: start);
    expect(container.read(temperatureLongHistoryProvider), hasLength(1));
    notifier.addPoint(-8.0, at: start.add(const Duration(minutes: 1)));
    final long = container.read(temperatureLongHistoryProvider);
    expect(long, hasLength(2));
    expect(long.last.temperature, -8.0);
  });
}
