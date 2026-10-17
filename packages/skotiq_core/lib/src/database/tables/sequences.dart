import 'package:drift/drift.dart';

import 'targets.dart';

/// Sequences table
/// Stores sequence definitions for the sequencer
@DataClassName('Sequence')
@TableIndex(name: 'idx_sequences_name', columns: {#name})
@TableIndex(name: 'idx_sequences_template', columns: {#isTemplate})
@TableIndex(name: 'idx_sequences_updated', columns: {#updatedAt})
class Sequences extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable()();

  // The root node ID of the behavior tree (nullable for new sequences)
  TextColumn get rootNodeId => text().nullable()();

  // Estimated duration in minutes
  IntColumn get estimatedDurationMins =>
      integer().withDefault(const Constant(0))();

  // Timestamps
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // Template flag - templates are reusable sequence patterns
  BoolColumn get isTemplate => boolean().withDefault(const Constant(false))();

  /// Library tags as a JSON-encoded `List<String>` (e.g. `["narrowband",
  /// "winter"]`). Defaults to an empty-list literal so existing rows and new
  /// inserts that omit it read back as "no tags" rather than null. Stored as
  /// JSON in a single column rather than a join table because tags are a
  /// lightweight, display-only library filter — there is no relational query
  /// against individual tags.
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();

  /// Library favorite flag. Drives the "starred" filter/sort in the sequence
  /// library. Defaults to false.
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
}

/// Sequence nodes table
/// Stores individual nodes that make up a sequence
@DataClassName('SequenceNode')
@TableIndex(name: 'idx_nodes_sequence', columns: {#sequenceId})
@TableIndex(name: 'idx_nodes_parent', columns: {#parentNodeId})
@TableIndex(name: 'idx_nodes_target', columns: {#targetId})
@TableIndex(name: 'idx_nodes_type', columns: {#nodeType})
@TableIndex(name: 'idx_nodes_node_id', columns: {#nodeId})
class SequenceNodes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get nodeId => text()(); // UUID
  IntColumn get sequenceId =>
      integer().references(Sequences, #id, onDelete: KeyAction.cascade)();

  // Optional target reference for target groups
  IntColumn get targetId => integer().nullable().references(
    Targets,
    #id,
    onDelete: KeyAction.setNull,
  )();

  // Node type (coarse category): instruction, trigger, logic, target.
  // Written from SequenceNode.category (see sequence_repository
  // _getNodeCategory) so this stays the single source of truth.
  TextColumn get nodeType => text()();
  // Specific type: slew, expose, autofocus, loop, etc.
  TextColumn get specificType => text()();

  // Display name
  TextColumn get name => text()();

  // Node properties as JSON
  TextColumn get properties => text().withDefault(const Constant('{}'))();

  // Recovery configuration as JSON
  TextColumn get recoveryConfig => text().nullable()();

  // Parent-child relationships
  TextColumn get parentNodeId => text().nullable()();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();

  // Enabled state
  BoolColumn get isEnabled => boolean().withDefault(const Constant(true))();
}

/// Sequence checkpoints table
/// Stores runtime state for sequence recovery after crashes
/// Uses sequenceId as primary key for upsert operations (one checkpoint per sequence)
@DataClassName('SequenceCheckpoint')
@TableIndex(name: 'idx_checkpoints_checkpointed_at', columns: {#checkpointedAt})
class SequenceCheckpoints extends Table {
  IntColumn get sequenceId =>
      integer().references(Sequences, #id, onDelete: KeyAction.cascade)();

  // Current execution state
  TextColumn get currentNodeId => text()();
  TextColumn get stateJson => text()(); // Serialized runtime state

  // Progress tracking
  IntColumn get completedFrames => integer()();
  IntColumn get totalFrames => integer()();
  IntColumn get currentTargetIndex => integer()();

  // Timestamp
  DateTimeColumn get checkpointedAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {sequenceId};
}
