// Pillar C ("Constellation") — Dart value types for the hub wire contract.
//
// These decode the JSON the Constellation hub returns (contract in
// `docs/skotiq_5_0_contracts.md`) and carry the typed error surface the
// client raises. Field names mirror the wire contract (camelCase) so the maps
// round-trip straight through.

/// How a [ConstellationException] should be classified by callers (retry vs
/// surface vs reauth). Mirrors the WebDAV sync target's error taxonomy.
enum ConstellationErrorKind {
  network,
  auth,
  notFound,
  conflict,
  geometryMismatch,
  server,
  protocol,
  unknown,
}

/// Raised on any hub interaction that fails or returns an unusable payload.
class ConstellationException implements Exception {
  final String message;
  final ConstellationErrorKind kind;
  final int? statusCode;

  const ConstellationException(
    this.message, {
    this.kind = ConstellationErrorKind.unknown,
    this.statusCode,
  });

  @override
  String toString() => 'ConstellationException($kind): $message';
}

/// `GET /v1/info` result — hub identity and tiling parameters.
class HubInfo {
  final String name;
  final String fingerprint; // SHA-256 hex server identity
  final String version;
  final int healpixOrder;
  final int tilePixels;
  final bool selfHosted;

  /// Whether this hub accepts raw FITS subframes in addition to additive sums.
  /// Drives whether the contribute sheet may offer the SUBS privacy option at
  /// all — when false the option is disabled with an explanatory note, because
  /// the hub has no endpoint to receive raw frames. Defaults false (older hubs
  /// that don't advertise the flag are treated as sums-only).
  final bool acceptsRawSubs;

  /// Whether the hub requires an explicit consented license on every share
  /// path. When true the contribute sheet MUST collect a license before any
  /// bytes are sent; the client pre-validates the user's choice against
  /// [supportedLicenses]. Defaults false for older hubs that don't advertise it
  /// (treated as no consent contract — the legacy unconditional contribute).
  final bool requiresConsent;

  /// The license wire names this hub accepts on a share (a subset of
  /// `ContributionLicense.wireName`). Empty for older hubs; the client offers
  /// only these in the contribute sheet when non-empty.
  final List<String> supportedLicenses;

  const HubInfo({
    required this.name,
    required this.fingerprint,
    required this.version,
    required this.healpixOrder,
    required this.tilePixels,
    required this.selfHosted,
    this.acceptsRawSubs = false,
    this.requiresConsent = false,
    this.supportedLicenses = const <String>[],
  });

  factory HubInfo.fromJson(Map<String, dynamic> json) => HubInfo(
    name: json['name'] as String? ?? '',
    fingerprint: json['fingerprint'] as String? ?? '',
    version: json['version'] as String? ?? '',
    healpixOrder: (json['healpixOrder'] as num?)?.toInt() ?? 0,
    tilePixels: (json['tilePixels'] as num?)?.toInt() ?? 0,
    selfHosted: json['selfHosted'] as bool? ?? true,
    acceptsRawSubs: json['acceptsRawSubs'] as bool? ?? false,
    requiresConsent: json['requiresConsent'] as bool? ?? false,
    supportedLicenses:
        (json['supportedLicenses'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[],
  );
}

/// `POST /v1/accounts` result — the issued account id + bearer token.
class HubAccount {
  final String accountId;
  final String bearerToken;
  final double trust;

  const HubAccount({
    required this.accountId,
    required this.bearerToken,
    required this.trust,
  });

  factory HubAccount.fromJson(Map<String, dynamic> json) => HubAccount(
    accountId: json['accountId'] as String? ?? '',
    bearerToken: json['bearerToken'] as String? ?? '',
    trust: (json['trust'] as num?)?.toDouble() ?? 0.0,
  );
}

/// `POST /v1/tokens` result — a freshly minted fine-grained scoped token.
/// [bearerToken] is the RAW token (returned exactly once), the rest echoes the
/// narrowing the hub applied so a UI can show what was granted.
class MintedToken {
  final String bearerToken;
  final String accountId;
  final String role;
  final String? deviceId;
  final String? resourceType;
  final String? resourceId;
  final List<String> actions;
  final int? lifetimeSeconds;

  const MintedToken({
    required this.bearerToken,
    required this.accountId,
    required this.role,
    this.deviceId,
    this.resourceType,
    this.resourceId,
    this.actions = const <String>[],
    this.lifetimeSeconds,
  });

  factory MintedToken.fromJson(Map<String, dynamic> json) => MintedToken(
    bearerToken: json['bearerToken'] as String? ?? '',
    accountId: json['accountId'] as String? ?? '',
    role: json['role'] as String? ?? 'read',
    deviceId: json['deviceId'] as String?,
    resourceType: json['resourceType'] as String?,
    resourceId: json['resourceId'] as String?,
    actions:
        (json['actions'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[],
    lifetimeSeconds: (json['lifetimeSeconds'] as num?)?.toInt(),
  );
}

/// `POST /v1/tiles/{id}/contributions` result — the hub's acceptance receipt.
class ContributionReceipt {
  final String contributionId;
  final bool accepted;
  final double trustApplied;
  final int totalFramesAfter;
  final double integrationSecondsAfter;

  const ContributionReceipt({
    required this.contributionId,
    required this.accepted,
    required this.trustApplied,
    required this.totalFramesAfter,
    required this.integrationSecondsAfter,
  });

  factory ContributionReceipt.fromJson(Map<String, dynamic> json) =>
      ContributionReceipt(
        contributionId: json['contributionId'] as String? ?? '',
        accepted: json['accepted'] as bool? ?? false,
        trustApplied: (json['trustApplied'] as num?)?.toDouble() ?? 0.0,
        totalFramesAfter: (json['totalFramesAfter'] as num?)?.toInt() ?? 0,
        integrationSecondsAfter:
            (json['integrationSecondsAfter'] as num?)?.toDouble() ?? 0.0,
      );
}

/// `POST /v1/tiles/{id}/subframes` result — the hub's raw-subframe receipt.
///
/// Unlike a sums [ContributionReceipt], a raw subframe is stored as its own
/// immutable file (not fused), so the receipt carries only the opaque
/// [contributionId] (the handle a later delete acts on) and the stored size.
class SubframeReceipt {
  final String contributionId;
  final bool accepted;
  final int storedBytes;

  const SubframeReceipt({
    required this.contributionId,
    required this.accepted,
    required this.storedBytes,
  });

  factory SubframeReceipt.fromJson(Map<String, dynamic> json) =>
      SubframeReceipt(
        contributionId: json['contributionId'] as String? ?? '',
        accepted: json['accepted'] as bool? ?? false,
        storedBytes: (json['storedBytes'] as num?)?.toInt() ?? 0,
      );
}

/// `DELETE /v1/contributions/{id}` result — the post-retraction tile depth.
class RetractionReceipt {
  final bool retracted;
  final int totalFramesAfter;

  const RetractionReceipt({
    required this.retracted,
    required this.totalFramesAfter,
  });

  factory RetractionReceipt.fromJson(Map<String, dynamic> json) =>
      RetractionReceipt(
        retracted: json['retracted'] as bool? ?? false,
        totalFramesAfter: (json['totalFramesAfter'] as num?)?.toInt() ?? 0,
      );
}

/// `GET|POST /v1/handoff/{targetId}` result — the follow-the-night baton state.
class HandoffClaim {
  final int targetId;

  /// The tile currently being deepened for this target (the hub's active id).
  final int? activeTileId;

  /// Account id currently holding the baton, or null when free.
  final String? holder;

  /// Whether the target is high enough for *this* user to image now.
  final bool altitudeOk;

  /// Opaque claim token returned by `/claim` (null on a plain query).
  final String? claimToken;

  /// Expiry of a granted claim (ISO-8601), when the hub supplies one.
  final DateTime? expiresAt;

  const HandoffClaim({
    required this.targetId,
    required this.activeTileId,
    required this.holder,
    required this.altitudeOk,
    required this.claimToken,
    required this.expiresAt,
  });

  /// True when no one holds the baton and the target is up for this user — the
  /// "go image this now" signal the planner surfaces.
  bool get isAvailableNow => holder == null && altitudeOk;

  factory HandoffClaim.fromJson(Map<String, dynamic> json) {
    final expiresRaw = json['expiresAt'] as String?;
    return HandoffClaim(
      targetId: (json['targetId'] as num?)?.toInt() ?? 0,
      activeTileId: (json['activeTileId'] as num?)?.toInt(),
      holder: json['holder'] as String?,
      altitudeOk: json['altitudeOk'] as bool? ?? false,
      claimToken: json['claimToken'] as String?,
      expiresAt: (expiresRaw == null || expiresRaw.isEmpty)
          ? null
          : DateTime.tryParse(expiresRaw),
    );
  }
}

/// A shared target advertised by the hub (browse / "what's dark now").
///
/// The hub's swarm-target listing is not pinned field-for-field in the contract
/// (the browse payload is left to the hub), so this decodes the stable subset
/// every hub returns and tolerates the rest.
class SharedTarget {
  final int targetId;
  final String name;
  final double raDeg;
  final double decDeg;

  /// Total fused integration depth across the swarm for this target (seconds).
  final double integrationSeconds;

  /// Number of distinct contributors currently feeding the target.
  final int contributors;

  /// The hub's primary tile id for the target's centre, when advertised.
  final int? activeTileId;

  /// The swarm cone radius (degrees) chosen when the target was shared. Drives
  /// what leaves the device on contribute and what the UI counts as local
  /// overlap. Defaults to 1.5° when the hub payload omits it.
  final double radiusDeg;

  const SharedTarget({
    required this.targetId,
    required this.name,
    required this.raDeg,
    required this.decDeg,
    required this.integrationSeconds,
    required this.contributors,
    required this.activeTileId,
    this.radiusDeg = 1.5,
  });

  factory SharedTarget.fromJson(Map<String, dynamic> json) => SharedTarget(
    targetId: (json['targetId'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    raDeg: (json['raDeg'] as num?)?.toDouble() ?? 0.0,
    decDeg: (json['decDeg'] as num?)?.toDouble() ?? 0.0,
    integrationSeconds: (json['integrationSeconds'] as num?)?.toDouble() ?? 0.0,
    contributors: (json['contributors'] as num?)?.toInt() ?? 0,
    activeTileId: (json['activeTileId'] as num?)?.toInt(),
    radiusDeg: (json['radiusDeg'] as num?)?.toDouble() ?? 1.5,
  );
}

/// A community tile pulled down and cached locally for blending into "Your Sky".
///
/// The pulled blob lives on disk under the atlas `swarm/` directory; this is the
/// cheap index row the blend overlay renders from.
class SwarmTile {
  final int tileId;
  final int order;
  final String localPath;
  final bool finalized;
  final int totalFrames;
  final double integrationSeconds;
  final int contributors;
  final DateTime pulledAt;

  const SwarmTile({
    required this.tileId,
    required this.order,
    required this.localPath,
    required this.finalized,
    required this.totalFrames,
    required this.integrationSeconds,
    required this.contributors,
    required this.pulledAt,
  });
}

/// A local imageable target offered as a candidate to seed a shared target on
/// the hub ("Share one of my targets"). Coordinates are in degrees.
class ShareableLocalTarget {
  final int targetId;
  final String name;
  final double raDeg;
  final double decDeg;

  const ShareableLocalTarget({
    required this.targetId,
    required this.name,
    required this.raDeg,
    required this.decDeg,
  });
}

/// One tile this device has contributed to a hub — the retractable unit.
///
/// Sourced from the persisted `constellation_contributions` receipt table (the
/// Wave-0 substrate): every row carrying a remote [contributionId] is a
/// contribution the hub can subtract back off the fused co-add exactly. This is
/// what the "Your contributions" list renders and the Retract action acts on.
class ContributionRecord {
  /// HEALPix NESTED tile id contributed.
  final int tileId;

  /// Remote receipt id the hub issued — the handle Retract subtracts.
  final String contributionId;

  /// Cumulative own-light frames shipped to the hub for this tile.
  final int contributedFrames;

  /// Cumulative own-light integration (seconds) shipped for this tile.
  final double contributedIntegrationSeconds;

  /// When this tile was last contributed (null if the receipt predates the
  /// timestamp column).
  final DateTime? lastContributedAt;

  const ContributionRecord({
    required this.tileId,
    required this.contributionId,
    required this.contributedFrames,
    required this.contributedIntegrationSeconds,
    required this.lastContributedAt,
  });
}

/// A collaborative mosaic published on the hub: a panel
/// grid whose panels are claimable distributed work items. Field names mirror the
/// hub's `CollaborativeMosaicRow.toJson` wire shape.
class CollabMosaic {
  final String mosaicId;

  /// Internal hub account id of the owner. Empty for a non-privileged caller
  /// (the hub strips it to avoid leaking enumerable internal ids); use
  /// [ownerDisplayName] for attribution instead.
  final String ownerAccountId;

  /// Server-resolved human-readable owner credit, or null when unavailable.
  /// The hub always resolves this for attribution even when [ownerAccountId] is
  /// withheld.
  final String? ownerDisplayName;
  final String name;
  final int rows;
  final int cols;
  final double overlapPct;
  final double positionAngleDeg;
  final double centerRaDeg;
  final double centerDecDeg;

  /// Hub lifecycle: `open` (claimable), `assembling` (all panels in, owner
  /// stitching), `complete` (finished mosaic available).
  final String status;

  /// Whether the finished stitched output is available for download.
  final bool outputPresent;

  /// Per-panel state (empty on the list endpoint, populated on the detail GET).
  final List<CollabMosaicPanel> panels;

  const CollabMosaic({
    required this.mosaicId,
    required this.ownerAccountId,
    this.ownerDisplayName,
    required this.name,
    required this.rows,
    required this.cols,
    required this.overlapPct,
    required this.positionAngleDeg,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.status,
    required this.outputPresent,
    this.panels = const [],
  });

  bool get isComplete => status == 'complete';
  bool get isAssembling => status == 'assembling';

  factory CollabMosaic.fromJson(Map<String, dynamic> json) {
    final panelsRaw = json['panels'];
    return CollabMosaic(
      mosaicId: json['mosaicId'] as String? ?? '',
      ownerAccountId: json['ownerAccountId'] as String? ?? '',
      ownerDisplayName: json['ownerDisplayName'] as String?,
      name: json['name'] as String? ?? '',
      rows: (json['rows'] as num?)?.toInt() ?? 0,
      cols: (json['cols'] as num?)?.toInt() ?? 0,
      overlapPct: (json['overlapPct'] as num?)?.toDouble() ?? 0.0,
      positionAngleDeg: (json['positionAngleDeg'] as num?)?.toDouble() ?? 0.0,
      centerRaDeg: (json['centerRaDeg'] as num?)?.toDouble() ?? 0.0,
      centerDecDeg: (json['centerDecDeg'] as num?)?.toDouble() ?? 0.0,
      status: json['status'] as String? ?? 'open',
      outputPresent: json['outputPresent'] as bool? ?? false,
      panels: panelsRaw is List
          ? panelsRaw
                .whereType<Map<String, dynamic>>()
                .map(CollabMosaicPanel.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// One panel of a [CollabMosaic] (the claimable work item). Mirrors the hub's
/// `CollaborativeMosaicPanelRow.toJson`.
class CollabMosaicPanel {
  final int panelIndex;
  final double centerRaDeg;
  final double centerDecDeg;

  /// `pending` (unclaimed), `claimed`, or `uploaded`.
  final String status;

  /// Hub account id the panel is assigned to, or null when unclaimed OR when the
  /// caller is not privileged (the hub withholds it from non-participants); use
  /// [assignedDisplayName] for attribution instead.
  final String? assignedAccountId;

  /// Rig fingerprint the panel is assigned to (provenance), or null when
  /// unclaimed or withheld from a non-privileged caller.
  final String? assignedRigId;

  /// Server-resolved human-readable contributor credit for this panel, or null.
  final String? assignedDisplayName;

  /// Whether this panel's master has been uploaded.
  final bool uploaded;

  const CollabMosaicPanel({
    required this.panelIndex,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.status,
    required this.assignedAccountId,
    required this.assignedRigId,
    this.assignedDisplayName,
    required this.uploaded,
  });

  factory CollabMosaicPanel.fromJson(Map<String, dynamic> json) =>
      CollabMosaicPanel(
        panelIndex: (json['panelIndex'] as num?)?.toInt() ?? 0,
        centerRaDeg: (json['centerRaDeg'] as num?)?.toDouble() ?? 0.0,
        centerDecDeg: (json['centerDecDeg'] as num?)?.toDouble() ?? 0.0,
        status: json['status'] as String? ?? 'pending',
        assignedAccountId: json['assignedAccountId'] as String?,
        assignedRigId: json['assignedRigId'] as String?,
        assignedDisplayName: json['assignedDisplayName'] as String?,
        uploaded: json['uploaded'] as bool? ?? false,
      );
}

/// A successful panel claim from the hub broker: the baton token + expiry.
/// Mirrors [HandoffClaim] but keyed by `(mosaicId, panelIndex)`.
class MosaicPanelClaim {
  final String mosaicId;
  final int panelIndex;
  final String claimToken;
  final DateTime? expiresAt;

  const MosaicPanelClaim({
    required this.mosaicId,
    required this.panelIndex,
    required this.claimToken,
    required this.expiresAt,
  });

  factory MosaicPanelClaim.fromJson(Map<String, dynamic> json) {
    final raw = json['expiresAt'] as String?;
    return MosaicPanelClaim(
      mosaicId: json['mosaicId'] as String? ?? '',
      panelIndex: (json['panelIndex'] as num?)?.toInt() ?? 0,
      claimToken: json['claimToken'] as String? ?? '',
      expiresAt: (raw == null || raw.isEmpty) ? null : DateTime.tryParse(raw),
    );
  }
}

/// A live co-imaging session on the hub: N rigs JOIN the
/// SAME target and their subs co-add through the additive fusion pipeline, so
/// effective integration scales with rig count and imaging continues across
/// longitudes. Field names mirror the hub's `CoImagingSessionRow.toJson`.
class CoImagingSession {
  final String sessionId;

  /// Internal hub account id of the owner. Empty for a non-privileged caller;
  /// use [ownerDisplayName] for attribution.
  final String ownerAccountId;
  final String? ownerDisplayName;
  final String targetName;
  final double centerRaDeg;
  final double centerDecDeg;

  /// The hub shared-target id the session's fusion + longitude baton key on.
  final int? sharedTargetId;

  /// `active` or `closed`.
  final String status;

  /// COMBINED frame count + integration across every participating rig — the
  /// "scales with rig count" headline.
  final int combinedFrames;
  final double combinedIntegrationSeconds;

  /// The fused-co-add tile id every participant pulls to watch the combined
  /// stack deepen.
  final int? activeTileId;

  /// Account id currently holding the active-imager baton (privileged-only), and
  /// a resolved display name for attribution.
  final String? batonHolder;
  final String? batonHolderDisplayName;

  /// Per-rig participant state (empty on the list endpoint).
  final List<CoImagingParticipant> participants;

  const CoImagingSession({
    required this.sessionId,
    required this.ownerAccountId,
    this.ownerDisplayName,
    required this.targetName,
    required this.centerRaDeg,
    required this.centerDecDeg,
    required this.sharedTargetId,
    required this.status,
    required this.combinedFrames,
    required this.combinedIntegrationSeconds,
    required this.activeTileId,
    required this.batonHolder,
    required this.batonHolderDisplayName,
    this.participants = const [],
  });

  bool get isActive => status == 'active';

  factory CoImagingSession.fromJson(Map<String, dynamic> json) {
    final ps = json['participants'];
    return CoImagingSession(
      sessionId: json['sessionId'] as String? ?? '',
      ownerAccountId: json['ownerAccountId'] as String? ?? '',
      ownerDisplayName: json['ownerDisplayName'] as String?,
      targetName: json['targetName'] as String? ?? '',
      centerRaDeg: (json['centerRaDeg'] as num?)?.toDouble() ?? 0.0,
      centerDecDeg: (json['centerDecDeg'] as num?)?.toDouble() ?? 0.0,
      sharedTargetId: (json['sharedTargetId'] as num?)?.toInt(),
      status: json['status'] as String? ?? 'active',
      combinedFrames: (json['combinedFrames'] as num?)?.toInt() ?? 0,
      combinedIntegrationSeconds:
          (json['combinedIntegrationSeconds'] as num?)?.toDouble() ?? 0.0,
      activeTileId: (json['activeTileId'] as num?)?.toInt(),
      batonHolder: json['batonHolder'] as String?,
      batonHolderDisplayName: json['batonHolderDisplayName'] as String?,
      participants: ps is List
          ? ps
                .whereType<Map<String, dynamic>>()
                .map(CoImagingParticipant.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// One rig's membership in a [CoImagingSession]: its hub-assigned framing offset
/// (the dither slot so rigs don't frame identically) + cumulative tallies. The
/// [membershipToken] is present only on the rig's OWN join response. Mirrors the
/// hub's `CoImagingParticipantRow.toJson`.
class CoImagingParticipant {
  final String sessionId;
  final String? accountId;
  final String? displayName;
  final String rigId;
  final String role;

  /// The hub-issued token this rig presents on later session contributions.
  /// Null except on the rig's own JOIN/CREATE response.
  final String? membershipToken;

  /// The hub-assigned participant slot index (0 = anchor / no offset).
  final int framingOffsetIndex;

  /// The assigned framing nudge in arcseconds, so this rig tiles the field
  /// instead of stacking identically.
  final double framingOffsetRaArcsec;
  final double framingOffsetDecArcsec;

  final int contributedFrames;
  final double contributedIntegrationSeconds;
  final bool active;

  const CoImagingParticipant({
    required this.sessionId,
    required this.accountId,
    required this.displayName,
    required this.rigId,
    required this.role,
    required this.membershipToken,
    required this.framingOffsetIndex,
    required this.framingOffsetRaArcsec,
    required this.framingOffsetDecArcsec,
    required this.contributedFrames,
    required this.contributedIntegrationSeconds,
    required this.active,
  });

  factory CoImagingParticipant.fromJson(Map<String, dynamic> json) =>
      CoImagingParticipant(
        sessionId: json['sessionId'] as String? ?? '',
        accountId: json['accountId'] as String?,
        displayName: json['displayName'] as String?,
        rigId: json['rigId'] as String? ?? '',
        role: json['role'] as String? ?? 'contribute',
        membershipToken: json['membershipToken'] as String?,
        framingOffsetIndex: (json['framingOffsetIndex'] as num?)?.toInt() ?? 0,
        framingOffsetRaArcsec:
            (json['framingOffsetRaArcsec'] as num?)?.toDouble() ?? 0.0,
        framingOffsetDecArcsec:
            (json['framingOffsetDecArcsec'] as num?)?.toDouble() ?? 0.0,
        contributedFrames: (json['contributedFrames'] as num?)?.toInt() ?? 0,
        contributedIntegrationSeconds:
            (json['contributedIntegrationSeconds'] as num?)?.toDouble() ?? 0.0,
        active: json['active'] as bool? ?? true,
      );
}

/// The COMBINED accounting the hub returns after a co-imaging contribution.
class CoImagingAccounting {
  final String sessionId;
  final int combinedFrames;
  final double combinedIntegrationSeconds;
  final int participantCount;

  const CoImagingAccounting({
    required this.sessionId,
    required this.combinedFrames,
    required this.combinedIntegrationSeconds,
    required this.participantCount,
  });

  factory CoImagingAccounting.fromJson(Map<String, dynamic> json) =>
      CoImagingAccounting(
        sessionId: json['sessionId'] as String? ?? '',
        combinedFrames: (json['combinedFrames'] as num?)?.toInt() ?? 0,
        combinedIntegrationSeconds:
            (json['combinedIntegrationSeconds'] as num?)?.toDouble() ?? 0.0,
        participantCount: (json['participantCount'] as num?)?.toInt() ?? 0,
      );
}

/// The longitude-baton state of a co-imaging session (who is actively imaging
/// the target now). Mirrors the hub's `CoImagingBatonState.toJson`.
class CoImagingBatonState {
  final String sessionId;
  final bool held;
  final String? holder;
  final String? holderDisplayName;
  final DateTime? expiresAt;

  const CoImagingBatonState({
    required this.sessionId,
    required this.held,
    required this.holder,
    required this.holderDisplayName,
    required this.expiresAt,
  });

  factory CoImagingBatonState.fromJson(Map<String, dynamic> json) {
    final raw = json['expiresAt'] as String?;
    return CoImagingBatonState(
      sessionId: json['sessionId'] as String? ?? '',
      held: json['held'] as bool? ?? false,
      holder: json['holder'] as String?,
      holderDisplayName: json['holderDisplayName'] as String?,
      expiresAt: (raw == null || raw.isEmpty) ? null : DateTime.tryParse(raw),
    );
  }
}

/// One live combined-preview event pushed over the co-imaging events channel as
/// subs fuse — the "we're building this together, right now" signal. Decoded
/// from one SSE `data:` JSON frame (the hub's `CoImagingPreviewEvent.toJson`).
class CoImagingPreview {
  /// `snapshot`, `combined-preview`, or `participant-joined`.
  final String type;
  final String sessionId;
  final int combinedFrames;
  final double combinedIntegrationSeconds;
  final int participantCount;

  /// The fused-tile id to pull for the deepening combined co-add.
  final int activeTileId;
  final String? actorRigId;
  final int? actorFramingOffsetIndex;
  final DateTime? at;

  const CoImagingPreview({
    required this.type,
    required this.sessionId,
    required this.combinedFrames,
    required this.combinedIntegrationSeconds,
    required this.participantCount,
    required this.activeTileId,
    required this.actorRigId,
    required this.actorFramingOffsetIndex,
    required this.at,
  });

  factory CoImagingPreview.fromJson(Map<String, dynamic> json) {
    final raw = json['at'] as String?;
    return CoImagingPreview(
      type: json['type'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      combinedFrames: (json['combinedFrames'] as num?)?.toInt() ?? 0,
      combinedIntegrationSeconds:
          (json['combinedIntegrationSeconds'] as num?)?.toDouble() ?? 0.0,
      participantCount: (json['participantCount'] as num?)?.toInt() ?? 0,
      activeTileId: (json['activeTileId'] as num?)?.toInt() ?? 0,
      actorRigId: json['actorRigId'] as String?,
      actorFramingOffsetIndex: (json['actorFramingOffsetIndex'] as num?)
          ?.toInt(),
      at: (raw == null || raw.isEmpty) ? null : DateTime.tryParse(raw),
    );
  }
}

/// One shared target the planner should surface tonight, pairing the local
/// target row with the hub's live handoff state.
class FollowTheNightSuggestion {
  final int targetId;
  final String targetName;
  final double raDeg;
  final double decDeg;
  final HandoffClaim handoff;

  /// Community integration depth so far (seconds), for ranking dark targets.
  final double swarmIntegrationSeconds;

  /// True when *this* user currently holds the baton for the target (the hub's
  /// `holder` account id matches the registered account). Drives the Release
  /// affordance: a held card offers "Release" rather than "Take the baton".
  final bool heldByMe;

  const FollowTheNightSuggestion({
    required this.targetId,
    required this.targetName,
    required this.raDeg,
    required this.decDeg,
    required this.handoff,
    required this.swarmIntegrationSeconds,
    this.heldByMe = false,
  });

  /// True when the baton is free and the target is up for this user now.
  bool get isReadyNow => handoff.isAvailableNow;
}

/// One credited contributor on a finished collaborative artifact, materialized
/// server-side by the hub's `AttributionService`. Mirrors one entry of the
/// `GET /v1/attribution` `contributors` list.
///
/// The hub honours each contributor's attribution consent: an anonymous
/// contributor arrives with [anonymous] `true`, [displayName] already resolved
/// to `'Anonymous contributor'`, and no [accountId] — so this credit is never a
/// local reconstruction the client has to trust, but the authoritative, consent-
/// aware line the hub retains and returns.
class ContributorCredit {
  /// Internal hub account id, or null when the contributor is anonymous (the hub
  /// omits it) or a non-privileged caller had it withheld.
  final String? accountId;

  /// Server-resolved credit label — a real display name, or
  /// `'Anonymous contributor'` when consent was withheld.
  final String displayName;

  /// Whether the contributor withheld public credit.
  final bool anonymous;

  /// Own-light frames this contributor added to the artifact.
  final int frames;

  /// Own-light integration (seconds) this contributor added.
  final double integrationSeconds;

  /// The most-recent license this contributor shared under, or null when the
  /// hub did not stamp one.
  final String? license;

  const ContributorCredit({
    required this.accountId,
    required this.displayName,
    required this.anonymous,
    required this.frames,
    required this.integrationSeconds,
    required this.license,
  });

  factory ContributorCredit.fromJson(Map<String, dynamic> json) =>
      ContributorCredit(
        accountId: json['accountId'] as String?,
        displayName: json['displayName'] as String? ?? 'Unknown',
        anonymous: json['anonymous'] as bool? ?? false,
        frames: (json['frames'] as num?)?.toInt() ?? 0,
        integrationSeconds:
            (json['integrationSeconds'] as num?)?.toDouble() ?? 0.0,
        license: json['license'] as String?,
      );
}

/// The authoritative, ordered contributor-credit list for one finished
/// collaborative artifact — the client-side decode of `GET /v1/attribution`
/// and the source for contributor-credits UI. The hub keys attribution on an
/// `(artifactType, artifactRef)` pair: `'mosaic'`/mosaicId, `'coimaging'`/
/// sessionId, or `'tile'`/`'subframe'`/`'calibration'` for the other flows.
///
/// The UI reads credits back through this rather than reconstructing them from
/// a browse payload: the consent + attribution truth is retained server-side,
/// where a local DB tamper cannot edit it away.
class ArtifactAttribution {
  final String artifactType;
  final String artifactRef;

  /// Contributors ordered by the hub (frames desc, then most recent).
  final List<ContributorCredit> contributors;

  const ArtifactAttribution({
    required this.artifactType,
    required this.artifactRef,
    this.contributors = const [],
  });

  bool get isEmpty => contributors.isEmpty;

  /// The ordered credit labels, ready for `formatContributorCredits`.
  List<String> get displayNames =>
      contributors.map((c) => c.displayName).toList(growable: false);

  factory ArtifactAttribution.fromJson(Map<String, dynamic> json) {
    final raw = json['contributors'];
    return ArtifactAttribution(
      artifactType: json['artifactType'] as String? ?? '',
      artifactRef: json['artifactRef'] as String? ?? '',
      contributors: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(ContributorCredit.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}
