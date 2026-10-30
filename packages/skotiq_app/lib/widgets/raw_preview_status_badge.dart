import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Badge for progressive capture preview (JPEG first, raw/HQ in background).
class RawPreviewStatusBadge extends StatelessWidget {
  final RawLoadStatus status;
  final SkotiqColors colors;

  const RawPreviewStatusBadge({
    super.key,
    required this.status,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (status) {
      RawLoadStatus.loading => (
          'Loading HQ…',
          colors.surface,
          colors.textSecondary,
        ),
      RawLoadStatus.ready => (
          'HQ ready',
          colors.accent.withValues(alpha: 0.9),
          colors.onPrimary,
        ),
      RawLoadStatus.failed => (
          'Preview only',
          colors.surface,
          colors.warning,
        ),
      RawLoadStatus.idle => (null, colors.surface, colors.textMuted),
    };
    if (label == null) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: SkotiqTypography.fontSize10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
