import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/weather_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/safety_monitor_state_provider.dart';
import 'package:skotiq_core/src/services/safe_rig_service.dart';

import '../mocks/mock_backend.dart';

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

/// Lets a test age the monitor's last successful read without waiting.
class _SeedableSafetyMonitorNotifier extends SafetyMonitorStateNotifier {
  _SeedableSafetyMonitorNotifier(super.ref);

  void seed(SafetyMonitorState seeded) => state = seeded;
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

void main() {
  // A configured safety source that stops responding must not keep its
  // optimistic `true` default and report the rig SAFE in fail-closed mode. The
  // all-sources-absent escape cannot catch that while one healthy source is
  // still connected.
  group('unreachable safety sources', () {
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

    ProviderContainer buildContainer({
      SafetyFailMode failMode = SafetyFailMode.failClosed,
    }) {
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              AppSettingsState(safetyFailMode: failMode),
            ),
          ),
          weatherSettingsDataProvider.overrideWith(
            (ref) =>
                Stream.value(const WeatherSettings(weatherSafetyEnabled: true)),
          ),
          safetyMonitorStateProvider.overrideWith(
            (ref) => _SeedableSafetyMonitorNotifier(ref),
          ),
          safeRigServiceProvider.overrideWith(
            (ref) => _NoopSafeRigService(ref),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// A healthy hardware weather device so the "no data sources at all"
    /// fail-mode escape cannot fire — this is the normal rig configuration in
    /// which the defect was reproduced.
    void connectHealthyWeatherDevice(ProviderContainer container) {
      final weather = container.read(weatherStateProvider.notifier);
      weather.setConnecting('weather-1');
      weather.setConnected();
      weather.updateConditions(
        humidity: 30,
        windSpeed: 1,
        cloudCover: 5,
        rainRate: 0,
      );
    }

    Future<void> settle(ProviderContainer container) async {
      await container.read(appSettingsProvider.future);
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'a safety monitor that stops responding is UNSAFE (fail-closed)',
      () async {
        final container = buildContainer();
        connectHealthyWeatherDevice(container);
        final monitor = container.read(safetyMonitorStateProvider.notifier);
        monitor.setConnecting('safety-1');
        monitor.setConnected();
        monitor.updateSafetyStatus(true);

        final safety = container.read(weatherSafetyProvider.notifier);
        await settle(container);
        expect(
          container.read(weatherSafetyProvider).status,
          WeatherSafetyStatus.safe,
        );

        // The sensor stops answering: the device drops to `error` while the
        // weather device stays healthy.
        monitor.setError(StateError('HTTP 500'));
        safety.forceEvaluation();
        await settle(container);

        final state = container.read(weatherSafetyProvider);
        expect(state.status, WeatherSafetyStatus.unsafe);
        expect(state.safetyMonitorSafe, isFalse);
        expect(state.safetyMonitorReading, SafetySourceReading.unknown);
        expect(state.actions.shouldPause, isTrue);
        expect(state.actions.reason, contains('Safety monitor'));
      },
    );

    test(
      'a weather device that stops responding is UNSAFE (fail-closed)',
      () async {
        final container = buildContainer();
        connectHealthyWeatherDevice(container);
        final monitor = container.read(safetyMonitorStateProvider.notifier);
        monitor.setConnecting('safety-1');
        monitor.setConnected();
        monitor.updateSafetyStatus(true);

        final safety = container.read(weatherSafetyProvider.notifier);
        await settle(container);

        container
            .read(weatherStateProvider.notifier)
            .setError(StateError('HTTP 500'));
        safety.forceEvaluation();
        await settle(container);

        final state = container.read(weatherSafetyProvider);
        expect(state.status, WeatherSafetyStatus.unsafe);
        expect(state.hardwareWeatherSafe, isFalse);
        expect(state.hardwareWeatherReading, SafetySourceReading.unknown);
        expect(state.actions.reason, contains('Weather device'));
      },
    );

    test('an unreachable source stays SAFE under fail-open', () async {
      final container = buildContainer(failMode: SafetyFailMode.failOpen);
      connectHealthyWeatherDevice(container);
      final monitor = container.read(safetyMonitorStateProvider.notifier);
      monitor.setConnecting('safety-1');
      monitor.setConnected();
      monitor.updateSafetyStatus(true);

      final safety = container.read(weatherSafetyProvider.notifier);
      await settle(container);

      monitor.setError(StateError('HTTP 500'));
      safety.forceEvaluation();
      await settle(container);

      final state = container.read(weatherSafetyProvider);
      expect(state.status, WeatherSafetyStatus.safe);
      expect(state.safetyMonitorReading, SafetySourceReading.unknown);
    });

    test(
      'a source the operator never configured does not force unsafe',
      () async {
        final container = buildContainer();
        connectHealthyWeatherDevice(container);

        container.read(weatherSafetyProvider.notifier);
        await settle(container);

        final state = container.read(weatherSafetyProvider);
        expect(state.status, WeatherSafetyStatus.safe);
        expect(state.safetyMonitorReading, SafetySourceReading.absent);
        expect(state.safetyMonitorSafe, isTrue);
      },
    );

    test('a reading that has gone stale is UNSAFE (fail-closed)', () async {
      final container = buildContainer();
      connectHealthyWeatherDevice(container);
      final monitor = container.read(safetyMonitorStateProvider.notifier);
      monitor.setConnecting('safety-1');
      monitor.setConnected();
      monitor.updateSafetyStatus(true);

      final safety = container.read(weatherSafetyProvider.notifier);
      await settle(container);
      expect(
        container.read(weatherSafetyProvider).status,
        WeatherSafetyStatus.safe,
      );

      // Still nominally connected, but the last successful read is far older
      // than the freshness budget.
      (monitor as _SeedableSafetyMonitorNotifier).seed(
        SafetyMonitorState(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'safety-1',
          isSafe: true,
          lastChecked: DateTime.now().subtract(const Duration(minutes: 30)),
        ),
      );
      safety.forceEvaluation();
      await settle(container);

      final state = container.read(weatherSafetyProvider);
      expect(state.status, WeatherSafetyStatus.unsafe);
      expect(state.safetyMonitorReading, SafetySourceReading.unknown);
    });

    // Lead's TZ=Asia/Tokyo instance: 16 min of uptime and the source had never
    // answered once. "Not answered yet" is not "answered, and it is safe".
    test(
      'a configured source that has never answered is UNSAFE (fail-closed)',
      () async {
        final container = buildContainer();
        final monitor = container.read(safetyMonitorStateProvider.notifier);
        monitor.setConnecting('safety-1');
        monitor.setConnected();
        monitor.updateSafetyStatus(true);

        // Connected, but no telemetry has ever arrived for it.
        final weather = container.read(weatherStateProvider.notifier);
        weather.setConnecting('weather-1');
        weather.setConnected();

        container.read(weatherSafetyProvider.notifier);
        await settle(container);

        final state = container.read(weatherSafetyProvider);
        expect(state.status, WeatherSafetyStatus.unsafe);
        expect(state.hardwareWeatherReading, SafetySourceReading.unknown);
        expect(state.hardwareWeatherSafe, isFalse);
      },
    );

    test(
      'a rig whose only source never answers is UNSAFE (fail-closed)',
      () async {
        final container = buildContainer();
        final weather = container.read(weatherStateProvider.notifier);
        weather.setConnecting('weather-1');
        weather.setConnected();

        container.read(weatherSafetyProvider.notifier);
        await settle(container);

        final state = container.read(weatherSafetyProvider);
        expect(state.status, WeatherSafetyStatus.unsafe);
        expect(state.dataSource, SafetyDataSource.unavailable);
        expect(state.hardwareWeatherReading, SafetySourceReading.unknown);
      },
    );

    // The card rendered "Data: Weather API" with a live reading AND the amber
    // "No weather data sources available" banner at the same time: copyWith
    // only ever set the warning, so the startup no-data text outlived the data
    // arriving.
    test('the no-data warning clears once a source reports', () async {
      final container = buildContainer();
      final safety = container.read(weatherSafetyProvider.notifier);
      await settle(container);
      expect(
        container.read(weatherSafetyProvider).failModeWarning,
        isNotNull,
        reason: 'no sources at startup must warn',
      );

      connectHealthyWeatherDevice(container);
      safety.forceEvaluation();
      await settle(container);

      final state = container.read(weatherSafetyProvider);
      expect(state.status, WeatherSafetyStatus.safe);
      expect(state.dataSource, SafetyDataSource.combined);
      expect(state.failModeWarning, isNull);
    });
  });
}
