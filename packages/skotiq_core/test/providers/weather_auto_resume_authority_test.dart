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

import '../mocks/mock_backend.dart';

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

class _GatedRepeatSafeRigService extends SafeRigService {
  _GatedRepeatSafeRigService(this.testRef, this.repeatGate)
    : super(testRef, stopSecondaryRig: _stopSecondaryRig);

  final Ref testRef;
  final Completer<void> repeatGate;
  int calls = 0;

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
    calls++;
    if (calls > 1) await repeatGate.future;
    testRef.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.paused;
    if (park) {
      testRef.read(mountStateProvider.notifier).setParked(true);
    }
    return SafeRigResult(sequencePaused: true, mountParked: park);
  }
}

Future<void> _pumpUntil(bool Function() predicate) async {
  for (var i = 0; i < 80 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}

void main() {
  test(
    'unsafe weather invalidates an auto-resume already awaiting mount unpark',
    () async {
      final backend = MockBackend();
      final unparkGate = Completer<void>();
      final unparkStarted = Completer<void>();
      final parkStarted = Completer<void>();
      final repeatSafingGate = Completer<void>();

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
      when(() => backend.mountUnpark('mount-1')).thenAnswer((_) {
        if (!unparkStarted.isCompleted) unparkStarted.complete();
        return unparkGate.future;
      });
      when(() => backend.mountPark('mount-1')).thenAnswer((_) async {
        if (!parkStarted.isCompleted) parkStarted.complete();
      });
      when(() => backend.sequencerResume()).thenAnswer((_) async {});
      when(() => backend.sequencerPause()).thenAnswer((_) async {});

      _GatedRepeatSafeRigService? safeRig;
      final testSafetyProvider =
          StateNotifierProvider<WeatherSafetyNotifier, WeatherSafetyState>((
            ref,
          ) {
            return WeatherSafetyNotifier(ref, autoResumeDelay: Duration.zero);
          });
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              const AppSettingsState(
                safetyFailMode: SafetyFailMode.failClosed,
                parkOnUnsafeWeather: true,
              ),
            ),
          ),
          weatherSettingsDataProvider.overrideWith(
            (ref) => Stream.value(
              const WeatherSettings(
                weatherSafetyEnabled: true,
                autoParkEnabled: true,
                autoResumeEnabled: true,
              ),
            ),
          ),
          safeRigServiceProvider.overrideWith((ref) {
            return safeRig = _GatedRepeatSafeRigService(ref, repeatSafingGate);
          }),
        ],
      );
      addTearDown(() {
        if (!repeatSafingGate.isCompleted) repeatSafingGate.complete();
        container.dispose();
      });

      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      final mount = container.read(mountStateProvider.notifier);
      mount.setConnecting('mount-1');
      mount.setConnected();
      mount.setParked(false);

      final safety = container.read(testSafetyProvider.notifier);
      safety.forceEvaluation();
      await _pumpUntil(() => safeRig?.calls == 1);

      // A connected, calm weather source moves the notifier from the initial
      // fail-closed unsafe episode to safe and starts immediate recovery.
      final weather = container.read(weatherStateProvider.notifier);
      weather.setConnecting('weather-1');
      weather.setConnected();
      weather.updateConditions(
        humidity: 30,
        windSpeed: 0,
        cloudCover: 0,
        rainRate: 0,
      );
      safety.forceEvaluation();
      await _pumpUntil(() => unparkStarted.isCompleted);

      // Re-degrade while mountUnpark is still in flight. Keep the second
      // SafeRig call pending to reproduce the ordering where an in-flight
      // recovery continuation could land last and resume the sequence.
      weather.updateConditions(windSpeed: 20);
      safety.forceEvaluation();
      await _pumpUntil(
        () =>
            container.read(testSafetyProvider).status ==
                WeatherSafetyStatus.unsafe &&
            safeRig?.calls == 2,
      );

      unparkGate.complete();
      await _pumpUntil(() => parkStarted.isCompleted);

      verify(() => backend.mountPark('mount-1')).called(1);
      verifyNever(() => backend.sequencerResume());
    },
  );
}
