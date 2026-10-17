import 'dart:async';

import '../../../models/sequence/sequence_models.dart';
import 'stop_confirmation.dart';

/// The immutable intent + mutable progress of the ONE per-run finalization
/// transaction the executor drives.
///
/// The intent fields are captured when teardown is first claimed and never
/// change — a later racing caller joins the same transaction rather than
/// re-deciding whether this run completed / failed / stopped. The progress
/// flags let a Stop retry (from stopFailed / cleanupFailed) resume EXACTLY where
/// the previous attempt failed, so a retry never repeats a confirmed native
/// stop, a persisted finishRun, or the once-only post-run hooks.
class RunFinalization implements NativeStopConfirmationTarget {
  RunFinalization({
    required this.generation,
    required this.runStatus,
    required this.finalUiState,
    required this.runId,
    required this.dbSessionId,
    required this.preserveCheckpoint,
    required this.nativeStopRequired,
    required this.nativeStopConfirmed,
    required this.publishTerminalResult,
    required this.discardCheckpointOnSuccess,
    required this.isRollback,
    this.originalError,
    this.originalStack,
    this.stopOrigin,
  });

  // Immutable intent (first-claim wins).
  /// Unique terminal id for this run's finalization.
  final int generation;

  /// Durable `sequence_runs.status` to persist (`completed` / `failed` /
  /// `stopped` / `paused-stopped`).
  final String runStatus;

  /// The settled UI state to publish on full success (`completed` / `failed` /
  /// `idle`).
  final SequenceExecutionState finalUiState;

  /// Snapshot of the finished run's ids, captured before cleanup clears them.
  final int? runId;
  final int? dbSessionId;

  /// Whether the operator asked to keep the checkpoint (a UI Stop).
  final bool preserveCheckpoint;

  /// WHO asked for the stop — `null`/`'operator'` for a human,
  /// `'scheduler'` for the autopilot, `'rollback'` for a failed-launch
  /// rollback. Threaded to the native stop so the executor records a
  /// non-operator stop as a system event instead of operator evidence (an
  /// unattended stop must never render as "Stopped by request"). Mutable
  /// for exactly one transition: a RETRY by a human upgrades a system
  /// origin to the operator's — that press is real and must be recorded.
  String? stopOrigin;

  /// Whether a `sequencerStop()` must be issued/confirmed before cleanup. False
  /// for a natural terminal (the hardware already terminated authoritatively)
  /// and for a pre-native-launch rollback; true for an explicit stop and a
  /// partial-launch rollback.
  final bool nativeStopRequired;

  /// Whether to publish a `SequenceTerminalRunResult` on success. True for
  /// natural terminals and explicit stops (both open the Session Report); false
  /// for a start/resume rollback (a rejected launch opens no report).
  final bool publishTerminalResult;

  /// Whether to discard the on-disk checkpoint on a clean success (a non-
  /// preserving explicit stop). Natural terminals and rollbacks leave the
  /// checkpoint untouched.
  final bool discardCheckpointOnSuccess;

  /// Whether this finalization is a failed-start rollback — controls the
  /// "retain identity on persistence failure, rethrow the original launch
  /// error" semantics.
  final bool isRollback;

  /// For a rollback, the original launch error/stack to preserve for the caller
  /// even when cleanup itself also fails.
  final Object? originalError;
  final StackTrace? originalStack;

  // Mutable progress (retry resumes here).
  /// True once the native executor is confirmed stopped (or was never running).
  @override
  bool nativeStopConfirmed;

  /// Completed only by an authoritative native terminal event. The stop API
  /// acknowledges the command path, but capture resources must remain owned
  /// until native reports that the exposure abort has actually finished.
  Completer<void>? nativeStopConfirmation;

  /// True once per-run timers / watchdogs / settings watchers / native
  /// subscription / live-stacking have been released (once).
  bool resourcesReleased = false;
}
