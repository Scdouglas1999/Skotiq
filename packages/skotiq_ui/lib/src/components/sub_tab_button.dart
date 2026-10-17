// The class in this file is itself deprecated; its own state class and
// constructor references are not separate mistakes.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// The pre-overhaul pill sub-tab.
///
/// 05 §4 replaces it: a second-level switch inside a panel is a
/// [SegmentedControl], and a switch in a page header is an [AdaptiveTabBar].
/// It has no call sites in `skotiq_app` and is deleted in wave 4 — it
/// stays only because the `design_system_gallery_missing` audit rule still
/// requires its marker in the gallery and the gallery test (see
/// `tools/production/ui_consistency_audit.dart`, which wave 0 owns).
@Deprecated('Use SegmentedControl or AdaptiveTabBar. Removed in wave 4.')
class SubTabButton extends StatefulWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const SubTabButton({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<SubTabButton> createState() => _SubTabButtonState();
}

class _SubTabButtonState extends State<SubTabButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    final backgroundColor = widget.isSelected
        ? Color.alphaBlend(
            colors.primary.withValues(alpha: 0.06),
            colors.surfaceAlt,
          )
        : _isHovered
        ? colors.surfaceHover
        : Colors.transparent;

    final borderColor = widget.isSelected
        ? colors.primary.withValues(alpha: 0.45)
        : _isHovered
        ? colors.borderHighlight.withValues(alpha: 0.85)
        : Colors.transparent;

    return Semantics(
      // Semantics publishes isEnabled only when this field is given;
      // omitting it makes assistive tech announce a live control as
      // disabled. Measured on the running app 2026-08-09.
      enabled: true,
      button: true,
      selected: widget.isSelected,
      label: widget.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: SkotiqTokens.durationQuick,
          curve: SkotiqTokens.curveSnappy,
          margin: const EdgeInsets.only(top: 4, bottom: 4, right: 4),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: SkotiqTokens.borderRadiusMd,
            border: Border.all(color: borderColor),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              hoverColor: Colors.transparent,
              highlightColor: colors.primary.withValues(alpha: 0.06),
              splashColor: colors.primary.withValues(alpha: 0.06),
              borderRadius: SkotiqTokens.borderRadiusMd,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceMd + 2,
                  vertical: SkotiqTokens.spaceSm - 2,
                ),
                child: Text(
                  widget.label,
                  style: SkotiqTypography.labelSm.copyWith(
                    fontWeight: widget.isSelected
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: widget.isSelected
                        ? colors.primary
                        : _isHovered
                        ? colors.textPrimary
                        : colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
