import 'package:flutter/material.dart';
import 'package:skotiq_design/skotiq_design.dart';

/// A container for grouped controls with tonal separation.
class SectionWell extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final BorderRadius? borderRadius;

  const SectionWell({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(SkotiqTokens.spaceLg),
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final effectiveRadius = borderRadius ?? SkotiqTokens.borderRadiusMd;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: effectiveRadius,
        border: Border.all(color: colors.border.withValues(alpha: 0.65)),
      ),
      child: child,
    );
  }
}
