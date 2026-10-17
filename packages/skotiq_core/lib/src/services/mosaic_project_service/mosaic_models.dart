part of '../mosaic_project_service.dart';

/// What [MosaicProjectService.startCapture] hands the app layer so it can build
/// the per-panel mosaic sequence and load it into the executor.
///
/// The service lives in `skotiq_core` and deliberately owns NO reference to
/// the app-layer `currentSequenceProvider` / `sequenceExecutorProvider`. Instead
/// it resolves the durable per-panel capture targets and the project geometry,
/// then hands them to this launcher — the app controller wires the real
/// [MosaicService.createMosaicSequence] (stamping each panel's
/// `TargetHeaderNode.catalogTargetId` from [panelTargetIds]) and starts the run.
typedef MosaicCaptureLauncher =
    Future<void> Function(MosaicCaptureRequest request);

/// The durable inputs [MosaicProjectService.startCapture] resolved for one
/// capture run — everything the launcher needs to build a per-panel-target
/// mosaic sequence without re-reading the DB.
class MosaicCaptureRequest {
  /// The project being launched.
  final MosaicProject project;

  /// The project's panels, ordered by `panel_index`.
  final List<MosaicProjectPanel> panels;

  /// Per-panel capture target ids keyed by 0-based `panel_index`. Every panel
  /// has a DISTINCT entry (the service guarantees this), so the launcher can
  /// stamp each panel's `TargetHeaderNode.catalogTargetId` and the subs each
  /// panel captures attribute to its own target.
  final Map<int, int> panelTargetIds;

  const MosaicCaptureRequest({
    required this.project,
    required this.panels,
    required this.panelTargetIds,
  });
}

/// One panel's outcome from [MosaicProjectService.integratePanels] — what the
/// caller (and the morning-report UI) needs to show per-panel progress without
/// re-reading the DB.
class MosaicPanelIntegrationOutcome {
  /// The `mosaic_panels.id` this outcome describes.
  final int panelId;

  /// The panel's 0-based grid index (matches the FITS `NS-PIDX` provenance).
  final int panelIndex;

  /// The per-panel `integrated_masters.id` produced, or null when the panel was
  /// skipped (no subs) or failed.
  final int? integratedMasterId;

  /// The panel's terminal status after this run
  /// ([MosaicPanelStatus.integrated] / [MosaicPanelStatus.failed] /
  /// [MosaicPanelStatus.pending] when skipped for want of subs).
  final MosaicPanelStatus status;

  /// Number of accepted subs that fed the panel's integration.
  final int subCount;

  /// A human-readable note when the panel was skipped or failed (null on
  /// success). Surfaced so the report can explain a weak/missing panel.
  final String? note;

  const MosaicPanelIntegrationOutcome({
    required this.panelId,
    required this.panelIndex,
    required this.integratedMasterId,
    required this.status,
    required this.subCount,
    this.note,
  });

  /// True when the panel produced a per-panel master this run.
  bool get integrated => integratedMasterId != null;
}

/// One panel's outcome from [MosaicProjectService.stitchProject]'s contribution
/// gate — surfaced so the UI/report can explain a panel the stitcher SKIPPED
/// (no master, no FITS on disk, or no WCS) instead of silently dropping it.
class MosaicPanelStitchSkip {
  /// The skipped panel's 0-based grid index.
  final int panelIndex;

  /// The panel's `integrated_masters.id`, or null when it had no master at all.
  final int? integratedMasterId;

  /// Why the panel was not handed to the stitcher.
  final String reason;

  const MosaicPanelStitchSkip({
    required this.panelIndex,
    required this.integratedMasterId,
    required this.reason,
  });
}

/// The result of [MosaicProjectService.stitchProject] — the persisted mosaic
/// master id, how many panels contributed, the raw native stitch result, and
/// any panels the WCS gate SKIPPED.
class MosaicStitchOutcome {
  /// The new `integrated_masters.id` for the stitched mosaic master (also set as
  /// the project's `output_master_id`).
  final int outputMasterId;

  /// How many panel masters were projected onto the canvas.
  final int panelCount;

  /// The decoded native stitch result (canvas geometry + diagnostics).
  final MosaicStitchResult result;

  /// Panels that carried a master but were SKIPPED (no FITS / no WCS) so they
  /// did not abort the whole mosaic. Empty when every panel-with-master
  /// contributed.
  final List<MosaicPanelStitchSkip> skips;

  const MosaicStitchOutcome({
    required this.outputMasterId,
    required this.panelCount,
    required this.result,
    this.skips = const [],
  });
}
