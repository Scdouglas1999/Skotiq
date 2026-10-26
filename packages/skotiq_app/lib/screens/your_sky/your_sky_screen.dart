import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'region_detail_screen.dart';
import 'sky_atlas_format.dart';
import 'widgets/atlas_coverage_overlay.dart';
import 'widgets/atlas_region_card.dart';
import 'widgets/name_region_sheet.dart';

/// Pillar A ("Your Sky") — the personal growing all-sky atlas.
///
/// A top-level shell destination that shows the regions the observer has imaged
/// as deep, co-added previews, the atlas-wide growth ("4h deeper than
/// yesterday"), and a coverage heat summary. Tapping a region opens the
/// [RegionDetailScreen] with its co-added cutout and a time-scrub control.
///
/// Reads exclusively through [skyAtlasServiceProvider] and its read providers,
/// so the screen works unchanged on the desktop `FfiBackend` and the mobile
/// `NetworkBackend` (the latter resolving the same calls over the headless
/// `/api/atlas/*` routes).
class YourSkyScreen extends StatelessWidget {
  const YourSkyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: const SafeArea(
        bottom: false,
        child: YourSkyView(),
      ),
    );
  }
}

/// Scaffold-free body so the atlas can also be embedded (e.g. a dashboard tab).
class YourSkyView extends ConsumerWidget {
  const YourSkyView({super.key});

  /// Re-reads the atlas.
  ///
  /// Public because the view no longer carries a header of its own: the Plan
  /// screen's "Your sky" tab owns the one refresh button for all three
  /// discovery surfaces (06 §Plan removes the second header row).
  static void refreshYourSky(WidgetRef ref) {
    ref.invalidate(skyAtlasRegionsProvider);
    ref.invalidate(skyAtlasCoverageProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regionsAsync = ref.watch(skyAtlasRegionsProvider);
    final coverageAsync = ref.watch(skyAtlasCoverageProvider);
    final backend = ref.watch(backendProvider);
    final canNameRegions = backend is FfiBackend || backend is NetworkBackend;

    return Column(
      children: [
        Expanded(
          child: regionsAsync.when(
            data: (regions) => _buildBody(
              context,
              ref,
              regions,
              coverageAsync,
              canNameRegions,
            ),
            loading: _buildLoading,
            error: (error, _) => _buildError(ref, error),
          ),
        ),
      ],
    );
  }

  /// Counts regions, and only claims any of them are "imaged" when tiles have
  /// actually landed.
  ///
  /// Naming a patch of sky is not imaging it: a freshly created region read
  /// "1 region imaged" directly above its own card showing 0 tiles / 0s, with
  /// the atlas coverage strip on the same screen reading 0 frames.
  static String _regionsSubtitle(List<SkyAtlasRegionRow> regions) {
    final total = regions.length;
    final noun = total == 1 ? 'region' : 'regions';
    final imaged = regions.where((r) => r.tileCount > 0).length;
    if (imaged == 0) return '$total $noun · none imaged yet';
    if (imaged == total) return '$total $noun imaged';
    return '$total $noun · $imaged imaged';
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    List<SkyAtlasRegionRow> regions,
    AsyncValue<List<AtlasTileCoverage>> coverageAsync,
    bool canNameRegions,
  ) {
    final coverage = coverageAsync.valueOrNull ?? const <AtlasTileCoverage>[];

    if (regions.isEmpty && coverage.isEmpty) {
      return _buildEmpty(context, canNameRegions);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < SkotiqTokens.breakpointTablet;
        final padding = isMobile
            ? SkotiqTokens.screenPaddingCompact
            : SkotiqTokens.screenPadding;
        // Two-up region grid on wide layouts, single column on phones.
        final columns = constraints.maxWidth >= 1100
            ? 3
            : constraints.maxWidth >= SkotiqTokens.breakpointTablet
                ? 2
                : 1;

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(skyAtlasRegionsProvider);
            ref.invalidate(skyAtlasCoverageProvider);
            ref.invalidate(skyAtlasTotalsProvider);
            await ref.read(skyAtlasCoverageProvider.future);
          },
          child: ListView(
            padding: padding,
            children: [
              AtlasCoverageOverlay(
                coverage: coverage,
                totals: ref.watch(skyAtlasTotalsProvider).valueOrNull,
              ),
              const SizedBox(height: SkotiqTokens.spaceLg),
              SectionHeader(
                title: 'Regions',
                subtitle: regions.isEmpty
                    ? 'Tiles are accumulating — name a region to track its depth.'
                    : _regionsSubtitle(regions),
                trailing: canNameRegions
                    ? SkotiqButton(
                        label: 'Name a region',
                        icon: LucideIcons.plus,
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                        onPressed: () => NameRegionSheet.show(context),
                      )
                    : null,
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              if (regions.isEmpty)
                _buildNoRegionsHint(context, canNameRegions)
              else
                _RegionGrid(
                  regions: regions,
                  columns: columns,
                  onOpen: (region) => _openRegion(context, region),
                ),
              const SizedBox(height: SkotiqTokens.spaceLg),
            ],
          ),
        );
      },
    );
  }

  void _openRegion(BuildContext context, SkyAtlasRegionRow region) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RegionDetailScreen(regionId: region.id),
      ),
    );
  }

  Widget _buildNoRegionsHint(BuildContext context, bool canNameRegions) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
        padding: SkotiqTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                  decoration: SkotiqDecorations.chip(colors, tone: colors.info),
                  child: Icon(LucideIcons.info,
                      size: SkotiqTokens.iconSm, color: colors.info),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    canNameRegions
                        ? 'Your atlas is filling in tile by tile. Image a target '
                            'and it becomes a named region automatically — or '
                            'name one yourself (a target, mosaic, or polar field) '
                            'to track its depth and scrub it through time.'
                        : 'Your atlas is filling in tile by tile. Regions appear '
                            'here automatically as your host images targets.',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            if (canNameRegions) ...[
              const SizedBox(height: SkotiqTokens.spaceMd),
              Align(
                alignment: Alignment.centerLeft,
                child: SkotiqButton(
                  label: 'Name a region',
                  icon: LucideIcons.plus,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () => NameRegionSheet.show(context),
                ),
              ),
            ],
          ],
        ));
  }

  Widget _buildEmpty(BuildContext context, bool canNameRegions) {
    return ListView(
      // ListView so the empty state is still pull-to-refreshable in context.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: SkotiqTokens.screenPadding,
      children: [
        const SizedBox(height: SkotiqTokens.spaceXl),
        EmptyState(
          icon: LucideIcons.orbit,
          title: 'Your sky is dark — for now',
          body: 'Image and plate-solve a target and it folds into Your Sky '
              'automatically. Each frame deepens a permanent tile you can '
              'revisit and scrub through time.',
          action: canNameRegions
              ? SkotiqButton(
                  label: 'Name a region',
                  icon: LucideIcons.plus,
                  variant: ButtonVariant.secondary,
                  onPressed: () => NameRegionSheet.show(context),
                )
              : null,
        ),
      ],
    );
  }

  Widget _buildLoading() {
    return ShimmerLoading(
      child: ListView(
        padding: SkotiqTokens.screenPadding,
        children: const [
          SkeletonBox(
              width: double.infinity,
              height: 96,
              borderRadius: SkotiqTokens.radiusLg),
          SizedBox(height: SkotiqTokens.spaceLg),
          SkeletonBox(width: 140, height: 18),
          SizedBox(height: SkotiqTokens.spaceMd),
          SkeletonBox(
              width: double.infinity,
              height: 180,
              borderRadius: SkotiqTokens.radiusLg),
          SizedBox(height: SkotiqTokens.spaceMd),
          SkeletonBox(
              width: double.infinity,
              height: 180,
              borderRadius: SkotiqTokens.radiusLg),
        ],
      ),
    );
  }

  Widget _buildError(WidgetRef ref, Object error) {
    return EmptyState(
      icon: LucideIcons.alertCircle,
      title: 'Could not load your atlas',
      body: describeAtlasError(error),
      action: SkotiqButton(
        label: 'Retry',
        icon: SkotiqIcons.refresh,
        onPressed: () {
          ref.invalidate(skyAtlasRegionsProvider);
          ref.invalidate(skyAtlasCoverageProvider);
        },
      ),
    );
  }
}

/// Responsive region grid. Uses a [Wrap]-free column/row layout so the cards
/// keep an intrinsic height (cover preview + growth stats) without the fixed
/// aspect ratio a [GridView] would impose.
class _RegionGrid extends StatelessWidget {
  final List<SkyAtlasRegionRow> regions;
  final int columns;
  final ValueChanged<SkyAtlasRegionRow> onOpen;

  const _RegionGrid({
    required this.regions,
    required this.columns,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (columns <= 1) {
      return Column(
        children: [
          for (final region in regions)
            Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
              child: AtlasRegionCard(
                region: region,
                onTap: () => onOpen(region),
              ),
            ),
        ],
      );
    }

    final rows = <Widget>[];
    for (var i = 0; i < regions.length; i += columns) {
      final rowChildren = <Widget>[];
      for (var c = 0; c < columns; c++) {
        final index = i + c;
        if (c > 0) {
          rowChildren.add(const SizedBox(width: SkotiqTokens.spaceMd));
        }
        rowChildren.add(
          Expanded(
            child: index < regions.length
                ? AtlasRegionCard(
                    region: regions[index],
                    onTap: () => onOpen(regions[index]),
                  )
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rowChildren,
            ),
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}
