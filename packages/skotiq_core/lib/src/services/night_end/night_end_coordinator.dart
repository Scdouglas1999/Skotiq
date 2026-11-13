import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/remote_host.dart';
import '../../providers/backend_provider.dart';
import '../../providers/sequence_stats_provider.dart';
import '../../models/sequence/sequence_run_status.dart';
import '../../models/sequence/terminal_run_result.dart';
import '../../providers/end_of_night_calibration/eon_providers.dart';
import '../end_of_night_calibration/eon_service.dart';
import '../end_of_night_calibration/eon_trigger.dart';
import 'night_end_run.dart';
import 'night_end_runner.dart';
import '../../providers/end_of_night_calibration/eon_trigger_provider.dart';
import '../../providers/logging_service_provider.dart';
import '../../providers/night_end/night_end_runner_provider.dart';

/// The one-line outcome of a night-end run, for the toast on whatever screen
/// is open.
class NightEndToast {
  const NightEndToast({required this.message, this.failed = false});

  final String message;

  /// True when a target's build failed.
  final bool failed;
}

/// The toast for the latest night the coordinator handled, keyed by the run
/// generation so a listener shows each night once.
class NightEndCompletion {
  const NightEndCompletion({required this.generation, required this.toast});

  final int generation;
  final NightEndToast toast;
}

final nightEndCompletionProvider = StateProvider<NightEndCompletion?>(
  (ref) => null,
);

/// How long to wait for the end-of-night coordinator to classify a finished
/// run before falling back to the run's own status.
const _nightDecisionTimeout = Duration(seconds: 30);

/// Always-on host lifecycle for the night-end automation.
///
/// Only the process that owns the device bridge runs it: a linked client
/// mirrors the host's runs and catalog and must never process its own database
/// or paths. Nights are handled one at a time.
///
/// A night is handled when its run ended it: the run completed, or a dawn or
/// obstruction park ended it. It waits for the end-of-night calibration that
/// run started, so the masters are calibrated with tonight's darks, then
/// hands the night to the [NightEndRunner]: build every imaged target from all
/// its nights, deliver, and send the morning message, as the Darkroom's
/// Activity settings say. At launch the runner carries on a night a restart
/// cut short.
final nightEndCoordinatorProvider = Provider<void>((ref) {
  final backend = ref.watch(backendProvider);
  if (!backend.ownsDeviceBridge) return;

  // Created first so it sees every terminal run this coordinator sees.
  final night = ref.read(endOfNightCalibrationCoordinatorProvider);
  final runner = ref.read(nightEndRunnerProvider);
  unawaited(runner.start());
  final handle = _nightEndHandler(ref);
  var queue = Future<void>.value();
  ref.listen<SequenceTerminalRunResult?>(sequenceTerminalRunResultProvider, (
    previous,
    next,
  ) {
    if (next == null) return;
    if (previous?.generation == next.generation) return;
    final sessionId = next.dbSessionId;
    if (sessionId == null) return;
    final generation = next.generation;
    final endedAt = DateTime.now();
    var classified = true;
    final ended = night
        .runEnded(generation)
        .timeout(
          _nightDecisionTimeout,
          onTimeout: () {
            classified = false;
            return next.runStatus == SequenceRunStatus.completed
                ? EonEndReason.targetsComplete
                : null;
          },
        );

    queue = queue.then((_) async {
      final reason = await ended;
      if (reason == null) return;
      if (classified) await night.nightSettled(generation);
      final report = ref.read(endOfNightCalibrationProvider).report;
      // Only a calibration this night started belongs to it.
      await handle(
        sessionId: sessionId,
        generation: generation,
        reason: reason,
        calibration:
            report != null &&
                !report.startedAt.isBefore(
                  endedAt.subtract(const Duration(minutes: 5)),
                )
            ? report
            : null,
      );
    });
  });

  // A night the operator stopped and then ended with a manual end-of-night
  // calibration is handled once that calibration is done.
  ref.listen<NightIntegrationRequest?>(nightIntegrationRequestProvider, (
    previous,
    next,
  ) {
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
})
_nightEndHandler(Ref ref) =>
    ({
      required sessionId,
      required generation,
      required reason,
      calibration,
    }) async {
      try {
        final run = await ref
            .read(nightEndRunnerProvider)
            .nightEnded(
              sessionId: sessionId,
              reason: reason.description,
              calibration: calibration,
            );
        if (run == null) return;
        final toast = describeNightEndRun(run);
        if (toast == null) return;
        ref.read(nightEndCompletionProvider.notifier).state =
            NightEndCompletion(generation: generation, toast: toast);
      } catch (error) {
        // Keep the serialization chain alive even if the run or the toast
        // publication fails; the run records its own outcome.
        ref
            .read(loggingServiceProvider)
            .error(
              'Night-end automation failed',
              source: 'NightEndCoordinator',
              fields: {'sessionId': sessionId, 'error': '$error'},
            );
      }
    };

/// The toast for a finished night-end run, or null when it built nothing.
NightEndToast? describeNightEndRun(NightEndRun run) {
  final lines = <String>[];
  var failed = false;
  for (final target in run.targets) {
    switch (target.build.state) {
      case NightEndStepState.done:
        final nights = target.nights;
        lines.add(
          '${target.target}: masters ready'
          '${nights == null ? '' : ' from $nights night${nights == 1 ? '' : 's'}'}.',
        );
      case NightEndStepState.waiting:
        lines.add('${target.target}: waits for you at the framing check.');
      case NightEndStepState.failed:
        failed = true;
        lines.add(
          '${target.target}: the build failed. '
                  '${target.build.detail ?? ''}'
              .trim(),
        );
      default:
        break;
    }
  }
  if (lines.isEmpty) return null;
  return NightEndToast(message: lines.join(' '), failed: failed);
}
