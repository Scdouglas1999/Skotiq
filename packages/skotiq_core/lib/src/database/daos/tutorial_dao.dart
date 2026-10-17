import '../../models/tutorial/tutorial_models.dart';
import 'tutorial_progress_dao.dart';

/// First-night wizard specific helpers over the broader
/// [TutorialProgressDao]. The base DAO operates on raw category names; this
/// class adds enum-typed helpers and answers the one question the bootstrap
/// flow cares about: "should we auto-open the wizard on this launch?".
///
/// Why this exists separately: the wizard has launch-time semantics nothing
/// else has — it's the only tutorial that auto-opens, and the only one that
/// distinguishes "never started" from "explicitly dismissed forever". Those
/// rules belong next to the wizard, not in the broad DAO that every screen
/// tour and contextual prompt also calls.
class TutorialDao {
  /// Stable identity of the first-night wizard category as stored in the
  /// `tutorial_progress` table. Derived from the enum so a rename here and
  /// a rename of the enum stay in lock-step.
  static final String firstNightCategoryName = TutorialCategory.firstNight.name;

  final TutorialProgressDao _progressDao;

  TutorialDao(this._progressDao);

  /// Should the first-night wizard auto-open on app launch?
  ///
  /// Returns true only when there is no row in `tutorial_progress` for the
  /// firstNight category at all — i.e. the user has never seen the wizard.
  /// If the user explicitly dismissed it ("don't show this again") or
  /// completed it, this returns false. If the user started it and closed
  /// it mid-way, this also returns false (resume is opt-in from the
  /// Settings → Help screen; we don't ambush them every launch).
  Future<bool> shouldShowFirstNightOnLaunch() async {
    final progress = await _progressDao.getProgress(firstNightCategoryName);
    return progress == null;
  }

  /// Last step index the user was on, or 0 if they have never started.
  /// Used by the wizard's resume button to jump back to where the user
  /// stopped, rather than restarting from the welcome step.
  Future<int> getLastStepIndex() async {
    final progress = await _progressDao.getProgress(firstNightCategoryName);
    return progress?.lastStepIndex ?? 0;
  }

  /// True if the user reached the final "Launch the sequence" step and
  /// finished the wizard. Used by the Settings → Help row to show a
  /// "Completed" badge instead of "Resume".
  Future<bool> isFirstNightCompleted() async {
    return _progressDao.isCategoryCompleted(firstNightCategoryName);
  }

  /// True if the user explicitly dismissed the wizard. Lets the UI render
  /// a "Replay" affordance distinct from "Resume".
  Future<bool> isFirstNightDismissed() async {
    return _progressDao.isCategoryDismissed(firstNightCategoryName);
  }

  /// Persist a "currently on step N" pointer so the wizard can resume from
  /// the same step after a relaunch. Called on every Next/Back click.
  Future<void> saveFirstNightProgress(int stepIndex) {
    return _progressDao.saveProgress(firstNightCategoryName, stepIndex);
  }

  /// Mark the wizard finished. Called from the final step's "Done" button.
  /// After this, [shouldShowFirstNightOnLaunch] returns false and the
  /// Settings → Help row shows "Completed".
  Future<void> markFirstNightCompleted() {
    return _progressDao.markCompleted(firstNightCategoryName);
  }

  /// Mark the wizard "Don't show again". The user explicitly clicked the
  /// "Skip forever" option; we record dismissal so [shouldShowFirstNightOnLaunch]
  /// returns false on subsequent launches. The user can still replay from
  /// Settings → Help.
  Future<void> dismissFirstNightForever() {
    return _progressDao.markDismissed(firstNightCategoryName);
  }

  /// Wipe the wizard's progress so it auto-opens again on next launch.
  /// Used by the Settings → Help "Restart" button when a user wants the
  /// guided experience back.
  Future<void> resetFirstNight() {
    return _progressDao.resetProgress(firstNightCategoryName);
  }
}
