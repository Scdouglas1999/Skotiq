// Fallback implementation for platforms without window_manager
import 'package:flutter/material.dart';

/// Callback type for when window close is requested
typedef OnCloseRequested = Future<bool> Function();

// Fallback functions for mobile/web
void initWindowManager(State state, {OnCloseRequested? onCloseRequested}) {
  // Not applicable on mobile/web
}

void disposeWindowManager(State state) {
  // Not applicable on mobile/web
}

// Compatibility mixin for platforms without window manager
mixin WindowListenerMixin {
  // Empty - not needed
}
