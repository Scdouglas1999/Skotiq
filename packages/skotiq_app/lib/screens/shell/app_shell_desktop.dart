// Desktop implementation with window_manager
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'shell_exit_recorder.dart';
import 'widgets/window_chrome_desktop.dart' as chrome_impl;

/// Callback type for when window close is requested
typedef OnCloseRequested = Future<bool> Function();

/// Window close listener that holds a reference to the close callback
class _WindowCloseListener extends WindowListener {
  final OnCloseRequested? onCloseRequested;

  _WindowCloseListener({this.onCloseRequested});

  @override
  void onWindowClose() async {
    final closeDecision = await onCloseRequested?.call();
    final shouldClose = closeDecision != false;
    if (shouldClose) {
      // Say so BEFORE destroying the window: the entry point's session record
      // is what tells the next launch whether the previous one ended on
      // purpose, and nothing after destroy() runs.
      ShellExit.recordClean('Window closed');
      await windowManager.destroy();
    }
  }
}

/// Global listener instance (needed because WindowManager uses static methods)
_WindowCloseListener? _closeListener;

/// Initialize window manager with optional close confirmation callback
void initWindowManager(State state, {OnCloseRequested? onCloseRequested}) {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      // Prevent default close behavior so we can intercept it
      windowManager.setPreventClose(true);

      // Create and add the listener, replacing the plain one a previous
      // shell left behind.
      if (_closeListener != null) {
        windowManager.removeListener(_closeListener!);
      }
      _closeListener = _WindowCloseListener(onCloseRequested: onCloseRequested);
      windowManager.addListener(_closeListener!);

      // The chrome state the shell draws from: maximize/restore on the
      // caption button, and the gates for the Linux edge hairline and resize
      // grips.
      chrome_impl.ensureWindowChromeState();
    } catch (e) {
      developer.log('[AppShell] Error initializing window manager: $e',
          name: 'AppShell', level: 1000, error: e);
    }
  }
}

/// Dispose window manager.
///
/// The close stays intercepted after the shell is gone (routes outside it,
/// such as onboarding, still own a frameless window), so the shell's listener
/// is swapped for one that closes without the shell's confirmation rather
/// than removed: a prevented close with no listener ignores every close
/// request, from the app's own button and from the desktop alike.
void disposeWindowManager(State state) {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      if (_closeListener != null) {
        windowManager.removeListener(_closeListener!);
        _closeListener = _WindowCloseListener();
        windowManager.addListener(_closeListener!);
      }
    } catch (e) {
      developer.log('[AppShell] Error disposing window manager: $e',
          name: 'AppShell', level: 1000, error: e);
    }
  }
}

// Compatibility mixin for platforms with window manager
mixin WindowListenerMixin {
  // Empty - not needed for basic functionality
}
