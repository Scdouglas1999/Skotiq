import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// App-settings key controlling whether masters are built automatically when
/// the night ends. An unset key reads as on; only an explicit `false` turns
/// it off. See [NightEndAutomationSettings.build].
const String kAutoIntegrateSettingKey = NightEndAutomationSettings.buildKey;

/// What a night-end run did, surfaced to the run-completion host so it can
/// toast the operator.
class AutoIntegrationResult {
  /// True when an integration / accumulation actually ran.
  final bool ran;

  /// Human-readable summary for the toast / notification body.
  final String message;

  /// True when the feature was enabled but processing failed.
  final bool failed;

  const AutoIntegrationResult({
    required this.ran,
    required this.message,
    this.failed = false,
  });
}

/// Host-authoritative setting used by both the local rig and remote clients.
final autoIntegrationEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return backend.getAutoIntegrationEnabled();
  }
  final raw =
      await ref.watch(settingsDaoProvider).getSetting(kAutoIntegrateSettingKey);
  return raw != 'false';
});

final autoIntegrationSettingsActionsProvider = Provider((ref) {
  final backend = ref.watch(backendProvider);
  return AutoIntegrationSettingsActions(
    ref,
    remote: backend is NetworkBackend ? backend : null,
    local: backend is NetworkBackend ? null : ref.read(settingsDaoProvider),
  );
});

class AutoIntegrationSettingsActions {
  AutoIntegrationSettingsActions(
    this._ref, {
    required NetworkBackend? remote,
    required SettingsDao? local,
  })  : _remote = remote,
        _local = local;

  final Ref _ref;
  final NetworkBackend? _remote;
  final SettingsDao? _local;

  Future<void> setEnabled(bool enabled) async {
    final remote = _remote;
    if (remote != null) {
      await remote.setAutoIntegrationEnabled(enabled);
    } else {
      await _local!.setSetting(kAutoIntegrateSettingKey, enabled.toString());
    }
    _ref.invalidate(autoIntegrationEnabledProvider);
  }
}

/// Stops the Darkroom passes recorded over a session. Passes are no longer
/// started from here: masters are built by the Darkroom's guided build and
/// the night-end automation, and the pass view keeps the earlier passes and
/// any pass a restart picks up from the queue.
class AutoIntegrationService {
  AutoIntegrationService(this._ref);

  final Ref _ref;

  /// Ask the Darkroom job [jobId] to stop.
  ///
  /// Exposed here because the run-completion host is where an operator's
  /// "stop" reaches the dawn pipeline; the flag it raises is the engine's own
  /// plus the autopilot's, so a render already inside Rust stops at its next
  /// poll and the pipeline stops before the next master.
  Future<void> cancelDarkroomJob(int jobId, {String? reason}) {
    return _ref
        .read(dawnAutopilotServiceProvider)
        .requestCancel(jobId, reason: reason);
  }

  /// Ask every Darkroom pass live over [sessionId] to stop, and report which
  /// jobs those were.
  ///
  /// Every live row is stopped, not only the newest, so no pass over the
  /// session runs on to delivery after a Stop.
  ///
  /// Returns the jobs asked to stop, oldest first, or an empty list when the
  /// session has no live job — the press landed in the gap between the enqueue
  /// and the row, or the pass finished on its own. The caller states which
  /// happened rather than reporting a stop that did not occur.
  Future<List<int>> cancelDarkroomPassForSession(
    int sessionId, {
    String? reason,
  }) async {
    final live = await _ref
        .read(dawnAutopilotServiceProvider)
        .liveJobsForSession(sessionId);
    final stopped = <int>[];
    for (final job in live) {
      await cancelDarkroomJob(job.id!, reason: reason);
      stopped.add(job.id!);
    }
    return stopped;
  }
}

/// Provider for the [AutoIntegrationService].
final autoIntegrationServiceProvider = Provider<AutoIntegrationService>(
  (ref) => AutoIntegrationService(ref),
);

class AutoIntegrationCompletion {
  const AutoIntegrationCompletion({
    required this.generation,
    required this.result,
  });

  final int generation;
  final AutoIntegrationResult result;
}

/// Latest user-visible completion from the background coordinator.
final autoIntegrationCompletionProvider =
    StateProvider<AutoIntegrationCompletion?>((ref) => null);

/// How long to wait for the end-of-night coordinator to classify a finished
/// run before falling back to the run's own status.
const _nightDecisionTimeout = Duration(seconds: 30);

/// Always-on host lifecycle for the night-end automation.
///
/// It deliberately activates only for [FfiBackend]. A remote UI mirrors the
/// host's terminal state and image catalog, but must never process its own
/// client-side database or paths. Nights are handled one at a time.
///
/// A night is handled when its run ended it: the run completed, or a dawn or
/// obstruction park ended it. It waits for the end-of-night calibration that
/// run started, so the masters are calibrated with tonight's darks, then
/// hands the night to the [NightEndRunner]: build every imaged target from all
/// its nights, deliver, and send the morning message, as the Darkroom's
/// Activity settings say. At launch the runner carries on a night a restart
/// cut short.
final autoIntegrationCoordinatorProvider = Provider<void>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is! FfiBackend) return;

  // Created first so it sees every terminal run this coordinator sees.
  final night = ref.read(endOfNightCalibrationCoordinatorProvider);
  final runner = ref.read(nightEndRunnerProvider);
  unawaited(runner.start());
  final handle = _nightEndHandler(ref);
  var queue = Future<void>.value();
  ref.listen<SequenceTerminalRunResult?>(sequenceTerminalRunResultProvider,
      (previous, next) {
    if (next == null) return;
    if (previous?.generation == next.generation) return;
    final sessionId = next.dbSessionId;
    if (sessionId == null) return;
    final generation = next.generation;
    final endedAt = DateTime.now();
    var classified = true;
    final ended = night.runEnded(generation).timeout(
      _nightDecisionTimeout,
      onTimeout: () {
        classified = false;
        return next.runStatus == 'completed'
            ? EonEndReason.targetsComplete
            : null;
      },
    );

    queue = queue.then((_) async {
      final reason = await ended;
      if (reason == null) return;
      if (classified) await night.nightSettled(generation);
      final report = ref.read(endOfNightCalibrationProvider).report;
      await handle(
        sessionId: sessionId,
        generation: generation,
        reason: reason,
        calibration: report != null &&
                !report.startedAt
                    .isBefore(endedAt.subtract(const Duration(minutes: 5)))
            ? report
            : null,
      );
    });
  });

  // A night the operator stopped and then ended with a manual end-of-night
  // calibration is handled once that calibration is done.
  ref.listen<NightIntegrationRequest?>(nightIntegrationRequestProvider,
      (previous, next) {
    if (next == null || previous?.generation == next.generation) return;
    queue = queue.then(
      (_) => handle(
        sessionId: next.sessionId,
        generation: -next.generation,
        reason: EonEndReason.manual,
        calibration: ref.read(endOfNightCalibrationProvider).report,
      ),
    );
  });
});

/// What the coordinator does for one night: run the night-end automation and
/// publish a one-line result for the toast. [generation] keys the toast.
Future<void> Function({
  required int sessionId,
  required int generation,
  required EonEndReason reason,
  EonReport? calibration,
}) _nightEndHandler(Ref ref) => ({
      required sessionId,
      required generation,
      required reason,
      calibration,
    }) async {
      try {
        final run = await ref.read(nightEndRunnerProvider).nightEnded(
              sessionId: sessionId,
              reason: reason.description,
              calibration: calibration,
            );
        if (run == null) return;
        final result = describeNightEndRun(run);
        if (result == null) return;
        ref.read(autoIntegrationCompletionProvider.notifier).state =
            AutoIntegrationCompletion(generation: generation, result: result);
      } catch (error) {
        // Keep the serialization chain alive even if the run or the toast
        // publication fails; the run records its own outcome.
        ref.read(loggingServiceProvider).error(
          'Night-end automation failed',
          source: 'AutoIntegrationCoordinator',
          fields: {'sessionId': sessionId, 'error': '$error'},
        );
      }
    };

/// The toast for a finished night-end run, or null when it built nothing.
AutoIntegrationResult? describeNightEndRun(NightEndRun run) {
  final lines = <String>[];
  var built = 0;
  var failed = false;
  for (final target in run.targets) {
    switch (target.build.state) {
      case NightEndStepState.done:
        built++;
        final nights = target.nights;
        lines.add('${target.target}: masters ready'
            '${nights == null ? '' : ' from $nights night${nights == 1 ? '' : 's'}'}.');
      case NightEndStepState.waiting:
        lines.add('${target.target}: waits for you at the framing check.');
      case NightEndStepState.failed:
        failed = true;
        lines.add('${target.target}: the build failed. '
                '${target.build.detail ?? ''}'
            .trim());
      default:
        break;
    }
  }
  if (lines.isEmpty) return null;
  return AutoIntegrationResult(
    ran: built > 0,
    failed: failed,
    message: lines.join(' '),
  );
}
