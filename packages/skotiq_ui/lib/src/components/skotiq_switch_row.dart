import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import 'skotiq_switch.dart';
import 'skotiq_tooltip.dart';

/// Label + [SkotiqSwitch] row for settings and imaging panels.
///
/// Use [expanded: true] (default) for full-width rows: label left, switch right.
/// Use [expanded: false] for compact inline toolbars.
///
/// Does not include a leading icon — for icon + title + subtitle rows in the
/// settings app, compose [SettingRow] with [SettingsSwitch] as the trailing
/// widget instead.
class SkotiqSwitchRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final String? tooltip;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final bool compact;
  final bool expanded;
  final TextStyle? labelStyle;
  final TextStyle? subtitleStyle;

  const SkotiqSwitchRow({
    super.key,
    required this.label,
    this.subtitle,
    this.tooltip,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.compact = false,
    this.expanded = true,
    this.labelStyle,
    this.subtitleStyle,
  });

  bool get _switchEnabled => enabled && onChanged != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final labelWidget = _buildLabel(colors);

    // The label is a sibling of the switch, so assistive tech announced
    // "toggle button, on" with no idea which setting it belonged to. Naming
    // the switch node is what ties the two together; `container: false` (the
    // default) merges the name into the switch's own node rather than adding
    // a second one.
    final switchWidget = Semantics(
      label: label,
      child: SkotiqSwitch(
        value: value,
        onChanged: onChanged,
        enabled: _switchEnabled,
        compact: compact,
      ),
    );

    if (!expanded) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          labelWidget,
          SizedBox(
            width: compact ? SkotiqTokens.spaceXs : SkotiqTokens.spaceSm,
          ),
          switchWidget,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: labelWidget),
        const SizedBox(width: SkotiqTokens.spaceMd),
        switchWidget,
      ],
    );
  }

  Widget _buildLabel(SkotiqColors colors) {
    final effectiveLabelStyle =
        labelStyle ??
        SkotiqTypography.bodySm.copyWith(
          color: colors.textSecondary,
          fontSize: compact ? 12 : null,
        );
    final effectiveSubtitleStyle =
        subtitleStyle ??
        SkotiqTypography.caption.copyWith(color: colors.textMuted);

    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(child: Text(label, style: effectiveLabelStyle)),
        if (tooltip != null) ...[
          const SizedBox(width: SkotiqTokens.spaceXs),
          SkotiqTooltip(
            message: tooltip!,
            position: SkotiqTooltipPosition.top,
            child: Icon(
              LucideIcons.helpCircle,
              size: 12,
              color: colors.textMuted,
            ),
          ),
        ],
      ],
    );

    if (subtitle == null) {
      return titleRow;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        titleRow,
        const SizedBox(height: 2),
        Text(subtitle!, style: effectiveSubtitleStyle),
      ],
    );
  }
}
