/// Durable mosaic project + panel records (Mosaic M2, v45).
///
/// A [MosaicProject] makes a mosaic a first-class durable entity: it links the
/// grid configuration (rows × cols, overlap, position angle) to its per-panel
/// capture targets ([MosaicProjectPanel] rows) and, once stitched, to the final
/// integrated mosaic master.
///
/// The two records map 1:1 to the raw-DDL `mosaic_projects` / `mosaic_panels`
/// tables (see [SkotiqDatabase._createMosaicTables]) and are read/written
/// via the plain [MosaicProjectsDao] / [MosaicPanelsDao]
/// (`customSelect`/`customInsert`), mirroring `CampaignsDao` /
/// `NarrowbandCompositesDao`.
///
/// Naming note: the capture-geometry value object [MosaicPanel] in
/// `services/mosaic_service.dart` is an in-memory generation result and already
/// occupies the `MosaicPanel` name in the barrel. The DURABLE per-panel record
/// is therefore [MosaicProjectPanel] to avoid a barrel-export collision.
library;

/// Lifecycle status of a [MosaicProject].
///
/// Stored as the lowercase string in `mosaic_projects.status`. Parsing is
/// tolerant: an unknown/garbled value maps to [planning] so a read never throws.
enum MosaicProjectStatus {
  /// Designed but not yet capturing — the grid is laid out, panels exist.
  planning,

  /// Panels are being captured across one or more nights.
  capturing,

  /// All panels captured; per-panel masters are being integrated.
  integrating,

  /// Per-panel masters exist; the native stitcher is composing the canvas.
  stitching,

  /// The stitched mosaic master exists (`output_master_id` is set).
  complete;

  /// The lowercase wire string stored in the DB.
  String get wire => name;

  /// Parse a stored status string, defaulting to [planning] on any
  /// unknown/null/blank value so a read never throws.
  static MosaicProjectStatus fromWire(String? value) {
    switch (value) {
      case 'capturing':
        return MosaicProjectStatus.capturing;
      case 'integrating':
        return MosaicProjectStatus.integrating;
      case 'stitching':
        return MosaicProjectStatus.stitching;
      case 'complete':
        return MosaicProjectStatus.complete;
      case 'planning':
      default:
        return MosaicProjectStatus.planning;
    }
  }
}

/// One durable mosaic project: a target region + grid configuration linking the
/// per-panel capture targets to the final stitched master.
class MosaicProject {
  /// DB primary key (`mosaic_projects.id`). Null for an unsaved record.
  final int? id;

  /// The framed region's `targets.id`, or null. `ON DELETE SET NULL` so a
  /// project survives its source target being removed.
  final int? targetId;

  /// Operator-facing project name (e.g. `Veil Nebula 3x2`).
  final String name;

  /// Grid rows (vertical panel count).
  final int rows;

  /// Grid columns (horizontal panel count).
  final int cols;

  /// Panel-to-panel overlap as a percentage of frame size.
  final double overlapPct;

  /// Mosaic-wide position angle (degrees), applied to every panel.
  final double positionAngleDeg;

  /// Lifecycle status.
  final MosaicProjectStatus status;

  /// The stitched output's `integrated_masters.id`, or null until the stitcher
  /// has produced the mosaic master. `ON DELETE SET NULL`.
  final int? outputMasterId;

  /// When the project row was created (UTC).
  final DateTime createdAt;

  /// When the project row was last updated (UTC).
  final DateTime updatedAt;

  /// The hub mosaic id once this project has been published as a collaborative
  /// mosaic, or null for a local-only project. The handle the panel claim
  /// broker / upload / assemble endpoints act on.
  final String? hubMosaicId;

  /// This device's collaborative role for the published mosaic: `owner` (the rig
  /// that published + assembles) or `participant` (a rig that claimed panels), or
  /// null when not part of a collaborative mosaic.
  final String? collabRole;

  /// The hub-side collaborative lifecycle, mirrored locally: `published`,
  /// `assembling`, or `complete` — or null for a local-only project.
  final String? collabStatus;

  const MosaicProject({
    this.id,
    this.targetId,
    required this.name,
    required this.rows,
    required this.cols,
    this.overlapPct = 15.0,
    this.positionAngleDeg = 0.0,
    this.status = MosaicProjectStatus.planning,
    this.outputMasterId,
    required this.createdAt,
    required this.updatedAt,
    this.hubMosaicId,
    this.collabRole,
    this.collabStatus,
  });

  /// True once this project has been published to the hub as a collaborative
  /// mosaic (it carries a hub mosaic id).
  bool get isPublished => hubMosaicId != null && hubMosaicId!.isNotEmpty;

  /// Total panels in the grid.
  int get totalPanels => rows * cols;

  /// True once the stitched output master has been produced.
  bool get isComplete =>
      status == MosaicProjectStatus.complete || outputMasterId != null;

  MosaicProject copyWith({
    int? id,
    int? targetId,
    String? name,
    int? rows,
    int? cols,
    double? overlapPct,
    double? positionAngleDeg,
    MosaicProjectStatus? status,
    int? outputMasterId,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? hubMosaicId,
    String? collabRole,
    String? collabStatus,
  }) {
    return MosaicProject(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      name: name ?? this.name,
      rows: rows ?? this.rows,
      cols: cols ?? this.cols,
      overlapPct: overlapPct ?? this.overlapPct,
      positionAngleDeg: positionAngleDeg ?? this.positionAngleDeg,
      status: status ?? this.status,
      outputMasterId: outputMasterId ?? this.outputMasterId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      hubMosaicId: hubMosaicId ?? this.hubMosaicId,
      collabRole: collabRole ?? this.collabRole,
      collabStatus: collabStatus ?? this.collabStatus,
    );
  }

  @override
  String toString() =>
      'MosaicProject(id=$id, name=$name, ${rows}x$cols, '
      'status=${status.wire})';
}

/// Lifecycle status of a [MosaicProjectPanel].
///
/// Stored as the lowercase string in `mosaic_panels.status`. Unknown values map
/// to [pending].
enum MosaicPanelStatus {
  /// Not yet captured.
  pending,

  /// Capturing subs (one or more nights).
  capturing,

  /// Capture goal met; subs are on disk.
  captured,

  /// The panel's per-panel master has been integrated.
  integrated,

  /// Capture/integration failed for this panel.
  failed;

  /// The lowercase wire string stored in the DB.
  String get wire => name;

  /// Parse a stored status string, defaulting to [pending] on any
  /// unknown/null/blank value so a read never throws.
  static MosaicPanelStatus fromWire(String? value) {
    switch (value) {
      case 'capturing':
        return MosaicPanelStatus.capturing;
      case 'captured':
        return MosaicPanelStatus.captured;
      case 'integrated':
        return MosaicPanelStatus.integrated;
      case 'failed':
        return MosaicPanelStatus.failed;
      case 'pending':
      default:
        return MosaicPanelStatus.pending;
    }
  }
}

/// One durable mosaic panel row: its grid position, center RA/Dec, the
/// per-panel capture target, and (once integrated) its per-panel master.
///
/// The panel's plate-solved WCS rides on its `integrated_masters` row (v44 WCS
/// columns) via [integratedMasterId] — there are no duplicate WCS columns on
/// `mosaic_panels`.
class MosaicProjectPanel {
  /// DB primary key (`mosaic_panels.id`). Null for an unsaved record.
  final int? id;

  /// Owning `mosaic_projects.id`. `ON DELETE CASCADE`.
  final int projectId;

  /// 0-based panel index, matching the FITS `SK-PIDX` / `PANELIDX` provenance.
  final int panelIndex;

  /// Panel center right ascension. Units follow [MosaicPanel] (RA hours).
  final double centerRa;

  /// Panel center declination (degrees).
  final double centerDec;

  /// The per-panel capture `targets.id`, or null. Making each panel a real
  /// target reuses the existing `(target_id, filter)` campaign + integration
  /// goal machinery for per-panel goals across nights. `ON DELETE SET NULL`.
  final int? targetId;

  /// The per-panel master's `integrated_masters.id`, or null until integrated.
  /// `ON DELETE SET NULL`.
  final int? integratedMasterId;

  /// Number of accepted frames captured for this panel so far.
  final int capturedCount;

  /// Lifecycle status.
  final MosaicPanelStatus status;

  /// The hub rig fingerprint this panel is assigned to for distributed capture,
  /// or null when unclaimed. Free-text provenance only.
  final String? assignedRigId;

  /// The hub account id this panel is assigned to, or null when unclaimed.
  final String? assignedUserId;

  /// The hub-issued claim baton token held for this panel, or null.
  final String? claimToken;

  /// The local `integrated_masters.id` of the panel master uploaded to the hub
  /// for this panel, or null until uploaded.
  final int? uploadedMasterId;

  const MosaicProjectPanel({
    this.id,
    required this.projectId,
    required this.panelIndex,
    required this.centerRa,
    required this.centerDec,
    this.targetId,
    this.integratedMasterId,
    this.capturedCount = 0,
    this.status = MosaicPanelStatus.pending,
    this.assignedRigId,
    this.assignedUserId,
    this.claimToken,
    this.uploadedMasterId,
  });

  /// True once this panel has been claimed by a rig (it carries a claim token).
  bool get isClaimed => claimToken != null && claimToken!.isNotEmpty;

  /// True once this panel's master has been uploaded to the hub.
  bool get isUploaded => uploadedMasterId != null;

  /// A short provenance label for the rig/user this panel is assigned to for
  /// distributed capture, or null when unassigned. Prefers the hub account id
  /// (the human who claimed it), falling back to the rig fingerprint, so the
  /// grid can attribute each claimed panel.
  String? get assignedLabel {
    final user = assignedUserId?.trim();
    if (user != null && user.isNotEmpty) return user;
    final rig = assignedRigId?.trim();
    if (rig != null && rig.isNotEmpty) return rig;
    return null;
  }

  /// True once the panel's per-panel master has been integrated.
  bool get isIntegrated =>
      status == MosaicPanelStatus.integrated || integratedMasterId != null;

  MosaicProjectPanel copyWith({
    int? id,
    int? projectId,
    int? panelIndex,
    double? centerRa,
    double? centerDec,
    int? targetId,
    int? integratedMasterId,
    int? capturedCount,
    MosaicPanelStatus? status,
    String? assignedRigId,
    String? assignedUserId,
    String? claimToken,
    int? uploadedMasterId,
  }) {
    return MosaicProjectPanel(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      panelIndex: panelIndex ?? this.panelIndex,
      centerRa: centerRa ?? this.centerRa,
      centerDec: centerDec ?? this.centerDec,
      targetId: targetId ?? this.targetId,
      integratedMasterId: integratedMasterId ?? this.integratedMasterId,
      capturedCount: capturedCount ?? this.capturedCount,
      status: status ?? this.status,
      assignedRigId: assignedRigId ?? this.assignedRigId,
      assignedUserId: assignedUserId ?? this.assignedUserId,
      claimToken: claimToken ?? this.claimToken,
      uploadedMasterId: uploadedMasterId ?? this.uploadedMasterId,
    );
  }

  @override
  String toString() =>
      'MosaicProjectPanel(project=$projectId, idx=$panelIndex, '
      'RA=${centerRa.toStringAsFixed(4)}, Dec=${centerDec.toStringAsFixed(4)}, '
      'status=${status.wire})';
}
