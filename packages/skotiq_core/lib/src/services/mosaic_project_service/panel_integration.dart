part of '../mosaic_project_service.dart';

extension _MosaicPanelIntegration on MosaicProjectService {
  /// Create a `targets` row for one panel, centered on the panel's RA/Dec, and
  /// return its id. The panel target is what subsequent capture + integration
  /// attribute to, so each panel folds only its own frames.
  Future<int> _createPanelTarget({
    required String projectName,
    required MosaicPanel panel,
  }) {
    final baseName = projectName.trim().isEmpty ? 'Mosaic' : projectName.trim();
    return _targetsDao.createTarget(
      TargetsCompanion.insert(
        name: '$baseName Panel ${panel.panelIndex + 1}',
        ra: panel.raHours,
        dec: panel.decDegrees,
        objectType: const Value('mosaic-panel'),
      ),
    );
  }

  /// Build the `panel_index -> target_id` map for a project and assert every
  /// panel carries a DISTINCT capture target. A missing or shared target is a
  /// [StateError] — several panels folding the same subs is the precise bug the
  /// durable per-panel-target model prevents.
  Map<int, int> _resolveDistinctPanelTargets(
    int projectId,
    List<MosaicProjectPanel> panels,
  ) {
    final byIndex = <int, int>{};
    final seen = <int, int>{}; // targetId -> first panelIndex that used it.
    for (final panel in panels) {
      final targetId = panel.targetId;
      if (targetId == null) {
        throw StateError(
          'mosaic project $projectId panel ${panel.panelIndex} has no capture '
          'target — every panel must carry its own target_id',
        );
      }
      final priorPanel = seen[targetId];
      if (priorPanel != null) {
        throw StateError(
          'mosaic project $projectId panels $priorPanel and ${panel.panelIndex} '
          'resolve to the SAME capture target ($targetId); panels must not '
          'share a target or they would fold each other\'s subs',
        );
      }
      seen[targetId] = panel.panelIndex;
      byIndex[panel.panelIndex] = targetId;
    }
    return byIndex;
  }

  /// Assert no two panels with a SET `target_id` resolve to the same target.
  /// Panels with a null target (project target also null) are tolerated — they
  /// are simply left pending. Falls back to the project target for the
  /// collision check so two panels inheriting one project target are caught too.
  void _assertNoSharedPanelTargets(
    int projectId,
    List<MosaicProjectPanel> panels,
  ) {
    final seen = <int, int>{}; // resolvedTargetId -> first panelIndex.
    for (final panel in panels) {
      // Per-panel target only: the project-region target is intentionally NOT a
      // capture target. A panel without its own target is "no subs yet", not a
      // collision.
      final targetId = panel.targetId;
      if (targetId == null) continue;
      final prior = seen[targetId];
      if (prior != null) {
        throw StateError(
          'mosaic project $projectId panels $prior and ${panel.panelIndex} '
          'share capture target $targetId; each panel must isolate its own '
          'subs — refusing to integrate identical subs into different panels',
        );
      }
      seen[targetId] = panel.panelIndex;
    }
  }

  Future<MosaicPanelIntegrationOutcome> _integratePanel({
    required MosaicProject project,
    required MosaicProjectPanel panel,
    required IntegrationSettings settings,
    required String Function(MosaicProjectPanel panel) outputFitsPathBuilder,
  }) async {
    final panelId = panel.id;
    if (panelId == null) {
      // An unsaved panel cannot be linked — should never happen for a row read
      // back from the DAO, but stays honest rather than crashing the loop.
      return MosaicPanelIntegrationOutcome(
        panelId: -1,
        panelIndex: panel.panelIndex,
        integratedMasterId: null,
        status: MosaicPanelStatus.failed,
        subCount: 0,
        note: 'panel row has no id',
      );
    }

    // Each panel is a distinct capture target. The per-panel target_id is the
    // ONLY capture target (the project-region target is not a capture target).
    final captureTargetId = panel.targetId;
    if (captureTargetId == null) {
      await _panelsDao.updateStatus(panelId, MosaicPanelStatus.pending);
      return MosaicPanelIntegrationOutcome(
        panelId: panelId,
        panelIndex: panel.panelIndex,
        integratedMasterId: null,
        status: MosaicPanelStatus.pending,
        subCount: 0,
        note: 'panel has no capture target',
      );
    }

    try {
      final subs = await _acceptedSubsForTarget(captureTargetId);
      if (subs.isEmpty) {
        await _panelsDao.updateStatus(panelId, MosaicPanelStatus.pending);
        return MosaicPanelIntegrationOutcome(
          panelId: panelId,
          panelIndex: panel.panelIndex,
          integratedMasterId: null,
          status: MosaicPanelStatus.pending,
          subCount: 0,
          note: 'no accepted subs captured yet',
        );
      }

      final panelBase = outputFitsPathBuilder(panel);
      final outcomes = await _integration.integrate(
        subs: subs,
        settings: settings,
        targetId: captureTargetId,
        targetName: project.name.isEmpty
            ? 'Panel ${panel.panelIndex + 1}'
            : '${project.name} Panel ${panel.panelIndex + 1}',
        // Each per-filter master MUST get a distinct file: the integration
        // service derives the preview/.png + rejection map from this path and
        // overwrites the FITS in place, so handing every filter group the same
        // base path would have each filter clobber the previous filter's
        // artifacts on disk. Suffix the bucket (e.g. `panel_0_R.fits`) so an
        // L+R+G+B panel yields four distinct masters; the unfiltered bucket
        // keeps the bare base path so the single-filter path is unchanged.
        outputFitsPathBuilder: (bucket) =>
            bucket == PostSessionIntegrationService.noFilterBucket
            ? panelBase
            : _suffixBeforeExtension(panelBase, '_$bucket'),
        hintRaHours: panel.centerRa,
        hintDecDegrees: panel.centerDec,
      );

      // A panel is one sky region; the stitcher consumes a single master per
      // panel. When several filters were captured, pick a deliberate
      // representative (luminance if present, else the highest frame-count
      // outcome) rather than relying on filter-group iteration order, which is
      // merely the order of the first accepted sub per filter. The per-filter
      // masters all share the panel's WCS, so the representative's on-disk
      // pixels are the ones the stitcher will project.
      final masterId = _representativeMasterId(outcomes);

      // RE-INTEGRATION: supersede the panel's previous master (DB row + on-disk
      // FITS/preview/rejmap) before linking the new one, so a re-run never
      // leaves an orphan. Skip if the panel happens to re-link the same id.
      //
      // Supersession is PATH-AWARE, not just id-aware. The per-panel master
      // FITS is written to a DURABLE
      // DETERMINISTIC path (`project_<id>/panel_<i>[_<filter>].fits`) that is
      // IDENTICAL across re-runs, so the freshly-written master and the prior
      // master share a path. An id-only skip guard would then delete the prior
      // master's `masterFitsPath` — which is the SAME file the new master was
      // just written to — leaving the panel linked to a live DB row whose FITS
      // is gone, and aborting the whole stitch. Collect every on-disk path
      // OWNED by the freshly-produced per-filter masters for this panel and pass
      // it to supersession so any prior path that equals a new path is NEVER
      // deleted.
      final keepPaths = await _ownedOnDiskPaths(outcomes);
      await _supersedePreviousMaster(
        panel,
        keepMasterId: masterId,
        keepPaths: keepPaths,
      );

      await _panelsDao.setMaster(panelId, masterId);
      // SET (not +=) so a re-integration with the same/refreshed accepted set
      // lands the count at the current population, never doubling it.
      await _panelsDao.setCaptured(panelId, subs.length);

      return MosaicPanelIntegrationOutcome(
        panelId: panelId,
        panelIndex: panel.panelIndex,
        integratedMasterId: masterId,
        status: MosaicPanelStatus.integrated,
        subCount: subs.length,
      );
    } catch (e, st) {
      _logSoftFailure('integratePanel[${panel.panelIndex}]', e, st);
      // On a failed integrate, clear any stale link so the panel does not
      // appear "integrated" with a master that no longer reflects a good run.
      await _panelsDao.updateStatus(panelId, MosaicPanelStatus.failed);
      await _clearPanelMaster(panelId);
      return MosaicPanelIntegrationOutcome(
        panelId: panelId,
        panelIndex: panel.panelIndex,
        integratedMasterId: null,
        status: MosaicPanelStatus.failed,
        subCount: 0,
        note: 'integration failed: $e',
      );
    }
  }

  /// Collect the set of on-disk artifact paths OWNED by the freshly-produced
  /// per-filter masters for a panel (FITS / preview / rejection map / sidecar
  /// across EVERY outcome, not just the representative). Supersession must never
  /// delete a path in this set — on the durable deterministic path the prior
  /// and new masters share a FITS path, so deleting the prior's path would
  /// destroy the file the new master was just written to.
  Future<Set<String>> _ownedOnDiskPaths(
    List<PostSessionIntegrationOutcome> outcomes,
  ) async {
    final owned = <String>{};
    for (final outcome in outcomes) {
      final master = await _mastersDao.getById(outcome.masterId);
      if (master == null) continue;
      for (final path in <String?>[
        master.masterFitsPath,
        master.previewPngPath,
        master.rejectionMapPath,
        master.rejectionMapPreviewPath,
        master.coverageMapPath,
        master.coverageMapPreviewPath,
        master.sidecarPath,
      ]) {
        if (path != null && path.trim().isNotEmpty) owned.add(path);
      }
    }
    return owned;
  }

  /// Delete the panel's previously-linked master row + its on-disk artifacts so
  /// a re-integration never orphans the old master/files. No-op when the panel
  /// had no prior master, or when the prior master IS the freshly-produced one
  /// ([keepMasterId]) — the per-filter integration may reuse a master row.
  ///
  /// [keepPaths] holds the on-disk paths owned by the freshly-produced
  /// master(s). A prior path that equals a kept path is NOT deleted: on the
  /// deterministic path the new master FITS shares the prior master's path, and
  /// an id-only guard would delete the live, just-written file.
  Future<void> _supersedePreviousMaster(
    MosaicProjectPanel panel, {
    required int keepMasterId,
    required Set<String> keepPaths,
  }) async {
    final priorId = panel.integratedMasterId;
    if (priorId == null || priorId == keepMasterId) return;
    final prior = await _mastersDao.getById(priorId);
    if (prior == null) return;
    await _deleteMasterArtifactsOnDisk(prior, keepPaths: keepPaths);
    await _mastersDao.deleteMaster(priorId);
  }

  /// Best-effort delete a master's on-disk FITS / preview / rejection map /
  /// sidecar. A missing file is fine (already gone); a delete error is logged
  /// but never aborts the integration — the DB row supersession is what matters.
  ///
  /// Any path in [keepPaths] is SKIPPED — it belongs to the freshly-produced
  /// master(s) (same durable deterministic path), so deleting it would destroy
  /// a live, just-written file.
  Future<void> _deleteMasterArtifactsOnDisk(
    IntegratedMaster master, {
    Set<String> keepPaths = const <String>{},
  }) async {
    for (final path in <String?>[
      master.masterFitsPath,
      master.previewPngPath,
      master.rejectionMapPath,
      master.rejectionMapPreviewPath,
      master.coverageMapPath,
      master.coverageMapPreviewPath,
      master.sidecarPath,
    ]) {
      if (path == null || path.trim().isEmpty) continue;
      if (keepPaths.contains(path)) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e, st) {
        _logSoftFailure('deleteMasterArtifact($path)', e, st);
      }
    }
  }

  /// Clear a panel's `integrated_master_id` link (without deleting the master),
  /// returning it to pending — used when a panel's integration throws so it
  /// does not masquerade as integrated.
  Future<void> _clearPanelMaster(int panelId) async {
    await _panelsDao.clearMaster(panelId);
  }
}
