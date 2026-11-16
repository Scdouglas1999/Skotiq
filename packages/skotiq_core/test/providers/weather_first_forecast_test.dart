import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/services/safe_rig_service.dart';
import 'package:skotiq_core/src/services/safety_config_service.dart';
import 'package:skotiq_core/src/services/weather/weather_alert_service.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(safetyFailMode: SafetyFailMode.failClosed);
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _RecordingSafeRigService extends SafeRigService {
  _RecordingSafeRigService(super.ref, this.reasons)
    : super(stopSecondaryRig: _noSecondary);

  static Future<bool> _noSecondary() async => false;

  final List<String> reasons;

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
    reasons.add(reason);
    return const SafeRigResult();
  }
}

/// The alert service as the forecast leaves it: empty until a fetch lands.
class _AlertService extends WeatherAlertService {
  WeatherAlert? alert;

  @override
  WeatherAlert? get currentAlert => alert;
}

/// Weather safety on, fail closed, auto-park on, no weather device and no
/// safety monitor: the internet forecast is the only source. The mount is
/// connected and tracking, so a verdict of "unsafe" would command it.
void main() {
  late MockBackend backend;
  late List<String> safeRigReasons;
  late List<bool?> pushes;
  late _AlertService alerts;
  late List<Completer<WeatherAlert>> fetches;

  setUp(() {
    backend = MockBackend();
    safeRigReasons = [];
    pushes = [];
    alerts = _AlertService();
    fetches = [];
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.sequencerUpdateWeatherVerdict(
        unsafeOverride: any(named: 'unsafeOverride'),
        advisory: any(named: 'advisory'),
      ),
    ).thenAnswer((invocation) async {
      pushes.add(invocation.namedArguments[#unsafeOverride] as bool?);
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

  Future<ProviderContainer> start({Stream<WeatherSettings>? settings}) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
        weatherSettingsDataProvider.overrideWith(
          (ref) =>
              settings ??
              Stream.value(const WeatherSettings(weatherSafetyEnabled: true)),
        ),
        weatherAlertServiceProvider.overrideWith((ref) => alerts),
        weatherDecisionPolicyProvider.overrideWith(
          (ref) async => WeatherDecisionPolicy.defaults,
        ),
        evaluateWeatherConditionsProvider.overrideWith((ref) {
          final fetch = Completer<WeatherAlert>();
          fetches.add(fetch);
          return fetch.future;
        }),
        cloudCoverPercentageProvider.overrideWith((ref) async => null),
        safeRigServiceProvider.overrideWith(
          (ref) => _RecordingSafeRigService(ref, safeRigReasons),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final mount = container.read(mountStateProvider.notifier);
    mount.setConnecting('mount-1');
    mount.setConnected();
    mount.setParked(false);
    mount.setTracking(true);
    container.read(weatherSafetyProvider.notifier);
    await settle();
    return container;
  }

  void answer(WeatherAlert alert) {
    alerts.alert = alert;
    fetches.last.complete(alert);
  }

  final clearSky = WeatherAlert(
    level: AlertLevel.clear,
    message: 'Clear',
    cloudDensityPercent: 10,
    distanceKm: 0,
    generatedAt: DateTime.now(),
  );

  Iterable<UiNotification> weatherNotices(ProviderContainer container) =>
      container
          .read(uiNotificationProvider)
          .where((n) => n.title == 'Weather Safety');

  test('a forecast still being fetched commands nothing', () async {
    final container = await start();

    expect(safeRigReasons, isEmpty);
    expect(pushes, isNot(contains(true)));
    expect(weatherNotices(container), isEmpty);
    expect(fetches, isNotEmpty, reason: 'the evaluation asks for one');
    final waiting = container.read(weatherSafetyProvider);
    expect(waiting.failModeWarning, 'Waiting for the first weather forecast');
    expect(waiting.actions.shouldPause, isFalse);
    expect(waiting.actions.shouldPark, isFalse);
    expect(waiting.lastEvaluation, isNull);

    answer(clearSky);
    await settle();

    expect(
      container.read(weatherSafetyProvider).status,
      WeatherSafetyStatus.safe,
    );
    expect(safeRigReasons, isEmpty);
  });

  test('a first fetch that fails leaves fail closed to safe the rig', () async {
    final container = await start();

    fetches.last.completeError(StateError('forecast unreachable'));
    await settle();

    final state = container.read(weatherSafetyProvider);
    expect(state.status, WeatherSafetyStatus.unsafe);
    expect(state.decisionSource, WeatherDecisionSource.noData);
    expect(state.actions.reason, 'No weather data sources available');
    expect(safeRigReasons, ['No weather data sources available']);
    expect(pushes.last, isTrue);
  });

  test('switching weather safety back on waits for a fresh forecast', () async {
    final settings = StreamController<WeatherSettings>();
    addTearDown(settings.close);
    settings.add(const WeatherSettings(weatherSafetyEnabled: true));
    final container = await start(settings: settings.stream);
    answer(clearSky.copyWith(generatedAt: DateTime(2000)));
    await settle();
    settings.add(const WeatherSettings());
    await settle();
    safeRigReasons.clear();

    settings.add(const WeatherSettings(weatherSafetyEnabled: true));
    await settle();

    expect(
      container.read(weatherSafetyProvider).failModeWarning,
      'Waiting for the first weather forecast',
    );
    expect(safeRigReasons, isEmpty);
  });
}

/// Long enough for a source-change evaluation (debounced 250 ms) to run.
Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
