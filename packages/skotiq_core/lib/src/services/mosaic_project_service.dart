import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/images_dao.dart';
import '../database/daos/integrated_masters_dao.dart';
import '../database/daos/mosaic_panels_dao.dart';
import '../database/daos/mosaic_projects_dao.dart';
import '../database/daos/targets_dao.dart';
import '../database/database.dart'
    show CapturedImage, SkotiqDatabase, TargetsCompanion;
import '../models/imaging/integrated_master.dart';
import '../models/imaging/integration_settings.dart';
import '../models/imaging/mosaic_project.dart';
import '../models/imaging/mosaic_stitch_result.dart';
import '../providers/database_provider.dart';
import 'mosaic_service.dart';
import 'post_session_integration_service.dart';
import 'post_session_seam.dart';
part 'mosaic_project_service/mosaic_models.dart';
part 'mosaic_project_service/panel_integration.dart';
part 'mosaic_project_service/stitching.dart';
part 'mosaic_project_service/path_helpers.dart';

/// Orchestrates a **durable mosaic project** end-to-end (Mosaic M2): lay out the
/// grid into per-panel rows each with its OWN capture target, launch capture of
/// the per-panel-target sequence, integrate each panel's captured subs into a
/// per-panel master, then stitch those masters into one mosaic master.
///
/// This service is the durable spine that ties together pieces that already
/// exist — it deliberately reuses, never reimplements:
///
///  * **Geometry** — the per-panel center RA/Dec come straight from
///    [MosaicService.generatePanels] (the canonical spherical grid math with
///    cos(dec) RA compression + position-angle rotation). The panel dimensions
///    are derived once from the rig FOV (arcmin) and handed to that generator.
///  * **Persistence** — [MosaicProjectsDao] / [MosaicPanelsDao] (raw-DDL v45).
///  * **Per-panel targets** — [TargetsDao]: each panel is a DISTINCT capture
///    target row centered on the panel's RA/Dec, so the subs a panel captures
///    attribute to *that* panel (and [integratePanels] folds exactly that
///    panel's subs, never the whole region's).
///  * **Per-panel integration** — [PostSessionIntegrationService.integrate],
///    which groups a panel's accepted subs by filter into per-filter masters,
///    each carrying its own plate-solved v44 WCS. (Because each panel is a real
///    target, its WCS rides on `integrated_masters` for free — exactly what the
///    stitcher consumes.)
///  * **Stitching** — [PostSessionSeam.stitchMosaic] (the `api_stitch_mosaic`
///    FFI), which projects the panel masters onto a shared gnomonic canvas and
///    feather-blends them into one master.
///
/// [integratePanels] is fail-soft per panel: one bad panel (no subs, an
/// integration throw) is recorded as [MosaicPanelStatus.failed] and the run
/// continues to the next panel, so a single weak panel never sinks the project.
class MosaicProjectService {
  MosaicProjectService({
    required SkotiqDatabase db,
    required MosaicProjectsDao projectsDao,
    required MosaicPanelsDao panelsDao,
    required TargetsDao targetsDao,
    required ImagesDao imagesDao,
    required IntegratedMastersDao mastersDao,
    required PostSessionIntegrationService integrationService,
    required PostSessionSeam seam,
    MosaicService geometry = const MosaicService(),
  }) : _db = db,
       _projectsDao = projectsDao,
       _panelsDao = panelsDao,
       _targetsDao = targetsDao,
       _imagesDao = imagesDao,
       _mastersDao = mastersDao,
       _integration = integrationService,
       _seam = seam,
       _geometry = geometry;

  final SkotiqDatabase _db;
  final MosaicProjectsDao _projectsDao;
  final MosaicPanelsDao _panelsDao;
  final TargetsDao _targetsDao;
  final ImagesDao _imagesDao;
  final IntegratedMastersDao _mastersDao;
  final PostSessionIntegrationService _integration;
  final PostSessionSeam _seam;
  final MosaicService _geometry;

  // 1. Plan — lay the grid out into a durable project + per-panel rows, each
  //    with its OWN distinct capture target.

  /// Create a durable mosaic project: persist a `mosaic_projects` row, compute
  /// each panel's center RA/Dec from the grid geometry, create one DISTINCT
  /// per-panel capture `targets` row centered on that panel, and persist one
  /// `mosaic_panels` row per `rows × cols` panel (0-based [MosaicProjectPanel]
  /// index, row-major) carrying its per-panel `target_id`.
  ///
  /// The per-panel centers are computed by [MosaicService.generatePanels] — the
  /// existing spherical-grid math — NOT re-derived here. The panel dimensions it
  /// needs are derived from the rig field of view: pass either an explicit
  /// [panelWidthArcmin]/[panelHeightArcmin], or [fovWidthDeg]/[fovHeightDeg]
  /// (degrees, e.g. `FramingEquipment.fovWidthDeg`) which are converted to
  /// arcmin.
  ///
  /// [centerRa] is in RA hours, [centerDec] in degrees — matching
  /// [MosaicConfig] and the [MosaicProjectPanel] units.
  ///
  /// Each panel gets its OWN capture target so its subs are isolated for
  /// [integratePanels]. By default the service CREATES one `targets` row per
  /// panel (named `"<project> Panel N"`, centered on the panel's RA/Dec); pass
  /// [panelTargetId] to override — return an existing `targets.id` for a panel
  /// to reuse it (e.g. a resumed project), or null to fall back to a freshly
  /// created per-panel target. Two panels resolving to the same id is rejected
  /// later by [integratePanels]/[startCapture] (panels must not share subs).
  ///
  /// [disabledCells] holds grid cells (0-based row/col) the caller disabled
  /// (e.g. the wizard's tap-to-disable): those panels are NOT persisted, but the
  /// grid geometry is unchanged so surviving panels keep their canonical
  /// row-major `panelIndex` (the stored `panel_index` set is simply sparse).
  ///
  /// The whole insert (project + per-panel targets + panels) runs in ONE
  /// transaction: a failure midway leaves no half-built project.
  ///
  /// Returns the new `mosaic_projects.id`.
  Future<int> createProject({
    required String name,
    required int rows,
    required int cols,
    required double centerRa,
    required double centerDec,
    int? targetId,
    double overlapPct = 15.0,
    double positionAngleDeg = 0.0,
    double? panelWidthArcmin,
    double? panelHeightArcmin,
    double? fovWidthDeg,
    double? fovHeightDeg,
    int? Function(int panelIndex)? panelTargetId,
    Set<({int row, int col})> disabledCells = const {},
  }) async {
    if (rows < 1 || cols < 1) {
      throw ArgumentError(
        'mosaic grid must be at least 1x1 (got ${rows}x$cols)',
      );
    }
    final widthArcmin =
        panelWidthArcmin ?? (fovWidthDeg != null ? fovWidthDeg * 60.0 : null);
    final heightArcmin =
        panelHeightArcmin ??
        (fovHeightDeg != null ? fovHeightDeg * 60.0 : null);
    if (widthArcmin == null || heightArcmin == null) {
      throw ArgumentError(
        'panel dimensions are required: pass panelWidthArcmin/'
        'panelHeightArcmin or fovWidthDeg/fovHeightDeg',
      );
    }
    if (widthArcmin <= 0 || heightArcmin <= 0) {
      throw ArgumentError('panel dimensions must be positive');
    }

    // Reuse the canonical spherical grid math (cos(dec) RA compression + PA
    // rotation). `MosaicConfig` uses `panelsHorizontal = cols`, `panelsVertical
    // = rows`; its generated `MosaicPanel.panelIndex` is row-major 0-based,
    // exactly the durable panel index.
    final config = MosaicConfig(
      centerRa: centerRa,
      centerDec: centerDec,
      panelWidthArcmin: widthArcmin,
      panelHeightArcmin: heightArcmin,
      overlapPercent: overlapPct,
      rotation: positionAngleDeg,
      panelsHorizontal: cols,
      panelsVertical: rows,
    );
    final panels = _geometry.generatePanels(config);

    // The whole layout — project row, per-panel target rows, panel rows — is a
    // single unit. If anything throws midway, the transaction rolls back so we
    // never leave a project with a partial panel/target set.
    return _db.transaction(() async {
      final projectId = await _projectsDao.create(
        targetId: targetId,
        name: name,
        rows: rows,
        cols: cols,
        overlapPct: overlapPct,
        positionAngleDeg: positionAngleDeg,
      );

      for (final panel in panels) {
        // Skip cells the user disabled in the wizard (e.g. a corner occluded by
        // trees). The grid geometry is unchanged, so surviving panels keep their
        // canonical row-major panelIndex — the persisted panel_index set is
        // simply sparse, which the capture/integrate paths already tolerate.
        if (disabledCells.contains((row: panel.row, col: panel.col))) continue;

        // Each panel is a DISTINCT capture target. Honor a caller override when
        // it returns a non-null id; otherwise create a fresh per-panel target
        // centered on the panel so its subs are isolated for integration.
        final overrideId = panelTargetId?.call(panel.panelIndex);
        final panelTarget =
            overrideId ??
            await _createPanelTarget(projectName: name, panel: panel);
        await _panelsDao.upsert(
          projectId: projectId,
          panelIndex: panel.panelIndex,
          centerRa: panel.raHours,
          centerDec: panel.decDegrees,
          targetId: panelTarget,
        );
      }

      return projectId;
    });
  }

  // 2. Capture — launch the per-panel-target mosaic sequence into the executor.

  /// LAUNCH capture for [projectId]: resolve each panel's distinct capture
  /// target, hand the app layer a [MosaicCaptureRequest] so it can build the
  /// per-panel-target mosaic sequence (via
  /// [MosaicService.createMosaicSequence], stamping each panel's
  /// `TargetHeaderNode.catalogTargetId`) and load it into the executor, then
  /// drive the project + panels into the capturing state.
  ///
  /// The per-panel target map is REQUIRED to be fully populated and DISTINCT —
  /// every panel must carry its own `target_id` (so a panel's subs attribute to
  /// that panel and only that panel). A missing per-panel target, or two panels
  /// sharing one, is a [StateError]: it would silently make several panels fold
  /// the SAME subs and is exactly the bug this durable project exists to avoid.
  ///
  /// Returns the resolved [MosaicCaptureRequest] (after the launcher accepts the
  /// run) so callers can inspect/log the per-panel target map.
  Future<MosaicCaptureRequest> startCapture(
    int projectId, {
    required MosaicCaptureLauncher launcher,
  }) async {
    final project = await _projectsDao.getById(projectId);
    if (project == null) {
      throw ArgumentError('no mosaic project with id $projectId');
    }
    final panels = await _panelsDao.getForProject(projectId);
    if (panels.isEmpty) {
      throw StateError('mosaic project $projectId has no panels to capture');
    }

    // Resolve + validate the per-panel target map: every panel distinct.
    final panelTargetIds = _resolveDistinctPanelTargets(projectId, panels);

    final request = MosaicCaptureRequest(
      project: project,
      panels: panels,
      panelTargetIds: panelTargetIds,
    );

    // Hand the per-panel sequence off to the launcher (app layer builds the
    // sequence + loads the executor). Only AFTER it accepts do we flip state —
    // a launcher throw leaves the project untouched.
    await launcher(request);

    await _projectsDao.updateStatus(projectId, MosaicProjectStatus.capturing);
    for (final panel in panels) {
      final panelId = panel.id;
      if (panelId == null) continue;
      // Already-integrated panels keep their terminal state; the rest are now
      // actively capturing.
      if (panel.status == MosaicPanelStatus.integrated) continue;
      await _panelsDao.updateStatus(panelId, MosaicPanelStatus.capturing);
    }

    return request;
  }

  // 3. Integrate — turn each panel's captured subs into a per-panel master.

  /// Integrate every panel of [projectId]: for each panel, gather its accepted
  /// captured subs (by the panel's `target_id`), run the existing
  /// [PostSessionIntegrationService.integrate], and link the produced per-panel
  /// master onto `mosaic_panels.integrated_master_id`.
  ///
  /// **Distinct-target guard.** Before integrating, the panels' targets are
  /// validated to be distinct (every panel has its own `target_id`, none
  /// shared) — two panels resolving to the same target would fold identical
  /// subs into "different" panels, which is never correct.
  ///
  /// **Fail-soft per panel.** A panel with no captured subs is left
  /// [MosaicPanelStatus.pending] (nothing to do yet); a panel whose integration
  /// throws is marked [MosaicPanelStatus.failed], has its
  /// `integrated_master_id` cleared, and the loop moves on. One bad panel never
  /// aborts the rest.
  ///
  /// **Re-integration is idempotent.** When a panel already carried a master,
  /// its previous `integrated_masters` row AND its on-disk FITS/preview/rejmap
  /// are superseded (deleted) before the fresh master is linked, so a re-run
  /// never leaves an orphan master/file behind, and `captured_count` is SET to
  /// the fresh accepted population (not accumulated).
  ///
  /// The project is moved to [MosaicProjectStatus.integrating] for the run.
  /// [outputFitsPathBuilder] maps a panel to that panel's master FITS base path
  /// (the preview / rejection map are derived by extension swap inside the
  /// integration service). Returns one outcome per panel.
  Future<List<MosaicPanelIntegrationOutcome>> integratePanels(
    int projectId, {
    required IntegrationSettings settings,
    required String Function(MosaicProjectPanel panel) outputFitsPathBuilder,
  }) async {
    final project = await _projectsDao.getById(projectId);
    if (project == null) {
      throw ArgumentError('no mosaic project with id $projectId');
    }
    final panels = await _panelsDao.getForProject(projectId);
    if (panels.isEmpty) {
      throw StateError('mosaic project $projectId has no panels to integrate');
    }

    // Guard: panels must not share a capture target (would fold identical subs).
    // A panel that legitimately has no target yet is tolerated (left pending in
    // _integratePanel); only an ACTUAL collision among set targets is fatal.
    _assertNoSharedPanelTargets(projectId, panels);

    await _projectsDao.updateStatus(projectId, MosaicProjectStatus.integrating);

    final outcomes = <MosaicPanelIntegrationOutcome>[];
    for (final panel in panels) {
      outcomes.add(
        await _integratePanel(
          project: project,
          panel: panel,
          settings: settings,
          outputFitsPathBuilder: outputFitsPathBuilder,
        ),
      );
    }
    return outcomes;
  }

  // 4. Stitch — project the panel masters onto one shared canvas.

  /// Stitch [projectId]'s integrated panels into one mosaic master.
  ///
  /// Gathers every panel that carries a per-panel master with a FITS path on
  /// disk AND a usable WCS (persisted v44 CD-matrix `wcs`, or one the native
  /// side can read from the FITS header), builds the `api_stitch_mosaic`
  /// request, calls [PostSessionSeam.stitchMosaic], persists the stitched output
  /// as a NEW `integrated_masters` row (with the returned canvas geometry),
  /// links it onto `mosaic_projects.output_master_id`, and marks the project
  /// [MosaicProjectStatus.complete].
  ///
  /// **WCS gate.** A panel master with NO WCS (neither a persisted CD-matrix nor
  /// a WCS-bearing FITS header) would make the native stitcher abort the WHOLE
  /// mosaic. Such a panel is SKIPPED and reported in [MosaicStitchOutcome.skips]
  /// rather than handed to the stitcher. The `>= 2` gate then applies to the
  /// panels that ACTUALLY have WCS: a mosaic of one WCS panel is not a mosaic.
  ///
  /// Output artifacts land under the project folder via [outputDirectory]
  /// (`<dir>/<project>_mosaic.fits` + `_coverage.fits` + `.png`).
  ///
  /// If the stitch throws, the project status is reverted off `stitching`
  /// (back to `integrating`) so a failed run never leaves the project pinned in
  /// a stuck `stitching` state.
  Future<MosaicStitchOutcome> stitchProject(
    int projectId, {
    required String outputDirectory,
    Map<String, dynamic>? stitchConfig,
    Future<bool> Function(String fitsPath)? fitsHasWcs,
  }) async {
    final project = await _projectsDao.getById(projectId);
    if (project == null) {
      throw ArgumentError('no mosaic project with id $projectId');
    }

    final panels = await _panelsDao.getForProject(projectId);
    final panelArgs = <Map<String, dynamic>>[];
    final skips = <MosaicPanelStitchSkip>[];
    for (final panel in panels) {
      final masterId = panel.integratedMasterId;
      if (masterId == null) {
        // No master is not a "skip to report" — the panel simply was not
        // integrated. Only count panels that HAD a master but lacked WCS/FITS.
        continue;
      }
      final master = await _mastersDao.getById(masterId);
      final fitsPath = master?.masterFitsPath;
      if (master == null || fitsPath == null || fitsPath.trim().isEmpty) {
        skips.add(
          MosaicPanelStitchSkip(
            panelIndex: panel.panelIndex,
            integratedMasterId: masterId,
            reason: 'panel master has no FITS path on disk',
          ),
        );
        continue;
      }

      // FITS-existence gate: a non-empty path is NOT proof the file is on
      // disk. A master FITS removed by a temp sweep on legacy data, a manual
      // cleanup, or a supersession bug reaches the native stitcher, which fails
      // to read it and ABORTS THE WHOLE MOSAIC, defeating the per-panel
      // skip-gate. Existence is probed (best-effort, like the WCS probe) and a
      // missing file degrades to a skipped panel so one bad panel never poisons
      // the stitch.
      if (!await _safeFitsExists(fitsPath)) {
        skips.add(
          MosaicPanelStitchSkip(
            panelIndex: panel.panelIndex,
            integratedMasterId: masterId,
            reason:
                'panel master FITS missing on disk — skipped so it does not '
                'abort the whole mosaic',
          ),
        );
        continue;
      }

      // WCS gate: a WCS-less panel aborts the whole native stitch. Prefer the
      // persisted CD-matrix; otherwise allow the panel only when the FITS header
      // itself carries a WCS (probed via [fitsHasWcs] when supplied). Without
      // either, skip + report instead of poisoning the mosaic.
      final wcs = _wcsArgs(master);
      if (wcs == null) {
        final headerHasWcs = fitsHasWcs == null
            ? false
            : await _safeFitsHasWcs(fitsHasWcs, fitsPath);
        if (!headerHasWcs) {
          skips.add(
            MosaicPanelStitchSkip(
              panelIndex: panel.panelIndex,
              integratedMasterId: masterId,
              reason:
                  'panel master has no WCS (no persisted CD-matrix and no '
                  'WCS in the FITS header) — skipped so it does not abort the '
                  'whole mosaic',
            ),
          );
          continue;
        }
      }

      panelArgs.add(<String, dynamic>{
        'fitsPath': fitsPath,
        if (wcs != null) 'wcs': wcs,
      });
    }

    final contributingMasters = panelArgs.length;
    if (contributingMasters < 2) {
      throw StateError(
        'mosaic project $projectId needs >= 2 panels with integrated masters '
        'AND a usable WCS to stitch (found $contributingMasters'
        '${skips.isEmpty ? '' : '; skipped ${skips.length} WCS-less/'
                  'pathless panel${skips.length == 1 ? '' : 's'}'})',
      );
    }

    await _projectsDao.updateStatus(projectId, MosaicProjectStatus.stitching);

    try {
      final base = _join(outputDirectory, '${_slug(project.name)}_mosaic');
      final args = <String, dynamic>{
        'panels': panelArgs,
        if (stitchConfig != null) 'config': stitchConfig,
        'output': <String, dynamic>{
          'mosaicFitsPath': '$base.fits',
          'coverageFitsPath': '${base}_coverage.fits',
          'previewPngPath': '$base.png',
        },
      };

      final stitch = await _seam.stitchMosaic(args);

      // Persist the stitched mosaic as a first-class integrated master so it
      // lands in the master library + morning report unchanged, then link it.
      final masterId = await _mastersDao.insertMaster(
        targetId: project.targetId,
        name: '${project.name} · Mosaic',
        masterFitsPath: stitch.outputPath,
        previewPngPath: stitch.previewPath,
        sidecarPath: null,
        rejectionMapPath: null,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        width: stitch.outWidth,
        height: stitch.outHeight,
        frameCount: contributingMasters,
        statsJson: _stitchStatsJson(stitch, contributingMasters),
      );

      // The stitcher stamps the output-canvas WCS into the mosaic FITS header
      // (`api_stitch_mosaic`) but does not surface it in the JSON result, so the
      // mosaic master's DB WCS columns are populated later by the same
      // plate-solve/header-read path every other master uses — not from here.

      // setOutputMaster also flips status -> complete + bumps updated_at.
      await _projectsDao.setOutputMaster(projectId, masterId);

      return MosaicStitchOutcome(
        outputMasterId: masterId,
        panelCount: contributingMasters,
        result: stitch,
        skips: skips,
      );
    } catch (e, st) {
      // A stitch throw must not pin the project in `stitching`. Revert to
      // `integrating` (the panels are integrated; the stitch can be retried)
      // so the project never sticks in a dead phase.
      _logSoftFailure('stitchProject[$projectId]', e, st);
      try {
        await _projectsDao.updateStatus(
          projectId,
          MosaicProjectStatus.integrating,
        );
      } catch (revertError, revertSt) {
        _logSoftFailure(
          'stitchProject[$projectId] status revert',
          revertError,
          revertSt,
        );
      }
      rethrow;
    }
  }
}

/// Provider for [MosaicProjectService], wiring the v45 mosaic DAOs, the targets
/// DAO (per-panel capture targets), the images DAO, the integrated-masters DAO,
/// the post-session integration service, and the post-session seam (which
/// carries `stitchMosaic`).
final mosaicProjectServiceProvider = Provider<MosaicProjectService>((ref) {
  return MosaicProjectService(
    db: ref.watch(databaseProvider),
    projectsDao: ref.watch(mosaicProjectsDaoProvider),
    panelsDao: ref.watch(mosaicPanelsDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
    imagesDao: ref.watch(imagesDaoProvider),
    mastersDao: ref.watch(integratedMastersDaoProvider),
    integrationService: ref.watch(postSessionIntegrationServiceProvider),
    seam: ref.watch(postSessionSeamProvider),
  );
});
