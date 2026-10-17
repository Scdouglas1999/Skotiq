import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/weather_state_provider.dart';
import 'package:skotiq_core/src/services/safe_rig_service.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

/// AppSettings fake that resolves immediately so `appSettingsProvider.future`
/// completes without touching the database.
class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

/// Backend notifier seeded with a fixed (mock) backend.
class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// No-op SafeRig so the unsafe-verdict path does not drag the heavy hardware
/// enforcement (mount park / dome close / critical notification) into this
/// push-wiring test. SafeRig enforcement has its own dedicated tests.
class _NoopSafeRigService extends SafeRigService {
  _NoopSafeRigService(super.ref) : super(stopSecondaryRig: _stopSecondaryRig);

  static Future<bool> _stopSecondaryRig() async => false;

  @override
  Future<SafeRigResult> safeTheRig({
    required String reason,
    bool park = true,
    bool closeDome = false,
    bool closeCover = false,
    bool abortExposure = false,
    bool disableCooling = false,
    bool quiesceSecondaryRig = true,
    bool notify = true,
  }) async => const SafeRigResult();
}

void main() {
  // Full-night audit 2026-06-04 (defense-in-depth): the weather-safety provider
  // must forward its overall verdict to the Rust executor on every evaluation
  // so the in-sequencer `WeatherUnsafe` trigger reacts even on a rig with no
  // hardware safety device. This pins that push wiring.
  group('weatherSafetyProvider pushes verdict to the executor', () {
    late MockBackend backend;

    setUp(() {
      backend = MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.sequencerUpdateWeatherVerdict(
          unsafeOverride: any(named: 'unsafeOverride'),
        ),
      ).thenAnswer((_) async {});
      // The constructor's cloud-motion / adaptive-conditions push loops also
      // touch the backend on their first microtask; stub them so they no-op
      // instead of throwing (which the provider would swallow anyway).
      when(
        () => backend.sequencerUpdateCloudMotion(
          currentCoverPercent: any(named: 'currentCoverPercent'),
          predictedArrivalMinutes: any(named: 'predictedArrivalMinutes'),
          predictedOpeningMinutes: any(named: 'predictedOpeningMinutes'),
          predictedOpeningDurationSecs: any(
            named: 'predictedOpeningDurationSecs',
          ),
          predictedClearSkyAlt: any(named: 'predictedClearSkyAlt'),
          predictedClearSkyAz: any(named: 'predictedClearSkyAz'),
        ),
      ).thenAnswer((_) async {});
    });

    ProviderContainer buildContainer({
      required bool safetyEnabled,
      SafetyFailMode failMode = SafetyFailMode.failClosed,
    }) {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              // With no connected weather/safety device and no API alert the
              // evaluator takes the fail-mode path.
              AppSettingsState(safetyFailMode: failMode),
            ),
          ),
          weatherSettingsDataProvider.overrideWith(
            (ref) => Stream.value(
              WeatherSettings(weatherSafetyEnabled: safetyEnabled),
            ),
          ),
          safeRigServiceProvider.overrideWith(
            (ref) => _NoopSafeRigService(ref),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'reports UNSAFE when no data source is available (fail-closed)',
      () async {
        final container = buildContainer(safetyEnabled: true);
        // Construct the notifier; the constructor runs an initial evaluation.
        container.read(weatherSafetyProvider.notifier);
        // Let the appSettings future + the evaluation's unawaited verdict push
        // resolve.
        await container.read(appSettingsProvider.future);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // No connected weather device + no safety monitor + no API alert under
        // fail-closed => the overall verdict is UNSAFE, so the executor must be
        // told `unsafeOverride: true`.
        verify(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
        ).called(greaterThanOrEqualTo(1));
        verifyNever(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: false),
        );
      },
    );

    test('ABSTAINS (pushes None) when weather safety is disabled', () async {
      // Architecture-unification 2026-06-05 (Subsystem 2 step 1): a disabled
      // weather toggle is the operator opting out of weather-driven aborts, but
      // it MUST NOT assert SAFE to the executor. Pushing `false` (SAFE) was only
      // harmless because Rust ORs it; if a future refactor ever made Rust trust
      // the verdict, a disabled toggle asserting SAFE would suppress a
      // hardware-unsafe abort. So we push `None` (abstain) instead — the
      // executor falls back to its own hardware poll. This is the deliberate
      // contract change (was: expect `false`).
      final container = buildContainer(safetyEnabled: false);
      container.read(weatherSafetyProvider.notifier);
      await container.read(appSettingsProvider.future);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(
        () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: null),
      ).called(greaterThanOrEqualTo(1));
      verifyNever(
        () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
      );
      verifyNever(
        () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: false),
      );
    });

    test(
      'ABSTAINS (pushes None) under the failOpen no-data fail-mode',
      () async {
        // Permissive fail-mode means "treat missing data as safe" for the
        // operator's UI, but the executor verdict must ABSTAIN, not assert SAFE,
        // so the permissive policy can never gag a hardware-unsafe device.
        final container = buildContainer(
          safetyEnabled: true,
          failMode: SafetyFailMode.failOpen,
        );
        final notifier = container.read(weatherSafetyProvider.notifier);
        await container.read(appSettingsProvider.future);
        // The construction-time evaluation runs before the async appSettings
        // future resolves (failMode defaults to failClosed until then). Force a
        // fresh evaluation now that the failOpen setting is loaded, then assert
        // only on the post-load push.
        clearInteractions(backend);
        notifier.forceEvaluation();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        verify(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: null),
        ).called(greaterThanOrEqualTo(1));
        verifyNever(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: false),
        );
        verifyNever(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
        );
      },
    );

    test(
      'ABSTAINS (pushes None) under the warnOnly no-data fail-mode',
      () async {
        final container = buildContainer(
          safetyEnabled: true,
          failMode: SafetyFailMode.warnOnly,
        );
        final notifier = container.read(weatherSafetyProvider.notifier);
        await container.read(appSettingsProvider.future);
        clearInteractions(backend);
        notifier.forceEvaluation();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        verify(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: null),
        ).called(greaterThanOrEqualTo(1));
        verifyNever(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: false),
        );
        verifyNever(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
        );
      },
    );

    test('ABSTAINS (pushes None) while snoozed', () async {
      // The abstain landmine, snooze variant: a snooze suppresses the operator
      // alert but MUST NOT assert SAFE to the executor. We snooze, force a
      // re-evaluation, and assert the push abstains. Combined with the Rust OR
      // (covered in triggers.rs), this proves a snooze cannot suppress a
      // hardware-unsafe abort.
      final container = buildContainer(safetyEnabled: true);
      final notifier = container.read(weatherSafetyProvider.notifier);
      await container.read(appSettingsProvider.future);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Re-arm the verify by clearing prior interactions, then snooze + force a
      // fresh evaluation so the snoozed-branch verdict is pushed.
      clearInteractions(backend);
      notifier.snooze(const Duration(minutes: 30));
      notifier.forceEvaluation();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verify(
        () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: null),
      ).called(greaterThanOrEqualTo(1));
      verifyNever(
        () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: false),
      );
    });

    test(
      'converts hardware wind from m/s before applying km/h limit',
      () async {
        final container = buildContainer(safetyEnabled: true);
        final hardwareWeather = container.read(weatherStateProvider.notifier);
        hardwareWeather.setConnecting('weather-1');
        hardwareWeather.setConnected();
        // Native weather telemetry is m/s: 10 m/s == 36 km/h, above the
        // default 30 km/h safety threshold.
        hardwareWeather.updateConditions(windSpeed: 10);

        final safety = container.read(weatherSafetyProvider.notifier);
        await container.read(appSettingsProvider.future);
        clearInteractions(backend);
        safety.forceEvaluation();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(weatherSafetyProvider).status,
          WeatherSafetyStatus.unsafe,
        );
        verify(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
        ).called(greaterThanOrEqualTo(1));
        verifyNever(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: false),
        );
      },
    );

    test(
      'fails closed when authoritative safety settings cannot load',
      () async {
        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            appSettingsProvider.overrideWith(
              () => _FakeAppSettingsNotifier(
                const AppSettingsState(safetyFailMode: SafetyFailMode.failOpen),
              ),
            ),
            weatherSettingsDataProvider.overrideWith(
              (ref) => Stream<WeatherSettings>.error(
                StateError('settings store unavailable'),
              ),
            ),
            safeRigServiceProvider.overrideWith(
              (ref) => _NoopSafeRigService(ref),
            ),
          ],
        );
        addTearDown(container.dispose);

        container.read(weatherSafetyProvider.notifier);
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        final state = container.read(weatherSafetyProvider);
        expect(state.status, WeatherSafetyStatus.unsafe);
        expect(state.dataSource, SafetyDataSource.unavailable);
        expect(state.failModeWarning, contains('configuration unavailable'));
        verify(
          () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
        ).called(greaterThanOrEqualTo(1));
      },
    );
  });
}
