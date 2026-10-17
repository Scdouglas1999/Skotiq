import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// One side-panel status row: `[dot] [title] [detail] [secondary sm action]`.
///
/// The shape 06 §Equipment gives the Readiness blockers, reused by System
/// health's insights so the two sections read as one list rather than two
/// invented layouts.
class EquipmentBlockerRow extends StatelessWidget {
  /// The status colour of the leading dot.
  final Color toneColor;

  /// The row's headline — one short noun phrase.
  final String title;

  /// One line saying what the state is and what to do about it.
  final String? detail;

  /// At most one `secondary sm` button, rendered under the detail.
  final Widget? action;

  /// A trailing control (a dismiss button, a count chip).
  final Widget? trailing;

  /// Whether to draw the hairline under the row. False on the last row.
  final bool showDivider;

  const EquipmentBlockerRow({
    super.key,
    required this.toneColor,
    required this.title,
    this.detail,
    this.action,
    this.trailing,
    this.showDivider = true,
  });

  /// Vertical padding, matching the mockup's 10 px rows.
  static const double verticalPadding = 10.0;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: verticalPadding),
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.border)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs + 1),
            child: StatusDot(color: toneColor),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail!,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                if (action != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Align(alignment: Alignment.centerLeft, child: action!),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            trailing!,
          ],
        ],
      ),
    );
  }
}
