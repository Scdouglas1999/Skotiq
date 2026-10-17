part of '../constellation_service.dart';

/// What a contribution puts on the wire.
///
/// [sums] (the default) ships only the additive `.nst` accumulator the master
/// integration already keeps — never the raw individual subframes. [subs] is a
/// heavier, more-revealing opt-in: it streams the user's own light FITS to the
/// hub ([ConstellationService.contributeRawSubs]), so it is only valid against
/// a hub that advertises `acceptsRawSubs`. Wire values mirror the app-side
/// persisted setting (`sums` | `subs`).
enum ConstellationPrivacy { sums, subs }

/// Resolved hub credentials for one Constellation hub.
class ConstellationCredentials {
  final Uri hubBaseUrl;
  final String bearerToken;

  const ConstellationCredentials({
    required this.hubBaseUrl,
    required this.bearerToken,
  });
}

/// Builds a [ConstellationClient] from resolved credentials. Injectable so the
/// service can be exercised with a `package:http/testing.dart` MockClient.
typedef ConstellationClientFactory =
    ConstellationClient Function(ConstellationCredentials credentials);

/// Looks up shared-target listings from a hub. The browse payload is not pinned
/// field-for-field by the contract (it is left to the hub), so it is fetched
/// through this small seam rather than baked into [ConstellationClient]; the
/// production impl issues a `GET /v1/targets` read.
typedef SharedTargetBrowser =
    Future<List<SharedTarget>> Function(ConstellationClient client);

/// One user-captured light frame eligible for raw-subframe sharing.
///
/// [contributeRawSubs] streams exactly these FITS files. The resolver MUST
/// return only ACCEPTED LIGHT frames the user captured on this host — never a
/// community-pulled or calibration frame — so a SUBS contribution can only ever
/// leak the user's own pixels.
class RawSubframe {
  /// Absolute path to the calibrated FITS light on the host.
  final String filePath;

  /// The local captured-image row id (provenance the hub records).
  final int capturedImageId;

  /// Exposure of this frame in seconds (provenance).
  final double exposureSeconds;

  const RawSubframe({
    required this.filePath,
    required this.capturedImageId,
    required this.exposureSeconds,
  });
}

/// Resolves the user's own accepted light frames for a target into raw
/// subframes. Injected (the production wiring reads `ImagesDao
/// .getImagesForTarget`, filtered to accepted lights) so the service stays
/// DB-agnostic and testable. HOST-ONLY: a slave's local images table is empty,
/// so this returns nothing there and the SUBS path is a no-op.
typedef RawSubframeResolver = Future<List<RawSubframe>> Function(int targetId);

/// Result of contributing one target's atlas tiles to the hub.
class ContributionOutcome {
  /// Tiles successfully accepted by the hub (tileId -> receipt).
  final Map<int, ContributionReceipt> accepted;

  /// Tiles the hub rejected on geometry/order mismatch (tileId -> reason).
  final Map<int, String> rejected;

  /// The TRUE per-call frame delta actually pushed this contribution — the sum
  /// of `export.framesInDelta` across every accepted tile, NOT a tile count.
  /// Co-imaging combined accounting reports THIS so the headline depth equals
  /// what the fusion received (never a hardcoded +1 per accepted tile).
  final int framesPushed;

  /// The TRUE per-call integration-seconds delta actually pushed this
  /// contribution — the sum of `export.integrationSeconds` across accepted
  /// tiles. Pairs with [framesPushed] for honest combined accounting.
  final double integrationSecondsPushed;

  const ContributionOutcome({
    required this.accepted,
    required this.rejected,
    this.framesPushed = 0,
    this.integrationSecondsPushed = 0.0,
  });

  int get acceptedCount => accepted.length;
  int get rejectedCount => rejected.length;

  /// Total frames the hub reports across the tiles we just deepened.
  int get totalFramesContributed =>
      accepted.values.fold(0, (s, r) => s + r.totalFramesAfter);
}
