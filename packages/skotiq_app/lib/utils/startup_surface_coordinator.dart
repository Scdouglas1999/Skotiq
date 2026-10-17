import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Serializes startup dialogs launched by otherwise-independent features.
class StartupSurfaceCoordinator {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final predecessor = _tail;
    final released = Completer<void>();
    _tail = released.future;

    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        if (!released.isCompleted) released.complete();
      }
    }();
  }
}

final startupSurfaceCoordinatorProvider =
    Provider<StartupSurfaceCoordinator>((ref) => StartupSurfaceCoordinator());
