import 'package:drift/drift.dart';

import 'sequences.dart';

/// Append-only version history for a sequence.
///
/// Each row is a point-in-time snapshot of the full sequence JSON, captured
/// on a meaningful save so the user can review and restore an earlier shape
/// of the sequence. The history is capped per sequence (see
/// `SequenceVersionsDao.appendVersion`) so a long-lived sequence does not
/// accumulate unbounded snapshots.
@DataClassName('SequenceVersion')
@TableIndex(name: 'idx_sequence_versions_sequence', columns: {#sequenceId})
@TableIndex(name: 'idx_sequence_versions_created', columns: {#createdAt})
class SequenceVersions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// FK to the owning sequence. Cascade-deletes with the sequence so the
  /// history never outlives the thing it describes.
  IntColumn get sequenceId =>
      integer().references(Sequences, #id, onDelete: KeyAction.cascade)();

  /// The full sequence JSON captured at this version.
  TextColumn get snapshotJson => text()();

  /// Optional human label (e.g. "before adding Hα", "auto-save"). Null when
  /// the snapshot was captured automatically without a caller-supplied label.
  TextColumn get label => text().nullable()();

  /// When this version was captured.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
