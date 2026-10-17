import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Shown in place of the palette's category list when a search matches nothing.
///
/// Without it the palette body is simply empty, and an empty body is
/// ambiguous: the operator cannot tell whether the search misfired, the
/// palette failed to load, or the node genuinely does not exist. All three
/// palette surfaces (toolbox tab, desktop sidebar, mobile sheet) render this.
class NodePaletteEmptyState extends StatelessWidget {
  final SkotiqColors colors;

  /// The raw query, echoed back so the operator can see exactly what was
  /// searched for (trailing spaces and typos included).
  final String query;

  final VoidCallback onClear;

  const NodePaletteEmptyState({
    super.key,
    required this.colors,
    required this.query,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.searchX, size: 28, color: colors.textMuted),
            const SizedBox(height: 12),
            Text(
              'No nodes match "${query.trim()}"',
              textAlign: TextAlign.center,
              style: SkotiqTypography.label.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Try a shorter term, or clear the search to browse every '
              'category.',
              textAlign: TextAlign.center,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 12),
            SkotiqButton(
              label: 'Clear search',
              icon: LucideIcons.x,
              onPressed: onClear,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
          ],
        ),
      ),
    );
  }
}
