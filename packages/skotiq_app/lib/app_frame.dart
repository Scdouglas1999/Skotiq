import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:skotiq_core/settings.dart' show AppSettingsState;
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

/// What every Skotiq `MaterialApp` takes from the operator's settings: the
/// theme, the language, and the text scale from Font size and UI scale.
///
/// Null [settings] (still loading) gives the defaults.
class SkotiqAppLook {
  SkotiqAppLook(AppSettingsState? settings)
      : theme = resolveSkotiqThemeData(
          themeSetting: settings?.theme ?? 'dark',
          accentColorHex: settings?.accentColor,
        ),
        locale = _localeOf(settings?.language),
        _fontScale = _fontScaleOf(settings?.fontSize ?? 'Medium'),
        _uiScaleSetting = settings?.uiScale;

  final ThemeData theme;
  final Locale? locale;
  final double _fontScale;
  final String? _uiScaleSetting;

  /// [child] at the chosen text scale. Call from `MaterialApp.builder`: the
  /// automatic UI scale reads the window's pixel ratio from [context].
  Widget scaled(BuildContext context, Widget child) {
    final uiScale = _uiScaleOf(context);
    if (uiScale == 1.0 && _fontScale == 1.0) return child;
    // Text only: Flutter scales the widget tree for the display itself, and a
    // Transform.scale over the whole tree causes rendering artifacts.
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(_fontScale * uiScale),
      ),
      child: child,
    );
  }

  double _uiScaleOf(BuildContext context) {
    switch (_uiScaleSetting) {
      case 'Small (0.8x)':
        return 0.8;
      case 'Normal (1.0x)':
        return 1.0;
      case 'Large (1.2x)':
        return 1.2;
      case 'Extra Large (1.4x)':
        return 1.4;
    }
    // Auto. Linux under Wayland/X11 does not always scale Flutter for a
    // high-DPI display (pixel ratio above 1.5): DPR 2.0 -> 1.25x, 2.5 -> 1.5x,
    // 3.0 -> 1.75x.
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    if (!kIsWeb && Platform.isLinux && devicePixelRatio > 1.5) {
      final extraScale = 1.0 + (devicePixelRatio - 1.5) * 0.5;
      return extraScale.clamp(1.0, 1.75);
    }
    return 1.0;
  }

  static double _fontScaleOf(String fontSize) {
    switch (fontSize) {
      case 'Small':
        return 0.85;
      case 'Large':
        return 1.15;
      case 'Medium':
      default:
        return 1.0;
    }
  }

  static Locale? _localeOf(String? languageCode) {
    switch (languageCode) {
      case 'en':
        return const Locale('en');
      case 'es':
        return const Locale('es');
      default:
        return null;
    }
  }
}
