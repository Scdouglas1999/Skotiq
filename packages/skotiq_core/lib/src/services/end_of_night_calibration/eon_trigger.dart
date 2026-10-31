import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../models/sequence/active_plan_owner.dart';
import '../../providers/backend_provider.dart';
import '../../providers/equipment_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/sequence/sequence_executor.dart';
import '../../providers/sequence/run_stop_classification.dart';
import '../../providers/sequence/sequence_progress.dart';
import '../../providers/sequence/sequence_selection.dart';
import '../../models/sequence/sequence_models.dart'
    show SequenceExecutionStateCapabilities;
import '../../providers/sequence_stats_provider.dart';
import '../../providers/settings_provider.dart';
import '../logging_service.dart';
import '../scheduler/sky_calculations.dart';
import 'eon_deferral.dart';
import 'eon_providers.dart';
import 'eon_service.dart' show EonReport;
import 'eon_settings.dart';

/// Why the night's imaging ended.
enum EonEndReason {
  /// The plan ran out of targets and completed.
  targetsComplete('the plan completed'),

  /// Dawn ended the run.
  dawn('dawn ended imaging'),

  /// Something in front of the telescope ended imaging.
  obstruction('an obstruction ended imaging'),

  /// The scheduler reached the end of its night.
  schedulerEndOfNight('the scheduler ended the night'),

  /// The operator asked for it.
  manual('started by the operator');

  const EonEndReason(this.description);
  final String description;
}

/// Sun altitude at and above which a stop is treated as the end of the night
/// when the sun is rising: the Dawn Approaching window opens about half an
/// hour before astronomical dawn (sun at -18 degrees).
const eonDawnSunAltitudeDeg = -24.0;

/// Whether the sun is rising and above [eonDawnSunAltitudeDeg] at [time].
bool isNightEnding({
  required DateTime time,
  required double latitude,
  required double longitude,
}) {
  final (now, _) = SkyCalculations.sunAltAz(
    time: time.toUtc(),
    latitudeDegrees: latitude,
    longitudeDegrees: longitude,
  );
  final (later, _) = SkyCalculations.sunAltAz(
    time: time.toUtc().add(const Duration(minutes: 10)),
    latitudeDegrees: latitude,
    longitudeDegrees: longitude,
  );
  return now >= eonDawnSunAltitudeDeg && later > now;
}

/// Stop origins of the native triggers that end the night: the run's stop
/// origin is the id of the trigger that parked it.
const eonDawnStopOrigin = 'dawn_approaching';
const eonObstructionStopOrigin = 'obstruction';

/// Run statuses a run ended by a stop is filed under: an operator stop is
/// `stopped` or `paused-stopped`, a stop the native side made itself (a
/// trigger's park) is `aborted`.
const _stoppedRunStatuses = {'stopped', 'paused-stopped', 'aborted'};

/// Whether a finished imaging run ended the night, and why. Null when it did
/// not: an operator stop, a failure, or a weather stop in the middle of the
/// night leave the night open.
EonEndReason? classifyRunEnd({
  required String runStatus,
  required String? stopOrigin,
  required bool nightEnding,
  bool parked = false,
}) {
  if (runStatus == 'completed') return EonEndReason.targetsComplete;
  // A recovered failure cause remains the run's verdict even when dawn
  // subsequently parks it. That verdict must not suppress night-end work.
  if (runStatus == 'failed' && parked) {
    if (stopOrigin == eonDawnStopOrigin) return EonEndReason.dawn;
    if (stopOrigin == eonObstructionStopOrigin) return EonEndReason.obstruction;
  }
  if (!_stoppedRunStatuses.contains(runStatus)) return null;
  if (stopOrigin == eonDawnStopOrigin) return EonEndReason.dawn;
  if (stopOrigin == eonObstructionStopOrigin) return EonEndReason.obstruction;
  final safetyStop =
      stopOrigin == 'weather_unsafe' ||
      stopOrigin == 'safety' ||
      stopOrigin == null;
  if (safetyStop && nightEnding) return EonEndReason.dawn;
  return null;
}

/// A request to integrate a night that ended without the run ending it: the
/// operator stopped the run and then ran end-of-night calibration.
class NightIntegrationRequest {
  const NightIntegrationRequest({
    required this.generation,
    required this.sessionId,
  });

  final int generation;
  final int sessionId;
}

/// The latest [NightIntegrationRequest]; the post-session integration
/// coordinator acts on each new one.
final nightIntegrationRequestProvider = StateProvider<NightIntegrationRequest?>(
  (ref) => null,
);

/// Starts the end-of-night calibration step when the night's imaging ends.
///
/// It watches every finished run. A run that took light frames and completed,
/// or was ended by dawn or an obstruction, starts the step when it is switched
/// on in Settings. Other features that end a night (the scheduler) call
/// [imagingEnded].
///
/// Work that belongs after the night's calibration, such as the post-session
/// integration, waits on [runEnded] and [nightSettled] for the run's
/// generation, so tonight's darks are in the library before it reads them.
class EndOfNightCalibrationCoordinator {
  EndOfNightCalibrationCoordinator(this._ref) {
    _ref.listen<SequenceTerminalRunResult?>(sequenceTerminalRunResultProvider, (
      _,
      next,
    ) {
      if (next == null || next.generation == _lastGeneration) return;
      _lastGeneration = next.generation;
      final owner = next.isCalibration
          ? ActivePlanOwner.calibration
          : _ref.read(currentSequenceProvider.notifier).activeOwner;
      final evidence = _ref.read(sequenceStopEvidenceProvider);
      final origin = switch (evidence?.author) {
        SequenceStopAuthor.operatorPress => 'operator',
        SequenceStopAuthor.autopilot => 'autopilot',
        SequenceStopAuthor.system => evidence?.origin,
        null =>
          next.runStatus == 'completed'
              ? null
              : _ref.read(sequenceExecutorProvider).lastRunEndOrigin,
      };
      unawaited(_settle(next, owner, origin));
    });
  }

  final Ref _ref;
  int? _lastGeneration;
  final _decided = <int, Completer<EonEndReason?>>{};

  /// The session of the last imaging run that ended without ending the night
  /// (an operator stop), so a later manual calibration can integrate it.
  int? _openNightSession;
  int _integrationRequests = 0;
  final _settled = <int, Completer<void>>{};

  LoggingService get _log => _ref.read(loggingServiceProvider);

  /// Whether the run of [generation] ended the night, and why; null when it
  /// left the night open. Completes as soon as the run is classified.
  Future<EonEndReason?> runEnded(int generation) =>
      (_decided[generation] ??= Completer<EonEndReason?>()).future;

  /// Completes once whatever the end of [generation]'s run started has
  /// finished: the calibration step when one ran, at once otherwise.
  Future<void> nightSettled(int generation) =>
      (_settled[generation] ??= Completer<void>()).future;

  Future<void> _settle(
    SequenceTerminalRunResult result,
    ActivePlanOwner owner,
    String? stopOrigin,
  ) async {
    final decided = _decided[result.generation] ??= Completer();
    final settled = _settled[result.generation] ??= Completer();
    final deferredWarmUp = _ref.read(shutdownWarmUpDeferredProvider);
    _ref.read(shutdownWarmUpDeferredProvider.notifier).state = false;
    try {
      final reason = await _classify(result, owner, stopOrigin);
      if (!decided.isCompleted) decided.complete(reason);
      if (owner != ActivePlanOwner.calibration) {
        _openNightSession = reason == null ? result.dbSessionId : null;
      }
      if (reason != null) {
        final calibrated = await _onNightEnded(
          result,
          owner,
          reason,
          deferredWarmUp,
        );
        if (deferredWarmUp && !calibrated) {
          await _ref
              .read(endOfNightCalibrationProvider.notifier)
              .warmUpDeferredCamera(
                'End-of-night calibration did not run, so the camera is '
                'warmed now',
              );
        }
      }
    } catch (e, stack) {
      _log.error(
        'End-of-night handling failed: $e',
        source: 'EndOfNightCalibration',
        fields: {'stack': '$stack'},
      );
      if (!decided.isCompleted) decided.complete(null);
    } finally {
      if (!settled.isCompleted) settled.complete();
    }
  }

  Future<EonEndReason?> _classify(
    SequenceTerminalRunResult result,
    ActivePlanOwner owner,
    String? stopOrigin,
  ) async {
    // A calibration run is the step's own and ends nothing.
    if (owner == ActivePlanOwner.calibration) return null;
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    final nightEnding =
        settings != null &&
        settings.hasObserverLocation &&
        isNightEnding(
          time: DateTime.now(),
          latitude: settings.latitude,
          longitude: settings.longitude,
        );
    var parked = false;
    if (result.runStatus == 'failed' &&
        (stopOrigin == eonDawnStopOrigin ||
            stopOrigin == eonObstructionStopOrigin)) {
      final mountId = _ref.read(mountStateProvider).deviceId;
      if (mountId != null) {
        try {
          final mount = await _ref
              .read(backendProvider)
              .getMountStatus(mountId)
              .timeout(const Duration(seconds: 5));
          parked = mount.connected && mount.parked && !mount.slewing;
        } catch (error) {
          _log.warning(
            'Cannot confirm end-of-night parking: $error',
            source: 'EndOfNightCalibration',
          );
        }
      }
      if (!parked) {
        _log.warning(
          'Failed run ended without confirmed parking; automatic calibration was not started',
          source: 'EndOfNightCalibration',
        );
      }
    }
    return classifyRunEnd(
      runStatus: result.runStatus,
      stopOrigin: stopOrigin,
      nightEnding: nightEnding,
      parked: parked,
    );
  }

  /// Returns whether the calibration step ran.
  Future<bool> _onNightEnded(
    SequenceTerminalRunResult result,
    ActivePlanOwner owner,
    EonEndReason reason,
    bool deferredWarmUp,
  ) async {
    // The scheduler runs a night as many runs and says itself when the night
    // is over.
    if (owner == ActivePlanOwner.autopilot) return false;
    final runId = result.runId;
    if (runId == null) return false;
    final frames = await _ref
        .read(imagesDaoProvider)
        .getImagesByProducingRun(producingRunId: '$runId');
    if (!frames.any((f) => f.frameType.toLowerCase() == 'light')) return false;
    return _start(reason, waitForCompletion: true, forceWarmUp: deferredWarmUp);
  }

  /// The operator's "take darks and bias now", which is also how they end a
  /// night they stopped themselves. After the step, a night whose run did not
  /// end it is handed to the post-session integration, as a dawn end is.
  /// Null when the step is already running.
  Future<EonReport?> runNow() async {
    final service = _ref.read(endOfNightCalibrationProvider.notifier);
    if (service.isRunning) return null;
    final report = await service.run(reason: EonEndReason.manual.description);
    final session = _openNightSession;
    if (session != null) {
      _openNightSession = null;
      _ref
          .read(nightIntegrationRequestProvider.notifier)
          .state = NightIntegrationRequest(
        generation: ++_integrationRequests,
        sessionId: session,
      );
    }
    return report;
  }

  /// The night's imaging has ended for [reason]: start the calibration step
  /// if it is switched on. Returns whether it started.
  Future<bool> imagingEnded(EonEndReason reason) => _start(reason);

  Future<bool> _start(
    EonEndReason reason, {
    bool waitForCompletion = false,
    bool forceWarmUp = false,
  }) async {
    if (_ref.read(backendProvider) is NetworkBackend) return false;
    final settings = await EonSettings.load(_ref.read(settingsDaoProvider));
    if (!settings.enabled) {
      _log.info(
        'Imaging ended (${reason.description}); end-of-night calibration is '
        'switched off',
        source: 'EndOfNightCalibration',
      );
      return false;
    }
    final service = _ref.read(endOfNightCalibrationProvider.notifier);
    if (service.isRunning) return false;
    if (!_ref.read(sequenceExecutionStateProvider).canStart) {
      _log.warning(
        'Imaging ended (${reason.description}) but a run is still active; '
        'end-of-night calibration was not started',
        source: 'EndOfNightCalibration',
      );
      return false;
    }
    _log.info(
      'Imaging ended (${reason.description}); starting end-of-night '
      'calibration',
      source: 'EndOfNightCalibration',
    );
    final run = service.run(
      reason: reason.description,
      settings: settings,
      forceWarmUp: forceWarmUp,
    );
    if (waitForCompletion) {
      await run;
    } else {
      unawaited(run.then((_) {}));
    }
    return true;
  }
}

final endOfNightCalibrationCoordinatorProvider =
    Provider<EndOfNightCalibrationCoordinator>(
      EndOfNightCalibrationCoordinator.new,
    );
