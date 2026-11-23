import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/sequence/sequence_models.dart'
    show SequenceExecutionStateCapabilities;
import '../../models/sequence/terminal_run_result.dart';
import '../../services/end_of_night_calibration/eon_trigger.dart';
import '../backend_provider.dart';
import '../database_provider.dart';
import '../equipment_provider.dart';
import '../logging_service_provider.dart';
import '../sequence/sequence_executor.dart';
import '../sequence/sequence_progress.dart';
import '../sequence/sequence_selection.dart';
import '../sequence_stats_provider.dart';
import '../settings_provider.dart';
import 'eon_deferral_provider.dart';
import 'eon_providers.dart';

/// The latest [NightIntegrationRequest]; the post-session integration
/// coordinator acts on each new one.
final nightIntegrationRequestProvider = StateProvider<NightIntegrationRequest?>(
  (ref) => null,
);

final endOfNightCalibrationCoordinatorProvider =
    Provider<EndOfNightCalibrationCoordinator>((ref) {
      final coordinator = EndOfNightCalibrationCoordinator(
        activeOwner: () =>
            ref.read(currentSequenceProvider.notifier).activeOwner,
        stopEvidence: () => ref.read(sequenceStopEvidenceProvider),
        lastRunEndOrigin: () =>
            ref.read(sequenceExecutorProvider).lastRunEndOrigin,
        log: () => ref.read(loggingServiceProvider),
        takeDeferredWarmUp: () {
          final deferred = ref.read(shutdownWarmUpDeferredProvider);
          ref.read(shutdownWarmUpDeferredProvider.notifier).state = false;
          return deferred;
        },
        calibration: () => ref.read(endOfNightCalibrationProvider.notifier),
        observerLocation: () {
          final settings = ref.read(appSettingsProvider).valueOrNull;
          if (settings == null || !settings.hasObserverLocation) return null;
          return (latitude: settings.latitude, longitude: settings.longitude);
        },
        mountId: () => ref.read(mountStateProvider).deviceId,
        backend: () => ref.read(backendProvider),
        imagesDao: () => ref.read(imagesDaoProvider),
        requestIntegration: (request) =>
            ref.read(nightIntegrationRequestProvider.notifier).state = request,
        isRemote: () => ref.read(isRemoteModeProvider),
        settingsDao: () => ref.read(settingsDaoProvider),
        canStartRun: () => ref.read(sequenceExecutionStateProvider).canStart,
      );
      ref.listen<SequenceTerminalRunResult?>(
        sequenceTerminalRunResultProvider,
        (_, next) => coordinator.runFinished(next),
      );
      return coordinator;
    });
