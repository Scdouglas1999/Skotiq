import 'package:drift/drift.dart';

/// Stores tutorial progress for each category so users can resume tours
/// and track which tutorials have been completed.
@DataClassName('TutorialProgressEntry')
@TableIndex(name: 'idx_tutorial_progress_category', columns: {#category})
class TutorialProgress extends Table {
  /// Auto-incrementing primary key
  IntColumn get id => integer().autoIncrement()();

  /// Tutorial category name (TutorialCategory.name, e.g., 'firstLight')
  /// Unique constraint ensures only one progress entry per category
  TextColumn get category => text().unique()();

  /// Last step index the user was on (0-indexed)
  IntColumn get lastStepIndex => integer().withDefault(const Constant(0))();

  /// Whether this tutorial has been fully completed
  BoolColumn get completed => boolean().withDefault(const Constant(false))();

  /// When the user first started this tutorial
  DateTimeColumn get startedAt => dateTime()();

  /// When the tutorial was completed (null if not completed)
  DateTimeColumn get completedAt => dateTime().nullable()();

  /// Whether the user explicitly dismissed this tutorial without completing
  BoolColumn get dismissed => boolean().withDefault(const Constant(false))();
}
