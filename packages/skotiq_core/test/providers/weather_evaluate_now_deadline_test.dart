// `evaluateNow` is awaited by the headless PUT /api/weather/settings route so
// the response cannot claim a toggle took effect while safety/status still
// reports the previous decision. It waits on an evaluation that depends on a
// settings fetch, which on a stalled NetworkBackend may never resolve — so the
// wait must be bounded rather than spinning forever.

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
import '../harness/in_memory_database.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
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
  test(
    'evaluateNow gives up rather than spinning on a stalled fetch',
    () async {
      final backend = MockBackend();
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

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          appSettingsProvider.overrideWith(_FakeAppSettingsNotifier.new),
          // Never emits: the evaluation's `await …future` never completes, so
          // the in-flight latch is never released.
          weatherSettingsDataProvider.overrideWith(
            (ref) => const Stream<WeatherSettings>.empty(),
          ),
          safeRigServiceProvider.overrideWith(
            (ref) => _NoopSafeRigService(ref),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(weatherSafetyProvider.notifier);

      await expectLater(
        notifier.evaluateNow(timeout: const Duration(milliseconds: 150)),
        completes,
      );
    },
  );
}
