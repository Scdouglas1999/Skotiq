// The run's meridian flip, as the Steps list shows it.
//
// A trigger-fired flip is not a step of the plan, so while one ran (and
// retried for twelve minutes) the Steps list said only "Smart Exposure,
// running now". The run reports the flip in its event stream: the trigger
// firing, a progress event per failed attempt with the wait before the next
// ("attempt 2/4 failed, retrying in 60s"), and the outcome. This follows
// those events, and the mount's side of the pier, so Tonight can say what
// the flip is doing and stop announcing a flip the mount has already made.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';

import '../../night_control_contracts.dart';
import '../../../../services/night_session/night_flip.dart';
import '../../../../services/run_control/run_control.dart';
import '../../../../services/night_session/night_now.dart';

/// The Steps list's row for the run's meridian flip, or null when no flip is
/// under way and none just failed.
@immutable
class NightFlipStepVm {
  const NightFlipStepVm({required this.status, required this.detail});

  /// [PlanStepStatus.active] while the flip runs, [PlanStepStatus.failed]
  /// after it gave up.
  final PlanStepStatus status;

  final NightText detail;

  @override
  bool operator ==(Object other) =>
      other is NightFlipStepVm &&
      other.status == status &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(status, detail);
}

final nightFlipStepProvider = Provider<NightFlipStepVm?>((ref) {
  if (!ref.watch(nightRunPhaseProvider).isRunLive) return null;
  final flip = ref.watch(nightFlipProvider);
  final clock = ref.watch(clockProvider);

  final failure = flip.failure;
  if (!flip.inProgress) {
    if (failure == null) return null;
    return NightFlipStepVm(
      status: PlanStepStatus.failed,
      detail: NightText(
        flip.pierChanged ? 'nightCtlFlipFailedMoved' : 'nightCtlFlipFailed',
        params: <String, String>{
          'attempts': '${failure.attempts}',
          'time': clock.hm(failure.at),
        },
      ),
    );
  }

  final failed = flip.failedAttempts;
  final max = flip.maxAttempts;
  final nextTry = flip.nextTryAt;
  final now = ref.watch(nightNowProvider);
  if (failed != null && max != null) {
    if (nextTry != null && now.isBefore(nextTry)) {
      return NightFlipStepVm(
        status: PlanStepStatus.active,
        detail: NightText(
          'nightCtlFlipAttemptFailed',
          params: <String, String>{
            'attempt': '$failed',
            'max': '$max',
            'time': clock.hm(nextTry),
          },
        ),
      );
    }
    return NightFlipStepVm(
      status: PlanStepStatus.active,
      detail: NightText(
        'nightCtlFlipAttempt',
        params: <String, String>{
          'attempt': '${(failed + 1).clamp(1, max)}',
          'max': '$max',
        },
      ),
    );
  }
  // The first attempt: the run's own account of what it is doing, when it
  // gives one.
  final message = ref.watch(sequenceProgressProvider.select((p) => p.message));
  return NightFlipStepVm(
    status: PlanStepStatus.active,
    detail: message != null && message.trim().isNotEmpty
        ? NightText.literal(message.trim())
        : const NightText('nightCtlFlipUnderway'),
  );
});
