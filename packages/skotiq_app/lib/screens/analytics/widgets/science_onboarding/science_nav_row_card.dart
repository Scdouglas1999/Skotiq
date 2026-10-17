import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class ScienceNavRowCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final Color labelColor;
  final VoidCallback onTap;

  const ScienceNavRowCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.labelColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceMd,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: SkotiqTokens.minTouchTarget,
        ),
        child: Row(
          children: [
            Icon(icon, size: SkotiqTokens.iconSm, color: iconColor),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Text(
                label,
                style: SkotiqTypography.bodySm.copyWith(
                  color: labelColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              LucideIcons.chevronRight,
              size: SkotiqTokens.iconXs,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}
