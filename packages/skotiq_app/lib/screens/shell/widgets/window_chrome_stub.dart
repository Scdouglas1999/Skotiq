// Fallback implementation for platforms without window_manager (mobile, web).
import 'package:flutter/widgets.dart';

import 'window_chrome.dart';

/// Live maximize/full-screen state of the host window. Platforms without a
/// managed window never change it, so a never-updating value is the truth.
final ValueNotifier<WindowChromeState> windowChromeState =
    ValueNotifier(const WindowChromeState());

/// No managed window exists to listen to.
void ensureWindowChromeState() {}

void onWindowDragPanStart(DragStartDetails details) {
  // Not applicable on mobile/web
}

void onWindowDragDoubleTap() {
  // Not applicable on mobile/web
}

/// The desktop's own answer for a title-bar double click. Non-desktop builds
/// never ask, so the default is a placeholder, not a read of a platform
/// default.
Future<WindowDoubleClickAction> titlebarDoubleClickAction() {
  return Future.value(WindowDoubleClickAction.toggleMaximize);
}

void minimizeWindow() {
  // Not applicable on mobile/web
}

void toggleMaximizeWindow() {
  // Not applicable on mobile/web
}

void closeWindow() {
  // Not applicable on mobile/web
}

void startWindowResize(WindowResizeEdge edge) {
  // Not applicable on mobile/web
}
