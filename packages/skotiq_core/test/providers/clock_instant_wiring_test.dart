// Settings → Location → Timezone must change what the operator READS without
// changing what the app RECORDS or DECIDES.
//
// `Clock.now()` is a rendering: Dart has no arbitrary-offset DateTime, so
// `FixedOffsetClock` shifts the fields and hands back a value the host still
// labels local. Converting that back (`.toUtc()`, `.millisecondsSinceEpoch`,
// `difference` against a real timestamp) lands chosenOffset + hostOffset away
// from the actual moment. The picker resolves — it offers 38 UTC offsets and
// migrates the legacy IANA names onto them — so any consumer that treats
// `now()` as an instant records and schedules against a time that never
// happened.
//
// These tests pin the two halves: the clock exposes a true instant, and the
// production wiring that needs an instant reads it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Offsets no CI host or workstation runs on, so "the picked zone" and "the
/// host's zone" can never coincide and let a reverted wiring pass.
const _nepal = Duration(hours: 5, minutes: 45);
const _marquesas = Duration(hours: -9, minutes: -30);

class _MutableSettings extends AppSettingsNotifier {
  _MutableSettings(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;

  void put(AppSettingsState next) => state = AsyncData(next);
}

class _NoCandidates implements SchedulerCandidateLoader {
  @override
  Ref get ref => throw UnimplementedError();

  @override
  Future<List<SchedulerCandidate>> load({int? projectId}) async => const [];
}

/// The live notifier of the most recently built container, so a test can push
/// a new Timezone the way the settings screen does.
late _MutableSettings _settingsNotifier;

ProviderContainer _container(AppSettingsState settings) {
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _settingsNotifier = _MutableSettings(settings),
      ),
      schedulerPersistedConfigProvider.overrideWith(
        (ref) async => SchedulerConfig.defaults,
      ),
      schedulerTriggerStreamProvider.overrideWithValue(const Stream.empty()),
      schedulerCandidateLoaderProvider.overrideWithValue(_NoCandidates()),
      activeProjectIdProvider.overrideWith(ActiveProjectNotifier.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('Clock exposes a real instant alongside the zone rendering', () {
    test('nowUtc is the true moment while now is the chosen zone', () {
      const clock = FixedOffsetClock(utcOffset: _nepal, label: 'UTC+05:45');
      final truth = DateTime.now().toUtc();

      // The instant: same moment, whatever zone the operator picked.
      expect(
        clock.nowUtc().difference(truth).abs(),
        lessThan(const Duration(seconds: 5)),
      );
      expect(clock.nowUtc().isUtc, isTrue);

      // The rendering: field values shifted by the chosen offset. This is the
      // value that must never be treated as an instant — rebasing it lands
      // offset + hostOffset away, which is what the assertion below proves is
      // NOT what nowUtc does.
      final rendered = clock.now();
      expect(
        rendered.difference(clock.fromUtc(truth)).abs(),
        lessThan(const Duration(seconds: 5)),
      );
      final rebased = rendered.toUtc();
      expect(
        rebased.difference(truth).abs(),
        greaterThan(const Duration(minutes: 1)),
        reason:
            'now().toUtc() is expected to be wrong — that is precisely why '
            'nowUtc() exists. If this ever passes, Dart grew offset-aware '
            'DateTimes and the whole seam can be simplified.',
      );
    });

    test('SystemClock reports the host offset and the host instant', () {
      const clock = SystemClock();
      expect(clock.utcOffset, DateTime.now().timeZoneOffset);
      expect(
        clock.nowUtc().difference(DateTime.now().toUtc()).abs(),
        lessThan(const Duration(seconds: 5)),
      );
    });

    test(
      'clockProvider surfaces the picked offset, not the host one',
      () async {
        final container = _container(
          const AppSettingsState(useSystemTime: false, timezone: 'UTC+05:45'),
        );
        await container.read(appSettingsProvider.future);
        expect(container.read(clockProvider).utcOffset, _nepal);
      },
    );
  });

  group('the scheduler runs on the picked zone', () {
    // The engine evaluates time-window constraints as
    // `now.toUtc().add(site.localOffset)`, so it needs a real instant AND the
    // observatory's offset. `clock.now` is a zone rendering and
    // `DateTime.now().timeZoneOffset` is the laptop's offset: either would
    // judge "image between 22:00 and 04:00 local" in the wrong zone.
    test('site offset comes from the Timezone setting', () async {
      final container = _container(
        const AppSettingsState(
          latitude: 27.7,
          longitude: 85.3,
          useSystemTime: false,
          timezone: 'UTC+05:45',
        ),
      );
      await container.read(appSettingsProvider.future);

      final engine = container.read(schedulerEngineProvider);
      expect(engine.site.localOffset, _nepal);
      expect(engine.site.localOffset, isNot(DateTime.now().timeZoneOffset));
    });

    // The ready gate re-hydrates the site after the engine is constructed, so
    // it is a second chance to overwrite the observatory's offset with the
    // laptop's — and it did.
    test('the ready gate does not put the host offset back', () async {
      final container = _container(
        const AppSettingsState(
          latitude: 27.7,
          longitude: 85.3,
          useSystemTime: false,
          timezone: 'UTC+05:45',
        ),
      );
      final engine = await container.read(schedulerEngineReadyProvider.future);
      expect(engine.site.localOffset, _nepal);
    });

    test('changing the Timezone setting moves the running engine', () async {
      final container = _container(
        const AppSettingsState(
          latitude: 27.7,
          longitude: 85.3,
          useSystemTime: false,
          timezone: 'UTC+05:45',
        ),
      );
      await container.read(appSettingsProvider.future);
      final engine = container.read(schedulerEngineProvider);
      expect(engine.site.localOffset, _nepal);

      _settingsNotifier.put(
        const AppSettingsState(
          latitude: 27.7,
          longitude: 85.3,
          useSystemTime: false,
          timezone: 'UTC-09:30',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        identical(container.read(schedulerEngineProvider), engine),
        isTrue,
      );
      expect(engine.site.localOffset, _marquesas);
    });

    test('evaluation timestamps the real instant, not the rendering', () async {
      final container = _container(
        const AppSettingsState(
          latitude: 27.7,
          longitude: 85.3,
          useSystemTime: false,
          timezone: 'UTC+05:45',
        ),
      );
      await container.read(appSettingsProvider.future);
      final engine = container.read(schedulerEngineProvider);

      // `SchedulerDecision.evaluatedAt` is the engine's injected clock read
      // verbatim, so it is the cheapest honest window onto what the engine
      // thinks "now" is.
      engine.requestReevaluation(reason: 'test');
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final decision = engine.lastDecision;
      expect(decision, isNotNull);
      expect(
        decision!.evaluatedAt.difference(DateTime.now().toUtc()).abs(),
        lessThan(const Duration(minutes: 1)),
        reason:
            'the autopilot evaluated at a moment 5h45m (plus the host offset) '
            'away from now, so every window, altitude and moon check ran '
            'against the wrong sky',
      );
    });
  });
}
