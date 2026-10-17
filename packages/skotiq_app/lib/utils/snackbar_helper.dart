import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../models/command_action_result.dart';
import 'transient_bottom_inset.dart';

/// Extension on BuildContext providing convenient SnackBar display methods.
///
/// All methods check `mounted` before showing to prevent errors when
/// the widget has been disposed.
///
/// Snackbars are floating (see the app theme), so they are anchored to the
/// bottom of the enclosing [Scaffold] and would otherwise be drawn straight
/// over a screen's own bottom bar. [TransientBottomInset] lets a screen declare
/// the height it needs kept clear — on the Imaging screen that is the
/// Snapshot / Loop / Duration strip — and every helper here honours it.
extension SnackBarHelper on BuildContext {
  /// Widest a snackbar is allowed to be.
  ///
  /// A floating snackbar with no margin spans the whole Scaffold: at 1600 px
  /// that is a 1600 px bar across the window bottom. Matched to the toast
  /// overlay's own column so routine feedback reads as one surface wherever it
  /// comes from.
  static const double _maxSnackBarWidth = 520.0;

  /// Margin that keeps a floating snackbar off the chrome it would otherwise
  /// paint over, and stops it spanning the whole window.
  ///
  /// Two things sit under a snackbar anchored to the shell Scaffold's bottom:
  /// the screen's own bottom bar, when it declares one via
  /// [TransientBottomInset], and the shell's global status bar, which nothing
  /// declared. So a routine "Glance mode on" toast blanked the connection
  /// chips, the save path and the clock — the one strip an operator glances at
  /// — for its whole lifetime, full-bleed across the window.
  ///
  /// The declared inset is measured from the bar's top edge to the bottom of
  /// the WINDOW, so it already covers the status bar; take the larger of the
  /// two rather than adding them.
  EdgeInsetsGeometry? get _snackBarMargin {
    // A margin is only legal on a floating snackbar — the framework asserts
    // otherwise. The app theme is floating everywhere, but a host that has not
    // installed it (a bare MaterialApp in a test, an embedded surface) must
    // still get a snackbar rather than an assertion.
    if (Theme.of(this).snackBarTheme.behavior != SnackBarBehavior.floating) {
      return null;
    }
    final declared = TransientBottomInset.of(this);
    final media = MediaQuery.maybeOf(this);
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

  /// Shows an error SnackBar with red background.
  void showErrorSnackBar(String message, {Duration? duration}) {
    if (!mounted) return;
    final colors = SkotiqColors.of(this);
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: colors.error,
        margin: _snackBarMargin,
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  /// Shows a success SnackBar with green background.
  void showSuccessSnackBar(String message, {Duration? duration}) {
    if (!mounted) return;
    final colors = SkotiqColors.of(this);
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: colors.success,
        margin: _snackBarMargin,
        duration: duration ?? const Duration(seconds: 3),
      ),
    );
  }

  /// Shows a warning SnackBar with amber/yellow background.
  void showWarningSnackBar(String message, {Duration? duration}) {
    if (!mounted) return;
    final colors = SkotiqColors.of(this);
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: colors.warning,
        margin: _snackBarMargin,
        duration: duration ?? const Duration(seconds: 3),
      ),
    );
  }

  /// Shows an info SnackBar with default background.
  void showInfoSnackBar(String message, {Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        margin: _snackBarMargin,
        duration: duration ?? const Duration(seconds: 2),
      ),
    );
  }

  /// Shows user feedback for a command result when it has a message payload.
  void showCommandActionResult(CommandActionResult result,
      {Duration? duration}) {
    if (!result.hasMessage) return;
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
}
