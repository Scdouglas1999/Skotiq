import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../services/command_action_result.dart';
import 'transient_bottom_inset.dart';

/// The one way the app shows a snackbar: from a [BuildContext]
/// (`context.showErrorSnackBar(...)`), or from a [ScaffoldMessengerState]
/// taken before an `await` (`messenger.showErrorSnackBar(...)`). Both place
/// it the same way and give it its tone's color and a duration long enough
/// to read. `ScaffoldMessenger.showSnackBar` is called nowhere else; the
/// architecture audit's app-feedback rule holds that.
///
/// Snackbars are floating (see the app theme), so they are anchored to the
/// bottom of the enclosing [Scaffold] and would otherwise be drawn straight
/// over a screen's own bottom bar. [TransientBottomInset] lets a screen declare
/// the height it needs kept clear (on the Imaging screen, the Snapshot / Loop /
/// Duration strip) and every snackbar here honors it.
extension SnackBarHelper on BuildContext {
  void showErrorSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.error, message, duration, action);

  void showSuccessSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.success, message, duration, action);

  void showWarningSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.warning, message, duration, action);

  void showInfoSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.info, message, duration, action);

  /// Shows user feedback for a command result when it has a message payload.
  void showCommandActionResult(
    CommandActionResult result, {
    Duration? duration,
  }) {
    if (!result.hasMessage || result.alreadyShown) return;
    final message = result.message!;
    switch (result.feedbackType) {
      case CommandFeedbackType.error:
        showErrorSnackBar(message, duration: duration);
        break;
      case CommandFeedbackType.warning:
        showWarningSnackBar(message, duration: duration);
        break;
      case CommandFeedbackType.info:
        showInfoSnackBar(message, duration: duration);
        break;
      case CommandFeedbackType.success:
        showSuccessSnackBar(message, duration: duration);
        break;
    }
  }

  void _feedback(
    _Tone tone,
    String message,
    Duration? duration,
    SnackBarAction? action,
  ) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(this);
    if (messenger == null) return;
    _show(messenger, this, tone, message, duration, action);
  }
}

/// The same snackbars for a messenger kept across an `await`, when the
/// widget that started the work may be gone by the time it reports.
extension SnackBarMessengerHelper on ScaffoldMessengerState {
  void showErrorSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.error, message, duration, action);

  void showSuccessSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.success, message, duration, action);

  void showWarningSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.warning, message, duration, action);

  void showInfoSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) =>
      _feedback(_Tone.info, message, duration, action);

  void _feedback(
    _Tone tone,
    String message,
    Duration? duration,
    SnackBarAction? action,
  ) {
    if (!mounted) return;
    _show(this, context, tone, message, duration, action);
  }
}

enum _Tone {
  info(Duration(seconds: 2)),
  success(Duration(seconds: 3)),
  warning(Duration(seconds: 3)),
  error(Duration(seconds: 4));

  const _Tone(this.shortest);

  /// How long a short message of this tone stays up.
  final Duration shortest;

  Color? background(SkotiqColors colors) => switch (this) {
        _Tone.info => null,
        _Tone.success => colors.success,
        _Tone.warning => colors.warning,
        _Tone.error => colors.error,
      };
}

/// Longest any snackbar stays up without an explicit duration.
const Duration _longest = Duration(seconds: 10);

/// Time to notice a message and read it, at about 15 characters a second,
/// never less than its tone's [_Tone.shortest] nor more than [_longest].
Duration _readingTime(_Tone tone, String message) {
  final reading = Duration(milliseconds: 1000 + message.length * 1000 ~/ 15);
  if (reading < tone.shortest) return tone.shortest;
  return reading > _longest ? _longest : reading;
}

/// Widest a snackbar is allowed to be.
///
/// A floating snackbar with no margin spans the whole Scaffold: at 1600 px
/// that is a 1600 px bar across the window bottom. Matched to the toast
/// overlay's own column so routine feedback reads as one surface wherever it
/// comes from.
const double _maxSnackBarWidth = 520.0;

void _show(
  ScaffoldMessengerState messenger,
  BuildContext placement,
  _Tone tone,
  String message,
  Duration? duration,
  SnackBarAction? action,
) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: tone.background(SkotiqColors.of(placement)),
      margin: _snackBarMargin(placement),
      duration: duration ?? _readingTime(tone, message),
      action: action,
      // `persist` defaults to `action != null`, and a persisting snackbar
      // ignores its duration: an Undo offer sat over the status bar until the
      // app restarted. An offer is not a modal, so it times out like any
      // other and has a close button besides.
      persist: false,
      showCloseIcon: action != null,
    ),
  );
}

/// Margin that keeps a floating snackbar off the chrome it would otherwise
/// paint over, and stops it spanning the whole window.
///
/// Two things sit under a snackbar anchored to the shell Scaffold's bottom:
/// the screen's own bottom bar, when it declares one via
/// [TransientBottomInset], and the shell's global status bar, which nothing
/// declared. So a routine "Glance mode on" toast blanked the connection
/// chips, the save path and the clock (the one strip an operator glances at)
/// for its whole lifetime, full-bleed across the window.
///
/// The declared inset is measured from the bar's top edge to the bottom of
/// the WINDOW, so it already covers the status bar; take the larger of the
/// two rather than adding them.
EdgeInsetsGeometry? _snackBarMargin(BuildContext context) {
  // A margin is only legal on a floating snackbar (the framework asserts
  // otherwise). The app theme is floating everywhere, but a host that has not
  // installed it (a bare MaterialApp in a test, an embedded surface) must
  // still get a snackbar rather than an assertion.
  if (Theme.of(context).snackBarTheme.behavior != SnackBarBehavior.floating) {
    return null;
  }
  final declared = TransientBottomInset.of(context);
  final media = MediaQuery.maybeOf(context);
  final width = media?.size.width ?? 0;
  final safeBottom = media?.padding.bottom ?? 0;
  final shellChrome = ShellChromeMetrics.contentStackBottomChromeHeight(
        useBottomNav:
            width > 0 && width < ShellChromeMetrics.shellLayoutBreakpoint,
      ) +
      safeBottom;
  final lift = declared > shellChrome ? declared : shellChrome;
  // Right-aligned on a wide window, where the toast column already lives;
  // full width minus the framework's own 15 px inset on a narrow one.
  final left = width - _maxSnackBarWidth - 15 > 15
      ? width - _maxSnackBarWidth - 15
      : 15.0;
  // Mirrors the framework's own floating-snackbar margin, plus the chrome.
  return EdgeInsets.fromLTRB(left, 5, 15, 10 + lift);
}
