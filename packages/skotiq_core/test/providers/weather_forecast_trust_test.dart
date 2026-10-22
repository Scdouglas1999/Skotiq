import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart' show SkotiqDatabase;
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment/weather_state_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/services/safe_rig_service.dart';
import 'package:skotiq_core/src/services/safety_config_service.dart';
import 'package:skotiq_core/src/services/weather/weather_alert_service.dart';

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

/// Records every SafeRig call so a test can prove a forecast commanded nothing.
class _RecordingSafeRigService extends SafeRigService {
  _RecordingSafeRigService(super.ref, this.calls)
    : super(stopSecondaryRig: _stopSecondaryRig);

  final List<({bool park, bool closeDome})> calls;

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
    IdleMountPolicy idleMount = IdleMountPolicy.leave,
    bool notify = true,
  }) async {
    calls.add((park: park, closeDome: closeDome));
    return const SafeRigResult();
  }
}

/// An alert service holding a fixed alert, of any age.
class _FixedAlertService extends WeatherAlertService {
  _FixedAlertService(this._alert);
  final WeatherAlert? _alert;

  @override
  WeatherAlert? get currentAlert => _alert;
}

WeatherAlert _cloudyForecast({DateTime? at}) => WeatherAlert(
  level: AlertLevel.critical,
  message: 'Heavy cloud cover overhead (100% density) - consider pausing',
  cloudDensityPercent: 100,
  distanceKm: 0,
  generatedAt: at ?? DateTime.now(),
);

void main() {
  late MockBackend backend;
  late List<({bool park, bool closeDome})> safeRigCalls;
  late List<({bool? unsafe, bool advisory})> pushes;

  setUp(() {
    backend = MockBackend();
    safeRigCalls = [];
    pushes = [];
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.sequencerUpdateWeatherVerdict(
        unsafeOverride: any(named: 'unsafeOverride'),
        advisory: any(named: 'advisory'),
      ),
    ).thenAnswer((invocation) async {
      pushes.add((
        unsafe: invocation.namedArguments[#unsafeOverride] as bool?,
        advisory: invocation.namedArguments[#advisory] as bool,
      ));
    });
    when(
      () => backend.sequencerSetWeatherOperatorClear(
        durationSecs: any(named: 'durationSecs'),
        reason: any(named: 'reason'),
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

  /// The owner's configuration on the night: weather safety on, auto-park on,
  /// fail open, no weather device and no safety monitor.
  Future<ProviderContainer> buildContainer({
    WeatherAlert? alert,
    WeatherDecisionPolicy policy = const WeatherDecisionPolicy(
      forecastHoldsRun: true,
    ),
    Stream<WeatherSettings>? settings,
  }) async {
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
          (ref) =>
              settings ??
              Stream.value(
                const WeatherSettings(
                  weatherSafetyEnabled: true,
                  autoParkEnabled: true,
                ),
              ),
        ),
        weatherAlertServiceProvider.overrideWith(
          (ref) => _FixedAlertService(alert),
        ),
        weatherDecisionPolicyProvider.overrideWith((ref) async => policy),
        evaluateWeatherConditionsProvider.overrideWith(
          (ref) async => throw StateError('offline in tests'),
        ),
        safeRigServiceProvider.overrideWith(
          (ref) => _RecordingSafeRigService(ref, safeRigCalls),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(weatherDecisionPolicyProvider.future);
    await container.read(appSettingsProvider.future);
    return container;
  }

  /// Long enough for the policy, read once the forecast says cloudy, to load
  /// and its re-evaluation (debounced 250 ms) to run.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('a forecast is advisory', () {
    test('a cloudy forecast holds the run and never parks or safes', () async {
      final container = await buildContainer(alert: _cloudyForecast());
      container.read(weatherSafetyProvider.notifier);
      await settle();

      final state = container.read(weatherSafetyProvider);
      expect(state.status, WeatherSafetyStatus.unsafe);
      expect(state.advisoryOnly, isTrue);
      expect(state.decisionSource, WeatherDecisionSource.forecast);
      expect(state.actions.shouldPark, isFalse);
      expect(state.actions.shouldCloseDome, isFalse);
      expect(state.actions.shouldPause, isTrue);
      expect(safeRigCalls, isEmpty);
      expect(pushes.last, (unsafe: true, advisory: true));
    });

    test('with forecasts set to warn, the run is not held at all', () async {
      final container = await buildContainer(
        alert: _cloudyForecast(),
        policy: const WeatherDecisionPolicy(forecastHoldsRun: false),
      );
      container.read(weatherSafetyProvider.notifier);
      await settle();

      final state = container.read(weatherSafetyProvider);
      expect(state.advisoryOnly, isTrue);
      expect(state.actions.shouldPause, isFalse);
      expect(state.actions.reason, contains('only warn'));
      expect(safeRigCalls, isEmpty);
      expect(pushes.last, (unsafe: null, advisory: false));
    });

    test('a weather device out of limits still parks', () async {
      final container = await buildContainer(alert: _cloudyForecast());
      final device = container.read(weatherStateProvider.notifier);
      device.setConnecting('weather-1');
      device.setConnected();
      device.updateConditions(humidity: 99, windSpeed: 1, rainRate: 0);
      container.read(weatherSafetyProvider.notifier);
      await settle();

      final state = container.read(weatherSafetyProvider);
      expect(state.decisionSource, WeatherDecisionSource.weatherDevice);
      expect(state.advisoryOnly, isFalse);
      expect(state.actions.shouldPark, isTrue);
      expect(pushes.last, (unsafe: true, advisory: false));
      expect(safeRigCalls.single.park, isTrue);
    });

    test('a forecast that has not refreshed is not acted on', () async {
      final container = await buildContainer(
        alert: _cloudyForecast(
          at: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      );
      container.read(weatherSafetyProvider.notifier);
      await settle();

      final state = container.read(weatherSafetyProvider);
      // Fail open: no current data reads as safe, with the reason given.
      expect(state.status, WeatherSafetyStatus.safe);
      expect(state.failModeWarning, contains('has not refreshed'));
      expect(pushes.last.unsafe, isNot(true));
    });
  });

  group('the operator and the settings release a hold at once', () {
    test(
      '"the sky is clear" withdraws the verdict and tells the sequencer',
      () async {
        final container = await buildContainer(alert: _cloudyForecast());
        final notifier = container.read(weatherSafetyProvider.notifier);
        await settle();
        expect(pushes.last.unsafe, isTrue);

        notifier.snooze(
          const Duration(minutes: 30),
          reason: 'Stars in the guide camera',
        );
        await settle();

        expect(pushes.last, (unsafe: null, advisory: false));
        verify(
          () => backend.sequencerSetWeatherOperatorClear(
            durationSecs: 1800,
            reason: 'Stars in the guide camera',
          ),
        ).called(1);
        expect(
          container.read(weatherSafetyProvider).snoozeReason,
          'Stars in the guide camera',
        );
      },
    );

    test('switching weather safety off withdraws the verdict', () async {
      final settings = StreamController<WeatherSettings>();
      addTearDown(settings.close);
      final container = await buildContainer(
        alert: _cloudyForecast(),
        settings: settings.stream,
      );
      container.read(weatherSafetyProvider.notifier);
      settings.add(const WeatherSettings(weatherSafetyEnabled: true));
      await settle();
      expect(pushes.last.unsafe, isTrue);

      pushes.clear();
      settings.add(const WeatherSettings(weatherSafetyEnabled: false));
      await settle();
      expect(pushes.first, (unsafe: null, advisory: false));
      // The sequencer stops acting on the app's weather at once, rather than
      // waiting out the safe period.
      verify(
        () => backend.sequencerSetWeatherOperatorClear(
          durationSecs: 24 * 3600,
          reason: 'Weather safety switched off',
        ),
      ).called(1);
    });
  });

  group('star evidence', () {
    final now = DateTime(2026, 10, 21, 23);
    List<StarSample> frames(List<int> stars) => [
      for (var i = 0; i < stars.length; i++)
        (
          capturedAt: now.subtract(Duration(minutes: 3 * (stars.length - i))),
          stars: stars[i],
          exposureSecs: 120.0,
        ),
    ];

    test('a frame with the usual stars reads clear', () {
      final evidence = evaluateStarEvidence(frames([400, 420, 410, 390]), now);
      expect(evidence?.clear, isTrue);
      expect(evidence?.typicalStars, 410);
      expect(evidence?.latestStars, 390);
    });

    test('a frame that lost most of its stars does not read clear', () {
      final evidence = evaluateStarEvidence(frames([400, 420, 410, 40]), now);
      expect(evidence?.clear, isFalse);
    });

    test('too few frames, a sparse field or an old frame say nothing', () {
      expect(evaluateStarEvidence(frames([400, 420, 410]), now), isNull);
      expect(evaluateStarEvidence(frames([10, 12, 11, 12]), now), isNull);
      expect(
        evaluateStarEvidence(
          frames([400, 420, 410, 400]),
          now.add(const Duration(hours: 1)),
        ),
        isNull,
      );
    });
  });

  group('decision policy migration', () {
    Future<SkotiqDatabase> database() async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      return container.read(databaseProvider);
    }

    test('an install with weather safety on starts with forecasts holding '
        'the run', () async {
      final db = await database();
      await db.weatherSettingsDao.updateSettings(weatherSafetyEnabled: true);
      final store = SafetyConfigStore(db);
      final policy = await store.loadDecisionPolicy();
      expect(policy.forecastHoldsRun, isTrue);
      expect(policy.starEvidenceOverridesForecast, isTrue);
      // Written back: turning the master switch off later does not move it.
      await db.weatherSettingsDao.updateSettings(weatherSafetyEnabled: false);
      expect((await store.loadDecisionPolicy()).forecastHoldsRun, isTrue);
    });

    test('a fresh install only warns on forecasts', () async {
      final db = await database();
      final policy = await SafetyConfigStore(db).loadDecisionPolicy();
      expect(policy.forecastHoldsRun, isFalse);
    });
  });
}
