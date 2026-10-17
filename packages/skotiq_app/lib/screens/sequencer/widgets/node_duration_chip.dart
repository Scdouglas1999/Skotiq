import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Small muted "~2h 14m" chip rendered next to container node rows
/// (Loop / Target / Parallel / Sequential).
///
/// Watches [nodeRollupDurationProvider] keyed by node id so the chip only
/// rebuilds when the cached rollup actually changes; everything else in
/// the tree row stays put when the user types in an exposure field.
class NodeDurationChip extends ConsumerWidget {
  const NodeDurationChip({
    super.key,
    required this.nodeId,
    required this.colors,
    this.compact = false,
  });

  final String nodeId;
  final SkotiqColors colors;

  /// `true` for the tighter target-header layout; drops the icon and uses
  /// a slightly smaller font. Mobile rows pass `compact: true`.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = ref.watch(nodeRollupDurationProvider(nodeId));
    // Don't draw anything for empty / zero-duration containers — the chip
    // would just read "<1s" which is noise.
    if (duration.inSeconds <= 0) return const SizedBox.shrink();

    final text = formatRollupDuration(duration);
    final fontSize = compact ? 10.0 : 11.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact) ...[
          Icon(
            LucideIcons.clock,
            size: 10,
            color: colors.textMuted,
          ),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            color: colors.textMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
