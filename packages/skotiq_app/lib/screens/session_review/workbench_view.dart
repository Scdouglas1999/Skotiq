import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/diagnostics_screen/psf_field_map_view.dart';
import '../sequencer/widgets/run_dashboard/frame_detail_dialog.dart';
import '../../utils/confirm_dialog.dart';
import '../../utils/darkroom_navigation.dart';
import 'session_review_controller.dart';
import 'widgets/ab_compare_panel.dart';
import 'widgets/darkroom_pass_banner.dart';
import 'widgets/integration_settings_panel.dart';
import 'widgets/master_library_panel.dart';
import 'widgets/master_overlay_view.dart';
import 'widgets/master_preview_view.dart';
import 'widgets/narrowband_mixer_panel.dart' as nb;
import 'widgets/session_interruption_banner.dart';
import 'widgets/sub_cull_rail.dart';

/// Keeps the PSF field-map selection attached to the same captured image when
/// the live sub list is reordered or replaced. If that image disappeared,
/// selects the sharpest remaining frame instead of borrowing the same numeric
/// index from an unrelated list.
@visibleForTesting
int reconcileFieldQualityIndex({
  required List<DbCapturedImage> oldSubs,
  required List<DbCapturedImage> newSubs,
  required int currentIndex,
}) {
  if (newSubs.isEmpty) return 0;

  final oldSelectedId = currentIndex >= 0 && currentIndex < oldSubs.length
      ? oldSubs[currentIndex].id
      : null;
  if (oldSelectedId != null) {
    final preserved = newSubs.indexWhere((sub) => sub.id == oldSelectedId);
    if (preserved >= 0) return preserved;
  }

  var best = 0;
  var bestHfr = double.infinity;
  for (var i = 0; i < newSubs.length; i++) {
    final hfr = newSubs[i].hfr ?? double.infinity;
    if (hfr < bestHfr) {
      bestHfr = hfr;
      best = i;
    }
  }
  return best;
}

/// The *workbench* rendering of the one [SessionReviewController] state: a
/// dense, control-heavy console for the operator who wants to drive every knob.
///
/// Layout: the cull rail (sub table + blink + lasso) on the
/// left; the master with every overlay toggle, the per-sub field-quality maps,
/// the narrowband mixer, an A/B re-integrate compare, and the full
/// integration-settings form on the right.
///
/// Same provider as `NarrativeView` — two renderings of one model. Every panel
/// is composed by its contract constructor signature and is design-system pure.
class WorkbenchView extends ConsumerWidget {
  final SessionReviewScope scope;

  const WorkbenchView({super.key, required this.scope});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionReviewControllerProvider(scope));
    final controller =
        ref.read(sessionReviewControllerProvider(scope).notifier);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= SkotiqTokens.breakpointDesktop;
        final left = _LeftColumn(
          state: state,
          controller: controller,
          onTapSub: (image) => FrameDetailDialog.showForFrame(
            context,
            imageId: image.id,
          ),
          onSetAccepted: controller.setAccepted,
          onBulkCull: ({hfrThreshold, qualityThreshold}) =>
              controller.bulkReject(
            hfrThreshold: hfrThreshold,
            qualityThreshold: qualityThreshold,
          ),
        );
        final right = _RightColumn(
          state: state,
          controller: controller,
        );

        // Above both columns in either layout: a pass that was cut off by a
        // process exit, then one that failed or was stopped. Both are the
        // reason the drafts and the delivery the panels below would otherwise
        // be read as reporting are not there.
        final passBanner = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SessionInterruptionBanner(notice: state.interruptedPassNotice),
            DarkroomPassBanner(job: state.darkroomJob),
          ],
        );

        if (!wide) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                passBanner,
                left,
                const SizedBox(height: SkotiqTokens.spaceLg),
                right,
              ],
            ),
          );
        }

        // Two dense columns side by side on desktop widths.
        return Padding(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              passBanner,
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: SingleChildScrollView(child: left),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceLg),
                    Expanded(
                      flex: 6,
                      child: SingleChildScrollView(child: right),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Left column: the sub-culling rail (full sub grid + blink + lasso + a
/// "drop to recommended keepN" action wired to the improvement curve).
class _LeftColumn extends StatelessWidget {
  final SessionReviewState state;
  final SessionReviewController controller;
  final void Function(DbCapturedImage) onTapSub;
  final void Function(int imageId, bool accepted) onSetAccepted;
  final void Function({double? hfrThreshold, double? qualityThreshold})
      onBulkCull;

  const _LeftColumn({
    required this.state,
    required this.controller,
    required this.onTapSub,
    required this.onSetAccepted,
    required this.onBulkCull,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SectionTitle(icon: SkotiqIcons.image, title: 'Subs & culling'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        // SubCullRail extends the existing sub gallery: blink + bulk-reject
        // plus multi-select / lasso cull and a curve-linked "drop to keepN".
        SizedBox(
          height: 520,
          child: SubCullRail(
            subs: state.lights,
            controller: controller,
            onTapSub: onTapSub,
            onSetAccepted: onSetAccepted,
            onBulkCull: onBulkCull,
          ),
        ),
      ],
    );
  }
}

/// Right column: the master + overlays, the per-sub field-quality maps, the
/// narrowband mixer, the A/B compare, and the integration-settings form.
class _RightColumn extends ConsumerWidget {
  final SessionReviewState state;
  final SessionReviewController controller;

  const _RightColumn({
    required this.state,
    required this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final outcome = state.lastOutcome;
    final master = state.reviewedMaster;
    // Prefer the freshest run's preview; otherwise the persisted master's.
    final previewPath = outcome?.result.previewPath ?? master?.previewPngPath;

    // A run that dropped subs still returns a master, so nothing else on this
    // column looks wrong — the card just reads a smaller frame count. The
    // toast is transient; this banner is what is still on screen when the user
    // looks at the master and wonders why it is thin.
    final shortfall = SessionReviewController.integrationShortfall(outcome);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (shortfall != null) ...[
          SkotiqBanner(
            tone: BannerTone.warning,
            title: 'Subs were dropped from this master',
            message: shortfall,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
        ],
        // ── Master with every overlay toggle. ────────────────────────────
        const SectionTitle(
            icon: SkotiqIcons.layers, title: 'Master & overlays'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (previewPath != null)
          SkotiqPanel(
            padding: EdgeInsets.zero,
            child: SizedBox(
              height: 480,
              child: MasterOverlayView(
                previewPngPath: previewPath,
                annotations: state.annotationLayer,
                rejectionMapPngPath: outcome?.result.rejectionMapPreviewPath ??
                    state.reviewedMaster?.rejectionMapPreviewPath,
                coverageMapPngPath: outcome?.result.coverageMapPreviewPath ??
                    state.coverageMapPath,
                showAnnotations: true,
                showRejection: false,
                showCoverage: false,
                finishingLayers: finishingLayersForMaster(master),
              ),
            ),
          )
        else
          SkotiqPanel(
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            child: Row(
              children: [
                Icon(SkotiqIcons.info,
                    size: SkotiqTokens.iconSm, color: colors.info),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    'Integrate to produce a master, then toggle the rejection '
                    'and annotation overlays here.',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: SkotiqTokens.spaceMd),

        // ── Finishing actions (non-destructive post-steps on the master). ─
        _FinishingActions(state: state, controller: controller),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // ── Multi-night master library (accumulate / finalize). ──────────
        MasterLibraryPanel(
          masters: state.masters,
          acceptedSubCount: state.acceptedCount,
          busy: state.busy,
          onOpen: (m) => _showMasterPreview(context, m),
          // The master row IS the Darkroom's scope: the screen loads that
          // master's newest recipe, or offers to compose one. No session lookup
          // is needed here because the card already names the row — but the
          // same role question every other entry point asks still is, so a
          // machine that cannot open the Darkroom says so here rather than
          // navigating into the host-only screen.
          onOpenInDarkroom: (m) => openDarkroomForMasterRow(context, ref, m.id),
          // Asked while the card is BUILT, so a client's card reads refused
          // instead of drawing a live button that explains itself after the
          // press. `openDarkroomForMasterRow` still asks on the way through,
          // for the deep links that reach the editor with no control to disable.
          darkroomRefusal: watchDarkroomHostOnlyRefusal(ref),
          onCreateAccumulating: () async {
            await controller.createAccumulatingMaster();
            await controller.loadSmartData();
          },
          onAddTonight: (m) async {
            await controller.addToAccumulatingMaster(master: m);
            await controller.loadSmartData();
          },
          onFinalize: (m) async {
            await controller.finalizeMaster(m);
            await controller.loadSmartData();
          },
          onDelete: (m) async {
            final ok = await ConfirmDialog.delete(
              context: context,
              itemName: m.name,
            );
            if (ok) await controller.deleteMaster(m);
          },
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // ── Per-sub field quality (PSF map). ─────────────────────────────
        // Reuses the shared PsfFieldMapView painter — the same one the
        // diagnostics surface renders — at per-sub granularity.
        const SectionTitle(
            icon: SkotiqIcons.crosshair, title: 'Optical field quality'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _FieldQualityCard(subs: state.acceptedLights),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // ── Narrowband channel mixer. ────────────────────────────────────
        const SectionTitle(
            icon: SkotiqIcons.sliders, title: 'Narrowband mixer'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        nb.NarrowbandMixerPanel(
          // Bridge the controller's canonical channel refs (which carry the
          // on-disk FITS path the combine consumes) to the mixer's display
          // refs. The combine re-resolves the FITS internally, so onApply only
          // needs to hand back the palette + weight matrix.
          channels: [
            for (final c in controller.narrowbandChannels())
              nb.NarrowbandChannelRef(
                masterId: c.masterId,
                filter: c.label,
                label: c.label,
              ),
          ],
          // Await the combine and surface the persisted composite path rather
          // than discarding it: a failed combine sets `state.error`, a successful
          // one pushes the `narrowband_composites` row onto state, which the
          // `_NarrowbandCompositeCard` below renders.
          busy: state.combiningNarrowband,
          onApply: (palette, weights) async {
            await controller.runNarrowband(palette, weights);
          },
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _NarrowbandCompositeCard(composite: state.narrowbandComposite),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // ── A/B compare two integration recipes. ─────────────────────────
        const SectionTitle(icon: SkotiqIcons.layers, title: 'A / B compare'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        AbComparePanel(controller: controller),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // ── Integration settings + actions. ──────────────────────────────
        const SectionTitle(
            icon: SkotiqIcons.sliders, title: 'Integration settings'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqPanel(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: IntegrationSettingsPanel(
            settings: state.settings,
            subCount: state.acceptedCount,
            onChanged: controller.updateSettings,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        SkotiqButton(
          label: state.lastOutcome == null ? 'Integrate now' : 'Re-integrate',
          icon: SkotiqIcons.play,
          isLoading: state.integrating,
          onPressed: (state.integrating || state.acceptedCount == 0)
              ? null
              : () => controller.reIntegrate(state.settings),
        ),
      ],
    );
  }
}

/// Open a persisted master's stretched preview in a dialog, so a card in the
/// [MasterLibraryPanel] can be inspected without leaving the workbench.
void _showMasterPreview(BuildContext context, IntegratedMaster master) {
  showDialog<void>(
    context: context,
    builder: (_) => SkotiqDialog(
      title: master.name,
      width: 760,
      height: 620,
      scrollableBody: false,
      child: MasterPreviewView.fromMaster(master),
    ),
  );
}

/// The non-destructive finishing-action row: "Background extract", "Deconvolve",
/// and "Reduce stars" buttons that run the matching post-step on the current
/// reviewed master's finished FITS (never re-integrating). Each writes its
/// `_bgx`/`_decon`/`_starred` FITS + a sibling preview PNG, persists the path,
/// and the result then surfaces as a toggleable "after" layer in the
/// `MasterOverlayView` hero above. Disabled (with a calm hint) until a finished
/// master exists or while any finishing pass is in flight.
class _FinishingActions extends StatelessWidget {
  final SessionReviewState state;
  final SessionReviewController controller;

  const _FinishingActions({required this.state, required this.controller});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final master = state.reviewedMaster;
    final hasMaster = master?.masterFitsPath != null &&
        master!.masterFitsPath!.trim().isNotEmpty;
    final busy = state.busy;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.sparkle,
                  size: SkotiqTokens.iconSm, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'Finishing (non-destructive previews)',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          if (!hasMaster)
            Text(
              'Integrate a master first — finishing runs on the finished FITS.',
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            )
          else
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                SkotiqButton(
                  label: 'Background extract',
                  icon: SkotiqIcons.grid,
                  variant: ButtonVariant.secondary,
                  isLoading: state.extractingBackground,
                  onPressed: busy ? null : controller.runBackgroundExtraction,
                ),
                SkotiqButton(
                  label: 'Deconvolve',
                  icon: SkotiqIcons.sparkle,
                  variant: ButtonVariant.secondary,
                  isLoading: state.deconvolving,
                  onPressed: busy ? null : controller.runDeconvolve,
                ),
                SkotiqButton(
                  label: 'Reduce stars',
                  icon: SkotiqIcons.star,
                  variant: ButtonVariant.secondary,
                  isLoading: state.reducingStars,
                  onPressed: busy ? null : controller.runStarReduction,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The per-sub optical field quality card: a HFR field-map heat-grid for the
/// selected sub, rendered through the shared [PsfFieldMapView] painter (the same
/// painter the Diagnostics surface uses — the design's reuse of
/// `psf_field_map.dart` at per-sub granularity).
///
/// It defaults to the best accepted sub, lets the operator step through subs,
/// and loads each sub's `psf_field_tiles` rows on demand. When a sub has no
/// per-sub tiles yet (not all rigs/pipelines populate them), it shows a calm
/// empty state rather than fabricating a map.
class _FieldQualityCard extends ConsumerStatefulWidget {
  final List<DbCapturedImage> subs;

  const _FieldQualityCard({required this.subs});

  @override
  ConsumerState<_FieldQualityCard> createState() => _FieldQualityCardState();
}

class _FieldQualityCardState extends ConsumerState<_FieldQualityCard> {
  int _index = 0;
  Future<List<PsfFieldTileRow>>? _tilesFuture;

  @override
  void initState() {
    super.initState();
    _index = _initialIndex();
    _loadTiles();
  }

  @override
  void didUpdateWidget(covariant _FieldQualityCard old) {
    super.didUpdateWidget(old);
    var idsChanged = widget.subs.length != old.subs.length;
    if (!idsChanged) {
      for (var i = 0; i < widget.subs.length; i++) {
        if (widget.subs[i].id != old.subs[i].id) {
          idsChanged = true;
          break;
        }
      }
    }
    if (idsChanged) {
      _index = reconcileFieldQualityIndex(
        oldSubs: old.subs,
        newSubs: widget.subs,
        currentIndex: _index,
      );
      _loadTiles();
    }
  }

  int get _maxIndex => widget.subs.isEmpty ? 0 : widget.subs.length - 1;

  /// Start on the sharpest accepted sub (lowest HFR) — the field map is most
  /// informative on a good frame.
  int _initialIndex() {
    return reconcileFieldQualityIndex(
      oldSubs: const [],
      newSubs: widget.subs,
      currentIndex: 0,
    );
  }

  void _loadTiles() {
    if (widget.subs.isEmpty) {
      _tilesFuture = Future.value(const <PsfFieldTileRow>[]);
      return;
    }
    final id = widget.subs[_index].id;
    _tilesFuture = ref.read(scienceDaoProvider).getPsfTilesForImage(id);
  }

  void _step(int delta) {
    if (widget.subs.isEmpty) return;
    setState(() {
      _index = (_index + delta).clamp(0, _maxIndex);
      _loadTiles();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final subs = widget.subs;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.grid,
                  size: SkotiqTokens.iconSm, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'PSF field map',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (subs.isNotEmpty) ...[
                IconButton(
                  iconSize: SkotiqTokens.iconSm,
                  visualDensity: VisualDensity.compact,
                  onPressed: _index > 0 ? () => _step(-1) : null,
                  icon: const Icon(SkotiqIcons.chevronLeft),
                  tooltip: 'Previous sub',
                ),
                Text(
                  'sub ${_index + 1} / ${subs.length}',
                  style: SkotiqTypography.labelSm
                      .copyWith(color: colors.textSecondary),
                ),
                IconButton(
                  iconSize: SkotiqTokens.iconSm,
                  visualDensity: VisualDensity.compact,
                  onPressed: _index < _maxIndex ? () => _step(1) : null,
                  icon: const Icon(SkotiqIcons.chevronRight),
                  tooltip: 'Next sub',
                ),
              ],
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          if (subs.isEmpty)
            Text(
              'No accepted subs to map.',
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            )
          else
            FutureBuilder<List<PsfFieldTileRow>>(
              future: _tilesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 180,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final tiles = snapshot.data ?? const <PsfFieldTileRow>[];
                if (tiles.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: SkotiqTokens.spaceMd),
                    child: Text(
                      'No PSF field tiles for this sub yet — capture '
                      'plate-solved frames to populate the per-sub map.',
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textSecondary),
                    ),
                  );
                }
                return AspectRatio(
                  aspectRatio: 1.5,
                  child: PsfFieldMapView(tiles: tiles),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// The applied narrowband composite result card.
///
/// Surfaces the persisted `narrowband_composites` row after a palette is
/// applied, so the SHO/HOO output is a durable row rather than an orphan FITS
/// on disk. It shows the palette, the component master ids the composite was
/// combined from, the output
/// dimensions, and the on-disk path. When a stretched preview PNG sits alongside
/// the composite FITS (same path, `.png` extension) it is rendered through the
/// shared [MasterOverlayView] hero exactly like an integrated master; otherwise a
/// calm "composite written" panel reports the artifact. Renders nothing until a
/// composite exists.
class _NarrowbandCompositeCard extends StatelessWidget {
  final NarrowbandComposite? composite;

  const _NarrowbandCompositeCard({required this.composite});

  /// The conventional sibling preview PNG for a composite FITS at [fitsPath]:
  /// the same path with a `.png` extension. The native combine writes only the
  /// composite FITS today, so this is usually absent — but when a preview is
  /// produced alongside it the hero lights up for free.
  String _siblingPreviewPath(String fitsPath) {
    final dir = p.dirname(fitsPath);
    final stem = p.basenameWithoutExtension(fitsPath);
    return p.join(dir, '$stem.png');
  }

  bool _exists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = composite;
    if (c == null) return const SizedBox.shrink();
    final colors = SkotiqColors.of(context);
    final previewPath = _siblingPreviewPath(c.outputPath);
    final hasPreview = _exists(previewPath);

    final components = c.componentMasterIds.isEmpty
        ? '—'
        : c.componentMasterIds.map((id) => '#$id').join(' · ');
    final dims =
        (c.width > 0 && c.height > 0) ? '${c.width}×${c.height}' : null;

    return SkotiqPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: Row(
              children: [
                Icon(SkotiqIcons.palette,
                    size: SkotiqTokens.iconSm, color: colors.primary),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${c.palette.toUpperCase()} composite',
                        style: SkotiqTypography.sectionTitle
                            .copyWith(color: colors.textPrimary),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                      Text(
                        'Channels $components'
                        '${dims != null ? '  ·  $dims' : ''}',
                        style: SkotiqTypography.bodySm
                            .copyWith(color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (hasPreview)
            SizedBox(
              height: 360,
              child: MasterOverlayView(
                previewPngPath: previewPath,
                showAnnotations: false,
                showRejection: false,
                showCoverage: false,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.spaceMd,
                0,
                SkotiqTokens.spaceMd,
                SkotiqTokens.spaceMd,
              ),
              child: Row(
                children: [
                  Icon(SkotiqIcons.check,
                      size: SkotiqTokens.iconSm, color: colors.success),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      'Composite written to\n${c.outputPath}',
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
