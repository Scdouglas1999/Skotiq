import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'sky_atlas_format.dart';
import 'widgets/atlas_growth_curve.dart';
import 'widgets/atlas_region_cutout.dart';
import 'widgets/atlas_timescrub.dart';

/// Injectable seam for producing a host-local region cutout.
typedef YourSkyRegionExporter = Future<RegionCutoutExport?> Function(
  int regionId,
);

/// Injectable seam for opening the platform share sheet.
typedef YourSkyRegionShare = Future<void> Function(
  String filePath, {
  required String text,
});

/// Injectable seam for arming live stacking with a region FITS.
typedef YourSkyReferenceStarter = Future<void> Function(String fitsPath);

Future<void> _shareRegionCutout(
  String filePath, {
  required String text,
}) async {
  await Share.shareXFiles([XFile(filePath)], text: text);
}

final yourSkyRegionExporterProvider = Provider<YourSkyRegionExporter>((ref) {
  return ref.read(skyAtlasServiceProvider).exportRegionCutout;
});

final yourSkyRegionShareProvider =
    Provider<YourSkyRegionShare>((ref) => _shareRegionCutout);

final yourSkyReferenceStarterProvider =
    Provider<YourSkyReferenceStarter>((ref) {
  return ref.read(liveStackingProvider.notifier).startFromFile;
});

/// The scrub anchor for the open region detail (null = latest / all folds).
final _scrubAnchorProvider =
    StateProvider.autoDispose<DateTime?>((ref) => null);

/// Region detail — the co-added cutout for a region with a time-scrub control
/// that replays how the region grew, the contributing folds, and provenance.
///
/// Backend-agnostic: every read flows through the backend-aware atlas families
/// ([atlasRegionProvider] / [atlasRegionTilesProvider] /
/// [atlasRegionTimelineProvider] / [atlasRegionCutoutProvider]), so the screen
/// renders identically on the desktop FFI backend AND a mobile network backend
/// companion — which reads the host's `/api/atlas/region/<id>[...]` routes
/// instead of its empty local atlas DB.
class RegionDetailScreen extends ConsumerWidget {
  final int regionId;

  const RegionDetailScreen({super.key, required this.regionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final regionAsync = ref.watch(atlasRegionProvider(regionId));

    // Escape has to leave. This is an opaque full-screen route that hides the
    // Plan Tonight tab bar, so its only exit was the 40 px arrow in the corner
    // — no barrier to click away, no tabs to click back to. A FocusScope (not
    // a bare Focus) so that a text field's unfocus cannot drop primary focus
    // out of the bindings' subtree and kill the shortcut for the rest of the
    // visit.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: FocusScope(
        autofocus: true,
        child: _buildScaffold(context, colors, regionAsync),
      ),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    SkotiqColors colors,
    AsyncValue<SkyAtlasRegionRow?> regionAsync,
  ) {
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: SkotiqIconButton(
          icon: LucideIcons.arrowLeft,
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          regionAsync.valueOrNull?.name ?? 'Region',
          style: SkotiqTypography.pageTitle.copyWith(
            color: colors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: regionAsync.when(
          data: (region) => region == null
              ? _missing(colors)
              : _RegionDetailBody(region: region),
          loading: () => const Center(
            child: SkotiqCircularProgress(
              value: 0,
              indeterminate: true,
              size: SkotiqTokens.iconXl,
            ),
          ),
          error: (error, _) => EmptyState(
            icon: LucideIcons.alertCircle,
            title: 'Could not load region',
            body: describeAtlasError(error),
          ),
        ),
      ),
    );
  }

  Widget _missing(SkotiqColors colors) => const EmptyState(
        icon: LucideIcons.searchX,
        title: 'Region not found',
        body: 'This region may have been removed since the gallery loaded.',
      );
}

class _RegionDetailBody extends ConsumerWidget {
  final SkyAtlasRegionRow region;

  const _RegionDetailBody({required this.region});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tilesAsync = ref.watch(atlasRegionTilesProvider(region.id));
    final timelineAsync = ref.watch(atlasRegionTimelineProvider(region.id));
    final anchor = ref.watch(_scrubAnchorProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < SkotiqTokens.breakpointTablet;
        final padding = isMobile
            ? SkotiqTokens.screenPaddingCompact
            : SkotiqTokens.screenPadding;

        final tiles = tilesAsync.valueOrNull ?? const <SkyTileRow>[];
        final folds = timelineAsync.valueOrNull ?? const <SkyAtlasFoldRow>[];

        return ListView(
          padding: padding,
          children: [
            _CutoutPanel(
              region: region,
              folds: folds,
              anchor: anchor,
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            _ScrubPanel(
              regionId: region.id,
              folds: folds,
              anchor: anchor,
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            _ChangedPanel(folds: folds, anchor: anchor),
            const SizedBox(height: SkotiqTokens.spaceLg),
            _GrowthPanel(regionId: region.id),
            const SizedBox(height: SkotiqTokens.spaceLg),
            _ProvenancePanel(region: region, tiles: tiles, folds: folds),
            const SizedBox(height: SkotiqTokens.spaceLg),
          ],
        );
      },
    );
  }
}

/// The co-added region cutout — ALWAYS the latest depth (the portable cone
/// co-add the host renders), never a per-pixel time machine the engine refuses.
///
/// HONEST SCRUB: the scrub anchor does NOT drive the cutout image. The native
/// `tilePng(asOf:)` raises whenever any fold is after the anchor (an honest
/// refusal), which would paint a broken-image icon over an "as of `<date>`"
/// badge on every past scrub stop. So the cutout fetches latest only, and an
/// honest line under it states "Showing latest depth — N of M
/// sessions by `<date>`" so the slider clearly scrubs the FRAME LIST + growth
/// below, not the hero image.
class _CutoutPanel extends ConsumerWidget {
  final SkyAtlasRegionRow region;
  final List<SkyAtlasFoldRow> folds;
  final DateTime? anchor;

  const _CutoutPanel({
    required this.region,
    required this.folds,
    required this.anchor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    // Session counts by the scrub point: distinct fold days at/before the anchor
    // out of all distinct fold days. Drives the honest depth line.
    String dayKey(DateTime d) {
      final u = d.toUtc();
      return '${u.year}-${u.month}-${u.day}';
    }

    final allDays = <String>{for (final f in folds) dayKey(f.foldedAt)};
    final shownDays = <String>{
      for (final f in folds)
        if (anchor == null || !f.foldedAt.toUtc().isAfter(anchor!.toUtc()))
          dayKey(f.foldedAt),
    };

    return SkotiqPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(SkotiqTokens.radiusLg),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // A free 3:2 preview is as tall as the pane is wide: on a
                // 1600x900 window that is ~1030px, so the coordinates, the
                // contributing-frames list and the growth chart all started
                // below the fold and the screen opened on nothing but a grey
                // rectangle. Cap it so the card's own facts stay on screen;
                // BoxFit.cover crops rather than distorts.
                final height = math.min(
                  constraints.maxWidth * 2 / 3,
                  _kCutoutMaxHeight,
                );
                return SizedBox(
                  width: double.infinity,
                  height: height,
                  child: folds.isEmpty
                      ? _EmptyCutout(colors: colors)
                      : AtlasRegionCutout(
                          regionId: region.id,
                          fit: BoxFit.cover,
                        ),
                );
              },
            ),
          ),
          Padding(
            padding: SkotiqTokens.cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.mapPin,
                        size: SkotiqTokens.iconSm, color: colors.textSecondary),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: Text(
                        '${formatCenter(region.centerRaDeg, region.centerDecDeg)}'
                        '  ·  r ${region.radiusDeg.toStringAsFixed(2)}°',
                        style: SkotiqTypography.monoSm
                            .copyWith(color: colors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (allDays.isNotEmpty) ...[
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    anchor == null
                        ? 'Showing latest depth — all ${allDays.length} '
                            'session${allDays.length == 1 ? '' : 's'}.'
                        : 'Showing latest depth — ${shownDays.length} of '
                            '${allDays.length} sessions by ${_dateLabel(anchor!)}.',
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
                ],
                if (folds.isNotEmpty) ...[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  RegionCutoutActions(region: region),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tallest the hero preview may get. Chosen so a standard 900px-high desktop
  /// window still shows the coordinate line and the start of the contributing-
  /// frames section without scrolling.
  static const double _kCutoutMaxHeight = 320;

  static String _dateLabel(DateTime instant) {
    final utc = instant.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }
}

/// What the hero preview shows before a single frame has been folded here.
///
/// Matches the parent Your Sky screen: a sentence and a next step. A bare icon
/// on flat background opens a newly created region on a viewport-filling grey
/// rectangle that says nothing about why it is empty.
class _EmptyCutout extends StatelessWidget {
  final SkotiqColors colors;

  const _EmptyCutout({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.well,
      alignment: Alignment.center,
      padding: SkotiqTokens.cardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.orbit,
            size: SkotiqTokens.iconXl,
            color: colors.textMuted,
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Nothing imaged here yet',
            textAlign: TextAlign.center,
            style: SkotiqTypography.labelStrong
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'Point a session at this patch of sky and its frames fold in here.',
            textAlign: TextAlign.center,
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Export / Share + "Use as reference frame" for a region's co-add. Export is
/// backend-agnostic (host shares the local PNG; a slave fetches PNG bytes over
/// `/api/atlas/region/<id>/cutout` and shares those). "Use as reference frame"
/// is HOST-ONLY — it co-adds the region to a photometric FITS and arms live
/// stacking against it ([LiveStackingService.startFromFile] takes a host path);
/// on a slave the button is hidden with a one-line "runs on your host" note.
class RegionCutoutActions extends ConsumerStatefulWidget {
  final SkyAtlasRegionRow region;

  const RegionCutoutActions({
    super.key,
    required this.region,
  });

  @override
  ConsumerState<RegionCutoutActions> createState() =>
      _RegionCutoutActionsState();
}

class _RegionCutoutActionsState extends ConsumerState<RegionCutoutActions> {
  bool _busy = false;
  int _operationGeneration = 0;

  @override
  void didUpdateWidget(covariant RegionCutoutActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.region.id != widget.region.id) {
      _operationGeneration++;
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final backend = ref.watch(backendProvider);
    final isHost =
        backend is! NetworkBackend && backend is! DisconnectedBackend;
    final canAccessAtlas = backend is! DisconnectedBackend;

    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (_busy && previous != null && !identical(previous, next)) {
        _operationGeneration++;
        setState(() => _busy = false);
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceSm,
          children: [
            SkotiqButton(
              label: 'Export',
              icon: LucideIcons.share2,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: _busy || !canAccessAtlas ? null : _export,
            ),
            if (isHost)
              SkotiqButton(
                label: 'Use as reference frame',
                icon: LucideIcons.crosshair,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: _busy ? null : _useAsReference,
              ),
          ],
        ),
        if (!canAccessAtlas) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'Reconnect to your imaging host to export this co-add.',
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ] else if (!isHost) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            'Use as a live-stack reference frame runs on your imaging host.',
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final generation = ++_operationGeneration;
    final regionId = widget.region.id;
    final regionName = widget.region.name;
    final backend = ref.read(backendProvider);
    setState(() => _busy = true);
    try {
      final String sharePath;
      if (backend is NetworkBackend) {
        // Slave: pull PNG bytes over the wire and stage a temp file to share.
        final bytes = await backend.getAtlasRegionCutout(regionId);
        if (!_isCurrent(generation, backend, regionId)) return;
        final dir = await getTemporaryDirectory();
        if (!_isCurrent(generation, backend, regionId)) return;
        final file = File(p.join(
          dir.path,
          'region_${regionId}_${_safeName(regionName)}.png',
        ));
        await file.writeAsBytes(bytes);
        if (!_isCurrent(generation, backend, regionId)) return;
        sharePath = file.path;
      } else if (backend is! DisconnectedBackend) {
        final export = await ref.read(yourSkyRegionExporterProvider)(regionId);
        if (!_isCurrent(generation, backend, regionId)) return;
        if (export == null || export.pngPath == null) {
          messenger.showSnackBar(const SnackBar(
            content: Text('No co-add to export yet.'),
            duration: Duration(seconds: 3),
          ));
          return;
        }
        sharePath = export.pngPath!;
      } else {
        throw StateError('Reconnect to the imaging host before exporting.');
      }
      if (!_isCurrent(generation, backend, regionId)) return;
      await ref.read(yourSkyRegionShareProvider)(
        sharePath,
        text: '$regionName — co-added in Your Sky',
      );
    } on Object catch (e) {
      if (!_isCurrent(generation, backend, regionId)) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Could not export: $e'),
        duration: const Duration(seconds: 4),
      ));
    } finally {
      _finish(generation);
    }
  }

  Future<void> _useAsReference() async {
    final messenger = ScaffoldMessenger.of(context);
    final generation = ++_operationGeneration;
    final regionId = widget.region.id;
    final regionName = widget.region.name;
    final backend = ref.read(backendProvider);
    setState(() => _busy = true);
    try {
      if (backend is NetworkBackend || backend is DisconnectedBackend) {
        throw StateError(
          'Reference frames can only be armed on the imaging host.',
        );
      }
      final export = await ref.read(yourSkyRegionExporterProvider)(regionId);
      if (!_isCurrent(generation, backend, regionId)) return;
      if (export == null) {
        messenger.showSnackBar(const SnackBar(
          content: Text('No co-add to use as a reference yet.'),
          duration: Duration(seconds: 3),
        ));
        return;
      }
      await ref.read(yourSkyReferenceStarterProvider)(export.fitsPath);
      if (!_isCurrent(generation, backend, regionId)) return;
      messenger.showSnackBar(SnackBar(
        content: Text(
          'Armed live stacking on $regionName as the reference frame.',
        ),
        duration: const Duration(seconds: 4),
      ));
    } on Object catch (e) {
      if (!_isCurrent(generation, backend, regionId)) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Could not set reference frame: $e'),
        duration: const Duration(seconds: 4),
      ));
    } finally {
      _finish(generation);
    }
  }

  bool _isCurrent(
    int generation,
    SkotiqBackend backend,
    int regionId,
  ) {
    return mounted &&
        generation == _operationGeneration &&
        widget.region.id == regionId &&
        identical(ref.read(backendProvider), backend);
  }

  void _finish(int generation) {
    if (mounted && generation == _operationGeneration) {
      setState(() => _busy = false);
    }
  }

  static String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    return cleaned.isEmpty ? 'region' : cleaned;
  }
}

class _ScrubPanel extends ConsumerWidget {
  final int regionId;
  final List<SkyAtlasFoldRow> folds;
  final DateTime? anchor;

  const _ScrubPanel({
    required this.regionId,
    required this.folds,
    required this.anchor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final stops = scrubStopsFromFolds(folds);

    return SkotiqPanel(
      padding: SkotiqTokens.cardPadding,
      child: stops.length < 2
          ? Row(
              children: [
                Icon(LucideIcons.history,
                    size: SkotiqTokens.iconSm, color: colors.textMuted),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    'Image this region across more nights to scrub it through '
                    'time.',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted, height: 1.4),
                  ),
                ),
              ],
            )
          : AtlasTimescrub(
              stops: stops,
              selected: anchor,
              onChanged: (instant) {
                ref.read(_scrubAnchorProvider.notifier).state = instant;
              },
            ),
    );
  }
}

/// "What changed" — the folds active at the current scrub anchor, newest first,
/// each summarising the frames + integration it added (seeds Pillar B's
/// discovery view).
class _ChangedPanel extends StatelessWidget {
  final List<SkyAtlasFoldRow> folds;
  final DateTime? anchor;

  const _ChangedPanel({required this.folds, required this.anchor});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final visible = [
      for (final fold in folds)
        if (anchor == null || !fold.foldedAt.toUtc().isAfter(anchor!.toUtc()))
          fold,
    ]..sort((a, b) => b.foldedAt.compareTo(a.foldedAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Contributing frames',
          subtitle: anchor == null
              ? 'Every session that has deepened this region.'
              : 'Sessions up to the scrub point.',
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (visible.isEmpty)
          SkotiqPanel(
            padding: SkotiqTokens.cardPadding,
            child: Text(
              'No folds at this point in time.',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          )
        else
          for (var i = 0; i < visible.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == visible.length - 1 ? 0 : SkotiqTokens.spaceSm,
              ),
              child: _FoldRow(fold: visible[i]),
            ),
      ],
    );
  }
}

class _FoldRow extends StatelessWidget {
  final SkyAtlasFoldRow fold;

  const _FoldRow({required this.fold});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isSwarm = fold.contributor.isNotEmpty;
    final tint = isSwarm ? colors.info : colors.primary;

    return SkotiqPanel(
      padding: SkotiqTokens.cardPadding,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            decoration: SkotiqDecorations.chip(colors, tone: tint),
            child: Icon(
              isSwarm ? LucideIcons.users : LucideIcons.image,
              size: SkotiqTokens.iconSm,
              color: tint,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(fold),
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  '${fold.framesAdded} frame${fold.framesAdded == 1 ? '' : 's'}'
                  '  ·  +${formatIntegration(fold.integrationSecondsAdded)}'
                  '  ·  tile ${fold.tileId}'
                  '${fold.rejected > 0 ? '  ·  ${fold.rejected} rejected' : ''}',
                  style: SkotiqTypography.captionSm
                      .copyWith(color: colors.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _label(SkyAtlasFoldRow fold) {
    if (fold.label.trim().isNotEmpty) return fold.label.trim();
    final utc = fold.foldedAt.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')} fold';
  }
}

/// The region's deepening growth curve (cumulative integration vs. night),
/// driven by the native [atlasRegionGrowthProvider] (host) or the host's
/// timeline `growth` payload (slave). Surfaces the per-cone deepening curve the
/// native bridge computes.
class _GrowthPanel extends ConsumerWidget {
  final int regionId;

  const _GrowthPanel({required this.regionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final growthAsync = ref.watch(atlasRegionGrowthProvider(regionId));
    final curve = growthAsync.valueOrNull ?? AtlasGrowthCurve.empty;
    return AtlasGrowthCurvePanel(curve: curve);
  }
}

/// Provenance trail — the native per-tile [TileProvenanceView] (coverage mean,
/// deduplicated contributor list, per-fold log) for the region's deepest tile,
/// driven by [atlasRegionProvenanceProvider]. Falls back to the region-level
/// rollup while the native view loads (or when the region has no tiles yet) so
/// the panel never blanks.
class _ProvenancePanel extends ConsumerWidget {
  final SkyAtlasRegionRow region;
  final List<SkyTileRow> tiles;
  final List<SkyAtlasFoldRow> folds;

  const _ProvenancePanel({
    required this.region,
    required this.tiles,
    required this.folds,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final provenanceAsync = ref.watch(atlasRegionProvenanceProvider(region.id));
    final provenance = provenanceAsync.valueOrNull;

    // Region-level rollups (always available from the rows already fetched);
    // the native tile-provenance view augments the contributors + per-fold log.
    final maxDepth = tiles.isEmpty
        ? 0.0
        : tiles
            .map((t) => t.integrationSeconds)
            .reduce((a, b) => a > b ? a : b);
    final contributors = provenance != null
        ? provenance.contributors
        : <String>{
            for (final f in folds)
              if (f.contributor.trim().isNotEmpty) f.contributor.trim(),
          }.toList(growable: false);
    // One frame lands in many tiles; count each (label, contributor) once.
    final totalFrames = {
      for (final f in folds)
        if (f.framesAdded > 0) '${f.contributor}\u0000${f.label}',
    }.length;
    final provFolds = provenance?.folds ?? const <TileFoldView>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Depth & provenance',
          subtitle: 'How this region was built, tile by tile.',
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqPanel(
          padding: SkotiqTokens.cardPadding,
          child: Column(
            children: [
              _StatLine(
                icon: LucideIcons.clock,
                label: 'Total integration',
                value: formatIntegration(region.integrationSeconds),
                colors: colors,
              ),
              _StatLine(
                icon: LucideIcons.layers,
                label: 'Deepest tile',
                value: formatIntegration(maxDepth),
                colors: colors,
              ),
              if (provenance != null)
                _StatLine(
                  icon: LucideIcons.target,
                  label: 'Deepest-tile coverage',
                  value:
                      '${(provenance.coverageMean * 100).toStringAsFixed(0)}%',
                  colors: colors,
                ),
              _StatLine(
                icon: LucideIcons.layoutGrid,
                label: 'Tiles',
                value: '${region.tileCount}',
                colors: colors,
              ),
              _StatLine(
                icon: LucideIcons.image,
                label: 'Frames folded',
                value: '$totalFrames',
                colors: colors,
              ),
              _StatLine(
                icon: LucideIcons.users,
                label: 'Contributors',
                value: contributors.isEmpty
                    ? 'You'
                    : (contributors.length == 1 &&
                            contributors.first.trim().isEmpty)
                        ? 'You'
                        : '${contributors.length}',
                colors: colors,
                isLast: provFolds.isEmpty,
              ),
            ],
          ),
        ),
        if (provFolds.isNotEmpty) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          _ProvenanceTrail(folds: provFolds),
        ],
      ],
    );
  }
}

/// The per-fold provenance trail for the region's deepest tile (newest first):
/// the native fold log every contribution left behind. Reads the native
/// [TileFoldView] list straight from [TileProvenanceView].
class _ProvenanceTrail extends StatelessWidget {
  final List<TileFoldView> folds;

  const _ProvenanceTrail({required this.folds});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final ordered = [...folds]..sort((a, b) => b.label.compareTo(a.label));

    return SkotiqPanel(
      padding: SkotiqTokens.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Provenance trail · deepest tile',
            style: SkotiqTypography.labelQuiet
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (var i = 0; i < ordered.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == ordered.length - 1 ? 0 : SkotiqTokens.spaceSm,
              ),
              child: Row(
                children: [
                  Icon(
                    ordered[i].contributor.trim().isNotEmpty
                        ? LucideIcons.users
                        : LucideIcons.image,
                    size: SkotiqTokens.iconSm,
                    color: ordered[i].contributor.trim().isNotEmpty
                        ? colors.info
                        : colors.primary,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Text(
                      _trailLabel(ordered[i]),
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${ordered[i].framesAdded}f · '
                    '+${formatIntegration(ordered[i].integrationSecondsAdded)}',
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _trailLabel(TileFoldView fold) {
    final label = fold.label.trim();
    if (label.isEmpty) return 'Fold';
    final contributor = fold.contributor.trim();
    return contributor.isEmpty ? label : '$label · $contributor';
  }
}

class _StatLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool isLast;

  const _StatLine({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: isLast ? 0 : SkotiqTokens.spaceMd,
      ),
      child: Row(
        children: [
          Icon(icon, size: SkotiqTokens.iconSm, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              label,
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
          ),
          Text(
            value,
            style: SkotiqTypography.monoSm.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}
