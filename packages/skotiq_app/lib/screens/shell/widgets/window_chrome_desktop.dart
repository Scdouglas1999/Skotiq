// Desktop implementation of window chrome calls (Linux, Windows, macOS).
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart' as wm;

import 'window_chrome.dart';

/// Live maximize/full-screen state of the host window. The resize edges and
/// the app-drawn window hairline are gated on this, and the maximize control
/// swaps its icon and label between "Maximize window" and "Restore window".
final ValueNotifier<WindowChromeState> windowChromeState =
    ValueNotifier(const WindowChromeState());

/// Updates [windowChromeState] from window_manager events.
class _WindowChromeListener extends wm.WindowListener {
  @override
  void onWindowMaximize() =>
      windowChromeState.value = windowChromeState.value.copyWith(
        maximized: true,
      );

  @override
  void onWindowUnmaximize() =>
      windowChromeState.value = windowChromeState.value.copyWith(
        maximized: false,
      );

  @override
  void onWindowEnterFullScreen() =>
      windowChromeState.value = windowChromeState.value.copyWith(
        fullscreen: true,
      );

  @override
  void onWindowLeaveFullScreen() =>
      windowChromeState.value = windowChromeState.value.copyWith(
        fullscreen: false,
      );
}

bool _windowChromeListenerInstalled = false;

/// Starts listening for maximize/full-screen events and seeds the current
/// state. Called once during desktop window setup; safe to call again.
void ensureWindowChromeState() {
  if (_windowChromeListenerInstalled) return;
  _windowChromeListenerInstalled = true;
  wm.windowManager.addListener(_WindowChromeListener());
  wm.windowManager.isMaximized().then((v) {
    windowChromeState.value = windowChromeState.value.copyWith(maximized: v);
  }).catchError((_) {});
  wm.windowManager.isFullScreen().then((v) {
    windowChromeState.value = windowChromeState.value.copyWith(fullscreen: v);
  }).catchError((_) {});
}

/// Answers the shell's platform-window questions that window_manager cannot:
/// what a title-bar double click should do. Linux reads
/// `gtk-titlebar-double-click`, macOS reads `AppleActionOnDoubleClick`;
/// Windows has no handler installed so the channel misses and the caller
/// falls back to the conventional toggle.
const MethodChannel _windowChromeChannel = MethodChannel(
  'com.skotiq.desktop/window_chrome',
);

Future<WindowDoubleClickAction> titlebarDoubleClickAction() async {
  try {
    final raw = await _windowChromeChannel.invokeMethod<String>(
      'getTitlebarDoubleClickAction',
    );
    switch (raw?.toLowerCase()) {
      case 'toggle-maximize':
      case 'maximize':
        return WindowDoubleClickAction.toggleMaximize;
      case 'toggle-minimize':
      case 'minimize':
        return WindowDoubleClickAction.minimize;
      case 'none':
        return WindowDoubleClickAction.nothing;
      default:
        return WindowDoubleClickAction.toggleMaximize;
    }
  } on MissingPluginException {
    return WindowDoubleClickAction.toggleMaximize;
  } on PlatformException {
    return WindowDoubleClickAction.toggleMaximize;
  }
}

void onWindowDragPanStart(DragStartDetails details) {
  wm.windowManager.startDragging();
}

void onWindowDragDoubleTap() {
  titlebarDoubleClickAction().then((action) {
    switch (action) {
      case WindowDoubleClickAction.toggleMaximize:
        toggleMaximizeWindow();
      case WindowDoubleClickAction.minimize:
        wm.windowManager.minimize();
      case WindowDoubleClickAction.nothing:
        break;
    }
  });
}

void minimizeWindow() {
  wm.windowManager.minimize();
}

void toggleMaximizeWindow() {
  wm.windowManager.isMaximized().then((maximized) {
    if (maximized) {
      wm.windowManager.unmaximize();
    } else {
      wm.windowManager.maximize();
    }
  });
}

void closeWindow() {
  wm.windowManager.close();
}

wm.ResizeEdge _toWmEdge(WindowResizeEdge edge) => switch (edge) {
      WindowResizeEdge.left => wm.ResizeEdge.left,
      WindowResizeEdge.right => wm.ResizeEdge.right,
      WindowResizeEdge.top => wm.ResizeEdge.top,
      WindowResizeEdge.bottom => wm.ResizeEdge.bottom,
      WindowResizeEdge.topLeft => wm.ResizeEdge.topLeft,
      WindowResizeEdge.topRight => wm.ResizeEdge.topRight,
      WindowResizeEdge.bottomLeft => wm.ResizeEdge.bottomLeft,
      WindowResizeEdge.bottomRight => wm.ResizeEdge.bottomRight,
    };

/// Begins a native resize drag. Called from pan gestures rather than plain
/// taps so the host picks up the live mouse press; gated on the chrome state
/// because an undecorated maximized window must not resize from its edges.
void startWindowResize(WindowResizeEdge edge) {
  if (!Platform.isLinux) return;
  if (windowChromeState.value.fillsScreen) return;
  wm.windowManager.startResizing(_toWmEdge(edge));
}
