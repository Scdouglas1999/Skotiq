// Mosaic project state and its snapshot value type.
part of '../mosaic_project_controller.dart';

/// Immutable snapshot the [MosaicProjectScreen] renders: the durable project, its
/// panels (ordered by index), the per-panel masters (so the grid can show a
/// thumbnail when a panel is integrated), and — once the project is complete —
/// the stitched output master.
///
/// Loading/busy/error are explicit fields rather than an `AsyncValue` so the
/// screen can show the project chrome immediately while an action (integrate /
/// stitch) runs, and surface a non-blocking error banner without tearing the
/// whole screen down.
class MosaicProjectState {
  /// The durable `mosaic_projects` row, or null before the first load resolves
  /// (or when the id does not exist).
  final MosaicProject? project;

  /// The project's panels, ordered by `panel_index`.
  final List<MosaicProjectPanel> panels;

  /// Per-panel integrated masters keyed by `mosaic_panels.integrated_master_id`,
  /// so the grid can render a panel's master thumbnail without re-querying.
  final Map<int, IntegratedMaster> panelMasters;

  /// The stitched mosaic master (the project's `output_master_id`), or null
  /// until the project is complete.
  final IntegratedMaster? stitchedMaster;

  /// True during the initial load (no project resolved yet).
  final bool isLoading;

  /// True while [MosaicProjectController.startCapture] is running.
  final bool isStartingCapture;

  /// True while [MosaicProjectController.integratePanels] is running.
  final bool isIntegrating;

  /// True while [MosaicProjectController.stitchProject] is running.
  final bool isStitching;

  /// True while [MosaicProjectController.publishToHub] is running.
  final bool isPublishing;

  /// True while a claim action is running.
  final bool isClaiming;

  /// True while a panel-master upload is running.
  final bool isUploading;

  /// True while [MosaicProjectController.assembleFromHub] is running.
  final bool isAssembling;

  /// True while [MosaicProjectController.joinAsParticipant] is running.
  final bool isJoining;

  /// True while [MosaicProjectController.refreshStatus] is running.
  final bool isRefreshing;

  /// True while [MosaicProjectController.downloadOutput] is running.
  final bool isDownloading;

  /// When the claims this rig currently holds expire on the hub, or null
  /// when nothing is held. Taken from the hub's own claim grant rather than a
  /// client-side copy of the TTL, so what the operator is shown is the time the
  /// hub will actually re-open their panels.
  final DateTime? claimExpiresAt;

  /// A human-readable error from the last load or action, or null. Surfaced as
  /// a dismissible banner; it never tears down the already-loaded chrome.
  final String? error;

  const MosaicProjectState({
    this.project,
    this.panels = const [],
    this.panelMasters = const {},
    this.stitchedMaster,
    this.isLoading = true,
    this.isStartingCapture = false,
    this.isIntegrating = false,
    this.isStitching = false,
    this.isPublishing = false,
    this.isClaiming = false,
    this.isUploading = false,
    this.isAssembling = false,
    this.isJoining = false,
    this.isRefreshing = false,
    this.isDownloading = false,
    this.claimExpiresAt,
    this.error,
  });

  /// True while any long-running action (start-capture, integrate, stitch, or a
  /// collaborative publish/claim/upload/assemble) is in flight.
  bool get isBusy =>
      isStartingCapture ||
      isIntegrating ||
      isStitching ||
      isPublishing ||
      isClaiming ||
      isUploading ||
      isAssembling ||
      isJoining ||
      isRefreshing ||
      isDownloading;

  /// The hub mosaic id once this project has been published, or null.
  String? get hubMosaicId => project?.hubMosaicId;

  /// True once this project has been published to the hub as a collaborative
  /// mosaic.
  bool get isPublished => project?.isPublished ?? false;

  /// The hub-side collaborative lifecycle (published|assembling|complete), or
  /// null when not a collaborative mosaic.
  String? get collabStatus => project?.collabStatus;

  /// Panels not yet claimed for distributed capture — the claim-all set.
  List<MosaicProjectPanel> get unclaimedPanels =>
      panels.where((p) => !p.isClaimed).toList(growable: false);

  /// Panels THIS rig is currently holding an OUTSTANDING claim on — claimed and
  /// not yet uploaded. A local panel row only carries a claim token after this
  /// device's own successful claim (nothing mirrors a peer's claim: the join
  /// mirror upserts panels with no token and `refreshStatus` only syncs the
  /// mosaic's lifecycle), so this is "mine", not "claimed by anyone".
  ///
  /// An uploaded panel is excluded because its claim is spent: the hub refuses
  /// to release it and never re-opens it ("an uploaded panel is done — never
  /// re-claimable", `MosaicBrokerService.claimPanel`/`releasePanel`), so
  /// counting it would offer the operator work to hand back that cannot be
  /// handed back. This is the same set the per-panel Release button and the
  /// claim-expiry caption already use.
  int get heldPanelCount =>
      panels.where((p) => p.isClaimed && !p.isUploaded).length;

  /// True when this device owns the collaborative mosaic (as opposed to having
  /// joined a peer's as a participant).
  bool get isOwner => project?.collabRole == 'owner';

  /// Integrated panels not yet uploaded to the hub — the upload-all set.
  List<MosaicProjectPanel> get integratedNotUploaded => panels
      .where((p) => p.integratedMasterId != null && !p.isUploaded)
      .toList(growable: false);

  /// Count of panels whose master has been uploaded to the hub.
  int get panelsUploaded => panels.where((p) => p.isUploaded).length;

  /// Number of panels that carry an integrated per-panel master — the
  /// population the stitcher consumes. Stitch is gated until this is >= 2 (one
  /// panel is not a mosaic).
  int get panelsWithMasters =>
      panels.where((p) => p.integratedMasterId != null).length;

  /// True once at least two panels have masters, so a mosaic can be stitched.
  bool get canStitch => panelsWithMasters >= 2;

  /// True when the stitched output master has been produced and is on hand.
  bool get isComplete =>
      (project?.isComplete ?? false) && stitchedMaster != null;

  /// Count of panels by [MosaicPanelStatus] — feeds the header status summary.
  int countWithStatus(MosaicPanelStatus status) =>
      panels.where((p) => p.status == status).length;

  MosaicProjectState copyWith({
    MosaicProject? project,
    List<MosaicProjectPanel>? panels,
    Map<int, IntegratedMaster>? panelMasters,
    IntegratedMaster? stitchedMaster,
    bool clearStitchedMaster = false,
    bool? isLoading,
    bool? isStartingCapture,
    bool? isIntegrating,
    bool? isStitching,
    bool? isPublishing,
    bool? isClaiming,
    bool? isUploading,
    bool? isAssembling,
    bool? isJoining,
    bool? isRefreshing,
    bool? isDownloading,
    DateTime? claimExpiresAt,
    bool clearClaimExpiresAt = false,
    String? error,
    bool clearError = false,
  }) {
    return MosaicProjectState(
      project: project ?? this.project,
      panels: panels ?? this.panels,
      panelMasters: panelMasters ?? this.panelMasters,
      stitchedMaster:
          clearStitchedMaster ? null : (stitchedMaster ?? this.stitchedMaster),
      isLoading: isLoading ?? this.isLoading,
      isStartingCapture: isStartingCapture ?? this.isStartingCapture,
      isIntegrating: isIntegrating ?? this.isIntegrating,
      isStitching: isStitching ?? this.isStitching,
      isPublishing: isPublishing ?? this.isPublishing,
      isClaiming: isClaiming ?? this.isClaiming,
      isUploading: isUploading ?? this.isUploading,
      isAssembling: isAssembling ?? this.isAssembling,
      isJoining: isJoining ?? this.isJoining,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isDownloading: isDownloading ?? this.isDownloading,
      claimExpiresAt:
          clearClaimExpiresAt ? null : (claimExpiresAt ?? this.claimExpiresAt),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// One database read of everything [MosaicProjectController.load] renders. A
/// null [project] means "no such project" (not an error).
class _MosaicProjectSnapshot {
  final MosaicProject? project;
  final List<MosaicProjectPanel> panels;
  final Map<int, IntegratedMaster> panelMasters;
  final IntegratedMaster? stitchedMaster;

  const _MosaicProjectSnapshot({
    this.project,
    this.panels = const [],
    this.panelMasters = const {},
    this.stitchedMaster,
  });
}
