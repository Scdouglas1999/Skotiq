import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../localization/skotiq_localizations.dart';

/// The label a frame list shows for a frame the run's frame watch excluded.
String frameExclusionLabel(BuildContext context, FrameExclusionKind kind) =>
    switch (kind) {
      FrameExclusionKind.offTarget => context.l10n.text('frameOffTarget'),
      FrameExclusionKind.obstructed => context.l10n.text('frameObstructed'),
    };

IconData frameExclusionIcon(FrameExclusionKind kind) => switch (kind) {
      FrameExclusionKind.offTarget => LucideIcons.crosshair,
      FrameExclusionKind.obstructed => LucideIcons.mountain,
    };

/// Marks a frame the run's frame watch excluded: "Off target" when its solved
/// center was too far from the target, "Obstructed" when it was taken through
/// trees or a roof. Nothing for any other frame.
///
/// [compact] draws the icon alone, for tiles too narrow for the words; the
/// label is then its tooltip and semantics.
class FrameExclusionBadge extends StatelessWidget {
  const FrameExclusionBadge({
    super.key,
    required this.kind,
    this.compact = false,
  });

  /// The badge for a frame's stored rejection reason.
  FrameExclusionBadge.forReason(
    String? rejectionReason, {
    Key? key,
    bool compact = false,
  }) : this(
          key: key,
          kind: frameExclusionKindOf(rejectionReason),
          compact: compact,
        );

  final FrameExclusionKind? kind;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final kind = this.kind;
    if (kind == null) return const SizedBox.shrink();
    final label = frameExclusionLabel(context, kind);
    final icon = frameExclusionIcon(kind);
    if (!compact) {
      return SkotiqChip(label: label, icon: icon, tone: ChipTone.warning);
    }
    final colors = context.skotiqColors;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        child: Container(
          width: SkotiqChip.height,
          height: SkotiqChip.height,
          // Opaque, so the tint reads the same over any thumbnail.
          decoration: SkotiqDecorations.chip(colors).copyWith(
            color: Color.alphaBlend(
              colors.warning.withValues(alpha: SkotiqTokens.opacityStatusFill),
              colors.surface,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: SkotiqTokens.iconXs, color: colors.warning),
        ),
      ),
    );
  }
}
