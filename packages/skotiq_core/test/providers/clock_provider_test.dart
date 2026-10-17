import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/clock_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/logging_service.dart';
import '../harness/in_memory_database.dart';

/// Build a [ProviderContainer] whose [appSettingsProvider] reports the
/// given [settings] without spinning up a Drift database.
///
/// Why: the production notifier loads settings from SQLite and applies
/// migrations. The clock provider only needs to read `useSystemTime`
/// and `timezone`, so we override the provider directly with a
/// pre-resolved AsyncValue.
ProviderContainer _containerWith(AppSettingsState settings) {
  return ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
      _initialSettingsProvider.overrideWithValue(settings),
    ],
  );
}

/// Helper provider read by the fake notifier so tests can swap state
/// between calls.
final _initialSettingsProvider = Provider<AppSettingsState>(
  (_) => throw UnimplementedError('Override in test'),
);

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    return ref.read(_initialSettingsProvider);
  }
}

void main() {
  group('clockProvider', () {
    test('returns SystemClock when useSystemTime is true', () {
      final container = _containerWith(
        const AppSettingsState(useSystemTime: true, timezone: 'UTC+05:00'),
      );
      addTearDown(container.dispose);
      // Pump the AsyncNotifier to a resolved state.
      container.read(appSettingsProvider);
      final clock = container.read(clockProvider);
      expect(clock, isA<SystemClock>());
    });

    test('returns FixedOffsetClock when useSystemTime is false', () async {
      final container = _containerWith(
        const AppSettingsState(useSystemTime: false, timezone: 'UTC+02:00'),
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final clock = container.read(clockProvider);
      expect(clock, isA<FixedOffsetClock>());
      final fixed = clock as FixedOffsetClock;
      expect(fixed.utcOffset, const Duration(hours: 2));
    });

    test('FixedOffsetClock.fromUtc applies offset', () {
      const clock = FixedOffsetClock(
        utcOffset: Duration(hours: -8),
        label: 'UTC-08:00',
      );
      final utc = DateTime.utc(2026, 5, 16, 12);
      final local = clock.fromUtc(utc);
      // 12:00 UTC minus 8 hours = 04:00 local.
      expect(local.hour, 4);
      expect(local.minute, 0);
    });

    test('FixedOffsetClock parses half-hour offset (UTC+05:30)', () async {
      final container = _containerWith(
        const AppSettingsState(useSystemTime: false, timezone: 'UTC+05:30'),
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final clock = container.read(clockProvider) as FixedOffsetClock;
      expect(clock.utcOffset, const Duration(hours: 5, minutes: 30));
    });

    test('falls back to SystemClock for unparseable timezone', () async {
      final container = _containerWith(
        const AppSettingsState(useSystemTime: false, timezone: 'gibberish'),
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final clock = container.read(clockProvider);
      expect(clock, isA<SystemClock>());
    });

    // The provider's own doc comment claimed an unparseable label was logged.
    // It was not, so a Timezone picker value the parser rejects produced a
    // clock silently identical to "use system time" with nothing anywhere
    // saying the choice had been ignored.
    test('an unparseable timezone is reported, not swallowed', () async {
      final logging = LoggingService();
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          _initialSettingsProvider.overrideWithValue(
            const AppSettingsState(
              useSystemTime: false,
              timezone: 'America/Denver',
            ),
          ),
          loggingServiceProvider.overrideWithValue(logging),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);

      expect(container.read(clockProvider), isA<SystemClock>());
      final warnings = logging
          .getRecentLogs(minLevel: LogLevel.warning)
          .where((e) => e.message.contains('America/Denver'))
          .toList();
      expect(warnings, isNotEmpty);
      expect(warnings.single.message, contains('host system time'));
    });

    test('UTC label yields zero-offset clock', () async {
      final container = _containerWith(
        const AppSettingsState(useSystemTime: false, timezone: 'UTC'),
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final clock = container.read(clockProvider) as FixedOffsetClock;
      expect(clock.utcOffset, Duration.zero);
    });
  });
}
