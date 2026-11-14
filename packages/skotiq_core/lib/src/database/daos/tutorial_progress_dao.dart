import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/tutorial_progress.dart';

part 'tutorial_progress_dao.g.dart';

/// Data access object for tutorial progress persistence.
/// Allows saving and restoring tutorial progress across app sessions.
@DriftAccessor(tables: [TutorialProgress])
class TutorialProgressDao extends DatabaseAccessor<SkotiqDatabase>
    with _$TutorialProgressDaoMixin {
  TutorialProgressDao(super.db);

  /// Get progress for a specific tutorial category.
  /// Returns null if no progress has been saved for this category.
  Future<TutorialProgressEntry?> getProgress(String category) {
    return (select(
      tutorialProgress,
    )..where((t) => t.category.equals(category))).getSingleOrNull();
  }

  /// Save progress for a tutorial category.
  /// Creates a new entry if none exists, or updates the existing one.
  Future<void> saveProgress(String category, int stepIndex) async {
    final existing = await getProgress(category);

    if (existing != null) {
      await (update(tutorialProgress)
            ..where((t) => t.category.equals(category)))
          .write(TutorialProgressCompanion(lastStepIndex: Value(stepIndex)));
    } else {
      await into(tutorialProgress).insert(
        TutorialProgressCompanion.insert(
          category: category,
          lastStepIndex: Value(stepIndex),
          startedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Mark a tutorial category as completed.
  /// Sets the completed flag and records the completion timestamp.
  Future<void> markCompleted(String category) async {
    final existing = await getProgress(category);

    if (existing != null) {
      await (update(
        tutorialProgress,
      )..where((t) => t.category.equals(category))).write(
        TutorialProgressCompanion(
          completed: const Value(true),
          completedAt: Value(DateTime.now()),
          dismissed: const Value(false),
        ),
      );
    } else {
      // Create entry if it doesn't exist (edge case: completing without starting)
      await into(tutorialProgress).insert(
        TutorialProgressCompanion.insert(
          category: category,
          completed: const Value(true),
          startedAt: DateTime.now(),
          completedAt: Value(DateTime.now()),
        ),
      );
    }
  }

  /// Mark a tutorial category as dismissed.
  /// The user explicitly chose to skip without completing.
  Future<void> markDismissed(String category) async {
    final existing = await getProgress(category);

    if (existing != null) {
      await (update(tutorialProgress)
            ..where((t) => t.category.equals(category)))
          .write(const TutorialProgressCompanion(dismissed: Value(true)));
    } else {
      await into(tutorialProgress).insert(
        TutorialProgressCompanion.insert(
          category: category,
          startedAt: DateTime.now(),
          dismissed: const Value(true),
        ),
      );
    }
  }

  /// Replace any saved state for [category] with a fresh step-zero run.
  ///
  /// A delete followed by a later save leaves a failure window where a
  /// completed tutorial has already lost its history but no new run exists.
  /// Keeping both writes in one transaction lets replay controls report a
  /// failure without partially resetting the persisted state.
  Future<void> restartProgress(String category) {
    return transaction(() async {
      await (delete(
        tutorialProgress,
      )..where((t) => t.category.equals(category))).go();
      await into(tutorialProgress).insert(
        TutorialProgressCompanion.insert(
          category: category,
          lastStepIndex: const Value(0),
          startedAt: DateTime.now(),
        ),
      );
    });
  }

  /// Get all tutorial progress entries.
  /// Useful for displaying an overview of tutorial completion status.
  Future<List<TutorialProgressEntry>> getAllProgress() {
    return select(tutorialProgress).get();
  }

  /// Reset all tutorial progress.
  /// Useful for a "reset all tutorials" settings option.
  Future<void> resetAllProgress() async {
    await delete(tutorialProgress).go();
  }

  /// Mark a screen's contextual tour prompt as dismissed.
  /// Uses the category field to store the screen ID for prompt tracking.
  Future<void> dismissPromptForScreen(String screenId) async {
    final existing = await getProgress(screenId);

    if (existing != null) {
      await (update(tutorialProgress)
            ..where((t) => t.category.equals(screenId)))
          .write(const TutorialProgressCompanion(dismissed: Value(true)));
    } else {
      await into(tutorialProgress).insert(
        TutorialProgressCompanion.insert(
          category: screenId,
          startedAt: DateTime.now(),
          dismissed: const Value(true),
        ),
      );
    }
  }

  /// Watch dismissed prompt screen IDs for reactive updates.
  Stream<Set<String>> watchDismissedPromptScreenIds() {
    return (select(tutorialProgress)..where((t) => t.dismissed.equals(true)))
        .watch()
        .map((entries) => entries.map((e) => e.category).toSet());
  }
}
