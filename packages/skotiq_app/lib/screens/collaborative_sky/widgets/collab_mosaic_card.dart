import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../mosaic/mosaic_format.dart';
import '../../your_sky/sky_atlas_format.dart';
import '../collaborative_sky_format.dart';

/// A card for one collaborative mosaic: a panel grid published to the hub
/// whose panels are claimable distributed work items, captured in parallel by a
/// club's rigs and fused centrally by the owner.
///
/// Surfaces the live combined progress (panels uploaded / total), the lifecycle
/// status (open → assembling → complete), and the contributor attribution that
/// makes the finished mosaic credit everyone. Tapping opens the panel detail.
///
/// Purely presentational; pass a [mosaic] with its `panels` populated (from the
/// detail GET) for real per-panel progress — it degrades to the grid dimensions
/// when only the cheap list payload is available. Pass [attribution] (the hub's
/// `GET /v1/attribution` result) to credit contributors from the authoritative,
/// consent-aware source; it degrades to the embedded owner/panel names when that
/// is not yet loaded.
class CollabMosaicCard extends StatelessWidget {
  final CollabMosaic mosaic;

  /// The hub's authoritative contributor credits for this mosaic, or null while
  /// they load (the card then falls back to the embedded owner/panel names).
  final ArtifactAttribution? attribution;
  final VoidCallback onView;

  const CollabMosaicCard({
    super.key,
    required this.mosaic,
    this.attribution,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final total = mosaic.panels.isNotEmpty
        ? mosaic.panels.length
        : mosaic.rows * mosaic.cols;
    final uploaded = mosaic.isComplete
        ? total
        : mosaic.panels.where((p) => p.uploaded).length;
    final fraction = mosaicCompletionFraction(uploaded: uploaded, total: total);

    final credits = mosaicContributorCredits(mosaic, attribution: attribution);

    return SkotiqCard(
      enableHover: true,
      onTap: onView,
      padding: SkotiqTokens.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                decoration:
                    SkotiqDecorations.chip(colors, tone: colors.primary),
                child: Icon(
                  LucideIcons.grid,
                  size: SkotiqTokens.iconSm,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mosaic.name.isEmpty ? 'Mosaic' : mosaic.name,
                      style: SkotiqTypography.labelStrong.copyWith(
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatMosaicGrid(cols: mosaic.cols, rows: mosaic.rows)}'
                      ' · ${formatCenter(mosaic.centerRaDeg, mosaic.centerDecDeg)}',
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              StatusPill(
                icon: _statusIcon(mosaic.status),
                label: '',
                value: formatMosaicStatus(mosaic.status),
                status: _statusVariant(mosaic.status),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqProgressBar(
            value: fraction,
            state: mosaic.isComplete
                ? SkotiqProgressState.success
                : SkotiqProgressState.normal,
            label: 'Panels captured',
            indeterminate: mosaic.isAssembling,
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            mosaic.isAssembling
                ? 'All panels in — the owner is stitching the mosaic'
                : formatPanelProgress(uploaded: uploaded, total: total),
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Row(
            children: [
              Icon(
                LucideIcons.users,
                size: SkotiqTokens.iconXs,
                color: colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  credits,
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqButton(
                label: mosaic.isComplete ? 'View mosaic' : 'View panels',
                icon: LucideIcons.chevronRight,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: onView,
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'complete':
        return LucideIcons.checkCircle2;
      case 'assembling':
        return LucideIcons.loader;
      default:
        return LucideIcons.grid;
    }
  }

  StatusPillStatus _statusVariant(String status) {
    switch (status) {
      case 'complete':
        return StatusPillStatus.success;
      case 'assembling':
        return StatusPillStatus.warning;
      default:
        return StatusPillStatus.active;
    }
  }
}
