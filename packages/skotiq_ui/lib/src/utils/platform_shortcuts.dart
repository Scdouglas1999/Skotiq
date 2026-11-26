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

/// A shortcut named after a label: " (Ctrl+Z)", or " (or Ctrl+Z)" with [or].
/// Empty on a phone or tablet, where a keyboard is the exception and a touch
/// tooltip naming one is noise.
String shortcutSuffix(String key, {bool or = false}) =>
    platformExpectsKeyboard()
    ? ' (${or ? 'or ' : ''}${shortcutLabel(key)})'
    : '';

/// Whether this platform is one a keyboard comes with: false on a phone or
/// tablet, where naming a shortcut is noise.
bool platformExpectsKeyboard() => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS => false,
  _ => true,
};
