part of '../preflight_validation_dialog.dart';

/// The dialog's ONE primary: a [SkotiqButton] on the `start` face.
///
/// It is a real button rather than a hand-rolled box, so the fill, the radius,
/// the disabled dimming, the focus ring and keyboard activation all come from
/// the design system. What stays local is the REFUSAL:
///
///  * the reason travels into the accessible NAME via [GatedAction.announce],
///    because a disabled control whose name reads exactly like the enabled one
///    is indistinguishable from it in a tree dump — the blocked dialog probed
///    as a plain `button: Start sequence` beside its live siblings;
///  * it travels onto the pointer as a tooltip;
///  * and the button's own label node is excluded so the name is published
///    once. Left to merge, the annotation and the visible label concatenate
///    and the node announces itself twice.
class _StartSequenceButton extends StatelessWidget {
  final bool canStart;
  final bool hasWarningsOnly;
  final VoidCallback? onPressed;

  /// Why the run cannot start, or null when it can.
  final String? blockedReason;

  const _StartSequenceButton({
    required this.canStart,
    required this.hasWarningsOnly,
    this.blockedReason,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final label = hasWarningsOnly ? 'Start anyway' : 'Start sequence';
    final reason = blockedReason;

    final Widget button = SkotiqButton(
      label: label,
      icon: canStart ? SkotiqIcons.play : SkotiqIcons.warning,
      variant: ButtonVariant.start,
      onPressed: onPressed,
      semanticsHint: reason,
    );

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: GatedAction.announce(label, reason),
      // Null when blocked, so the node advertises no tap action: a disabled
      // primary that still offers one reads as live to the platform bridge.
      onTap: onPressed,
      child: ExcludeSemantics(
        child: reason == null
            ? button
            : SkotiqTooltip(message: reason, child: button),
      ),
    );
  }
}
