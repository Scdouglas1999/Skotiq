import 'package:drift/drift.dart';

import 'sequences.dart';

/// Stores execution history for sequences.
/// Each row represents a single run of a sequence (completed, failed, or aborted).
@DataClassName('SequenceRun')
@TableIndex(name: 'idx_sequence_runs_sequence', columns: {#sequenceId})
@TableIndex(name: 'idx_sequence_runs_started', columns: {#startedAt})
@TableIndex(name: 'idx_sequence_runs_status', columns: {#status})
class SequenceRuns extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// FK to sequences table (nullable because the sequence may be deleted)
  IntColumn get sequenceId => integer().nullable().references(
    Sequences,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// Snapshot of the sequence name at the time of execution
  TextColumn get sequenceName => text()();

  /// When the run started
  DateTimeColumn get startedAt => dateTime()();

  /// When the run ended (null if still running)
  DateTimeColumn get endedAt => dateTime().nullable()();

  /// Final status: 'completed', 'failed', 'aborted', 'stopped',
  /// 'paused-stopped', 'interrupted', or 'running' while in flight.
  ///
  /// 'interrupted' is assigned at startup to any row still marked 'running'
  /// when the database opens: the executor that owned it lives in memory, so
  /// such a row can only be residue from a process that died mid-run.
  TextColumn get status => text().withDefault(const Constant('running'))();

  /// JSON blob with detailed statistics
  /// Structure: {
  ///   "wallClockSecs": double,
  ///   "integrationSecs": double,
  ///   "overheadSecs": double,
  ///   "framesCaptured": int,
  ///   "framesRejected": int,
  ///   "targetBreakdown": { "targetName": { "filter": { "captured": int, "rejected": int, "integrationSecs": double } } },
  ///   "triggerFires": int,
  ///   "autofocusRuns": int,
  ///   "meridianFlips": int,
  ///   "ditherCount": int,
  ///   "errorMessages": [ "..." ]
  /// }
  TextColumn get statsJson => text().withDefault(const Constant('{}'))();

  /// The exact sequence JSON used for this run, captured at run start.
  ///
  /// Persisting the real snapshot — rather than re-reading the live, possibly
  /// since-edited sequence — lets the run-history "diff vs previous run" view
  /// compare what actually executed on each night. Nullable because legacy
  /// rows (and runs started before this column existed) have no snapshot, and
  /// resumed-from-checkpoint runs may not have a Dart-side sequence to capture.
  TextColumn get sequenceSnapshotJson => text().nullable()();
}
