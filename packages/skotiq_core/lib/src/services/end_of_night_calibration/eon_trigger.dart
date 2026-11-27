import '../../database/rows/frame_type_record.dart';
import 'dart:async';

import 'package:skotiq_bridge/skotiq_bridge.dart' show SequencerNightEnd;

import '../../models/sequence/active_plan_owner.dart';
import '../../models/sequence/run_stop_classification.dart';
import '../../models/sequence/sequence_run_status.dart';
import '../../models/sequence/terminal_run_result.dart';
import '../../utils/logging_service.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'eon_settings.dart';
import '../../backend/skotiq_backend.dart';
import '../../database/daos/images_dao.dart';
import '../../database/daos/settings_dao.dart';
import '../../models/calibration/eon_status.dart';
import 'eon_service.dart';

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
  final (now, _) = AstronomyCalculations.sunAltAz(
    dt: time.toUtc(),
    latitudeDeg: latitude,
    longitudeDeg: longitude,
  );
  final (later, _) = AstronomyCalculations.sunAltAz(
    dt: time.toUtc().add(const Duration(minutes: 10)),
    latitudeDeg: latitude,
    longitudeDeg: longitude,
  );
  return now >= eonDawnSunAltitudeDeg && later > now;
}

/// The end-of-night reason a native night end gives.
EonEndReason? _nightEndReason(SequencerNightEnd? nightEnd) =>
    switch (nightEnd) {
      SequencerNightEnd.dawn => EonEndReason.dawn,
      SequencerNightEnd.obstruction => EonEndReason.obstruction,
      null => null,
    };

/// Whether a finished imaging run ended the night, and why. Null when it did
/// not: an operator stop, a failure, or a weather stop in the middle of the
/// night leave the night open. [nightEnd] is the native trigger table's
/// answer for the trigger that parked the run; [stopOrigin] is who stopped
/// it otherwise.
EonEndReason? classifyRunEnd({
  required SequenceRunStatus runStatus,
  required String? stopOrigin,
  required bool nightEnding,
  SequencerNightEnd? nightEnd,
  bool parked = false,
}) {
  if (runStatus == SequenceRunStatus.completed) {
    return EonEndReason.targetsComplete;
  }
  // A recovered failure cause remains the run's verdict even when dawn
  // subsequently parks it. That verdict must not suppress night-end work.
  if (runStatus == SequenceRunStatus.failed && parked) {
    final reason = _nightEndReason(nightEnd);
    if (reason != null) return reason;
  }
  if (!runStatus.endedByStop) return null;
  final reason = _nightEndReason(nightEnd);
  if (reason != null) return reason;
  // A trigger's stop carries the trigger's id as its origin.
  final safetyStop =
      stopOrigin == 'weather_unsafe' ||
      stopOrigin == RunStopOrigin.safety.wire ||
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
  /// Every collaborator is asked for when it is needed, so a setting edited
  /// during the night applies to the next run that ends.
  ///
  /// [observerLocation] is the site, or null while it is not set.
  /// [takeDeferredWarmUp] returns whether the finished run left its camera
  /// warm-up to this step and clears that flag. [requestIntegration] hands a
  /// night the operator stopped to the post-session integration. The owner
  /// calls [runFinished] with each finished run.
  EndOfNightCalibrationCoordinator({
    required ActivePlanOwner Function() activeOwner,
    required SequenceStopDecision? Function() stopEvidence,
    required String? Function() lastRunEndOrigin,
    required LoggingService Function() log,
    required bool Function() takeDeferredWarmUp,
    required EndOfNightCalibrationService Function() calibration,
    required ({double latitude, double longitude})? Function() observerLocation,
    required String? Function() mountId,
    required SkotiqBackend Function() backend,
    required ImagesDao Function() imagesDao,
    required void Function(NightIntegrationRequest request) requestIntegration,
    required bool Function() isRemote,
    required SettingsDao Function() settingsDao,
    required bool Function() canStartRun,
  }) : _activeOwner = activeOwner,
       _stopEvidence = stopEvidence,
       _lastRunEndOrigin = lastRunEndOrigin,
       _logOf = log,
       _takeDeferredWarmUp = takeDeferredWarmUp,
       _calibration = calibration,
       _observerLocation = observerLocation,
       _mountId = mountId,
       _backend = backend,
       _imagesDao = imagesDao,
       _requestIntegration = requestIntegration,
       _isRemote = isRemote,
       _settingsDao = settingsDao,
       _canStartRun = canStartRun;

  final ActivePlanOwner Function() _activeOwner;
  final SequenceStopDecision? Function() _stopEvidence;
  final String? Function() _lastRunEndOrigin;
  final LoggingService Function() _logOf;
  final bool Function() _takeDeferredWarmUp;
  final EndOfNightCalibrationService Function() _calibration;
  final ({double latitude, double longitude})? Function() _observerLocation;
  final String? Function() _mountId;
  final SkotiqBackend Function() _backend;
  final ImagesDao Function() _imagesDao;
  final void Function(NightIntegrationRequest request) _requestIntegration;
  final bool Function() _isRemote;
  final SettingsDao Function() _settingsDao;
  final bool Function() _canStartRun;

  /// Classifies the run that just finished and starts what its end calls
  /// for. A generation already seen is ignored.
  void runFinished(SequenceTerminalRunResult? next) {
    if (next == null || next.generation == _lastGeneration) return;
    _lastGeneration = next.generation;
    final owner = next.isCalibration
        ? ActivePlanOwner.calibration
        : _activeOwner();
    final evidence = _stopEvidence();
    final origin = switch (evidence?.author) {
      SequenceStopAuthor.operatorPress => RunStopOrigin.operator.wire,
      SequenceStopAuthor.autopilot => 'autopilot',
      SequenceStopAuthor.system => evidence?.origin,
      null =>
        next.runStatus == SequenceRunStatus.completed
            ? null
            : _lastRunEndOrigin(),
    };
    final nightEnd = evidence?.author == SequenceStopAuthor.system
        ? evidence?.nightEnd
        : null;
    unawaited(_settle(next, owner, origin, nightEnd));
  }

  int? _lastGeneration;
  final _decided = <int, Completer<EonEndReason?>>{};

  /// The session of the last imaging run that ended without ending the night
  /// (an operator stop), so a later manual calibration can integrate it.
  int? _openNightSession;
  int _integrationRequests = 0;
  final _settled = <int, Completer<void>>{};

  LoggingService get _log => _logOf();

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
    SequencerNightEnd? nightEnd,
  ) async {
    final decided = _decided[result.generation] ??= Completer();
    final settled = _settled[result.generation] ??= Completer();
    final deferredWarmUp = _takeDeferredWarmUp();
    try {
      final reason = await _classify(result, owner, stopOrigin, nightEnd);
      if (!decided.isCompleted) decided.complete(reason);
      if (owner != ActivePlanOwner.calibration) {
        _openNightSession = reason == null ? result.dbSessionId : null;
      }
      final calibrated =
          reason != null &&
          await _onNightEnded(result, owner, reason, deferredWarmUp);
      // The run left its Warm camera step to the calibration. When none ran,
      // for whatever reason the run ended, the warm-up is owed now. After the
      // operator's own Stop the run puts nothing away, so neither does this.
      if (deferredWarmUp &&
          !calibrated &&
          stopOrigin != RunStopOrigin.operator.wire) {
        await _calibration().warmUpDeferredCamera(
          'End-of-night calibration did not run, so the camera is '
          'warmed now',
        );
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
      _pruneCompletedGenerations();
    }
  }

  static const _maxRetainedGenerations = 32;

  void _pruneCompletedGenerations() {
    while (_settled.length > _maxRetainedGenerations) {
      final oldestKey = _settled.keys.firstWhere(
        (k) => _settled[k]?.isCompleted == true,
        orElse: () => -1,
      );
      if (oldestKey == -1) break;
      _settled.remove(oldestKey);
      if (_decided[oldestKey]?.isCompleted == true) {
        _decided.remove(oldestKey);
      }
    }
  }

  Future<EonEndReason?> _classify(
    SequenceTerminalRunResult result,
    ActivePlanOwner owner,
    String? stopOrigin,
    SequencerNightEnd? nightEnd,
  ) async {
    // A calibration run is the step's own and ends nothing.
    if (owner == ActivePlanOwner.calibration) return null;
    final site = _observerLocation();
    final nightEnding =
        site != null &&
        isNightEnding(
          time: DateTime.now(),
          latitude: site.latitude,
          longitude: site.longitude,
        );
    var parked = false;
    if (result.runStatus == SequenceRunStatus.failed && nightEnd != null) {
      final mountId = _mountId();
      if (mountId != null) {
        try {
          final mount = await _backend()
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
      nightEnd: nightEnd,
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
    final frames = await _imagesDao().getImagesByProducingRun(
      producingRunId: '$runId',
    );
    if (!frames.any((f) => f.isLight)) return false;
    return _start(reason, waitForCompletion: true, forceWarmUp: deferredWarmUp);
  }

  /// The operator's "take darks and bias now", which is also how they end a
  /// night they stopped themselves. [retake] takes every set, also those the
  /// library already holds. After the step, a night whose run did not end it
  /// is handed to the post-session integration, as a dawn end is. Null when
  /// the step is already running.
  Future<EonReport?> runNow({bool retake = false}) async {
    final service = _calibration();
    if (service.isRunning) return null;
    final report = await service.run(
      reason: EonEndReason.manual.description,
      retake: retake,
    );
    final session = _openNightSession;
    if (session != null) {
      _openNightSession = null;
      _requestIntegration(
        NightIntegrationRequest(
          generation: ++_integrationRequests,
          sessionId: session,
        ),
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
    if (_isRemote()) return false;
    final settings = await EonSettings.load(_settingsDao());
    if (!settings.enabled) {
      _log.info(
        'Imaging ended (${reason.description}); end-of-night calibration is '
        'switched off',
        source: 'EndOfNightCalibration',
      );
      return false;
    }
    final service = _calibration();
    if (service.isRunning) return false;
    if (!_canStartRun()) {
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
