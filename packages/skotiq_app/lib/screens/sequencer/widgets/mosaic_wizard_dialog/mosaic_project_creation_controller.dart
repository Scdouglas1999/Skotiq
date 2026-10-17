// Mosaic M3 — planner-wiring: persist the wizard's current mosaic design as a
// durable [MosaicProject].
//
// This is the thin glue the brief asks for: it does NOT re-derive any geometry
// (the per-panel centres come from `MosaicService.generatePanels` inside
// [MosaicProjectService.createProject]); it only takes the design the wizard
// already holds — target centre RA/Dec, rows × cols, overlap %, position angle,
// and the per-panel FOV/dims already computed on screen — and hands them to the
// committed M2 service, returning the new `mosaic_projects.id` so the caller can
// route to `/mosaic/:id`.
//
// Splitting this out of the widget keeps the persist contract unit-testable
// without pumping a dialog: a test can drive [MosaicProjectCreationController]
// directly and assert it calls `createProject` with the design's values.

import 'package:skotiq_core/skotiq_core.dart';

/// The snapshot of the wizard's mosaic design that becomes a durable project.
///
/// These are exactly the values the Mosaic Wizard already maintains as it draws
/// the grid over the sky (centre RA/Dec, grid size, overlap, rotation, per-panel
/// FOV in arcmin). Carrying them in one value object keeps the persist call
/// (and its test) independent of the dialog's internal state fields.
class MosaicProjectDesign {
  /// Operator-facing project name (e.g. `Mosaic 12.50h 30.0°`).
  final String name;

  /// Target / mosaic centre right ascension, in HOURS (matches [MosaicConfig]
  /// and [MosaicProjectService.createProject]).
  final double centerRaHours;

  /// Target / mosaic centre declination, in DEGREES.
  final double centerDecDegrees;

  /// Grid rows (vertical panel count).
  final int rows;

  /// Grid columns (horizontal panel count).
  final int cols;

  /// Panel-to-panel overlap, as a percentage of frame size.
  final double overlapPercent;

  /// Mosaic-wide position angle (degrees), applied to every panel.
  final double positionAngleDeg;

  /// Single-panel field-of-view width (arcmin) — the FOV the wizard already
  /// computed from the rig optics + sensor for the on-screen footprints.
  final double panelWidthArcmin;

  /// Single-panel field-of-view height (arcmin).
  final double panelHeightArcmin;

  /// Grid cells (0-based row/col) the user disabled in the wizard. These panels
  /// are NOT persisted as `mosaic_panels` rows, but the grid geometry
  /// (rows × cols) is unchanged so surviving panels keep their canonical
  /// row-major [MosaicPanel.panelIndex]. Empty => every panel is created.
  final Set<({int row, int col})> disabledCells;

  /// The framed region's `targets.id`, when the design came from a saved
  /// target; null for an ad-hoc centre.
  final int? targetId;

  /// Optional map from a panel's 0-based row-major index to the DB `targets.id`
  /// that panel should image. Forwarded to
  /// [MosaicProjectService.createProject] so each `mosaic_panels` row carries
  /// its OWN capture target (and so a launched capture sequence can stamp the
  /// matching per-panel `TargetHeaderNode.catalogTargetId`). `null` => every
  /// panel inherits the project [targetId] (the legacy pooled behaviour where
  /// `integratePanels` would integrate the same field for every panel).
  final int? Function(int panelIndex)? panelTargetId;

  const MosaicProjectDesign({
    required this.name,
    required this.centerRaHours,
    required this.centerDecDegrees,
    required this.rows,
    required this.cols,
    required this.overlapPercent,
    required this.positionAngleDeg,
    required this.panelWidthArcmin,
    required this.panelHeightArcmin,
    this.disabledCells = const {},
    this.targetId,
    this.panelTargetId,
  });
}

/// Persists a [MosaicProjectDesign] into a durable [MosaicProject] via the
/// committed [MosaicProjectService].
///
/// Deliberately tiny: one method that forwards the design's values to
/// [MosaicProjectService.createProject] and returns the new project id. It owns
/// no geometry and no navigation — the caller routes to `/mosaic/:id` with the
/// returned id. Kept as a plain class (not a Notifier) so a controller test can
/// construct it with a fake service and assert the forwarded arguments.
class MosaicProjectCreationController {
  const MosaicProjectCreationController(this._service);

  final MosaicProjectService _service;

  /// Create the durable project for [design] and return its new
  /// `mosaic_projects.id`.
  ///
  /// The per-panel rows are laid out by the service from the same grid math the
  /// wizard previews; this method adds nothing but the forwarding of the design
  /// the user already shaped on screen.
  Future<int> createProject(MosaicProjectDesign design) {
    return _service.createProject(
      name: design.name,
      rows: design.rows,
      cols: design.cols,
      centerRa: design.centerRaHours,
      centerDec: design.centerDecDegrees,
      targetId: design.targetId,
      overlapPct: design.overlapPercent,
      positionAngleDeg: design.positionAngleDeg,
      panelWidthArcmin: design.panelWidthArcmin,
      panelHeightArcmin: design.panelHeightArcmin,
      panelTargetId: design.panelTargetId,
      disabledCells: design.disabledCells,
    );
  }
}
