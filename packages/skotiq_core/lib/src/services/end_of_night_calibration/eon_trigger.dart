import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../models/sequence/active_plan_owner.dart';
import '../../providers/backend_provider.dart';
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
import 'eon_providers.dart';
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
}) {
  if (runStatus == 'completed') return EonEndReason.targetsComplete;
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

/// Starts the end-of-night calibration step when the night's imaging ends.
///
/// It watches every finished run. A run that took light frames and completed,
/// or was ended by dawn, starts the step when it is switched on in Settings.
/// Other features that end a night (obstruction detection, the scheduler)
/// call [imagingEnded].
class EndOfNightCalibrationCoordinator {
  EndOfNightCalibrationCoordinator(this._ref) {
    _ref.listen<SequenceTerminalRunResult?>(sequenceTerminalRunResultProvider, (
      _,
      next,
    ) {
      if (next == null || next.generation == _lastGeneration) return;
      _lastGeneration = next.generation;
      final owner = _ref.read(currentSequenceProvider.notifier).activeOwner;
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
      unawaited(_onRunEnded(next, owner, origin));
    });
  }

  final Ref _ref;
  int? _lastGeneration;

  LoggingService get _log => _ref.read(loggingServiceProvider);

  Future<void> _onRunEnded(
    SequenceTerminalRunResult result,
    ActivePlanOwner owner,
    String? stopOrigin,
  ) async {
    // The scheduler runs a night as many runs and says itself when the night
    // is over; a calibration run is the step's own.
    if (owner == ActivePlanOwner.autopilot ||
        owner == ActivePlanOwner.calibration) {
      return;
    }
    final runId = result.runId;
    if (runId == null) return;
    final frames = await _ref
        .read(imagesDaoProvider)
        .getImagesByProducingRun(producingRunId: '$runId');
    if (!frames.any((f) => f.frameType.toLowerCase() == 'light')) return;
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    final nightEnding =
        settings != null &&
        settings.hasObserverLocation &&
        isNightEnding(
          time: DateTime.now(),
          latitude: settings.latitude,
          longitude: settings.longitude,
        );
    final reason = classifyRunEnd(
      runStatus: result.runStatus,
      stopOrigin: stopOrigin,
      nightEnding: nightEnding,
    );
    if (reason == null) return;
    await imagingEnded(reason);
  }

  /// The night's imaging has ended for [reason]: start the calibration step
  /// if it is switched on. Returns whether it started.
  Future<bool> imagingEnded(EonEndReason reason) async {
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
    unawaited(
      service.run(reason: reason.description, settings: settings).then((_) {}),
    );
    return true;
  }
}

final endOfNightCalibrationCoordinatorProvider =
    Provider<EndOfNightCalibrationCoordinator>(
      EndOfNightCalibrationCoordinator.new,
    );
