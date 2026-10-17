import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/tutorial_dao.dart';
import '../database/daos/tutorial_progress_dao.dart';
import '../database/daos/settings_dao.dart';
import '../models/tutorial/tutorial_models.dart';
import 'database_provider.dart';

/// Provider for tutorial progress DAO
final tutorialProgressDaoProvider = Provider<TutorialProgressDao>((ref) {
  return TutorialProgressDao(ref.watch(databaseProvider));
});

/// Provider for the first-night wizard DAO wrapper.
///
/// Built on top of [tutorialProgressDaoProvider] so it shares the same
/// underlying Drift database connection — no risk of the wizard reading
/// stale state because it has its own DAO instance.
final tutorialDaoProvider = Provider<TutorialDao>((ref) {
  return TutorialDao(ref.watch(tutorialProgressDaoProvider));
});

/// State of the first-night wizard UI.
///
/// `currentStepIndex` is 0-based into [FirstNightWizard.steps]. `isLoaded`
/// flips to true once the saved progress has been read from the database;
/// the wizard widget waits on this so a freshly-launched app doesn't flash
/// step 0 before jumping to the resumed step.
class FirstNightWizardState {
  final int currentStepIndex;
  final bool isLoaded;

  const FirstNightWizardState({
    this.currentStepIndex = 0,
    this.isLoaded = false,
  });

  FirstNightWizardState copyWith({int? currentStepIndex, bool? isLoaded}) {
    return FirstNightWizardState(
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }
}

/// First-night wizard state notifier.
///
/// Lifecycle: created when the wizard opens, loads saved progress from the
/// DAO on construction, persists progress on every advance/back/dismiss.
/// The notifier intentionally does NOT auto-launch — the bootstrap flow
/// in `app.dart` decides when to open the wizard, this notifier just runs
/// it. Why: auto-launching from inside a provider creates surprise
/// rebuilds in tests and headless mode.
class FirstNightWizardNotifier extends StateNotifier<FirstNightWizardState> {
  final TutorialDao _dao;
  late final Future<void> _loadFuture;
  Future<void> _mutationTail = Future<void>.value();

  FirstNightWizardNotifier(this._dao) : super(const FirstNightWizardState()) {
    _loadFuture = _loadResumeIndex();
  }

  Future<void> _loadResumeIndex() async {
    try {
      final stepIndex = await _dao.getLastStepIndex();
      // Clamp into the valid range — defends against a future where the
      // wizard is shortened and a user has a saved step beyond the new end.
      final clamped = stepIndex.clamp(0, _maxStepIndex);
      if (!mounted) return;
      state = state.copyWith(currentStepIndex: clamped, isLoaded: true);
    } catch (_) {
      // A corrupt/unavailable progress database must not strand the user on
      // an infinite loading spinner. Let them use the wizard from step zero;
      // mutations still report persistence errors to the UI.
      if (mounted) {
        state = state.copyWith(currentStepIndex: 0, isLoaded: true);
      }
    }
  }

  Future<R> _serializeMutation<R>(Future<R> Function() operation) {
    final completer = Completer<R>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        await _loadFuture;
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Total step count is owned by the model layer; we mirror it here as a
  /// constant so the clamp/advance math doesn't reach across packages
  /// every call.
  static const int _maxStepIndex = 6;

  /// True if the wizard is on the last (Launch sequence) step.
  bool get isLastStep => state.currentStepIndex >= _maxStepIndex;

  /// True if the wizard is on the first (Welcome) step. The Back button
  /// hides itself when this is true.
  bool get isFirstStep => state.currentStepIndex == 0;

  /// Advance one step. Persists progress. Calling next() on the last step
  /// completes the wizard; the caller uses [isLastStep] to swap the Next
  /// button to "Done".
  Future<void> next() async {
    return _serializeMutation(() async {
      if (state.currentStepIndex >= _maxStepIndex) {
        await _dao.markFirstNightCompleted();
        return;
      }
      final newIndex = state.currentStepIndex + 1;
      await _dao.saveFirstNightProgress(newIndex);
      state = state.copyWith(currentStepIndex: newIndex);
    });
  }

  /// Go back one step. Persists. Does nothing on step 0.
  Future<void> back() async {
    return _serializeMutation(() async {
      if (state.currentStepIndex == 0) return;
      final newIndex = state.currentStepIndex - 1;
      await _dao.saveFirstNightProgress(newIndex);
      state = state.copyWith(currentStepIndex: newIndex);
    });
  }

  /// Jump directly to a step (used by Settings → Help "Resume" deep-link).
  Future<void> goToStep(int index) async {
    if (index < 0 || index > _maxStepIndex) {
      // An out-of-range index is a caller bug, not user input: clamping it
      // would park the wizard on an arbitrary step.
      throw ArgumentError(
        'FirstNightWizardNotifier.goToStep: index $index outside '
        '[0..$_maxStepIndex]',
      );
    }
    return _serializeMutation(() async {
      await _dao.saveFirstNightProgress(index);
      state = state.copyWith(currentStepIndex: index);
    });
  }

  /// Mark the wizard finished. The user reached the final step and clicked
  /// Done. The wizard will not auto-open again on launch but can be
  /// replayed from Settings → Help.
  Future<void> complete() async {
    return _serializeMutation(_dao.markFirstNightCompleted);
  }

  /// "Skip forever" — the user explicitly opted out. Same launch-time
  /// effect as [complete] but distinguishes intent for analytics and the
  /// Settings → Help row label.
  Future<void> dismissForever() async {
    return _serializeMutation(_dao.dismissFirstNightForever);
  }

  /// "Show on next launch" — the wizard closes for this session but
  /// reopens next time. Implemented by deleting the saved progress row;
  /// [TutorialDao.shouldShowFirstNightOnLaunch] keys off row absence.
  Future<void> showOnNextLaunch() async {
    return _serializeMutation(_dao.resetFirstNight);
  }

  /// Restart from the welcome step. Used by Settings → Help "Restart".
  /// Doesn't dismiss or complete — just rewinds the saved index and the
  /// in-memory state.
  Future<void> restart() async {
    return _serializeMutation(() async {
      await _dao.saveFirstNightProgress(0);
      state = state.copyWith(currentStepIndex: 0);
    });
  }
}

/// Provider for the first-night wizard state notifier. Standalone from
/// [tutorialProvider] (which is shared by all the screen tours) because the
/// wizard has different lifecycle semantics — it's modal, single-shot, and
/// auto-launched.
final firstNightWizardProvider =
    StateNotifierProvider<FirstNightWizardNotifier, FirstNightWizardState>((
      ref,
    ) {
      return FirstNightWizardNotifier(ref.watch(tutorialDaoProvider));
    });

/// True while the first-night walkthrough owns the user's attention.
///
/// Set when the modal opens and cleared when the user finishes it, skips it
/// forever, or closes it — but deliberately NOT when they follow a "Show me on
/// the X screen" deep link, because that parks the walkthrough on a screen
/// rather than ending it. One guided flow at a time: while this is set, the
/// destination screen's own tour offer stays quiet instead of pitching the
/// ground the walkthrough step just covered.
///
/// Session-scoped on purpose. Deriving it from the persisted step row would
/// suppress every per-screen tour offer forever for a user who clicked Next
/// once and never came back.
final guidedFlowActiveProvider = StateProvider<bool>((ref) => false);

/// Stable category name for the first-launch onboarding tour persisted in
/// the `tutorial_progress` table. The OnboardingOverlay reads and writes
/// this row to decide whether to auto-fire on app launch.
///
/// Kept distinct from the first-night wizard category so the modal wizard
/// and the inline spotlight tour can be completed or skipped independently
/// — a user who skips the wizard may still want the lightweight overlay,
/// and vice versa.
const String firstLaunchTourCategory = 'firstLaunchTour';

/// State of the first-launch onboarding tour overlay.
///
/// Why a tri-state instead of a bool: knowing the row is missing
/// (`unknown`) lets the UI render nothing while the DAO read is in flight,
/// avoiding a frame where the overlay briefly mounts before the DAO says
/// the tour is already complete. `completed` and `skipped` are kept
/// distinct because Settings → Help shows different copy ("Replay" vs
/// "Restart") and analytics distinguishes "the user finished" from "the
/// user opted out".
enum FirstLaunchTourStatus {
  /// DAO read hasn't returned yet — render nothing.
  unknown,

  /// No row exists: the tour has never been run and has never been asked
  /// for. Distinct from [pending] because the coach-mark tour is
  /// replay-only — a fresh install must not be handed it on top of the
  /// equipment-onboarding spine it just finished.
  notStarted,

  /// The user explicitly asked for the tour (Settings → Help → Re-run) and
  /// has not yet finished or dismissed that run. This is the only status
  /// that mounts the overlay.
  pending,

  /// User clicked Done on the final step.
  completed,

  /// User clicked Skip, pressed Escape, or tapped outside the cutout.
  skipped,
}

/// Helpers around [TutorialProgressDao] that answer the questions the
/// onboarding overlay needs: "should I auto-open?", "did the user skip?",
/// "mark me done". Keeping them in a tiny wrapper class means the overlay
/// widget doesn't have to know the category name string or duplicate the
/// finished/dismissed flag mapping.
class FirstLaunchTourDao {
  final TutorialProgressDao _progressDao;

  FirstLaunchTourDao(this._progressDao);

  /// Resolve the tour's current persistence status — used by the launcher
  /// to decide whether to mount the overlay.
  Future<FirstLaunchTourStatus> getStatus() async {
    final progress = await _progressDao.getProgress(firstLaunchTourCategory);
    if (progress == null) {
      // No row at all. Nobody has asked for this tour, so it must not run:
      // mapping "missing row" to `pending` is what made the replay-only
      // coach-mark tour auto-fire on every fresh install, stacking a
      // "set up equipment and a profile" walkthrough on top of the
      // equipment-onboarding wizard that had just done exactly that.
      return FirstLaunchTourStatus.notStarted;
    }
    if (progress.completed) {
      return FirstLaunchTourStatus.completed;
    }
    if (progress.dismissed) {
      return FirstLaunchTourStatus.skipped;
    }
    // A row exists with neither terminal flag set — [reset] wrote it, so the
    // user explicitly asked for a replay and has not finished it yet. A user
    // who closes the overlay mid-run keeps that request until they complete
    // or skip.
    return FirstLaunchTourStatus.pending;
  }

  /// Mark the tour finished. Called when the user clicks Done on the
  /// final step. After this, [getStatus] returns [FirstLaunchTourStatus.completed]
  /// and the launcher will not auto-open again until [reset] is called.
  Future<void> markCompleted() {
    return _progressDao.markCompleted(firstLaunchTourCategory);
  }

  /// Mark the tour skipped — user pressed Skip, Escape, or tapped outside
  /// the cutout. Distinguished from [markCompleted] so the Settings → Help
  /// row can render a different label.
  Future<void> markSkipped() {
    return _progressDao.markDismissed(firstLaunchTourCategory);
  }

  /// Record an explicit replay request, so the launcher mounts the overlay.
  /// Backs the Settings → Help "Re-run tutorial" button.
  ///
  /// Writes a fresh row (rather than only deleting the old one) because the
  /// request itself is what [getStatus] reads: an absent row means "never
  /// asked for", and deleting without replacing would make the tour
  /// indistinguishable from a fresh install.
  Future<void> reset() async {
    await _progressDao.resetProgress(firstLaunchTourCategory);
    await _progressDao.saveProgress(firstLaunchTourCategory, 0);
  }
}

/// Provider for the first-launch onboarding tour DAO wrapper.
final firstLaunchTourDaoProvider = Provider<FirstLaunchTourDao>((ref) {
  return FirstLaunchTourDao(ref.watch(tutorialProgressDaoProvider));
});

/// Resolves the first-launch onboarding tour's current persistence status.
///
/// The OnboardingOverlay launcher watches this provider; when it resolves
/// to [FirstLaunchTourStatus.pending], the overlay mounts. The provider is
/// keyed by ref so widget code that calls [markCompleted] / [markSkipped]
/// via the notifier below can `ref.invalidate` this provider to retrigger
/// the launcher's gate (used by the Settings → Help "Re-run tutorial"
/// row to drop the user straight into the overlay without a restart).
final firstLaunchTourStatusProvider = FutureProvider<FirstLaunchTourStatus>((
  ref,
) {
  return ref.watch(firstLaunchTourDaoProvider).getStatus();
});

/// State notifier driving the OnboardingOverlay's step pointer.
///
/// Step state is intentionally session-only (not persisted) — the tour is
/// short (6 steps + 1 optional) and meant to be completed in a single
/// sitting. Persisting per-step would create a "you're 3/6 done, resume?"
/// UX that nobody asked for. Completion or skip is what gets persisted via
/// [FirstLaunchTourDao]; everything else lives in memory.
class OnboardingTourNotifier extends StateNotifier<int> {
  final FirstLaunchTourDao _dao;
  final Ref _ref;
  final int _totalCoreSteps;

  /// Whether the user has unlocked the optional "defect maps" follow-up
  /// step. Toggled on from the final card's "Show me about defect maps"
  /// button. Off by default so the linear next/skip path stops at the
  /// "You're set" card.
  bool _defectMapStepUnlocked = false;

  OnboardingTourNotifier({
    required FirstLaunchTourDao dao,
    required Ref ref,
    required int totalCoreSteps,
  }) : _dao = dao,
       _ref = ref,
       _totalCoreSteps = totalCoreSteps,
       super(0);

  /// True if the optional defect-map step is currently part of the tour.
  bool get defectMapStepUnlocked => _defectMapStepUnlocked;

  /// Current pointer to a step, 0-based.
  int get currentStepIndex => state;

  /// Total number of steps the user will see, including the optional
  /// defect-map follow-up if it was unlocked.
  int get totalSteps =>
      _defectMapStepUnlocked ? _totalCoreSteps + 1 : _totalCoreSteps;

  bool get isFirstStep => state == 0;
  bool get isLastStep => state >= totalSteps - 1;

  /// Advance one step. Calling next() on the last step is a no-op — the
  /// final card uses [complete] for its Done button.
  void next() {
    if (state >= totalSteps - 1) return;
    state = state + 1;
  }

  /// Go back one step. No-op on step 0.
  void back() {
    if (state == 0) return;
    state = state - 1;
  }

  /// Jump to a specific step index. Throws if out of range: an out-of-range
  /// index here is a caller bug.
  void goToStep(int index) {
    if (index < 0 || index >= totalSteps) {
      throw ArgumentError(
        'OnboardingTourNotifier.goToStep: index $index outside '
        '[0..${totalSteps - 1}]',
      );
    }
    state = index;
  }

  /// Unlock the optional defect-map follow-up and jump to it. Called from
  /// the "Show me about defect maps" button on the completion card.
  void unlockDefectMapStep() {
    _defectMapStepUnlocked = true;
    state = totalSteps - 1;
  }

  /// Persist completion and invalidate the status provider so the launcher
  /// reacts immediately (tearing down the overlay without waiting for a
  /// rebuild from elsewhere).
  Future<void> complete() async {
    await _dao.markCompleted();
    _ref.invalidate(firstLaunchTourStatusProvider);
  }

  /// Persist skip and invalidate the status provider. Same effect as
  /// [complete] on the next launch (tour does not re-fire) but recorded
  /// distinctly so the Settings → Help row can show "Replay" vs "Restart".
  Future<void> skip() async {
    await _dao.markSkipped();
    _ref.invalidate(firstLaunchTourStatusProvider);
  }

  /// Reset the persisted progress AND the in-memory step pointer. Used by
  /// Settings → Help → Re-run tutorial.
  Future<void> reset() async {
    await _dao.reset();
    if (!mounted) return;
    _defectMapStepUnlocked = false;
    state = 0;
    _ref.invalidate(firstLaunchTourStatusProvider);
  }
}

/// Total non-optional onboarding step count. Exposed as a top-level
/// constant so the notifier and the widget agree without round-tripping
/// through a Provider value at construction time.
const int onboardingTourCoreStepCount = 7;

/// Provider for the onboarding tour step notifier.
///
/// Intentionally NOT auto-disposing: the overlay can sit above any
/// screen, and route changes during the tour (e.g. the user clicked
/// through to Equipment from elsewhere) would otherwise dispose the
/// notifier and reset the step pointer. The Settings → Help "Re-run
/// tutorial" path calls [OnboardingTourNotifier.reset] explicitly to
/// rewind state, so we don't need the auto-dispose lifecycle to do it
/// for us.
final onboardingTourProvider =
    StateNotifierProvider<OnboardingTourNotifier, int>((ref) {
      return OnboardingTourNotifier(
        dao: ref.watch(firstLaunchTourDaoProvider),
        ref: ref,
        totalCoreSteps: onboardingTourCoreStepCount,
      );
    });

/// Provider for tutorial state with database persistence
final tutorialProvider =
    StateNotifierProvider<TutorialNotifier, TutorialProgress>((ref) {
      final dao = ref.watch(tutorialProgressDaoProvider);
      final notifier = TutorialNotifier(dao, ref.watch(settingsDaoProvider));
      // Load persisted progress on creation
      notifier._loadPersistedProgress();
      return notifier;
    });

/// Provider for dismissed tour prompts with database persistence.
/// Tracks which screen IDs have had their contextual tour prompts dismissed.
final dismissedTourPromptsProvider =
    StateNotifierProvider<DismissedTourPromptsNotifier, Set<String>>((ref) {
      final dao = ref.watch(tutorialProgressDaoProvider);
      return DismissedTourPromptsNotifier(dao);
    });

/// Manages dismissed tour prompts with database persistence
class DismissedTourPromptsNotifier extends StateNotifier<Set<String>> {
  final TutorialProgressDao _dao;

  DismissedTourPromptsNotifier(this._dao) : super({}) {
    _ready = _loadDismissedPrompts();
  }

  late final Future<void> _ready;

  /// Completes once the persisted dismissals have been read.
  ///
  /// Callers that DECIDE something from this state have to await it. The load is
  /// asynchronous while the initial state is an empty set, so a synchronous read
  /// taken right after the provider is first created always sees "nothing has
  /// been dismissed" — which is how a dismissed tour prompt came back on every
  /// single launch despite its dismissal being written to the database
  /// correctly. There is no delay long enough to paper over that reliably,
  /// because reading the provider is itself what starts the load.
  Future<void> get ready => _ready;

  /// Load dismissed prompts from database
  Future<void> _loadDismissedPrompts() async {
    final dismissed = await _dao.getDismissedPromptScreenIds();
    if (mounted) state = dismissed;
  }

  /// Dismiss a tour prompt for a screen (persists to database)
  Future<void> dismissPrompt(String screenId) async {
    await _dao.dismissPromptForScreen(screenId);
    if (mounted) state = {...state, screenId};
  }

  /// Check if a screen's prompt has been dismissed
  bool isPromptDismissed(String screenId) {
    return state.contains(screenId);
  }

  /// Reset all dismissed prompts (for "reset tutorials" feature)
  Future<void> resetAllDismissed() async {
    // This will be handled by resetAllProgress in TutorialProgressDao
    if (mounted) state = {};
  }
}

/// Manages global keys for tutorial targets
class TutorialKeyRegistry {
  final Map<String, GlobalKey> _keys = {};

  /// Register a key for a target
  GlobalKey registerKey(String id) {
    return _keys.putIfAbsent(id, () => GlobalKey());
  }

  /// Get a key by id
  GlobalKey? getKey(String id) => _keys[id];

  /// Get the render box for a target
  RenderBox? getRenderBox(String id) {
    final key = _keys[id];
    if (key?.currentContext == null) return null;
    return key!.currentContext!.findRenderObject() as RenderBox?;
  }

  /// Get the global position of a target
  Rect? getTargetRect(String id) {
    final renderBox = getRenderBox(id);
    if (renderBox == null) return null;
    final position = renderBox.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      position.dx,
      position.dy,
      renderBox.size.width,
      renderBox.size.height,
    );
  }
}

/// Manages tutorial progress and state with database persistence
class TutorialNotifier extends StateNotifier<TutorialProgress> {
  final TutorialProgressDao _dao;
  final SettingsDao? _settingsDao;
  Future<void> _settingsMutationTail = Future<void>.value();
  int _settingsRevision = 0;
  Future<void> _progressMutationTail = Future<void>.value();
  int _progressRevision = 0;

  static const String _tutorialsEnabledSettingKey = 'tutorials_enabled';

  TutorialNotifier(this._dao, [this._settingsDao])
    : super(const TutorialProgress());

  /// Load persisted progress from database
  Future<void> _loadPersistedProgress() async {
    final settingsRevisionAtStart = _settingsRevision;
    final progressRevisionAtStart = _progressRevision;
    final allProgress = await _dao.getAllProgress();
    final storedTutorialsEnabled = await _settingsDao?.getSetting(
      _tutorialsEnabledSettingKey,
    );

    // Build completed steps set from all completed categories
    final completedSteps = <String>{};
    bool hasSeenInitialTour = false;

    for (final entry in allProgress) {
      final category = _categoryFromName(entry.category);
      if (category != null) {
        final steps = TutorialDefinitions.getStepsForCategory(category);
        if (entry.completed) {
          // Add all steps from completed categories.
          completedSteps.addAll(steps.map((s) => s.id));

          // Check if firstLight (initial tour) was completed
          if (category == TutorialCategory.firstLight) {
            hasSeenInitialTour = true;
          }
        } else {
          // lastStepIndex is the step the user should resume on, so every
          // preceding step was completed. Rehydrate that partial set as well;
          // otherwise the Help screen and tour picker falsely say "Not
          // started" after every app restart despite a valid resume pointer.
          final completedCount = entry.lastStepIndex.clamp(0, steps.length);
          completedSteps.addAll(
            steps.take(completedCount).map((step) => step.id),
          );
        }
      }
    }

    if (!mounted) return;
    state = state.copyWith(
      completedSteps: progressRevisionAtStart == _progressRevision
          ? completedSteps
          : state.completedSteps,
      hasSeenInitialTour: progressRevisionAtStart == _progressRevision
          ? hasSeenInitialTour
          : state.hasSeenInitialTour,
      tutorialsEnabled: settingsRevisionAtStart == _settingsRevision
          ? storedTutorialsEnabled != 'false'
          : state.tutorialsEnabled,
    );
  }

  Future<R> _serializeProgressMutation<R>(Future<R> Function() operation) {
    _progressRevision++;
    final completer = Completer<R>();
    _progressMutationTail = _progressMutationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Convert category name string to enum
  TutorialCategory? _categoryFromName(String name) {
    for (final cat in TutorialCategory.values) {
      if (cat.name == name) return cat;
    }
    return null;
  }

  /// Start a tutorial category
  Future<void> startTutorial(TutorialCategory category) =>
      _restartTutorial(category);

  /// Resume a tutorial from where the user left off
  Future<void> resumeTutorial(TutorialCategory category) =>
      _serializeProgressMutation(() async {
        final progress = await _dao.getProgress(category.name);
        final stepIndex = progress?.lastStepIndex ?? 0;

        // Make sure the step index is valid
        final steps = TutorialDefinitions.getStepsForCategory(category);
        final validIndex = stepIndex.clamp(0, steps.length - 1);

        if (!mounted) return;
        state = state.copyWith(
          activeCategory: category,
          currentStepIndex: validIndex,
        );
      });

  /// Restart a tutorial from the beginning
  Future<void> restartTutorial(TutorialCategory category) =>
      _restartTutorial(category);

  Future<void> _restartTutorial(TutorialCategory category) =>
      _serializeProgressMutation(() async {
        // Commit the complete reset first. If persistence fails, the existing
        // status and active tutorial remain truthful and the UI can retry.
        await _dao.restartProgress(category.name);
        if (!mounted) return;

        final steps = TutorialDefinitions.getStepsForCategory(category);
        final stepIds = steps.map((s) => s.id).toSet();
        final newCompleted = Set<String>.from(state.completedSteps)
          ..removeAll(stepIds);

        state = state.copyWith(
          completedSteps: newCompleted,
          activeCategory: category,
          currentStepIndex: 0,
        );
      });

  /// Go to the next step in the current tutorial
  Future<void> nextStep() => _serializeProgressMutation(() async {
    final category = state.activeCategory;
    if (category == null) return;

    final steps = TutorialDefinitions.getStepsForCategory(category);
    if (state.currentStepIndex < steps.length - 1) {
      final currentStep = steps[state.currentStepIndex];
      final newCompleted = Set<String>.from(state.completedSteps)
        ..add(currentStep.id);
      final newIndex = state.currentStepIndex + 1;

      await _dao.saveProgress(category.name, newIndex);
      if (!mounted || state.activeCategory != category) return;
      state = state.copyWith(
        completedSteps: newCompleted,
        currentStepIndex: newIndex,
      );
      return;
    }

    await _completeTutorial(category, steps);
  });

  /// Go to the previous step
  Future<void> previousStep() => _serializeProgressMutation(() async {
    final category = state.activeCategory;
    if (category == null || state.currentStepIndex <= 0) return;
    final newIndex = state.currentStepIndex - 1;
    await _dao.saveProgress(category.name, newIndex);
    if (!mounted || state.activeCategory != category) return;
    state = state.copyWith(currentStepIndex: newIndex);
  });

  /// Skip to a specific step
  Future<void> goToStep(int index) => _serializeProgressMutation(() async {
    final category = state.activeCategory;
    if (category == null) return;
    final steps = TutorialDefinitions.getStepsForCategory(category);
    if (index < 0 || index >= steps.length) return;
    await _dao.saveProgress(category.name, index);
    if (!mounted || state.activeCategory != category) return;
    state = state.copyWith(currentStepIndex: index);
  });

  /// Complete the current tutorial
  Future<void> completeTutorial() => _serializeProgressMutation(() async {
    final category = state.activeCategory;
    if (category == null) return;
    final steps = TutorialDefinitions.getStepsForCategory(category);
    await _completeTutorial(category, steps);
  });

  Future<void> _completeTutorial(
    TutorialCategory category,
    List<TutorialStep> steps,
  ) async {
    await _dao.markCompleted(category.name);
    if (!mounted || state.activeCategory != category) return;
    final newCompleted = Set<String>.from(state.completedSteps)
      ..addAll(steps.map((s) => s.id));
    state = state.copyWith(
      completedSteps: newCompleted,
      hasSeenInitialTour: category == TutorialCategory.firstLight
          ? true
          : state.hasSeenInitialTour,
      clearActiveCategory: true,
      currentStepIndex: 0,
    );
  }

  /// Dismiss the current tutorial without completing
  Future<void> dismissTutorial() => _serializeProgressMutation(() async {
    final category = state.activeCategory;
    if (category == null) return;
    await _dao.markDismissed(category.name);
    if (!mounted || state.activeCategory != category) return;
    state = state.copyWith(clearActiveCategory: true, currentStepIndex: 0);
  });

  /// Toggle tutorials globally
  Future<void> setTutorialsEnabled(bool enabled) {
    _settingsRevision++;
    final completer = Completer<void>();
    _settingsMutationTail = _settingsMutationTail.then((_) async {
      try {
        await _settingsDao?.setSetting(
          _tutorialsEnabledSettingKey,
          enabled.toString(),
        );
        if (mounted) state = state.copyWith(tutorialsEnabled: enabled);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Reset all tutorial progress
  Future<void> resetProgress() => _serializeProgressMutation(() async {
    await _dao.resetAllProgress();
    if (mounted) {
      state = TutorialProgress(tutorialsEnabled: state.tutorialsEnabled);
    }
  });

  /// Mark the initial tour as seen (without completing it)
  void markInitialTourSeen() {
    state = state.copyWith(hasSeenInitialTour: true);
  }

  /// Check if a category has been completed
  Future<bool> isCategoryCompleted(TutorialCategory category) async {
    return _dao.isCategoryCompleted(category.name);
  }

  /// Check if a category was dismissed
  Future<bool> isCategoryDismissed(TutorialCategory category) async {
    return _dao.isCategoryDismissed(category.name);
  }

  /// Get saved progress for a category (step index)
  Future<int?> getSavedStepIndex(TutorialCategory category) async {
    final progress = await _dao.getProgress(category.name);
    return progress?.lastStepIndex;
  }

  /// Get the number of completed steps for a category (synchronous from state)
  int getCompletedStepsCount(TutorialCategory category) {
    final steps = TutorialDefinitions.getStepsForCategory(category);
    return steps.where((s) => state.completedSteps.contains(s.id)).length;
  }

  /// Get the total number of steps for a category
  int getTotalStepsCount(TutorialCategory category) {
    return TutorialDefinitions.getStepsForCategory(category).length;
  }

  /// Check if a category is fully completed (synchronous from state)
  bool isCategoryCompletedSync(TutorialCategory category) {
    final steps = TutorialDefinitions.getStepsForCategory(category);
    return steps.every((s) => state.completedSteps.contains(s.id));
  }

  /// Check if a category has any progress (synchronous from state)
  bool hasCategoryProgress(TutorialCategory category) {
    final steps = TutorialDefinitions.getStepsForCategory(category);
    return steps.any((s) => state.completedSteps.contains(s.id));
  }

  /// Get the current step
  TutorialStep? get currentStep {
    if (state.activeCategory == null) return null;
    final steps = TutorialDefinitions.getStepsForCategory(
      state.activeCategory!,
    );
    if (state.currentStepIndex >= steps.length) return null;
    return steps[state.currentStepIndex];
  }

  /// Get total steps in current tutorial
  int get totalSteps {
    if (state.activeCategory == null) return 0;
    return TutorialDefinitions.getStepsForCategory(
      state.activeCategory!,
    ).length;
  }

  /// Check if this is the last step
  bool get isLastStep {
    return state.currentStepIndex >= totalSteps - 1;
  }

  /// Check if this is the first step
  bool get isFirstStep {
    return state.currentStepIndex == 0;
  }
}
