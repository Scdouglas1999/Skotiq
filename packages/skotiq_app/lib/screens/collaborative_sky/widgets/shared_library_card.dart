import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../collaborative_sky_providers.dart';

/// A summary card for the shared calibration library: pull a sensor-matched
/// master another member shared instead of re-shooting your own darks, with
/// provenance + consent gating so you trust what you pull.
///
/// Surfaces this rig's participation — masters shared out vs masters pulled in —
/// and links to the full calibration library where the matcher folds remote
/// candidates into the local ranking. Purely presentational.
class SharedLibraryCard extends StatelessWidget {
  final SharedLibrarySummary summary;

  /// Opens the calibration library (where shared masters are matched, pulled,
  /// and published).
  final VoidCallback onOpen;

  const SharedLibraryCard({
    super.key,
    required this.summary,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                  decoration: SkotiqDecorations.chip(colors, tone: colors.info),
                  child: Icon(
                    LucideIcons.library,
                    size: SkotiqTokens.iconSm,
                    color: colors.info,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Shared calibration library',
                        style: SkotiqTypography.labelStrong.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        summary.isEmpty
                            ? 'Never shoot the same dark twice — pull a '
                                'sensor-matched master a member already shot.'
                            : 'Sensor-matched masters, shared with provenance and '
                                'consent so you trust what you pull.',
                        style: SkotiqTypography.captionSm.copyWith(
                          color: colors.textMuted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            ResponsiveStatStrip(
              minCellWidth: 120,
              stats: [
                ResponsiveStat(
                  label: 'YOU SHARED',
                  value: '${summary.publishedCount}',
                  icon: LucideIcons.upload,
                ),
                ResponsiveStat(
                  label: 'YOU PULLED',
                  value: '${summary.pulledCount}',
                  icon: LucideIcons.download,
                  accent: summary.pulledCount > 0 ? colors.success : null,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: 'Open calibration library',
                icon: LucideIcons.library,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: onOpen,
              ),
            ),
          ],
        ));
  }
}
