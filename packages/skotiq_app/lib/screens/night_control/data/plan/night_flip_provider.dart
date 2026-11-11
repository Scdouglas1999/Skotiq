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
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;

import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';

/// The run's progress node for its meridian flip (the native
/// `MERIDIAN_FLIP_RUN_PROGRESS_NODE_ID`).
const String kMeridianFlipProgressNodeId = 'trigger:meridian_flip';

/// "attempt 2/4 failed, retrying in 60s", the run's retry notice.
final RegExp _attemptFailed = RegExp(
  r'attempt\s+(\d+)\s*/\s*(\d+)\s+failed(?:,\s*retrying in\s+(\d+(?:\.\d+)?)\s*s)?',
  caseSensitive: false,
);

/// Where the run's meridian flip stands.
@immutable
class NightFlipState {
  const NightFlipState({
    this.startedAt,
    this.failedAttempts,
    this.maxAttempts,
    this.nextTryAt,
    this.pierAtStart,
    this.pierChanged = false,
    this.succeeded = false,
    this.failure,
  });

  /// When the flip under way started; null when none is.
  final DateTime? startedAt;

  /// Attempts that failed so far, and the attempts allowed, from the run's
  /// retry notices.
  final int? failedAttempts;
  final int? maxAttempts;

  /// When the run tries again after the last failed attempt.
  final DateTime? nextTryAt;

  /// The mount's side of the pier when the flip started.
  final String? pierAtStart;

  /// The mount has been seen on the other side of the pier since then: the
  /// flip moved it, whatever happened after.
  final bool pierChanged;

  final bool succeeded;

  /// When the flip gave up, and after how many attempts; null unless the
  /// last flip failed.
  final ({DateTime at, int attempts})? failure;

  bool get inProgress => startedAt != null;

  /// This transit's flip is done: the flip succeeded, or the mount took the
  /// other side of the pier and the run will not flip it again.
  bool get doneForThisTransit => succeeded || pierChanged;

  NightFlipState copyWith({
    DateTime? Function()? startedAt,
    int? Function()? failedAttempts,
    int? Function()? maxAttempts,
    DateTime? Function()? nextTryAt,
    String? Function()? pierAtStart,
    bool? pierChanged,
    bool? succeeded,
    ({DateTime at, int attempts})? Function()? failure,
  }) =>
      NightFlipState(
        startedAt: startedAt == null ? this.startedAt : startedAt(),
        failedAttempts:
            failedAttempts == null ? this.failedAttempts : failedAttempts(),
        maxAttempts: maxAttempts == null ? this.maxAttempts : maxAttempts(),
        nextTryAt: nextTryAt == null ? this.nextTryAt : nextTryAt(),
        pierAtStart: pierAtStart == null ? this.pierAtStart : pierAtStart(),
        pierChanged: pierChanged ?? this.pierChanged,
        succeeded: succeeded ?? this.succeeded,
        failure: failure == null ? this.failure : failure(),
      );

  @override
  bool operator ==(Object other) =>
      other is NightFlipState &&
      other.startedAt == startedAt &&
      other.failedAttempts == failedAttempts &&
      other.maxAttempts == maxAttempts &&
      other.nextTryAt == nextTryAt &&
      other.pierAtStart == pierAtStart &&
      other.pierChanged == pierChanged &&
      other.succeeded == succeeded &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(
        startedAt,
        failedAttempts,
        maxAttempts,
        nextTryAt,
        pierAtStart,
        pierChanged,
        succeeded,
        failure,
      );
}

bool _isLive(SequenceExecutionState state) => switch (state) {
      SequenceExecutionState.running ||
      SequenceExecutionState.paused ||
      SequenceExecutionState.recovering ||
      SequenceExecutionState.stopping ||
      SequenceExecutionState.finalizing ||
      SequenceExecutionState.stopFailed ||
      SequenceExecutionState.cleanupFailed =>
        true,
      SequenceExecutionState.idle ||
      SequenceExecutionState.completed ||
      SequenceExecutionState.failed =>
        false,
    };

/// "east" or "west" for a side of pier the mount reports, else null.
String? _pier(String? side) => switch (side?.trim().toLowerCase()) {
      'east' || 'pierside_east' || 'pier_east' => 'east',
      'west' || 'pierside_west' || 'pier_west' => 'west',
      _ => null,
    };

final nightFlipProvider = NotifierProvider<NightFlipTracker, NightFlipState>(
  NightFlipTracker.new,
);

class NightFlipTracker extends Notifier<NightFlipState> {
  @override
  NightFlipState build() {
    ref.listen<List<sk_events.SkotiqEvent>>(
      eventHistoryProvider,
      (previous, next) {
        // The history only gains events at its front; the new ones are those
        // the previous list did not hold, by identity.
        final known = Set<sk_events.SkotiqEvent>.identity()
          ..addAll(previous ?? const []);
        final fresh = next.takeWhile((e) => !known.contains(e)).toList();
        for (final event in fresh.reversed) {
          _apply(event);
        }
      },
    );
    ref.listen<String?>(
      mountStateProvider.select((m) => m.sideOfPier),
      (_, side) => _observePier(side),
    );
    // A new run starts with no flip behind it. Read off the executor, not
    // the run phase: the action controller's gating reads this provider, and
    // the run phase reads the action controller.
    ref.listen<bool>(
      sequenceExecutionStateProvider.select(_isLive),
      (wasLive, live) {
        if (live && wasLive == false) state = const NightFlipState();
      },
    );
    state = const NightFlipState();
    for (final event in ref.read(eventHistoryProvider).reversed) {
      _apply(event);
    }
    return state;
  }

  void _apply(sk_events.SkotiqEvent event) {
    final payload = event.payload;
    if (payload is! sk_events.EventPayload_Sequencer) return;
    final at = DateTime.fromMillisecondsSinceEpoch(event.timestamp.toInt());
    switch (payload.field0) {
      case sk_events.SequencerEvent_Started():
        state = const NightFlipState();
      case sk_events.SequencerEvent_TriggerFired(
            :final triggerId,
            :final action,
          )
          when triggerId == 'meridian_flip' ||
              action.startsWith('MeridianFlip'):
        _start(at);
      case sk_events.SequencerEvent_InstructionProgress(
            :final nodeId,
            :final detail,
          )
          when nodeId == kMeridianFlipProgressNodeId:
        if (!state.inProgress) _start(at);
        final match = _attemptFailed.firstMatch(detail);
        if (match == null) return;
        final wait = match.group(3);
        final delay = wait == null ? null : double.tryParse(wait);
        state = state.copyWith(
          failedAttempts: () => int.tryParse(match.group(1)!),
          maxAttempts: () => int.tryParse(match.group(2)!),
          nextTryAt: () => delay == null
              ? null
              : at.add(Duration(milliseconds: (delay * 1000).round())),
        );
      case sk_events.SequencerEvent_MeridianFlipOutcome(
          :final outcome,
          :final attempts,
        ):
        // The mount reached its new side; centering and guiding are still
        // being restored, and the verdict follows.
        if (outcome == meridianFlipPierChangedOutcome) {
          if (!state.inProgress) _start(at);
          state = state.copyWith(pierChanged: true);
          return;
        }
        final success = outcome == 'success';
        state = state.copyWith(
          startedAt: () => null,
          nextTryAt: () => null,
          succeeded: success,
          failure: () =>
              outcome == 'failed' ? (at: at, attempts: attempts) : null,
        );
      case sk_events.SequencerEvent_Resumed():
        // The operator has seen the failure; the Steps list moves on.
        if (state.failure != null) {
          state = state.copyWith(failure: () => null);
        }
      default:
        return;
    }
  }

  void _start(DateTime at) {
    state = NightFlipState(
      startedAt: at,
      pierAtStart: _pier(ref.read(mountStateProvider).sideOfPier),
    );
  }

  void _observePier(String? side) {
    final now = _pier(side);
    if (now == null || state.pierChanged) return;
    // Only the flip moves the mount across the pier here; a slew to the next
    // target after it may too, and says nothing about the flip.
    if (!state.inProgress && state.failure == null) return;
    final before = state.pierAtStart;
    if (before == null) {
      // The flip started before the mount said where it was; the first
      // reading is where it started from.
      if (state.inProgress) {
        state = state.copyWith(pierAtStart: () => now);
      }
      return;
    }
    if (now != before) state = state.copyWith(pierChanged: true);
  }
}

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
          'time': ClockFormat.hm(clock.toNightClock(failure.at)),
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
            'time': ClockFormat.hm(clock.toNightClock(nextTry)),
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
