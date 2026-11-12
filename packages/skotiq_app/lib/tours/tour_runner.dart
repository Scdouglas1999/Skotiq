import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show TutorialProgressDao, tutorialProgressDaoProvider;

import 'tour.dart';

/// How far the user has got through one tour.
@immutable
class TourProgress {
  const TourProgress({
    this.stepIndex = 0,
    this.completed = false,
    this.skipped = false,
  });

  /// The step to resume on.
  final int stepIndex;

  final bool completed;

  /// The user left the tour with Skip.
  final bool skipped;
}

@immutable
class TourRunState {
  const TourRunState({
    this.active,
    this.stepIndex = 0,
    this.parked = false,
    this.progress = const {},
  });

  /// The tour on screen, or null.
  final Tour? active;

  /// The step of [active] on show.
  final int stepIndex;

  /// A walkthrough has sent the user to a screen and stepped aside until they
  /// call it back.
  final bool parked;

  /// What is saved for each tour that has been started.
  final Map<Tour, TourProgress> progress;

  TourStep? get step => active?.steps[stepIndex];

  bool get isFirstStep => stepIndex == 0;

  bool get isLastStep =>
      active != null && stepIndex >= active!.steps.length - 1;

  /// Steps of [tour] the user has been through.
  int stepsDone(Tour tour) {
    final saved = progress[tour];
    if (saved == null) return 0;
    return saved.completed
        ? tour.steps.length
        : saved.stepIndex.clamp(0, tour.steps.length);
  }

  bool isCompleted(Tour tour) => progress[tour]?.completed ?? false;
}

/// Runs every tour: which one is on screen, which step, and what is saved.
///
/// Each move is written to `tutorial_progress` before the state changes, so a
/// failed write leaves the tour where it was and the caller hears about it.
class TourRunner extends StateNotifier<TourRunState> {
  TourRunner(this._dao) : super(const TourRunState()) {
    _tail = _load();
  }

  final TutorialProgressDao _dao;
  late Future<void> _tail;

  Future<void> _load() async {
    try {
      final rows = await _dao.getAllProgress();
      if (!mounted) return;
      final byId = {for (final tour in Tour.values) tour.id: tour};
      state = TourRunState(
        active: state.active,
        stepIndex: state.stepIndex,
        parked: state.parked,
        progress: {
          for (final row in rows)
            if (byId[row.category] case final tour?)
              tour: TourProgress(
                stepIndex: row.lastStepIndex,
                completed: row.completed,
                skipped: row.dismissed,
              ),
        },
      );
    } catch (error, stack) {
      // Tours still run without their saved progress; each move then reports
      // its own write.
      debugPrint('TourRunner: could not read saved progress: $error\n$stack');
    }
  }

  /// Runs [move] after every earlier one has finished.
  Future<void> _then(Future<void> Function() move) {
    final done = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await move();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  void _show(Tour? active, int stepIndex, {TourProgress? saved}) {
    if (!mounted) return;
    final tour = active ?? state.active;
    state = TourRunState(
      active: active,
      stepIndex: stepIndex,
      progress: {
        ...state.progress,
        if (tour != null && saved != null) tour: saved,
      },
    );
  }

  /// Saved progress has been read.
  Future<void> get ready => _then(() async {});

  /// Shows [tour] from its first step, forgetting what was saved for it.
  Future<void> start(Tour tour) => _then(() async {
        await _dao.restartProgress(tour.id);
        _show(tour, 0, saved: const TourProgress());
      });

  /// Shows [tour] on the step the user left it at.
  Future<void> resume(Tour tour) => _then(() async {
        final saved = state.progress[tour];
        if (saved == null || saved.completed) {
          await _dao.restartProgress(tour.id);
          _show(tour, 0, saved: const TourProgress());
          return;
        }
        _show(tour, saved.stepIndex.clamp(0, tour.steps.length - 1));
      });

  /// The next step, or the end of the tour from its last one.
  Future<void> next() => _then(() async {
        final tour = state.active;
        if (tour == null) return;
        if (state.isLastStep) {
          await _finish(tour);
        } else {
          await _goTo(tour, state.stepIndex + 1);
        }
      });

  Future<void> back() => _then(() async {
        final tour = state.active;
        if (tour == null || state.isFirstStep) return;
        await _goTo(tour, state.stepIndex - 1);
      });

  Future<void> goTo(int index) => _then(() async {
        final tour = state.active;
        if (tour == null) return;
        RangeError.checkValidIndex(index, tour.steps, 'index');
        await _goTo(tour, index);
      });

  Future<void> _goTo(Tour tour, int index) async {
    await _dao.saveProgress(tour.id, index);
    if (state.active != tour) return;
    _show(tour, index, saved: TourProgress(stepIndex: index));
  }

  /// Ends the tour as done.
  Future<void> finish() => _then(() async {
        final tour = state.active;
        if (tour != null) await _finish(tour);
      });

  Future<void> _finish(Tour tour) async {
    await _dao.markCompleted(tour.id);
    if (state.active != tour) return;
    _show(null, 0, saved: const TourProgress(completed: true));
  }

  /// Ends the tour at the user's request, keeping the step to resume on.
  Future<void> skip() => _then(() async {
        final tour = state.active;
        if (tour == null) return;
        await _dao.markDismissed(tour.id);
        if (state.active != tour) return;
        _show(
          null,
          0,
          saved: TourProgress(stepIndex: state.stepIndex, skipped: true),
        );
      });

  /// Takes the tour off screen without marking it; it resumes where it was.
  void close() => _show(null, 0);

  /// Steps a walkthrough aside while the user looks at the screen it opened.
  void park() => _setParked(true);

  /// Brings a parked walkthrough back.
  void unpark() => _setParked(false);

  void _setParked(bool parked) {
    if (state.active == null) return;
    state = TourRunState(
      active: state.active,
      stepIndex: state.stepIndex,
      parked: parked,
      progress: state.progress,
    );
  }

  /// Forgets all saved progress and takes any tour off screen.
  Future<void> resetAll() => _then(() async {
        await _dao.resetAllProgress();
        if (mounted) state = const TourRunState();
      });
}

final tourRunnerProvider =
    StateNotifierProvider<TourRunner, TourRunState>((ref) {
  return TourRunner(ref.watch(tutorialProgressDaoProvider));
});
