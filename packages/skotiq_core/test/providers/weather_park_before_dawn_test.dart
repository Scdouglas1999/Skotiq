import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/weather_state_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/services/safe_rig_service.dart';
import 'package:skotiq_core/src/services/scheduler/sky_calculations.dart';

import '../mocks/mock_backend.dart';

// Park-before-dawn had no test that could reach it: the check read
// `DateTime.now()` directly, so no test could stand in the half hour before
// dawn, and deleting the dawn rule from both the verdict and the executor push
// left every weather test green (manual mutation, w27).

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

class _RecordingSafeRigService extends SafeRigService {
  _RecordingSafeRigService(super.ref)
    : super(stopSecondaryRig: () async => false);

  final reasons = <String>[];

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
    return SafeRigResult(sequencePaused: true, mountParked: park);
  }
}

const _latitude = 40.0;
const _longitude = -75.0;

/// Astronomical dawn on the morning of 2026-03-16 at the test site.
DateTime _dawn() => SkyCalculations.computeTwilight(
  noonLocal: DateTime(2026, 3, 15, 12),
  latitudeDegrees: _latitude,
  longitudeDegrees: _longitude,
  kind: TwilightKind.astronomical,
).morningStart!.toLocal();

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

  /// Evaluate a clear night with park-before-dawn on, at [now].
  Future<({WeatherSafetyState state, List<String> safeRigReasons})> evaluateAt(
    DateTime now, {
    double latitude = _latitude,
    double longitude = _longitude,
  }) async {
    _RecordingSafeRigService? safeRig;
    final provider =
        StateNotifierProvider<WeatherSafetyNotifier, WeatherSafetyState>(
          (ref) => WeatherSafetyNotifier(ref, clock: () => now),
        );
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            AppSettingsState(
              latitude: latitude,
              longitude: longitude,
              safetyFailMode: SafetyFailMode.failClosed,
              parkOnUnsafeWeather: true,
              parkBeforeDawn: true,
            ),
          ),
        ),
        weatherSettingsDataProvider.overrideWith(
          (ref) => Stream.value(
            const WeatherSettings(
              weatherSafetyEnabled: true,
              autoParkEnabled: true,
              autoResumeEnabled: false,
            ),
          ),
        ),
        safeRigServiceProvider.overrideWith(
          (ref) => safeRig = _RecordingSafeRigService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;
    final mount = container.read(mountStateProvider.notifier);
    mount.setConnecting('mount-1');
    mount.setConnected();
    mount.setParked(false);
    // A live, calm weather device: every source reads safe, so dawn is the
    // only thing that can make this evaluation unsafe.
    final weather = container.read(weatherStateProvider.notifier);
    weather.setConnecting('weather-1');
    weather.setConnected();
    weather.updateConditions(
      humidity: 30,
      windSpeed: 0,
      cloudCover: 0,
      rainRate: 0,
    );

    final safety = container.read(provider.notifier);
    await container.read(appSettingsProvider.future);
    await safety.evaluateNow();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return (
      state: container.read(provider),
      safeRigReasons: safeRig?.reasons ?? const <String>[],
    );
  }

  test('twenty minutes before dawn a clear night is held unsafe and the '
      'rig is parked', () async {
    final result = await evaluateAt(
      _dawn().subtract(const Duration(minutes: 20)),
    );

    expect(result.state.status, WeatherSafetyStatus.unsafe);
    expect(result.state.actions.reason, 'Astronomical dawn is approaching');
    expect(result.state.actions.shouldPark, isTrue);
    expect(result.safeRigReasons, isNotEmpty);
    // The in-sequencer WeatherUnsafe trigger hears it too.
    verify(
      () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
    ).called(greaterThan(0));
  });

  test('with no observing site there is no dawn to park before', () async {
    // The unset site reads as 0°, 0°. Twenty minutes before dawn THERE, a
    // rig with no site on record was held unsafe and told dawn was coming.
    final nullIslandDawn = SkyCalculations.computeTwilight(
      noonLocal: DateTime(2026, 3, 15, 12),
      latitudeDegrees: 0,
      longitudeDegrees: 0,
      kind: TwilightKind.astronomical,
    ).morningStart!.toLocal();
    final result = await evaluateAt(
      nullIslandDawn.subtract(const Duration(minutes: 20)),
      latitude: 0,
      longitude: 0,
    );

    expect(result.state.status, WeatherSafetyStatus.safe);
    expect(result.safeRigReasons, isEmpty);
  });

  test('three hours before dawn the same night is safe', () async {
    final result = await evaluateAt(_dawn().subtract(const Duration(hours: 3)));

    expect(result.state.status, WeatherSafetyStatus.safe);
    expect(result.safeRigReasons, isEmpty);
    verifyNever(
      () => backend.sequencerUpdateWeatherVerdict(unsafeOverride: true),
    );
  });

  test('before midnight, dawn is still hours away and nothing parks', () async {
    final evening = DateTime(2026, 3, 15, 22);
    final result = await evaluateAt(evening);

    expect(result.state.status, WeatherSafetyStatus.safe);
    expect(result.safeRigReasons, isEmpty);
  });
}
