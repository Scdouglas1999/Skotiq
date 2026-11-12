import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../models/backend/sequencer_status.dart';
import '../models/sequence/sequence_models.dart';
import '../database/daos/sequence_runs_dao.dart';
import '../database/daos/sequence_versions_dao.dart';
import '../database/daos/session_diagnostics_dao.dart';
import 'package:skotiq_astro/format.dart';
import 'backend_provider.dart';
import '../backend/remote_host.dart';
import '../backend/roles/host_data/host_records.dart';
import 'database_provider.dart';
import 'sequence/run_record.dart';
import 'sequence/run_stop_classification.dart';

/// Statistics collected during a sequence execution run.
class SequenceRunStats {
  final DateTime startTime;
  DateTime? endTime;

  /// Every exposure this run took off the sensor and recorded — accepted and
  /// rejected alike. A rejected sub was still captured, still cost the night
  /// its minutes and is still sitting on disk, so it counts here.
  int framesCaptured;

  /// The subset of [framesCaptured] the grader rejected. Always
  /// `<= framesCaptured`; `framesCaptured - framesRejected` is what the night
  /// can actually be stacked from.
  int framesRejected;

  /// ACCEPTED exposure time only — see [recordFrame].
  double integrationSecs;
  int triggerFires;
  int autofocusRuns;
  int meridianFlips;
  int ditherCount;

  /// The directory the grader has been moving rejected frames into, or null
  /// until one is rejected. The first thing an operator opens after a reject
  /// storm, so the run record carries it rather than making him find it.
  String? rejectFolder;

  /// The one sentence that says WHY this run ended badly, or null for a run
  /// that has not failed.
  ///
  /// Distinct from [errorMessages], which is the whole cascade in the order it
  /// happened. This is the link the cause-selection rule picked out of it: the
  /// first real fault, never a teardown step that was cancelled *because* the
  /// run was already failing. See `executor::failure_cause` on the native side,
  /// which chooses it, and [recordTerminalError], which stores it.
  String? terminalCause;

  /// Per-target, per-filter breakdown: targetName -> filterName -> stats
  final Map<String, Map<String, FilterStats>> targetBreakdown;

  final List<String> errorMessages;

  /// Non-fatal warnings accumulated during the run. Used by the executor to
  /// surface conditions like "filter wheel not connected, using filter name
  /// as a literal" — situations that don't stop the sequence but the user
  /// should see in the post-session report.
  final List<String> warningMessages;

  SequenceRunStats()
    : startTime = DateTime.now(),
      framesCaptured = 0,
      framesRejected = 0,
      integrationSecs = 0,
      triggerFires = 0,
      autofocusRuns = 0,
      meridianFlips = 0,
      ditherCount = 0,
      rejectFolder = null,
      terminalCause = null,
      targetBreakdown = {},
      errorMessages = [],
      warningMessages = [];

  SequenceRunStats._({
    required this.startTime,
    required this.endTime,
    required this.framesCaptured,
    required this.framesRejected,
    required this.integrationSecs,
    required this.triggerFires,
    required this.autofocusRuns,
    required this.meridianFlips,
    required this.ditherCount,
    required this.rejectFolder,
    required this.terminalCause,
    required this.warningMessages,
    required this.errorMessages,
  }) : targetBreakdown = {};

  /// Reconstruct a live-stats snapshot from the master's run-vitals wire model.
  ///
  /// Used by the remote sync handler so a slave can mirror the master's Session
  /// Vitals tile. The per-target breakdown is not carried on the vitals wire
  /// (the Vitals tile reads only the aggregate counters plus the warning and
  /// error lists), so it is reconstructed empty.
  factory SequenceRunStats.fromRemoteVitals(SequencerRunVitals vitals) {
    return SequenceRunStats._(
      startTime: vitals.startTime,
      endTime: vitals.endTime,
      framesCaptured: vitals.framesCaptured,
      framesRejected: vitals.framesRejected,
      integrationSecs: vitals.integrationSecs,
      triggerFires: vitals.triggerFires,
      autofocusRuns: vitals.autofocusRuns,
      meridianFlips: vitals.meridianFlips,
      ditherCount: vitals.ditherCount,
      rejectFolder: vitals.rejectFolder,
      terminalCause: vitals.terminalCause,
      warningMessages: List<String>.from(vitals.warningMessages),
      errorMessages: List<String>.from(vitals.errorMessages),
    );
  }

  /// A fresh deep copy carrying the same values but a NEW identity.
  ///
  /// [liveSequenceStatsProvider] is a `StateProvider`, whose `updateShouldNotify`
  /// is `!identical(previous, next)`. Mutating this instance in place and then
  /// re-storing the SAME object therefore notifies NO consumer — the live
  /// Session Vitals tile and run dashboard would silently stop updating. The
  /// executor stores `copy()` after each incremental mutation so the identity
  /// changes and watchers actually rebuild. Deep-copying the per-target /
  /// per-filter breakdown keeps the previous snapshot immutable (a consumer that
  /// retained it sees a consistent point-in-time value, not a shared mutable
  /// map). The frame cadence (seconds apart) makes the copy cost negligible.
  SequenceRunStats copy() {
    final c = SequenceRunStats._(
      startTime: startTime,
      endTime: endTime,
      framesCaptured: framesCaptured,
      framesRejected: framesRejected,
      integrationSecs: integrationSecs,
      triggerFires: triggerFires,
      autofocusRuns: autofocusRuns,
      meridianFlips: meridianFlips,
      ditherCount: ditherCount,
      rejectFolder: rejectFolder,
      terminalCause: terminalCause,
      warningMessages: List<String>.from(warningMessages),
      errorMessages: List<String>.from(errorMessages),
    );
    for (final targetEntry in targetBreakdown.entries) {
      final filters = <String, FilterStats>{};
      for (final filterEntry in targetEntry.value.entries) {
        final fs = FilterStats();
        fs.captured = filterEntry.value.captured;
        fs.rejected = filterEntry.value.rejected;
        fs.integrationSecs = filterEntry.value.integrationSecs;
        filters[filterEntry.key] = fs;
      }
      c.targetBreakdown[targetEntry.key] = filters;
    }
    return c;
  }

  double get wallClockSecs {
    final end = endTime ?? DateTime.now();
    return end.difference(startTime).inMilliseconds / 1000.0;
  }

  double get overheadSecs => wallClockSecs - integrationSecs;

  /// Record one completed exposure and the grader's verdict on it.
  ///
  /// [integrationSecs] counts only ACCEPTED exposure time. A rejected sub was
  /// still captured (so it advances [framesCaptured] and [framesRejected]) but
  /// it is not usable data, and the time it consumed is overhead — which is
  /// exactly how the native executor's integration budget treats it (see the
  /// `FrameRejected` contract in
  /// `native/skotiq_native/sequencer/src/node/progress.rs`: "the
  /// integration budget tracker listens for this and skips counting the
  /// exposure time"). Crediting it unconditionally made the run record
  /// contradict itself in one sentence — "2 of 3 rejected" printed beside
  /// "900 s integrated" on a night with 300 s of usable data — in the Session
  /// Report, the cockpit vitals and the morning recap alike.
  void recordFrame({
    required String target,
    required String filter,
    required double exposureSecs,
    required bool accepted,
  }) {
    framesCaptured++;
    if (!accepted) framesRejected++;
    if (accepted) integrationSecs += exposureSecs;

    targetBreakdown.putIfAbsent(target, () => {});
    final filterStats = targetBreakdown[target]!.putIfAbsent(
      filter,
      () => FilterStats(),
    );
    filterStats.captured++;
    if (!accepted) filterStats.rejected++;
    if (accepted) filterStats.integrationSecs += exposureSecs;
  }

  /// Move one frame already counted as accepted into the rejected count: the
  /// frame watch excluded it (off target, obstructed) after the grader passed
  /// it, so its time stops counting as integration. A no-op when [target] /
  /// [filter] holds no accepted frame to move.
  void reclassifyAsRejected({
    required String target,
    required String filter,
    required double exposureSecs,
  }) {
    final filterStats = targetBreakdown[target]?[filter];
    if (filterStats == null ||
        filterStats.captured - filterStats.rejected <= 0) {
      return;
    }
    filterStats.rejected++;
    filterStats.integrationSecs = math.max(
      0.0,
      filterStats.integrationSecs - exposureSecs,
    );
    framesRejected++;
    integrationSecs = math.max(0.0, integrationSecs - exposureSecs);
  }

  void recordTriggerFire() => triggerFires++;
  void recordAutofocus() => autofocusRuns++;
  void recordMeridianFlip() => meridianFlips++;
  void recordDither() => ditherCount++;
  void recordError(String message) => errorMessages.add(message);

  /// Record the directory the grader is moving rejected frames into.
  ///
  /// Last writer wins: a run that changes save path mid-night should point the
  /// operator at the folder its most recent reject actually landed in.
  void recordRejectFolder(String folder) => rejectFolder = folder;

  /// Record the run's TERMINAL error (the reason on `SequenceFailed`) as this
  /// run's [terminalCause].
  ///
  /// The native executor picks that reason out of the failures the run reported
  /// (`executor::failure_cause::run_failure_cause`) and it is, by construction,
  /// a RESTATEMENT of one of them — byte-for-byte a string the bridge already
  /// delivered as a mid-run `Error` event and which [recordError] already
  /// stored. So it is not appended when [errorMessages] already holds it
  /// anywhere: one failing Dither node used to end the night with the same
  /// sentence twice, printed twice in the Session Report and stacked as two
  /// identical critical banners.
  ///
  /// Comparing against the whole list, not just the last entry, is what the
  /// cause-selection rule requires. The chosen cause is the FIRST fault, so by
  /// the time the run dies there are usually later entries behind it — the
  /// cancelled teardown steps among them — and a last-entry-only comparison
  /// would append the cause a second time. Faults recorded through
  /// [recordError] are untouched by this, so a node that really fails twice
  /// still records two errors.
  ///
  /// The two fixed placeholders a failure carries when nobody found a reason
  /// (the native executor's "Sequence failed", and the "Unknown error" the
  /// event handler substitutes for a missing field) are not causes, so they
  /// leave [terminalCause] unset rather than being headlined as one.
  void recordTerminalError(String message) {
    if (!isUnexplainedRunFailure(message)) {
      terminalCause = message;
    }
    if (errorMessages.contains(message)) {
      return;
    }
    errorMessages.add(message);
  }

  /// Record a non-fatal warning surfaced during execution. Idempotent on
  /// exact-duplicate consecutive messages so a per-frame warning (e.g.
  /// "filter wheel not connected") doesn't bloat the stats blob.
  void recordWarning(String message) {
    if (warningMessages.isNotEmpty && warningMessages.last == message) {
      return;
    }
    warningMessages.add(message);
  }

  /// Serialize to JSON for database storage.
  String toJson() {
    final breakdown = <String, dynamic>{};
    for (final targetEntry in targetBreakdown.entries) {
      final filters = <String, dynamic>{};
      for (final filterEntry in targetEntry.value.entries) {
        filters[filterEntry.key] = {
          'captured': filterEntry.value.captured,
          'rejected': filterEntry.value.rejected,
          'integrationSecs': filterEntry.value.integrationSecs,
        };
      }
      breakdown[targetEntry.key] = filters;
    }

    return jsonEncode({
      'wallClockSecs': wallClockSecs,
      'integrationSecs': integrationSecs,
      'overheadSecs': overheadSecs,
      'framesCaptured': framesCaptured,
      'framesRejected': framesRejected,
      'targetBreakdown': breakdown,
      'triggerFires': triggerFires,
      'autofocusRuns': autofocusRuns,
      'meridianFlips': meridianFlips,
      'ditherCount': ditherCount,
      if (rejectFolder != null) 'rejectFolder': rejectFolder,
      if (terminalCause != null) 'terminalCause': terminalCause,
      'errorMessages': errorMessages,
      'warningMessages': warningMessages,
    });
  }

  /// Deserialize from JSON stored in the database.
  factory SequenceRunStats.fromJson(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    final stats = SequenceRunStats();
    stats.framesCaptured = (map['framesCaptured'] as num?)?.toInt() ?? 0;
    stats.framesRejected = (map['framesRejected'] as num?)?.toInt() ?? 0;
    stats.integrationSecs = (map['integrationSecs'] as num?)?.toDouble() ?? 0.0;
    stats.triggerFires = (map['triggerFires'] as num?)?.toInt() ?? 0;
    stats.autofocusRuns = (map['autofocusRuns'] as num?)?.toInt() ?? 0;
    stats.meridianFlips = (map['meridianFlips'] as num?)?.toInt() ?? 0;
    stats.ditherCount = (map['ditherCount'] as num?)?.toInt() ?? 0;
    stats.rejectFolder = map['rejectFolder'] as String?;
    stats.terminalCause = map['terminalCause'] as String?;

    final errors = map['errorMessages'] as List<dynamic>?;
    if (errors != null) {
      stats.errorMessages.addAll(errors.cast<String>());
    }

    final warnings = map['warningMessages'] as List<dynamic>?;
    if (warnings != null) {
      stats.warningMessages.addAll(warnings.cast<String>());
    }

    final breakdown = map['targetBreakdown'] as Map<String, dynamic>?;
    if (breakdown != null) {
      for (final targetEntry in breakdown.entries) {
        final filters = targetEntry.value as Map<String, dynamic>;
        stats.targetBreakdown[targetEntry.key] = {};
        for (final filterEntry in filters.entries) {
          final fMap = filterEntry.value as Map<String, dynamic>;
          final fs = FilterStats();
          fs.captured = (fMap['captured'] as num?)?.toInt() ?? 0;
          fs.rejected = (fMap['rejected'] as num?)?.toInt() ?? 0;
          fs.integrationSecs =
              (fMap['integrationSecs'] as num?)?.toDouble() ?? 0.0;
          stats.targetBreakdown[targetEntry.key]![filterEntry.key] = fs;
        }
      }
    }

    return stats;
  }
}

class FilterStats {
  int captured = 0;
  int rejected = 0;
  double integrationSecs = 0.0;
}

/// Parsed stats from a SequenceRun for easy UI consumption.
class ParsedRunStats {
  final double wallClockSecs;
  final double integrationSecs;
  final double overheadSecs;
  final int framesCaptured;
  final int framesRejected;
  final int triggerFires;
  final int autofocusRuns;
  final int meridianFlips;
  final int ditherCount;

  /// The directory this run's rejected frames were moved into, or null when
  /// nothing was rejected. See [SequenceRunStats.rejectFolder].
  final String? rejectFolder;

  /// Why this run ended badly, or null for one that did not — the first real
  /// fault, never a cancelled teardown step. See
  /// [SequenceRunStats.terminalCause].
  final String? terminalCause;

  final Map<String, Map<String, Map<String, dynamic>>> targetBreakdown;
  final List<String> errorMessages;
  final List<String> warningMessages;

  ParsedRunStats({
    required this.wallClockSecs,
    required this.integrationSecs,
    required this.overheadSecs,
    required this.framesCaptured,
    required this.framesRejected,
    required this.triggerFires,
    required this.autofocusRuns,
    required this.meridianFlips,
    required this.ditherCount,
    required this.targetBreakdown,
    required this.errorMessages,
    this.rejectFolder,
    this.terminalCause,
    this.warningMessages = const [],
  });

  factory ParsedRunStats.fromJson(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;

    final breakdown = <String, Map<String, Map<String, dynamic>>>{};
    final rawBreakdown = map['targetBreakdown'] as Map<String, dynamic>?;
    if (rawBreakdown != null) {
      for (final te in rawBreakdown.entries) {
        breakdown[te.key] = {};
        final filters = te.value as Map<String, dynamic>;
        for (final fe in filters.entries) {
          breakdown[te.key]![fe.key] = fe.value as Map<String, dynamic>;
        }
      }
    }

    return ParsedRunStats(
      wallClockSecs: (map['wallClockSecs'] as num?)?.toDouble() ?? 0,
      integrationSecs: (map['integrationSecs'] as num?)?.toDouble() ?? 0,
      overheadSecs: (map['overheadSecs'] as num?)?.toDouble() ?? 0,
      framesCaptured: (map['framesCaptured'] as num?)?.toInt() ?? 0,
      framesRejected: (map['framesRejected'] as num?)?.toInt() ?? 0,
      triggerFires: (map['triggerFires'] as num?)?.toInt() ?? 0,
      autofocusRuns: (map['autofocusRuns'] as num?)?.toInt() ?? 0,
      meridianFlips: (map['meridianFlips'] as num?)?.toInt() ?? 0,
      ditherCount: (map['ditherCount'] as num?)?.toInt() ?? 0,
      rejectFolder: map['rejectFolder'] as String?,
      terminalCause: map['terminalCause'] as String?,
      targetBreakdown: breakdown,
      errorMessages:
          (map['errorMessages'] as List<dynamic>?)?.cast<String>() ?? [],
      warningMessages:
          (map['warningMessages'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  /// Delegates to the shared formatter so the run cards, the history tab and
  /// the Continue Session dialog all describe one run identically.
  String formatDuration(double secs) => DurationFormat.seconds(secs);
}

final sequenceRunsDaoProvider = Provider<SequenceRunsDao>((ref) {
  final db = ref.watch(databaseProvider);
  return db.sequenceRunsDao;
});

final sequenceVersionsDaoProvider = Provider<SequenceVersionsDao>((ref) {
  final db = ref.watch(databaseProvider);
  return db.sequenceVersionsDao;
});

final sessionDiagnosticsDaoProvider = Provider<SessionDiagnosticsDao>((ref) {
  final db = ref.watch(databaseProvider);
  return db.sessionDiagnosticsDao;
});

/// Live stats tracker for the currently running sequence.
/// Null when no sequence is running.
final liveSequenceStatsProvider = runRecordProvider.select((run) => run.stats);

/// The database row ID of the current run (for updating on completion).
final currentRunIdProvider = runRecordProvider.select((run) => run.runId);

/// Immutable, one-shot result of a fully-finalized sequence run.
///
/// The executor publishes exactly one of these to
/// [sequenceTerminalRunResultProvider] AFTER durable finalization (finishRun +
/// endSession) succeeds — i.e. after [currentRunIdProvider] and the durable
/// session have already been cleared. It carries a SNAPSHOT of the ids the
/// finished run owned so the auto-opening Session Report and its run-scoped
/// Journal resolve against the completed run instead of racing the live
/// providers that finalization has (correctly) just cleared.
///
/// [generation] is unique and monotonic per terminal event, giving consumers
/// event-consumption semantics: a screen reacts to the transition into a new
/// result, so a fresh mount (which only observes subsequent changes) never
/// reopens an already-consumed report.
class SequenceTerminalRunResult {
  const SequenceTerminalRunResult({
    required this.generation,
    required this.outcome,
    required this.runStatus,
    required this.runId,
    required this.dbSessionId,
    this.isCalibration = false,
  });

  final bool isCalibration;

  /// Unique, monotonically increasing id for this terminal event.
  final int generation;

  /// The settled UI state the run ended in: `completed`, `failed`, or `idle`
  /// (a stop / abort).
  final SequenceExecutionState outcome;

  /// The durable run-row status recorded for this run (`completed`, `failed`,
  /// `stopped`, `paused-stopped`).
  final String runStatus;

  /// The finished run's `sequence_runs.id`, captured before finalization
  /// cleared [currentRunIdProvider]. Null when the run never got a row.
  final int? runId;

  /// The finished run's `sessions.id`, captured before finalization ended the
  /// durable session. Null when the run never opened a session.
  final int? dbSessionId;
}

/// The result of the last run this app finalized, or null before any run has
/// terminated this session and on a linked client. Published exactly once per
/// terminal run by the executor; a change opens the Session Report and starts
/// end-of-night work, which a client joining after the host's run must not do,
/// so the host's result is not shown here (see [shownTerminalRunResultProvider]).
final sequenceTerminalRunResultProvider = runRecordProvider.select(
  (run) => run.terminalFromHost ? null : run.terminal,
);

/// The last terminal run result the screens describe: this app's own run, or
/// on a linked client the host's.
final shownTerminalRunResultProvider = runRecordProvider.select(
  (run) => run.terminal,
);

/// The last imaging run, retained when automatic calibration replaces the live
/// run and session. Updated by the executor before publishing a terminal event.
class CompletedImagingRun {
  const CompletedImagingRun(this.result, this.stats);
  final SequenceTerminalRunResult result;
  final SequenceRunStats? stats;
}

final completedImagingRunProvider = runRecordProvider.select(
  (run) => run.completedImagingRun,
);

/// The recorded sequence runs of whichever machine is the imaging host.
final runHistoryProvider = Provider<RunHistory>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.records ??
      ref.watch(sequenceRunsDaoProvider),
);

/// Every sequence run on the imaging host, newest first. The dashboard recap,
/// the Morning Report and the History tab read this.
final sequenceRunsProvider = StreamProvider<List<SequenceRun>>((ref) {
  return ref.watch(runHistoryProvider).watchAllRuns();
});

/// Best-effort legacy join for a run that has no captured frame provenance.
///
/// The executor opens the session immediately before it creates the run row,
/// so a five-minute bound is deliberately generous while still refusing to
/// link an unrelated historical session. Overlapping time windows and known
/// sequence/name mismatches are rejected before the nearest start wins.
int? resolveSessionIdForSequenceRun(
  SequenceRun run,
  Iterable<ImagingSession> sessions,
) {
  const maxStartDelta = Duration(minutes: 5);
  ImagingSession? best;
  Duration? bestDelta;

  for (final session in sessions) {
    if (run.sequenceId != null &&
        session.sequenceId != null &&
        run.sequenceId != session.sequenceId) {
      continue;
    }
    if (session.name != null &&
        session.name!.isNotEmpty &&
        run.sequenceName.isNotEmpty &&
        session.name != run.sequenceName) {
      continue;
    }

    final sessionEnd = session.endTime;
    final runEnd = run.endedAt;
    if (sessionEnd != null && sessionEnd.isBefore(run.startedAt)) continue;
    if (runEnd != null && session.startTime.isAfter(runEnd)) continue;

    final rawDelta = run.startedAt.difference(session.startTime);
    final delta = rawDelta.isNegative ? -rawDelta : rawDelta;
    if (delta > maxStartDelta) continue;
    if (bestDelta == null || delta < bestDelta) {
      best = session;
      bestDelta = delta;
    }
  }

  return best?.id;
}

final sequenceRunsForSequenceProvider =
    StreamProvider.family<List<SequenceRun>, int>((ref, sequenceId) {
      return ref.watch(runHistoryProvider).watchRunsForSequence(sequenceId);
    });
