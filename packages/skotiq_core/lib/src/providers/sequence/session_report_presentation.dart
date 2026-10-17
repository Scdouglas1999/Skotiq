/// How a finished run's Session Report reaches the operator.
///
/// A MODAL Session Report plus a "How did this run go? / Write note" prompt on
/// every terminal run lands over whatever screen the operator happens to be on.
/// With the autopilot armed and its dispatched runs failing fast, that is a
/// modal per minute — one on the Builder at 00:06:13, another while navigating
/// to Plan Tonight at 00:06:53, another on History at 00:07:40 — each one
/// swallowing the click aimed at the app underneath.
///
/// A report the operator asked for by pressing Start has earned a modal: they
/// are sitting there, the run just ended, and the report is the answer to the
/// thing they were watching. A report for a run the autopilot dispatched while
/// nobody was watching has not. Those are queued and surfaced quietly, so an
/// unattended night leaves a list to read in the morning instead of a stack of
/// dialogs to dismiss.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/scheduler/scheduler_status.dart';
import '../../models/sequence/active_plan_owner.dart';
import '../scheduler_provider.dart' show schedulerStatusProvider;
import 'sequence_editor.dart' show activePlanOwnerProvider;

enum SessionReportPresentation {
  /// Open the report (and the notes prompt) immediately.
  modal,

  /// Add it to [pendingSessionReportsProvider] and say so without stealing
  /// focus.
  queued,
}

/// The decision, as a pure function of the two facts that answer "is anybody
/// watching this run?".
///
/// * The autopilot RUNNING (or PAUSED — a paused autopilot still holds the rig
///   and resumes on its own) means an unattended night is in progress: another
///   run, and another report, is due in minutes.
/// * The editor slot owned by [ActivePlanOwner.autopilot] means the run that
///   just ended was the scheduler's own dispatch, not something the operator
///   started. This still holds just after the engine disengages, which is
///   exactly when the last dispatched run finishes.
SessionReportPresentation sessionReportPresentationFor({
  required SchedulerState schedulerState,
  required ActivePlanOwner planOwner,
}) {
  final unattended =
      schedulerState == SchedulerState.running ||
      schedulerState == SchedulerState.paused ||
      planOwner == ActivePlanOwner.autopilot;
  return unattended
      ? SessionReportPresentation.queued
      : SessionReportPresentation.modal;
}

/// Live wiring of [sessionReportPresentationFor].
final sessionReportPresentationProvider = Provider<SessionReportPresentation>((
  ref,
) {
  return sessionReportPresentationFor(
    schedulerState: ref.watch(schedulerStatusProvider).state,
    planOwner: ref.watch(activePlanOwnerProvider),
  );
});

/// A finished run whose report is waiting to be read.
class PendingSessionReport {
  const PendingSessionReport({
    required this.sessionId,
    required this.runId,
    required this.endedAt,
  });

  /// Database session id the report resolves against.
  final int sessionId;

  /// Completed run id, captured at finalization (may be null for a run that
  /// never got a row).
  final int? runId;

  final DateTime endedAt;

  /// Identity is the run, not the position in the queue — the same terminal
  /// result must never enqueue twice, and a list index is not an identity.
  bool sameRunAs(PendingSessionReport other) =>
      sessionId == other.sessionId && runId == other.runId;

  @override
  String toString() =>
      'PendingSessionReport(session=$sessionId, run=$runId, at=$endedAt)';
}

class PendingSessionReportsNotifier
    extends StateNotifier<List<PendingSessionReport>> {
  PendingSessionReportsNotifier() : super(const []);

  /// Upper bound on the queue. An unattended night that re-dispatches every
  /// minute would otherwise accumulate hundreds of entries by dawn; the oldest
  /// are the ones worth dropping.
  static const int maxRetained = 20;

  void enqueue(PendingSessionReport report) {
    if (state.any((existing) => existing.sameRunAs(report))) return;
    final appended = [...state, report];
    state = appended.length > maxRetained
        ? appended.sublist(appended.length - maxRetained)
        : appended;
  }

  void remove(PendingSessionReport report) {
    state = state.where((existing) => !existing.sameRunAs(report)).toList();
  }

  void clear() => state = const [];
}

final pendingSessionReportsProvider =
    StateNotifierProvider<
      PendingSessionReportsNotifier,
      List<PendingSessionReport>
    >((ref) => PendingSessionReportsNotifier());
