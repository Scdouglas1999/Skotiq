// The environment poll runs every 5 seconds all night. Each tick re-reports the
// same sensor values, and the weather-safety evaluator used to re-run — and
// re-push its verdict over FFI — on every one of them. A rig whose weather is
// simply not changing must go quiet.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_readiness.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/weather_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/safety_monitor_state_provider.dart';
import 'package:skotiq_core/src/services/safe_rig_service.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

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

Future<void> _settle() async {
  // The source-change listener debounces for 250 ms before evaluating.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late MockBackend backend;

  setUp(() {
    backend = MockBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.sequencerUpdateWeatherVerdict(
        unsafeOverride: any(named: 'unsafeOverride'),
      ),
    ).thenAnswer((_) async {});
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

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(const AppSettingsState()),
        ),
        weatherSettingsDataProvider.overrideWith(
          (ref) =>
              Stream.value(const WeatherSettings(weatherSafetyEnabled: true)),
        ),
        safeRigServiceProvider.overrideWith((ref) => _NoopSafeRigService(ref)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('an unchanged weather poll does not re-push the verdict', () async {
    final container = buildContainer();
    container.read(weatherSafetyProvider.notifier);
    final weather = container.read(weatherStateProvider.notifier);
    weather.setConnecting('weather-1');
    weather.setConnected();
    weather.updateConditions(temperature: 5, humidity: 40, windSpeed: 2);
    await container.read(appSettingsProvider.future);
    await _settle();

    clearInteractions(backend);
    // Three more polls reporting exactly what the last one did.
    for (var i = 0; i < 3; i++) {
      weather.updateConditions(temperature: 5, humidity: 40, windSpeed: 2);
    }
    await _settle();

    verifyNever(
      () => backend.sequencerUpdateWeatherVerdict(
        unsafeOverride: any(named: 'unsafeOverride'),
      ),
    );
  });

  test(
    'an unchanged safety-monitor poll does not re-push the verdict',
    () async {
      final container = buildContainer();
      container.read(weatherSafetyProvider.notifier);
      final monitor = container.read(safetyMonitorStateProvider.notifier);
      monitor.setConnecting('safety-1');
      monitor.setConnected();
      monitor.updateSafetyStatus(true);
      await container.read(appSettingsProvider.future);
      await _settle();

      clearInteractions(backend);
      for (var i = 0; i < 3; i++) {
        monitor.updateSafetyStatus(true);
      }
      await _settle();

      verifyNever(
        () => backend.sequencerUpdateWeatherVerdict(
          unsafeOverride: any(named: 'unsafeOverride'),
        ),
      );
    },
  );

  test('a real weather change still re-pushes the verdict', () async {
    final container = buildContainer();
    container.read(weatherSafetyProvider.notifier);
    final weather = container.read(weatherStateProvider.notifier);
    weather.setConnecting('weather-1');
    weather.setConnected();
    weather.updateConditions(temperature: 5, humidity: 40, windSpeed: 2);
    await container.read(appSettingsProvider.future);
    await _settle();

    clearInteractions(backend);
    // 40 m/s is far past any sane wind limit — the verdict must move.
    weather.updateConditions(temperature: 5, humidity: 40, windSpeed: 40);
    await _settle();

    verify(
      () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
    ).called(greaterThanOrEqualTo(1));
  });

  group('SchedulerStartReadiness equality', () {
    // Built at runtime, never `const`: the readiness provider recomputes a
    // fresh instance on every evaluation, so const canonicalization would hide
    // exactly the identity comparison this pins.
    SchedulerStartReadiness build({
      SchedulerReadinessSeverity severity = SchedulerReadinessSeverity.warning,
    }) => SchedulerStartReadiness(
      issues: <SchedulerReadinessIssue>[
        SchedulerReadinessIssue(
          id: SchedulerReadinessIssueId.weather,
          severity: severity,
          title: 'No weather source',
          detail: 'Connect a weather device.',
        ),
      ],
      available: true,
      solverRequired: false,
    );

    test('two identical assessments compare equal', () {
      expect(identical(build(), build()), isFalse);
      expect(build(), equals(build()));
      expect(build().hashCode, equals(build().hashCode));
    });

    test('a changed issue is not equal', () {
      expect(
        build(),
        isNot(equals(build(severity: SchedulerReadinessSeverity.blocker))),
      );
    });
  });
}
