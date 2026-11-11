// Fallback implementation for platforms without window_manager
import 'package:flutter/material.dart';

typedef OnCloseRequested = Future<bool> Function();

void initWindowManager(State state, {OnCloseRequested? onCloseRequested}) {
  // Not applicable on mobile/web
}

void disposeWindowManager(State state) {
  // Not applicable on mobile/web
}

mixin WindowListenerMixin {
}
