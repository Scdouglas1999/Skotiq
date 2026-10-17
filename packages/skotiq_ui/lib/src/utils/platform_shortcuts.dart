import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

/// Label for the modifier that opens app-wide shortcuts on the running
/// platform.
///
/// The shortcut handlers accept Meta OR Control, but the badges next to them
/// were hardcoded to the Apple Command glyph, so a Linux or Windows rig
/// advertised a key its keyboard does not have.
String shortcutModifierLabel() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.iOS:
      return '⌘';
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
      return 'Ctrl+';
  }
}

/// The badge text for a primary-modifier shortcut, e.g. `⌘K` on macOS and
/// `Ctrl+K` everywhere else.
String shortcutLabel(String key) => '${shortcutModifierLabel()}$key';
