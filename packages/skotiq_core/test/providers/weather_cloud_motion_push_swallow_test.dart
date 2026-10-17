// The opportunistic cloud-motion push is best-effort telemetry layered on top
// of the authoritative SafeRig (Dart) and WeatherUnsafe (Rust) gates. A failure
// pushing it stays non-blocking: it never rethrows out of `_pushCloudMotion` and
// never wedges the verdict-push loop. The failure is logged, not swallowed.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';
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
    bool notify = true,
  }) async => const SafeRigResult();
}

void main() {
  test('a throwing cloud-motion push is swallowed (non-blocking) and does not '
      'wedge the verdict push', () async {
    final backend = MockBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.sequencerUpdateWeatherVerdict(
        unsafeOverride: any(named: 'unsafeOverride'),
      ),
    ).thenAnswer((_) async {});
    // The cloud-motion push faults; the failure must be logged, not dropped.
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
    ).thenThrow(StateError('cloud-motion backend unavailable'));

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            const AppSettingsState(safetyFailMode: SafetyFailMode.failClosed),
          ),
        ),
        weatherSettingsDataProvider.overrideWith(
          (ref) =>
              Stream.value(const WeatherSettings(weatherSafetyEnabled: true)),
        ),
        safeRigServiceProvider.overrideWith((ref) => _NoopSafeRigService(ref)),
        // Drive _pushCloudMotion all the way to the throwing backend call:
        // a low finite cover (10%) with no motion data. Low current cover must
        // not be fabricated into a future-opening prediction.
        analyzeCloudMotionProvider.overrideWith((ref) async => null),
        cloudCoverPercentageProvider.overrideWith((ref) async => 10.0),
      ],
    );
    addTearDown(container.dispose);

    // Construct the notifier; the constructor schedules the first cloud-motion
    // push on the next microtask.
    container.read(weatherSafetyProvider.notifier);
    await container.read(appSettingsProvider.future);

    // Pump enough event-loop turns for the async provider reads inside
    // _pushCloudMotion to resolve and reach the throwing backend call. If the
    // throw were rethrown out of the unawaited future, flutter_test would
    // surface it as an unhandled async error and fail this test.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    // It reached (and tolerated) the faulting push.
    verify(
      () => backend.sequencerUpdateCloudMotion(
        currentCoverPercent: 10.0,
        predictedArrivalMinutes: any(named: 'predictedArrivalMinutes'),
        predictedOpeningMinutes: null,
        predictedOpeningDurationSecs: null,
        predictedClearSkyAlt: any(named: 'predictedClearSkyAlt'),
        predictedClearSkyAz: any(named: 'predictedClearSkyAz'),
      ),
    ).called(greaterThanOrEqualTo(1));

    // The authoritative verdict push still happened — the faulting telemetry
    // push did not wedge the safety path.
    verify(
      () => backend.sequencerUpdateWeatherVerdict(
        unsafeOverride: any(named: 'unsafeOverride'),
      ),
    ).called(greaterThanOrEqualTo(1));
  });
}
