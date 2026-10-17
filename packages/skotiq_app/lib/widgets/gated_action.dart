import 'package:flutter/material.dart';

/// Wraps an action control that is currently unavailable so the REASON travels
/// with it — into the accessibility tree, not just into a hover tooltip.
///
/// `onPressed: null` plus an inline reason is not enough. A disabled control
/// whose accessible NAME still reads exactly like the enabled one is
/// indistinguishable in a tree dump from a live control: both read as "a plain
/// `button: X` with no `[DISABLED]`", and a click on either produces no
/// snackbar, no inline error, no log line.
///
/// So when [blockedReason] is non-null the announced name becomes
/// `"<label> — unavailable: <reason>"`. That single string is the discriminator:
///
///   * a dump that shows the bare label proves the gate did not apply (the
///     control really is live, and an inert click is a different defect);
///   * a dump that shows the reason proves this build is the one running, so a
///     "still broken" report cannot be a stale-binary artifact.
///
/// It changes no pixels: `Semantics` here only annotates.
class GatedAction extends StatelessWidget {
  /// The control's visible label, repeated here because a disabled child's own
  /// semantics may carry no usable name of its own.
  final String label;

  /// Why the action cannot run right now, or null when it can. Phrased as a
  /// sentence fragment ("panel size unknown, so …") — it is appended after
  /// "unavailable:".
  final String? blockedReason;

  final Widget child;

  const GatedAction({
    super.key,
    required this.label,
    required this.blockedReason,
    required this.child,
  });

  /// The accessible name for [label] given [blockedReason]. Public so the
  /// pin-tests assert the exact string a screen reader (and the audit harness)
  /// will read.
  static String announce(String label, String? blockedReason) =>
      blockedReason == null ? label : '$label — unavailable: $blockedReason';

  @override
  Widget build(BuildContext context) {
    final reason = blockedReason;
    if (reason == null) return child;
    return Semantics(
      button: true,
      enabled: false,
      label: announce(label, reason),
      child: ExcludeSemantics(child: child),
    );
  }
}
