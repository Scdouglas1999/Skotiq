import 'package:flutter/widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'screens/shell/shell_chrome.dart' show DeviceShellLayoutScope;
import 'widgets/red_night_filter.dart' show RedNightScreen;

/// The wrappers every Skotiq `MaterialApp` puts around its navigator: this
/// device's layout facts for [ShellLayout], the red-night filter over every
/// pixel, and text editing that ends when the soft keyboard closes.
///
/// The app root and the phone's own apps (the connection screen, first-run
/// setup, the error screen) all build through it, so a root wrapper added
/// here reaches each of them.
Widget skotiqAppFrame(Widget? child) => DeviceShellLayoutScope(
      child: RedNightScreen(
        child: UnfocusOnKeyboardClose(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );

/// The observers each of the app's navigators takes. A new list per call:
/// an observer serves one navigator.
List<NavigatorObserver> skotiqNavigatorObservers() =>
    [UnfocusTextOnPopupObserver()];
