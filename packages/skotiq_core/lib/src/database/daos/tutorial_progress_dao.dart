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
      // Update existing entry
      await (update(tutorialProgress)
            ..where((t) => t.category.equals(category)))
          .write(TutorialProgressCompanion(lastStepIndex: Value(stepIndex)));
    } else {
      // Create new entry
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
      // Create entry if it doesn't exist
      await into(tutorialProgress).insert(
        TutorialProgressCompanion.insert(
          category: category,
          startedAt: DateTime.now(),
          dismissed: const Value(true),
        ),
      );
    }
  }

  /// Reset progress for a tutorial category.
  /// Deletes the progress entry so the tutorial can be restarted fresh.
  Future<void> resetProgress(String category) async {
    await (delete(
      tutorialProgress,
    )..where((t) => t.category.equals(category))).go();
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

  /// Watch all tutorial progress entries for reactive updates.
  Stream<List<TutorialProgressEntry>> watchAllProgress() {
    return select(tutorialProgress).watch();
  }

  /// Check if a tutorial category has been completed.
  Future<bool> isCategoryCompleted(String category) async {
    final progress = await getProgress(category);
    return progress?.completed ?? false;
  }

  /// Check if a tutorial category has been dismissed.
  Future<bool> isCategoryDismissed(String category) async {
    final progress = await getProgress(category);
    return progress?.dismissed ?? false;
  }

  /// Get all completed tutorial categories.
  Future<List<String>> getCompletedCategories() async {
    final entries = await (select(
      tutorialProgress,
    )..where((t) => t.completed.equals(true))).get();
    return entries.map((e) => e.category).toList();
  }

  /// Reset all tutorial progress.
  /// Useful for a "reset all tutorials" settings option.
  Future<void> resetAllProgress() async {
    await delete(tutorialProgress).go();
  }

  /// Get all dismissed screen IDs for contextual tour prompts.
  /// Returns a set of screen IDs that have been dismissed.
  Future<Set<String>> getDismissedPromptScreenIds() async {
    final entries = await (select(
      tutorialProgress,
    )..where((t) => t.dismissed.equals(true))).get();
    return entries.map((e) => e.category).toSet();
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
      // Create entry for the screen prompt dismissal
      await into(tutorialProgress).insert(
        TutorialProgressCompanion.insert(
          category: screenId,
          startedAt: DateTime.now(),
          dismissed: const Value(true),
        ),
      );
    }
  }

  /// Check if a screen's contextual tour prompt has been dismissed.
  Future<bool> isPromptDismissedForScreen(String screenId) async {
    final progress = await getProgress(screenId);
    return progress?.dismissed ?? false;
  }

  /// Watch dismissed prompt screen IDs for reactive updates.
  Stream<Set<String>> watchDismissedPromptScreenIds() {
    return (select(tutorialProgress)..where((t) => t.dismissed.equals(true)))
        .watch()
        .map((entries) => entries.map((e) => e.category).toSet());
  }
}
