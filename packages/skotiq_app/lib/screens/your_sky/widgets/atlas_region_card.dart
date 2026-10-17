import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../sky_atlas_format.dart';
import 'atlas_region_cutout.dart';

/// One region in the Your Sky gallery: a deep co-added preview, the region name
/// + kind, its centre, and the depth / growth rollups. Tapping opens the region
/// detail (cutout + time-scrub).
///
/// The preview renders the region's co-added cone via [AtlasRegionCutout], which
/// is portable across backends (host file path / remote PNG bytes), so the
/// gallery thumbnail renders on a slave instead of reading an empty local store.
class AtlasRegionCard extends ConsumerWidget {
  final SkyAtlasRegionRow region;
  final VoidCallback onTap;

  const AtlasRegionCard({
    super.key,
    required this.region,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final tilesAsync = ref.watch(atlasRegionTilesProvider(region.id));
    final timelineAsync = ref.watch(atlasRegionTimelineProvider(region.id));

    return SkotiqCard(
      onTap: onTap,
      enableHover: true,
      padding: EdgeInsets.zero,
      borderRadius: SkotiqTokens.radiusLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(SkotiqTokens.radiusLg),
            ),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: tilesAsync.when(
                data: (tiles) => tiles.isEmpty
                    ? _PreviewPlaceholder(colors: colors)
                    : AtlasRegionCutout(regionId: region.id),
                loading: () =>
                    _PreviewPlaceholder(colors: colors, loading: true),
                error: (_, __) => _PreviewPlaceholder(colors: colors),
              ),
            ),
          ),
          Padding(
            padding: SkotiqTokens.cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        region.name,
                        style: SkotiqTypography.bodyStrong
                            .copyWith(color: colors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    _KindBadge(kind: region.kind),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  formatCenter(region.centerRaDeg, region.centerDecDeg),
                  style: SkotiqTypography.monoSm
                      .copyWith(color: colors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                Row(
                  children: [
                    _Pill(
                      icon: LucideIcons.clock,
                      label: formatIntegration(region.integrationSeconds),
                      colors: colors,
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    _Pill(
                      icon: LucideIcons.layoutGrid,
                      label:
                          '${region.tileCount} tile${region.tileCount == 1 ? '' : 's'}',
                      colors: colors,
                    ),
                  ],
                ),
                timelineAsync.maybeWhen(
                  data: (folds) {
                    final phrase = _growthPhrase(folds);
                    if (phrase == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
                      child: Row(
                        children: [
                          Icon(LucideIcons.trendingUp,
                              size: SkotiqTokens.iconSm, color: colors.success),
                          const SizedBox(width: SkotiqTokens.spaceXs),
                          Expanded(
                            child: Text(
                              phrase,
                              style: SkotiqTypography.captionSm
                                  .copyWith(color: colors.success),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A day-over-day "deeper than" phrase from the fold timeline: the integration
  /// gained on the most recent imaging day versus what existed before it. This
  /// is the "4h deeper than yesterday" headline. Returns null when the region
  /// has been touched on a single day (nothing comparative to say).
  String? _growthPhrase(List<SkyAtlasFoldRow> folds) {
    if (folds.isEmpty) return null;

    // Bucket the per-fold integration by UTC calendar day.
    final byDay = <int, double>{};
    for (final fold in folds) {
      final utc = fold.foldedAt.toUtc();
      final dayKey = utc.year * 10000 + utc.month * 100 + utc.day;
      byDay[dayKey] = (byDay[dayKey] ?? 0) + fold.integrationSecondsAdded;
    }
    final days = byDay.keys.toList()..sort();
    final latestDay = days.last;
    final recent = byDay[latestDay] ?? 0;
    if (recent <= 0) return null;

    final priorTotal = [
      for (final d in days)
        if (d != latestDay) byDay[d] ?? 0,
    ].fold<double>(0, (a, b) => a + b);

    if (days.length == 1) {
      return formatGrowthDelta(recentSeconds: recent, priorSeconds: 0);
    }
    return formatGrowthDelta(
      recentSeconds: recent,
      priorSeconds: priorTotal,
      period: 'before tonight',
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  final SkotiqColors colors;
  final bool loading;

  const _PreviewPlaceholder({required this.colors, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.well,
      alignment: Alignment.center,
      child: loading
          ? const SkotiqCircularProgress(
              value: 0,
              indeterminate: true,
              size: SkotiqTokens.iconLg,
            )
          : Icon(LucideIcons.orbit,
              size: SkotiqTokens.iconLg, color: colors.textMuted),
    );
  }
}

class _KindBadge extends StatelessWidget {
  final String kind;

  const _KindBadge({required this.kind});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final tint = switch (kind) {
      'target' => colors.primary,
      'mosaic' => colors.info,
      'polar' => colors.warning,
      _ => colors.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: 2,
      ),
      decoration: SkotiqDecorations.chip(colors, tone: tint),
      child: Text(
        _label(kind),
        style: SkotiqTypography.captionSm.copyWith(color: tint),
      ),
    );
  }

  static String _label(String kind) => switch (kind) {
        'target' => 'Target',
        'mosaic' => 'Mosaic',
        'polar' => 'Polar',
        'custom' => 'Custom',
        _ => kind.isEmpty ? 'Region' : kind,
      };
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;

  const _Pill({required this.icon, required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusInline8,
        border: Border.all(color: colors.border.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: SkotiqTokens.iconSm, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            label,
            style: SkotiqTypography.captionSm
                .copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
