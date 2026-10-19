import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
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
    IdleMountPolicy idleMount = IdleMountPolicy.leave,
    bool notify = true,
  }) async => const SafeRigResult();
}

void main() {
  // Audit 2026-07-29: with "Enable weather safety" OFF the Weather screen showed
  // a green shield, "Conditions safe for imaging" and "Auto-Park: Enabled" —
  // pixel-identical to the monitoring-on state. The provider short-circuits to
  // `safe` when nothing is evaluated, so the state has to carry the distinction
  // for surfaces to render; these flags existed but were never written.
  group('weather safety monitoring disclosure', () {
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
      required bool weatherSafetyEnabled,
      bool autoParkEnabled = true,
      bool autoResumeEnabled = true,
      bool parkOnUnsafeWeather = true,
      bool parkBeforeDawn = false,
    }) {
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(
              AppSettingsState(
                parkOnUnsafeWeather: parkOnUnsafeWeather,
                parkBeforeDawn: parkBeforeDawn,
              ),
            ),
          ),
          weatherSettingsDataProvider.overrideWith(
            (ref) => Stream.value(
              WeatherSettings(
                weatherSafetyEnabled: weatherSafetyEnabled,
                autoParkEnabled: autoParkEnabled,
                autoResumeEnabled: autoResumeEnabled,
              ),
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

    Future<WeatherSafetyState> evaluate(ProviderContainer container) async {
      await container.read(appSettingsProvider.future);
      container.read(weatherSafetyProvider.notifier).forceEvaluation();
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      return container.read(weatherSafetyProvider);
    }

    test('monitoring off is reported as not monitoring, not as safe', () async {
      final state = await evaluate(buildContainer(weatherSafetyEnabled: false));

      // `status` stays `safe` for the sequencer's benefit (no verdict to act
      // on), so the flag is the only thing that stops the UI claiming the sky
      // is being watched.
      expect(state.status, WeatherSafetyStatus.safe);
      expect(state.monitoringEnabled, isFalse);
      expect(state.actions.reason, contains('Weather safety is off'));
    });

    test('monitoring on reports monitoring enabled', () async {
      final state = await evaluate(buildContainer(weatherSafetyEnabled: true));

      expect(state.monitoringEnabled, isTrue);
    });

    test(
      'auto-park is not armed while the master switch is off, even with both '
      'park toggles on',
      () async {
        final state = await evaluate(
          buildContainer(
            weatherSafetyEnabled: false,
            autoParkEnabled: true,
            parkOnUnsafeWeather: true,
          ),
        );

        expect(state.autoParkArmed, isFalse);
        expect(state.autoResumeArmed, isFalse);
      },
    );

    test('auto-park is not armed when the Sequencer policy is off', () async {
      final state = await evaluate(
        buildContainer(
          weatherSafetyEnabled: true,
          autoParkEnabled: true,
          parkOnUnsafeWeather: false,
        ),
      );

      expect(state.autoParkArmed, isFalse);
    });

    test('auto-park is not armed when the weather toggle is off', () async {
      final state = await evaluate(
        buildContainer(
          weatherSafetyEnabled: true,
          autoParkEnabled: false,
          parkOnUnsafeWeather: true,
        ),
      );

      expect(state.autoParkArmed, isFalse);
    });

    test('auto-park is armed when every gate is on', () async {
      final state = await evaluate(
        buildContainer(
          weatherSafetyEnabled: true,
          autoParkEnabled: true,
          parkOnUnsafeWeather: true,
        ),
      );

      expect(state.autoParkArmed, isTrue);
      expect(state.autoResumeArmed, isTrue);
    });

    test(
      'park-before-dawn does NOT make weather auto-park look armed',
      () async {
        // The dawn watchdog can park with weather safety off, but it is a
        // different feature. Counting it here would let the Weather panel imply
        // the sky is covered when nothing is watching it.
        final state = await evaluate(
          buildContainer(
            weatherSafetyEnabled: false,
            autoParkEnabled: true,
            parkOnUnsafeWeather: true,
            parkBeforeDawn: true,
          ),
        );

        expect(state.monitoringEnabled, isFalse);
        expect(state.autoParkArmed, isFalse);
      },
    );
  });
}
