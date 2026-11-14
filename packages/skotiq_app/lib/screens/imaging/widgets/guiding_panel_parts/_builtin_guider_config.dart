// Built-in guider configuration section.
part of '../guiding_panel.dart';

/// Collapsible configuration panel for the built-in multi-star guider.
/// Only displayed when the built-in guider is the active guider device.
class _BuiltinGuiderConfigSection extends StatelessWidget {
  final SkotiqColors colors;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _BuiltinGuiderConfigSection({
    required this.colors,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onToggle,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              children: [
                Icon(
                  isExpanded
                      ? SkotiqIcons.chevronDown
                      : SkotiqIcons.chevronRight,
                  size: 14,
                  color: colors.textPrimary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Guider Configuration',
                  style:
                      SkotiqTypography.h6.copyWith(color: colors.textPrimary),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: SkotiqDecorations.tintedBadge(
                    colors.primary,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    'Built-in',
                    style: SkotiqTypography.caption.copyWith(
                        fontWeight: FontWeight.w600, color: colors.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded) ...[
          const SizedBox(height: 12),
          SkotiqCard(
            padding: const EdgeInsets.all(14),
            borderRadius: SkotiqTokens.radiusLg,
            child: const BuiltinGuiderConfigForm(),
          ),
        ],
      ],
    );
  }
}
