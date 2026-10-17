part of '../coimaging_session_service.dart';

/// The session context a [CoImagingTileFuser] needs to fold this rig's freshly
/// completed sub into the shared-target tile the session is deepening — resolved
/// from the live session by [CoImagingSessionService.recordCompletedSub] so the
/// fuser stays a thin seam over the existing [ConstellationService.contributeTarget]
/// additive-sum upload (the same `.nst` path the async swarm already uses).
class CoImagingFusionRequest {
  /// The hub shared-target id whose fused tile the session deepens. Null when the
  /// session is not (yet) bound to a shared target — then nothing can be fused.
  final int? sharedTargetId;
  final String targetName;
  final double centerRaDeg;
  final double centerDecDeg;
  final double radiusDeg;

  /// The hub's active fused-co-add tile for the session (provenance / tagging).
  final int? activeTileId;

  /// The operator-consented sharing license the additive sums are uploaded
  /// under. Resolved from the persisted contribution consent before the fuse —
  /// never a silent default — so an unattended fold honours the user's choice.
  final ContributionLicense license;

  /// Whether the operator consented to public, name-credited attribution (vs
  /// anonymous). Threaded into the underlying `.nst` push so the hub records the
  /// contribution under the operator's actual attribution preference.
  final bool attributionConsent;

  const CoImagingFusionRequest({
    required this.sharedTargetId,
    required this.targetName,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.radiusDeg,
    required this.activeTileId,
    required this.license,
    required this.attributionConsent,
  });
}

/// What the fuser actually pushed to the hub for one completed sub: the TRUE
/// per-call frame + integration delta the additive-sum upload deepened, and the
/// number of tiles the hub accepted. Combined accounting reports [framesPushed]
/// / [integrationSecondsPushed] (NOT a hardcoded +1) so the headline depth
/// equals what the fusion received; [acceptedTiles] == 0 means nothing was
/// deepened (the fusion-failure guard trips and accounting is not advanced).
class CoImagingFusionResult {
  final int framesPushed;
  final double integrationSecondsPushed;
  final int acceptedTiles;

  const CoImagingFusionResult({
    required this.framesPushed,
    required this.integrationSecondsPushed,
    required this.acceptedTiles,
  });

  static const CoImagingFusionResult none = CoImagingFusionResult(
    framesPushed: 0,
    integrationSecondsPushed: 0.0,
    acceptedTiles: 0,
  );
}

/// Folds this rig's completed sub into the session's shared-target tile via the
/// EXISTING additive-sum contribution pipeline, returning the TRUE delta the hub
/// accepted (a zero [CoImagingFusionResult.acceptedTiles] == nothing was
/// actually deepened). Injected so the session service reuses
/// [ConstellationService.contributeTarget] without depending on it directly, and
/// so tests can assert the fuse-before-account ordering.
typedef CoImagingTileFuser =
    Future<CoImagingFusionResult> Function(CoImagingFusionRequest request);

/// Resolves the operator's persisted contribution consent — the sharing license
/// + public-attribution choice that gates co-imaging data egress — or null when
/// no consent is on record. Co-imaging mirrors the mosaic upload path: an
/// unattended fold must NEVER leave the device under a silent hardcoded license,
/// so a null result fails closed (the sub is not contributed). Injected so the
/// service stays DB-agnostic and reuses the same persisted record the mosaic
/// contribute sheet captures.
typedef CoImagingContributionConsentResolver =
    Future<({ContributionLicense license, bool attributionConsent})?>
    Function();

/// The outcome of one altitude-driven longitude-baton evaluation
/// ([CoImagingSessionService.evaluateBaton]): the computed target altitude at the
/// rig's site and the action taken on the per-session baton.
class CoImagingBatonDecision {
  /// The session target's altitude (degrees) at the rig's location + clock.
  final double altitudeDeg;

  /// Whether the target is above the imaging-altitude floor at this site now.
  final bool aboveFloor;

  /// The granted claim when the target is up and the baton was claimable here,
  /// else null (another site holds it, or the target has set).
  final HandoffClaim? claim;

  /// Whether the baton was released (target has set at this site).
  final bool released;

  const CoImagingBatonDecision({
    required this.altitudeDeg,
    required this.aboveFloor,
    required this.claim,
    required this.released,
  });

  /// True when this site now holds the active-imager baton (claimed + granted).
  bool get holdsBaton => claim != null;
}

/// The reconciled outcome of one baton-scheduler tick, aggregated across ALL of
/// this rig's active co-imaging memberships into a SINGLE decision before the
/// engine layer is touched.
///
/// The scheduler drives one process-global autopilot, so per-membership
/// pause/resume callbacks would let two memberships fight over a shared resource
/// within a tick (target A up -> resume while target B set -> pause, with the
/// net engine state depending on iteration order). This carries the whole
/// picture for the tick so the engine policy can make one deterministic call.
class CoImagingBatonReconciliation {
  const CoImagingBatonReconciliation({
    required this.held,
    required this.released,
  });

  /// Memberships whose target is up here AND whose active-imager baton this rig
  /// holds right now (begin/continue imaging their target).
  final List<CoImagingSessionRow> held;

  /// Active memberships this rig does NOT hold the baton for this tick — the
  /// target has set, or another site is the active imager.
  final List<CoImagingSessionRow> released;

  /// True when this rig holds at least one session's baton now.
  bool get anyHeld => held.isNotEmpty;
}
