import 'package:flutter/widgets.dart';

import 'hold_to_confirm_button.dart';

/// A run's Stop: held to confirm, so a stray tap never ends a night's run.
///
/// [face] draws the control as it looks, given the press it shows (null
/// when [enabled] is false). The hold owns every pointer gesture, and
/// [onConfirmed] fires when the hold completes.
class HoldToStop extends StatelessWidget {
  const HoldToStop({
    super.key,
    required this.enabled,
    required this.onConfirmed,
    required this.holdColor,
    required this.confirmText,
    required this.semanticsLabel,
    required this.face,
    this.faceSemantics = false,
  });

  final bool enabled;
  final VoidCallback onConfirmed;
  final Color holdColor;

  /// Shown when a press is too short to be a hold ("Hold to stop").
  final String confirmText;

  /// What a screen reader announces for the control.
  final String semanticsLabel;

  final Widget Function(VoidCallback? onPressed) face;

  /// The face keeps its own semantics under the hold's, and its press (a
  /// screen reader's or a key's) stops at once. Otherwise the face is
  /// drawn only and its press does nothing.
  final bool faceSemantics;

  static void _drawnOnly() {}

  @override
  Widget build(BuildContext context) {
    final drawn = face(
      !enabled
          ? null
          : faceSemantics
          ? onConfirmed
          : _drawnOnly,
    );
    return HoldToConfirmButton(
      enabled: enabled,
      holdColor: holdColor,
      confirmText: confirmText,
      semanticsLabel: semanticsLabel,
      onConfirmed: onConfirmed,
      child: IgnorePointer(
        child: faceSemantics ? drawn : ExcludeSemantics(child: drawn),
      ),
    );
  }
}
