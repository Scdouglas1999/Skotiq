import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The prompts Skotiq may raise by itself at launch, in the order they are
/// shown. One at a time; a later one waits until every earlier one has either
/// been answered or found nothing to say.
enum StartupSurface {
  /// "Your data was reset" after a database that could not be opened.
  databaseRecovery,

  /// A run the app died under, offered for restore.
  checkpointRecovery,

  /// An imaging session that never closed.
  interruptedSession,

  /// "Load the previous setup" for a recent session.
  quickStart,

  /// A new install sent to equipment setup.
  equipmentOnboarding,

  /// The one-time "Your Sky is now off" notice.
  yourSkyOffNotice;

  /// Earlier surfaces that put the same question to the operator. Once one
  /// of them has been answered, this one is not raised.
  ///
  /// Quick Start offers to continue the last session, which after a crash is
  /// the run the checkpoint prompt has just asked about: restored or
  /// discarded there, it is not asked about a second time.
  Set<StartupSurface> get sameQuestionAs => switch (this) {
        quickStart => const {checkpointRecovery},
        _ => const {},
      };
}

/// Orders the start-up prompts and shows one at a time.
///
/// A launcher [expect]s its surface when it mounts, runs its own check, and
/// then either takes its [turn] or [pass]es. Nothing waits for a fixed time:
/// a surface waits for the earlier ones, and for the prompt on screen.
class StartupSurfaceQueue {
  final Map<StartupSurface, Completer<void>> _undecided = {};
  final Set<StartupSurface> _answered = {};
  Completer<void>? _showing;

  /// Announces that [surface] will take a turn or pass. Call it when the
  /// launcher mounts, before any `await`, so later surfaces know to wait.
  void expect(StartupSurface surface) {
    _undecided.putIfAbsent(surface, Completer<void>.new);
  }

  /// [surface] has nothing to show.
  void pass(StartupSurface surface) {
    _undecided.remove(surface)?.complete();
  }

  /// Shows [surface] once every earlier surface has had its turn and no other
  /// prompt is up. Completes with [present]'s result when it is dismissed.
  Future<T> turn<T>(
    StartupSurface surface,
    Future<T> Function() present,
  ) async {
    try {
      await _earlierDecided(surface.index);
      return await _exclusive(present);
    } finally {
      pass(surface);
    }
  }

  /// Records that the operator answered [surface]'s prompt. Call it from the
  /// prompt's own turn, before the turn ends.
  void answered(StartupSurface surface) => _answered.add(surface);

  /// Whether the operator has already answered [surface]'s question, in the
  /// prompt of one of its [StartupSurface.sameQuestionAs]. Ask when the
  /// surface's turn comes, not before: the earlier prompt may still be up.
  bool alreadyAnswered(StartupSurface surface) =>
      surface.sameQuestionAs.any(_answered.contains);

  /// Shows a prompt that is not part of the start-up order (one raised by an
  /// event, such as a mount connecting) after every start-up surface, one at
  /// a time with the rest.
  Future<T> run<T>(Future<T> Function() present) async {
    await _earlierDecided(StartupSurface.values.length);
    return _exclusive(present);
  }

  Future<void> _earlierDecided(int index) async {
    while (true) {
      Completer<void>? blocker;
      for (final surface in StartupSurface.values) {
        if (surface.index >= index) break;
        blocker = _undecided[surface];
        if (blocker != null) break;
      }
      if (blocker == null) return;
      await blocker.future;
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() present) async {
    while (_showing != null) {
      await _showing!.future;
    }
    final mine = _showing = Completer<void>();
    try {
      return await present();
    } finally {
      _showing = null;
      mine.complete();
    }
  }
}

final startupSurfaceQueueProvider = Provider<StartupSurfaceQueue>(
  (ref) => StartupSurfaceQueue(),
);
