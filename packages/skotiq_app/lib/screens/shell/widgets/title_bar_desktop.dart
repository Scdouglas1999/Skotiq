// Desktop implementation with window_manager
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

void onTitleBarPanStart(DragStartDetails details) {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    windowManager.startDragging();
  }
}

void onTitleBarDoubleTap() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    windowManager.isMaximized().then((isMaximized) {
      if (isMaximized) {
        windowManager.unmaximize();
      } else {
        windowManager.maximize();
      }
    });
  }
}

void minimizeWindow() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    windowManager.minimize();
  }
}

void toggleMaximizeWindow() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    windowManager.isMaximized().then((isMaximized) {
      if (isMaximized) {
        windowManager.unmaximize();
      } else {
        windowManager.maximize();
      }
    });
  }
}

void closeWindow() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    windowManager.close();
  }
}
