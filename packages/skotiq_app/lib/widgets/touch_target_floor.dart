import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Floors an interactive child's hit-testable box at the platform touch
/// minimum, while leaving the child PAINTED at its own (usually smaller) size.
///
/// Why this exists: several controls set an explicit `width`/`height` on the
/// box inside their `InkWell`/`GestureDetector`, which makes the visual size and
/// the touch size the same thing. Measured against Flutter's
/// `androidTapTargetGuideline`, that left real controls under the 48dp minimum
/// (e.g. the dashboard's Glance-mode toggle at 36.0x36.0 on every phone width).
/// Material's own `IconButton` avoids this by padding a 24dp icon out to 48dp;
/// this widget applies the same separation to bespoke controls.
///
/// The floor itself comes from [SkotiqTouchTarget], so this widget and
/// every other platform-aware control agree on one number. Grows on touch
/// platforms only, so dense desktop panels do not reflow for an imprecision a
/// mouse does not have.
class TouchTargetFloor extends StatelessWidget {
  final Widget child;

  /// Override the floor. Defaults to [SkotiqTokens.minTouchTarget] (48).
  final double? extent;

  const TouchTargetFloor({super.key, required this.child, this.extent});

  static double floorFor(BuildContext context, {double? extent}) {
    final platformFloor = SkotiqTouchTarget.minExtent(context);
    if (platformFloor == 0.0) return 0.0;
    return extent ?? platformFloor;
  }

  @override
  Widget build(BuildContext context) {
    final floor = floorFor(context, extent: extent);
    if (floor == 0.0) return child;
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: floor, minHeight: floor),
      child: Center(child: child),
    );
  }
}
