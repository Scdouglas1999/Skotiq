import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../your_sky/sky_atlas_format.dart';
import '../constellation_ui_providers.dart';
import 'contribution_bar.dart';

/// A browse-list card for one shared community target: its name and coordinates,
/// the fused swarm depth + contributor count, and — once your local atlas
/// overlaps it — your personal contribution bar. Tapping opens the detail.
class SharedTargetCard extends ConsumerWidget {
  final SharedTarget target;
  final VoidCallback onTap;

  const SharedTargetCard({
    super.key,
    required this.target,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final yourSecondsAsync = ref.watch(
      yourContributionSecondsProvider(target),
    );
    final yourSeconds = yourSecondsAsync.valueOrNull ?? 0.0;

    return SkotiqCard(
      enableHover: true,
      onTap: onTap,
      padding: SkotiqTokens.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                decoration:
                    SkotiqDecorations.chip(colors, tone: colors.accent),
                child: Icon(
                  LucideIcons.users,
                  size: SkotiqTokens.iconSm,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.name.isEmpty
                          ? 'Target #${target.targetId}'
                          : target.name,
                      style: SkotiqTypography.labelStrong.copyWith(
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatCenter(target.raDeg, target.decDeg),
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: SkotiqTokens.iconSm,
                color: colors.textMuted,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          ResponsiveStatStrip(
            minCellWidth: 110,
            stats: [
              ResponsiveStat(
                label: 'FUSED',
                value: formatIntegration(target.integrationSeconds),
                icon: LucideIcons.layers,
              ),
              ResponsiveStat(
                label: 'IMAGERS',
                value: '${target.contributors}',
                icon: LucideIcons.users,
              ),
            ],
          ),
          if (yourSeconds > 0) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            ContributionBar(
              yourSeconds: yourSeconds,
              swarmSeconds: target.integrationSeconds,
            ),
          ],
        ],
      ),
    );
  }
}
